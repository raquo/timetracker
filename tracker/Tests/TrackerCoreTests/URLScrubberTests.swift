import Foundation
import Testing
@testable import TrackerCore

/// Every case states the exact string stored, so any change in what's kept, dropped, redacted or
/// re-encoded shows up.
struct URLScrubberTests {
    private func scrub(_ s: String) -> String? {
        URLScrubber.scrub(URL(string: s)!)
    }

    @Test("Fragments are dropped", arguments: [
        // Notion: a block within the page.
        ("https://www.notion.so/Team-Wiki-41a8a3be18da8001829ed285a3de678f#1f2a3b4c5d6e7f80", "https://www.notion.so/Team-Wiki-41a8a3be18da8001829ed285a3de678f"),
        // A heading anchor.
        ("https://developer.mozilla.org/en-US/docs/Web/API/URL#instance_properties", "https://developer.mozilla.org/en-US/docs/Web/API/URL"),
        // OAuth implicit flow: the token is in the fragment.
        ("https://app.example.com/callback#access_token=ya29.a0AfB&token_type=Bearer&expires_in=3599", "https://app.example.com/callback"),
        // Hash routing outside the fragment-routed hosts.
        ("https://app.example.com/#/settings/profile", "https://app.example.com/"),
        // Google Docs heading; the query stays.
        ("https://docs.google.com/document/d/1AbCdEf/edit?tab=t.0#heading=h.abc123", "https://docs.google.com/document/d/1AbCdEf/edit?tab=t.0"),
        // An empty fragment.
        ("https://example.com/page#", "https://example.com/page"),
        // Other Google apps aren't fragment-routed.
        ("https://calendar.google.com/calendar/u/0/r#main", "https://calendar.google.com/calendar/u/0/r"),
        // Only the exact host is fragment-routed.
        ("https://mail.google.com.example.net/#inbox/FMfcgz", "https://mail.google.com.example.net/"),
        // Any scheme.
        ("file:///Users/someone/report.html#section-2", "file:///Users/someone/report.html"),
    ])
    func dropsFragments(input: String, expected: String) {
        #expect(scrub(input) == expected)
    }

    @Test("Gmail keeps the view, nothing after it", arguments: [
        ("https://mail.google.com/mail/u/0/#inbox", "https://mail.google.com/mail/u/0/#inbox"),
        ("https://mail.google.com/mail/u/0/#inbox/FMfcgzQXJWDsKTnTdpjsHVSHWbbNTRvq", "https://mail.google.com/mail/u/0/#inbox"),
        ("https://mail.google.com/mail/u/1/#sent/QgrcJHrnxyz", "https://mail.google.com/mail/u/1/#sent"),
        // The search terms and label names are private; the view isn't.
        ("https://mail.google.com/mail/u/0/#search/from%3Aalice+invoice", "https://mail.google.com/mail/u/0/#search"),
        ("https://mail.google.com/mail/u/0/#label/Work%2FProjects/FMfcgz", "https://mail.google.com/mail/u/0/#label"),
        ("https://mail.google.com/mail/u/0/#settings/general", "https://mail.google.com/mail/u/0/#settings"),
        ("https://mail.google.com/mail/u/0/#inbox?compose=new", "https://mail.google.com/mail/u/0/#inbox"),
        ("https://mail.google.com/mail/u/0/#all-mail_x/abc", "https://mail.google.com/mail/u/0/#all-mail_x"),
        // Host compared case-insensitively, and kept as written.
        ("https://MAIL.GOOGLE.COM/mail/u/0/#inbox/FMfcgz", "https://MAIL.GOOGLE.COM/mail/u/0/#inbox"),
        // Not a plain word: nothing kept.
        ("https://mail.google.com/mail/u/0/#access_token=abc", "https://mail.google.com/mail/u/0/"),
        ("https://mail.google.com/mail/u/0/#%69nbox", "https://mail.google.com/mail/u/0/"),
        ("https://mail.google.com/mail/u/0/#/inbox", "https://mail.google.com/mail/u/0/"),
        ("https://mail.google.com/mail/u/0/#", "https://mail.google.com/mail/u/0/"),
    ])
    func gmail(input: String, expected: String) {
        #expect(scrub(input) == expected)
    }

