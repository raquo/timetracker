import Foundation

/// Hides the parts of a URL that we never record: secrets and personal data. Values are
/// replaced with `redacted`, keeping the name, so the URL keeps its shape and says that a secret
/// was there (a sign-in or password reset link), like logging tools do (Rails' `[FILTERED]`,
/// OpenTelemetry's `REDACTED`). Applied to every URL before it reaches the database (privacy is
/// enforced in the tracker, since a later cleanup can't un-write the file). See "URL fragments"
/// and "Sensitive data in URLs" in notes/PLAN.md.
///
/// Dropped:
/// - The fragment (`#…`): usually a position within the page (Notion's `#<block-id>`), which would
///   split rows, and sometimes a secret (`#access_token=…`). Except for apps that route by
///   fragment (`fragmentRoutedHosts`): there its first segment says which view is open, so we
///   keep that (Gmail `#inbox/<message-id>` → `#inbox`; the message is in the title anyway).
///
/// Redacted:
/// - User name and password (`https://user:pass@host/` → `https://REDACTED:REDACTED@host/`).
/// - Values of query parameters whose name says they hold a secret (`?token=…`, `?code=…`,
///   `X-Amz-Signature`) or personal data (`?email=…`, `?login=…`), and values that contain an
///   email address (decoded repeatedly, so double encoding doesn't hide it). Other parameters
///   stay, since some say what's open (`?v=` on YouTube, `?q=` in searches). Empty values stay:
///   nothing to hide.
/// - Path parameters under the same names (`/app;jsessionid=…`), and parameters after a `;` in
///   a query value (`?a=1;token=…`: some servers split the query on `;` too).
/// - The same, recursively, in URLs carried as parameter values (`?next=/verify?token=…`,
///   `?continue=https://…`): such a value is replaced by its scrubbed URL, re-encoded.
/// - The content of a `data:` URL (`data:image/png;base64,…`): it's the page itself. Its media
///   type stays.
enum URLScrubber {
    /// What replaces a hidden value. Needs no percent-encoding.
    static let redacted = "REDACTED"

    /// Parameter names whose values are redacted, in any spelling (see `LooseNamePattern`): secrets, and personal data.
    /// Not OAuth's `state`: a one-time nonce, not a secret, and GitHub uses it for views
    /// (`/issues?state=closed`).
    static let redactedNames = LooseNamePattern(
        exact: [
            "code", "nonce", "otp", "ticket", "jwt", "sid", "auth", "authorization",
            "key", "sig", "hash", "hmac", "credential", "credentials",
            "pass", "passwd", "pwd", "saml_request", "saml_response", "relay_state",
            "policy", "key_pair_id",  // CloudFront signed URLs
            "subscription_key",
            // One-time codes under other names (Firebase's `oobCode`), OAuth 1.0a's verifier, card codes.
            "oob_code", "auth_code", "authorization_code", "verification_code", "verify_code",
            "confirmation_code", "activation_code", "reset_code", "access_code", "one_time_code",
            "otp_code", "mfa_code", "sms_code", "security_code", "oauth_verifier", "cvc", "cvv",
            // Who's signing in (WordPress `?login=`, OpenID `?login_hint=`).
            "login", "login_hint", "user_name",
        ],
        containing: [
            "token", "secret", "password", "signature", "session", "x_amz_", "x_goog_",
            "sess_id",  // PHPSESSID, ASPSESSID
            "api_key", "access_key", "private_key",
            "email",
        ]
    )

    static let fragmentRoutedHosts: Set<String> = ["mail.google.com"]

