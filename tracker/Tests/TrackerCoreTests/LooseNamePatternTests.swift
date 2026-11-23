import Testing
@testable import TrackerCore

struct LooseNamePatternTests {
    @Test("Every spelling normalizes to the same name", arguments: [
        "accesskey", "access_key", "access-key", "access.key", "access key", "accessKey", "AccessKey",
        "ACCESS_KEY", "Access-Key", "access__key", "_access_key_", "access%5Fkey", "access%2Dkey", "access+key",
    ])
    func normalizes(spelling: String) {
        #expect(LooseNamePattern.normalize(spelling) == "accesskey")
    }

    @Test func normalizeKeepsLettersAndDigitsOnly() {
        #expect(LooseNamePattern.normalize("X-Amz-Signature") == "xamzsignature")
        #expect(LooseNamePattern.normalize("utm_source2") == "utmsource2")
        #expect(LooseNamePattern.normalize("Ünïcode_Näme") == "ünïcodenäme")
        #expect(LooseNamePattern.normalize("%") == "")
        #expect(LooseNamePattern.normalize("") == "")
    }

    @Test func rulesAreNormalizedToo() {
        let pattern = LooseNamePattern(exact: ["Login_Hint", "key"], containing: ["API-KEY", "api_key", "apiKey", "x_amz_"])
        #expect(pattern.exact == ["loginhint", "key"])
        #expect(pattern.containing == ["apikey", "xamz"])
    }

    private let pattern = LooseNamePattern(exact: ["key", "login_hint"], containing: ["api_key", "token"])

    @Test("Matches", arguments: [
        // Exact, any spelling.
        "key", "KEY", "Key", "_key", "key-", "login_hint", "loginHint", "LoginHint", "login-hint", "LOGIN_HINT", "loginhint",
        // Containing, any spelling, anywhere.
        "api_key", "apiKey", "x-api-key", "X-API-KEY", "xApiKey", "google_api_key_v2", "apikey",
        "token", "access_token", "accessToken", "csrfToken", "TOKEN_ID", "max_tokens",
        // A bracketed name's innermost key, raw or percent-encoded, exact or containing.
        "user[key]", "a[b][Login-Hint]", "user%5Bkey%5D", "form[api_key]", "key[]",
    ])
    func matches(name: String) {
        #expect(pattern.matches(name))
    }

    @Test("Doesn't match", arguments: [
        // A rule matched exactly isn't matched as a part.
        "keyword", "monkey", "keys", "key_id", "sort_key", "login", "hint", "login_hints",
        // Parts must appear whole.
        "api", "api_k", "tok", "tokn",
        // Only the innermost key, and only a trailing one.
        "key[name]", "a[key][b]", "user[keys]", "[key]x", "user[]", "user[",
        "", "q", "v",
    ])
    func doesntMatch(name: String) {
        #expect(!pattern.matches(name))
    }

    @Test func innermostKey() {
        #expect(LooseNamePattern.innermostKey("user[login]") == "login")
        #expect(LooseNamePattern.innermostKey("a[b][c]") == "c")
        #expect(LooseNamePattern.innermostKey("a%5Bb%5D") == "b")
        #expect(LooseNamePattern.innermostKey("a[]") == "")
        #expect(LooseNamePattern.innermostKey("a[b]c") == nil)
        #expect(LooseNamePattern.innermostKey("a]") == nil)
        #expect(LooseNamePattern.innermostKey("login") == nil)
    }
}
