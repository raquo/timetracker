import Foundation

/// Removes the parts of a URL that we never record: they rarely say what's being worked on, and
/// they can carry secrets. Applied to every URL before it reaches the database (privacy is
/// enforced in the tracker, since a later cleanup can't un-write the file). See "URL fragments"
/// and "Sensitive data in URLs" in notes/PLAN.md.
///
/// - The fragment (`#…`): usually a position within the page (Notion's `#<block-id>`), which would
///   split rows, and sometimes a secret (`#access_token=…`). Except for apps that route by
///   fragment (`fragmentRoutedHosts`): there its first segment says which view is open, so we
///   keep that (Gmail `#inbox/<message-id>` → `#inbox`; the message is in the title anyway).
/// - User name and password (`https://user:pass@host/`).
/// - Query parameters whose name says they hold a secret (`?token=…`, `?code=…`, `X-Amz-Signature`)
///   or personal data (`?email=…`, `?login=…`), and any whose value contains an email address
///   (decoded repeatedly, so double encoding doesn't hide it). Other parameters stay, since some
///   say what's open (`?v=` on YouTube, `?q=` in searches).
/// - Path parameters under the same names (`/app;jsessionid=…`).
/// - The same, recursively, in URLs carried as parameter values (`?next=/verify?token=…`,
///   `?continue=https://…`): such a value is replaced by its scrubbed URL, re-encoded.
enum URLScrubber {
    /// Parameter names removed, in any spelling (see `LooseNamePattern`): secrets, and personal data.
    /// Not OAuth's `state`: a one-time nonce, not a secret, and GitHub uses it for views
    /// (`/issues?state=closed`).
    static let removedNames = LooseNamePattern(
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
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return scrub(components, original: url.absoluteString, depth: 0)
    }

    /// How deep URLs nested in parameter values are scrubbed. Deeper ones are left as they are
    /// (but a parameter holding an email address still goes).
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
        if components.user != nil || components.password != nil {
            components.user = nil
            components.password = nil
            isChanged = true
        }
        if let path = scrubPathParameters(components.percentEncodedPath) {
            components.percentEncodedPath = path
            isChanged = true
        }
        // Percent-encoded items, so the parameters we keep are written back exactly as they were.
        if let items = components.percentEncodedQueryItems {
            var kept: [URLQueryItem] = []
            for item in items where !removedNames.matches(item.name) {
                var value = item.value
                if let nested = value.flatMap({ scrubNestedURL($0, depth: depth) }) {
                    value = nested
                }
                if !isEmailAddress(value) {
                    kept.append(URLQueryItem(name: item.name, value: value))
                }
            }
            if kept != items {
                components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
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

    /// If the percent-encoded `value` is a URL (absolute, or a path starting with `/`) that
    /// scrubbing changes: the scrubbed URL, percent-encoded as a parameter value. Else nil.
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
        return scrubbed.addingPercentEncoding(withAllowedCharacters: unreservedCharacters)
    }

    /// `path` without the path parameters (`/app;jsessionid=…`, Java servers' session ID) whose
    /// name is removed, nil if there are none.
    private static func scrubPathParameters(_ path: String) -> String? {
        guard path.contains(";") else {
            return nil
        }
        var isChanged = false
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map { segment in
            let parts = segment.split(separator: ";", omittingEmptySubsequences: false)
            let kept = parts.dropFirst().filter { !removedNames.matches(String($0.prefix { $0 != "=" })) }
            if kept.count == parts.count - 1 {
                return String(segment)
            }
            isChanged = true
            return ([parts[0]] + kept).joined(separator: ";")
        }
        return isChanged ? segments.joined(separator: "/") : nil
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