    /// nil when the URL can't be taken apart or put back together: then it isn't recorded at
    /// all, rather than recorded unscrubbed.
    static func scrub(_ url: URL) -> String? {
        if url.scheme?.lowercased() == "data" {
            return scrubDataURL(url.absoluteString)
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return scrub(components, original: url.absoluteString, depth: 0)
    }

    /// How deep URLs nested in parameter values are scrubbed. Deeper ones are left as they are
    /// (but a value holding an email address is still redacted).
    static let maxNestingDepth = 3

    /// `original`: `components` as a string, returned when nothing changes.
    private static func scrub(_ c: URLComponents, original: String, depth: Int) -> String? {
        var components = c
        var isChanged = false
        if let fragment = components.percentEncodedFragment {
            let kept = fragmentView(fragment, host: components.host)
            if kept != fragment {
                components.percentEncodedFragment = kept
                isChanged = true
            }
        }
        if components.user != nil {
            components.user = redacted
            isChanged = true
        }
        if components.password != nil {
            components.password = redacted
            isChanged = true
        }
        if let path = scrubPathParameters(components.percentEncodedPath) {
            components.percentEncodedPath = path
            isChanged = true
        }
        // Percent-encoded items, so everything else is written back exactly as it was.
        if let items = components.percentEncodedQueryItems {
            let scrubbed = items.map { item in
                URLQueryItem(name: item.name, value: scrubValue(item.value, name: item.name, depth: depth))
            }
            if scrubbed != items {
                components.percentEncodedQueryItems = scrubbed
                isChanged = true
            }
        }
        if isChanged {
            return components.string
        }
        else {
            return original
        }
    }

    /// A percent-encoded query parameter value, scrubbed: redacted if `name` says it's secret
    /// or it contains an email address, a nested URL scrubbed. Empty values stay.
    private static func scrubValue(_ value: String?, name: String, depth: Int) -> String? {
        guard let value, !value.isEmpty else {
            return value
        }
        if redactedNames.matches(name) {
            return redacted
        }
        if let nested = scrubNestedURL(value, depth: depth) {
            return nested
        }
        if isEmailAddress(value) {
            return redacted
        }
        return scrubParameters(Substring(value))
    }

    /// `data:<media type>,<content>` → `data:<media type>,REDACTED`. Empty content stays. nil
    /// without the comma: not a data URL we can take apart.
    private static func scrubDataURL(_ url: String) -> String? {
        guard let comma = url.firstIndex(of: ",") else {
            return nil
        }
        let header = url[...comma]
        return url.index(after: comma) == url.endIndex ? url : header + redacted
    }

    /// If the percent-encoded `value` is a URL (absolute, or a path starting with `/`) that
    /// scrubbing changes: the scrubbed URL, percent-encoded as a parameter value, or redacted if
    /// an email address is left in it (in its path). Else nil.
    private static func scrubNestedURL(_ value: String, depth: Int) -> String? {
        guard depth < maxNestingDepth, let decoded = value.removingPercentEncoding, decoded.hasPrefix("/") || decoded.contains("://") else {
            return nil
        }
        guard let inner = URLComponents(string: decoded), inner.scheme != nil || decoded.hasPrefix("/") else {
            return nil
        }
        guard let scrubbed = scrub(inner, original: decoded, depth: depth + 1), scrubbed != decoded else {
            return nil
        }
        // Not the redacted user info: `REDACTED@host` looks like an email address.
        var withoutUser = URLComponents(string: scrubbed)
        withoutUser?.user = nil
        withoutUser?.password = nil
        if isEmailAddress(withoutUser?.string ?? scrubbed) {
            return redacted
        }
        return scrubbed.addingPercentEncoding(withAllowedCharacters: unreservedCharacters)
    }

    /// `path` with the values of path parameters (`/app;jsessionid=…`, Java servers' session ID)
    /// under redacted names redacted, nil if there are none.
    private static func scrubPathParameters(_ path: String) -> String? {
        guard path.contains(";") else {
            return nil
        }
        let scrubbed = path.split(separator: "/", omittingEmptySubsequences: false).map(scrubParameters).joined(separator: "/")
        return scrubbed == path ? nil : scrubbed
    }

    /// `text` with the values of its `;name=value` parameters under redacted names redacted.
    /// What's before the first `;` stays.
    private static func scrubParameters(_ text: Substring) -> String {
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        let scrubbed = [String(parts[0])] + parts.dropFirst().map { part in
            let name = part.prefix { $0 != "=" }
            let value = part.dropFirst(name.count + 1)
            return value.isEmpty || !redactedNames.matches(String(name)) ? String(part) : "\(name)=\(redacted)"
        }
        return scrubbed.joined(separator: ";")
    }

    /// RFC 3986 unreserved characters: everything else is percent-encoded in a nested URL.
    private static let unreservedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The part of the fragment we keep: for fragment-routed hosts its first segment, if it's a
    /// plain word (not `access_token=…`); otherwise nothing.
    private static func fragmentView(_ fragment: String, host: String?) -> String? {
        guard let host, fragmentRoutedHosts.contains(host.lowercased()) else {
            return nil
        }
        let view = fragment.prefix { $0 != "/" && $0 != "?" }
        guard !view.isEmpty, view.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        return String(view)
    }

    /// A percent-encoded parameter value that contains an email address (`alice%40example.com`,
    /// or within a search like `q=mail+bob@example.com`). Decoded up to `maxNestingDepth + 1`
    /// times, so an address encoded twice inside a nested URL (`alice%2540example.com`) counts too.
    static func isEmailAddress(_ value: String?) -> Bool {
        guard var text = value?.replacingOccurrences(of: "+", with: " ") else {
            return false
        }
        for _ in 0...maxNestingDepth {
            if text.range(of: #"[^\s@]+@[^\s@]+\.[A-Za-z]{2,}"#, options: .regularExpression) != nil {
                return true
            }
            guard let decoded = text.removingPercentEncoding, decoded != text else {
                return false
            }
            text = decoded
        }
        return false
    }

}
