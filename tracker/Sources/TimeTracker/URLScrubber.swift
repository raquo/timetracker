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
/// - Query parameters whose name says they hold a secret (`?token=…`, `?code=…`, `X-Amz-Signature`).
///   Other parameters stay, since some say what's open (`?v=` on YouTube, `?q=` in searches).
enum URLScrubber {
    /// Parameter names (lowercased) removed exactly. Not OAuth's `state`: a one-time nonce, not a
    /// secret, and GitHub uses it for views (`/issues?state=closed`).
    static let secretNames: Set<String> = [
        "code", "nonce", "otp", "ticket", "jwt", "sid", "auth", "authorization",
        "key", "apikey", "api_key", "api-key", "sig", "hash", "hmac", "credential", "credentials",
        "pass", "passwd", "pwd", "samlrequest", "samlresponse", "relaystate",
        "policy", "key-pair-id",  // CloudFront signed URLs
    ]

    /// Parameter names (lowercased) removed when they contain one of these.
    static let secretParts = ["token", "secret", "password", "signature", "session", "x-amz-", "x-goog-"]

    static let fragmentRoutedHosts: Set<String> = ["mail.google.com"]

    /// nil when the URL can't be taken apart or put back together: then it isn't recorded at
    /// all, rather than recorded unscrubbed.
    static func scrub(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
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
        // Percent-encoded items, so the parameters we keep are written back exactly as they were.
        if let items = components.percentEncodedQueryItems {
            let kept = items.filter { !isSecret($0.name) }
            if kept.count != items.count {
                components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
                isChanged = true
            }
        }
        if isChanged {
            return components.string
        }
        else {
            return url.absoluteString
        }
    }

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

    static func isSecret(_ name: String) -> Bool {
        let lowercased = (name.removingPercentEncoding ?? name).lowercased()
        return secretNames.contains(lowercased) || secretParts.contains { lowercased.contains($0) }
    }
}