    @Test("User name and password are redacted", arguments: [
        ("https://user:pass@example.com/", "https://REDACTED:REDACTED@example.com/"),
        ("https://alice@git.example.com/repo", "https://REDACTED@git.example.com/repo"),
        ("ftp://anonymous:guest@ftp.example.com/pub/file.txt", "ftp://REDACTED:REDACTED@ftp.example.com/pub/file.txt"),
        // Port, query and the rest stay.
        ("https://admin:hunter2@localhost:8080/dashboard?tab=1", "https://REDACTED:REDACTED@localhost:8080/dashboard?tab=1"),
    ])
    func redactsUserInfo(input: String, expected: String) {
        #expect(scrub(input) == expected)
    }

    @Test("Secret values are redacted, the rest kept as written", arguments: [
        // Zoom meeting password.
        ("https://us02web.zoom.us/j/81234567890?pwd=aBcDeFgHiJkLmNoPqRsTuVwXyZ.1", "https://us02web.zoom.us/j/81234567890?pwd=REDACTED"),
        // OAuth callback: the code goes, state and scope stay, still percent-encoded.
        ("https://app.example.com/oauth/callback?code=4%2F0AfJohX&state=xyz123&scope=email%20profile", "https://app.example.com/oauth/callback?code=REDACTED&state=xyz123&scope=email%20profile"),
        // S3 presigned URL: every X-Amz- parameter goes.
        ("https://bucket.s3.us-east-1.amazonaws.com/report.pdf?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIA%2F20261123%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20261123T000000Z&X-Amz-Expires=3600&X-Amz-SignedHeaders=host&X-Amz-Signature=abcdef0123", "https://bucket.s3.us-east-1.amazonaws.com/report.pdf?X-Amz-Algorithm=REDACTED&X-Amz-Credential=REDACTED&X-Amz-Date=REDACTED&X-Amz-Expires=REDACTED&X-Amz-SignedHeaders=REDACTED&X-Amz-Signature=REDACTED"),
        // Google Cloud Storage signed URL.
        ("https://storage.googleapis.com/bucket/file.csv?X-Goog-Algorithm=GOOG4-RSA-SHA256&X-Goog-Credential=sa%40p.iam&X-Goog-Date=20261123T000000Z&X-Goog-Expires=900&X-Goog-SignedHeaders=host&X-Goog-Signature=ab12", "https://storage.googleapis.com/bucket/file.csv?X-Goog-Algorithm=REDACTED&X-Goog-Credential=REDACTED&X-Goog-Date=REDACTED&X-Goog-Expires=REDACTED&X-Goog-SignedHeaders=REDACTED&X-Goog-Signature=REDACTED"),
        // CloudFront signed URL: Expires isn't secret.
        ("https://d111111abcdef8.cloudfront.net/video.mp4?Expires=1800000000&Signature=abc~def&Key-Pair-Id=K2JCJMDEHXQW5F", "https://d111111abcdef8.cloudfront.net/video.mp4?Expires=1800000000&Signature=REDACTED&Key-Pair-Id=REDACTED"),
        ("https://d111111abcdef8.cloudfront.net/video.mp4?Policy=eyJTdGF0&Signature=abc&Key-Pair-Id=K2J", "https://d111111abcdef8.cloudfront.net/video.mp4?Policy=REDACTED&Signature=REDACTED&Key-Pair-Id=REDACTED"),
        // Azure SAS: only the signature goes.
        ("https://acct.blob.core.windows.net/c/file.txt?sv=2022-11-02&sp=r&se=2026-12-01T00:00:00Z&sig=abc%3D", "https://acct.blob.core.windows.net/c/file.txt?sv=2022-11-02&sp=r&se=2026-12-01T00:00:00Z&sig=REDACTED"),
        // Password reset and magic links.
        ("https://accounts.example.com/reset?reset_password_token=abc123", "https://accounts.example.com/reset?reset_password_token=REDACTED"),
        ("https://kagi.com/search?token=abc.def&q=swift+testing", "https://kagi.com/search?token=REDACTED&q=swift+testing"),
        ("https://app.example.com/invite?invite_token=abc&team=design", "https://app.example.com/invite?invite_token=REDACTED&team=design"),
        ("https://example.com/sso?SAMLResponse=PHNhbWw%3D&RelayState=%2Fhome", "https://example.com/sso?SAMLResponse=REDACTED&RelayState=REDACTED"),
        ("https://example.com/api/data?client_id=web&client_secret=s3cr3t", "https://example.com/api/data?client_id=web&client_secret=REDACTED"),
        ("https://maps.googleapis.com/maps/api/js?key=AIzaSyA&callback=initMap", "https://maps.googleapis.com/maps/api/js?key=REDACTED&callback=initMap"),
        ("https://example.com/docs?session_id=abc&page=2#intro", "https://example.com/docs?session_id=REDACTED&page=2"),
        ("https://example.com/verify?otp=123456&nonce=n1&jwt=eyJ&sid=s1&ticket=ST-1&hmac=h&hash=d41d", "https://example.com/verify?otp=REDACTED&nonce=REDACTED&jwt=REDACTED&sid=REDACTED&ticket=REDACTED&hmac=REDACTED&hash=REDACTED"),
        ("https://example.com/x?auth=a&authorization=b&apikey=c&api_key=d&api-key=e&credential=f&credentials=g&pass=h&passwd=i&pwd=j&samlrequest=k&relaystate=l", "https://example.com/x?auth=REDACTED&authorization=REDACTED&apikey=REDACTED&api_key=REDACTED&api-key=REDACTED&credential=REDACTED&credentials=REDACTED&pass=REDACTED&passwd=REDACTED&pwd=REDACTED&samlrequest=REDACTED&relaystate=REDACTED"),
        // Session IDs, and keys, under other names.
        ("https://shop.example.com/cart.php?PHPSESSID=abc123&item=4", "https://shop.example.com/cart.php?PHPSESSID=REDACTED&item=4"),
        ("https://api.example.com/v1/data?access_key=AKIA123&format=json", "https://api.example.com/v1/data?access_key=REDACTED&format=json"),
        ("https://api.example.com/v1/data?x-api-key=abc&private_key=def&subscription-key=ghi&format=json", "https://api.example.com/v1/data?x-api-key=REDACTED&private_key=REDACTED&subscription-key=REDACTED&format=json"),
        // WordPress password reset: the key and who it's for.
        ("https://shop.example.com/wp-login.php?action=rp&key=Xk3pQ9&login=alice&wp_lang=en_US", "https://shop.example.com/wp-login.php?action=rp&key=REDACTED&login=REDACTED&wp_lang=en_US"),
        // Personal data by name.
        ("https://app.example.com/login?email=alice%40example.com&token=abc", "https://app.example.com/login?email=REDACTED&token=REDACTED"),
        ("https://accounts.example.com/o/oauth2/auth?client_id=web&login_hint=alice%40example.com&prompt=consent", "https://accounts.example.com/o/oauth2/auth?client_id=web&login_hint=REDACTED&prompt=consent"),
        ("https://app.example.com/signup?user_email=a&e-mail=b&username=c&ref=home", "https://app.example.com/signup?user_email=REDACTED&e-mail=REDACTED&username=REDACTED&ref=home"),
        // An email address in any value, encoded or not, whole or within a search.
        ("https://example.com/share?u=alice@example.com&v=2", "https://example.com/share?u=REDACTED&v=2"),
        ("https://www.google.com/search?q=email+bob%40example.co.uk+invoice&hl=en", "https://www.google.com/search?q=REDACTED&hl=en"),
        // One-time codes under other names, OAuth 1.0a's verifier, card codes.
        ("https://myapp.firebaseapp.com/__/auth/action?mode=resetPassword&oobCode=ABC123&apiKey=k&lang=en", "https://myapp.firebaseapp.com/__/auth/action?mode=resetPassword&oobCode=REDACTED&apiKey=REDACTED&lang=en"),
        ("https://example.com/x?auth_code=a&authorizationCode=b&verification_code=c&confirmationCode=d&oauth_verifier=e&otp_code=f&cvc=1&CVV=2&page=2", "https://example.com/x?auth_code=REDACTED&authorizationCode=REDACTED&verification_code=REDACTED&confirmationCode=REDACTED&oauth_verifier=REDACTED&otp_code=REDACTED&cvc=REDACTED&CVV=REDACTED&page=2"),
        // "password" on its own.
        ("https://example.com/account?new_password=hunter2&tab=security", "https://example.com/account?new_password=REDACTED&tab=security"),
        ("https://example.com/account?Password=x&ok=1", "https://example.com/account?Password=REDACTED&ok=1"),
        // A URL in a parameter is scrubbed by the same rules and re-encoded.
        ("https://example.com/login?next=%2Fverify%3Femail%3Dalice%2540example.com%26token%3Dsecret", "https://example.com/login?next=%2Fverify%3Femail%3DREDACTED%26token%3DREDACTED"),
        ("https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmail.google.com%2Fmail%2Fu%2F0%2F%23inbox%2FFMfcg&service=mail", "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmail.google.com%2Fmail%2Fu%2F0%2F%23inbox&service=mail"),
        ("https://example.com/sso?redirect_uri=https://bob:pw@app.example.com/cb?state=1%26code=2", "https://example.com/sso?redirect_uri=https%3A%2F%2FREDACTED%3AREDACTED%40app.example.com%2Fcb%3Fstate%3D1%26code%3DREDACTED"),
        // A protocol-relative URL in a parameter.
        ("https://example.com/login?next=//cdn.example.com/cb%3Ftoken%3D1%26x%3D2", "https://example.com/login?next=%2F%2Fcdn.example.com%2Fcb%3Ftoken%3DREDACTED%26x%3D2"),
        // Nested twice.
        ("https://example.com/?a=https%3A%2F%2Fx.com%2F%3Fb%3Dhttps%253A%252F%252Fy.com%252F%253Ftoken%253Dt%2526k%253D1", "https://example.com/?a=https%3A%2F%2Fx.com%2F%3Fb%3Dhttps%253A%252F%252Fy.com%252F%253Ftoken%253DREDACTED%2526k%253D1"),
        // An email address encoded twice.
        ("https://example.com/?ref=alice%2540example.com&x=1", "https://example.com/?ref=REDACTED&x=1"),
        // Any spelling: case, snake_case, kebab-case, camelCase, run together.
        ("https://example.com/?accessKey=1&AccessKey=2&ACCESS-KEY=3&access.key=4&accesskey=5&x=1", "https://example.com/?accessKey=REDACTED&AccessKey=REDACTED&ACCESS-KEY=REDACTED&access.key=REDACTED&accesskey=REDACTED&x=1"),
        ("https://example.com/?xApiKey=1&phpSessId=2&emailAddress=3&userName=4&loginHint=5&keyPairId=6&SAML_Response=7&x=1", "https://example.com/?xApiKey=REDACTED&phpSessId=REDACTED&emailAddress=REDACTED&userName=REDACTED&loginHint=REDACTED&keyPairId=REDACTED&SAML_Response=REDACTED&x=1"),
        // Names compared case-insensitively, and after percent-decoding.
        ("https://example.com/?Token=a&API_KEY=b&q=1", "https://example.com/?Token=REDACTED&API_KEY=REDACTED&q=1"),
        ("https://example.com/?access%5Ftoken=abc&q=1", "https://example.com/?access%5Ftoken=REDACTED&q=1"),
        // Names containing a secret part, even harmless ones.
        ("https://example.com/llm?model=m&max_tokens=100", "https://example.com/llm?model=m&max_tokens=REDACTED"),
        // The rest stays byte for byte: encoding, '+', order, repeats, no value, empty value.
        ("https://www.google.com/search?q=caf%C3%A9+au+lait&hl=en&key=xyz&sca_esv=abc", "https://www.google.com/search?q=caf%C3%A9+au+lait&hl=en&key=REDACTED&sca_esv=abc"),
        ("https://example.com/?tag=a&token=x&tag=b", "https://example.com/?tag=a&token=REDACTED&tag=b"),
        ("https://example.com/?debug&token=x&empty=", "https://example.com/?debug&token=REDACTED&empty="),
        // Only secrets.
        ("https://example.com/api?api_key=abc&sig=def", "https://example.com/api?api_key=REDACTED&sig=REDACTED"),
        // The path stays encoded.
        ("https://example.com/My%20Docs/file?token=1", "https://example.com/My%20Docs/file?token=REDACTED"),
        // Path parameters under redacted names (Java servers' session ID); others stay, and so
        // does a secret name without a value.
        ("https://shop.example.com/store/cart;jsessionid=0A1B2C3D4E?item=4", "https://shop.example.com/store/cart;jsessionid=REDACTED?item=4"),
        ("https://shop.example.com/a;JSESSIONID=X;lang=en/b;token=t;v=2/c;sid", "https://shop.example.com/a;JSESSIONID=REDACTED;lang=en/b;token=REDACTED;v=2/c;sid"),
        // Empty values have nothing to hide.
        ("https://example.com/?token=&code&x=1&sig=abc", "https://example.com/?token=&code&x=1&sig=REDACTED"),
        ("https://example.com/a;jsessionid=;token=t", "https://example.com/a;jsessionid=;token=REDACTED"),
        // An email address left in a nested URL's path: the whole value is redacted. Its
        // redacted user info doesn't count as one.
        ("https://example.com/r?next=%2Fu%2Falice%40example.com%2Fprofile&x=1", "https://example.com/r?next=REDACTED&x=1"),
        ("https://example.com/r?next=%2Fu%2Falice%40example.com%3Ftoken%3Dt&x=1", "https://example.com/r?next=REDACTED&x=1"),
        ("https://example.com/r?next=https%3A%2F%2Falice%40example.com%2F", "https://example.com/r?next=https%3A%2F%2FREDACTED%40example.com%2F"),
        // Everything at once.
        ("https://bob:pw@app.example.com/p/1?view=grid&token=t#row-5", "https://REDACTED:REDACTED@app.example.com/p/1?view=grid&token=REDACTED"),
    ])
    func redactsSecretValues(input: String, expected: String) {
        #expect(scrub(input) == expected)
    }

    @Test("URLs with nothing to remove come back exactly as given", arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf&index=3&t=42s",
        "https://www.youtube.com/results?search_query=swift+testing",
        "https://github.com/swiftlang/swift-testing/issues?q=is%3Aopen+label%3Abug&state=closed",
        "https://app.notion.com/p/41a8a3be18da8001829ed285a3de678f?v=1a2b3c&p=4d5e6f&pm=s",
        "https://news.ycombinator.com/item?id=50560563",
        "https://app.slack.com/client/T01ABCDEF/C02GHIJKL",
        "https://claude.ai/chat/1f2e3d4c-5b6a-7980-a1b2-c3d4e5f60718",
        // Exact names, not parts: these aren't secret.
        "https://example.com/?keyword=swift&monkey=1&passage=3&codec=h264&hashtag=x&signup=1&author=bob&authuser=1&state=open",
        // Harmless codes.
        "https://example.com/checkout?country_code=CA&zipcode=V6B1A1&promo_code=FALL&lang_code=en&codec=h264",
        // Nested URLs with nothing to remove stay byte for byte, encoded or not.
        "https://example.com/login?next=%2Fdashboard%3Ftab%3D2&x=1",
        "https://example.com/login?return_to=/settings/profile",
        "https://example.com/r?u=https://news.ycombinator.com/item?id=1",
        // Path parameters with other names, and protocol-relative nested URLs.
        "https://example.com/a;v=1/b;lang=en;x?page=2",
        "https://example.com/login?next=//cdn.example.com/cb%3Fx%3D2",
        // '+' is a space: "from @nytimes.com" has no address.
        "https://x.com/search?q=from+%40nytimes.com",
        // An @ without a domain isn't an email address.
        "https://x.com/search?q=%40raquo&src=typed_query",
        "https://example.com/?q=a@b",
        // Shapes seen in real use.
        "https://calendar.google.com/calendar/u/1/r/week/2026/11/25?ctz=America/Vancouver&hl=en_GB&es=1&csspa=1",
        "https://meet.google.com/abc-defg-hij?hs=224",
        "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcdEf/edit?tab=t.0",
        "https://shop.example.com/my-account/lost-password/?show-reset-form=true&action",
        "https://us05web.zoom.us/j/81234567890",
        // Tracking parameters aren't secret, so they stay.
        "https://example.com/article?utm_source=newsletter&utm_medium=email&utm_campaign=nov&fbclid=IwAR0abc&gclid=Cj0K",
        // Not normalized: dot segments, case, default port, trailing '?'.
        "HTTPS://Example.COM:443/a/./b/../c?",
        "about:blank",
        "vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-sandbox/workbench/workbench.html",
    ])
    func keepsCleanURLs(input: String) {
        #expect(scrub(input) == input)
    }
}
