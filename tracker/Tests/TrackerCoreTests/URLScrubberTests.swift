import Foundation
import Testing
@testable import TrackerCore

struct URLScrubberTests {
    @Test(arguments: [
        ("https://example.com/page#section", "https://example.com/page"),
        ("https://mail.google.com/mail/u/0/#inbox/FMfcgz", "https://mail.google.com/mail/u/0/#inbox"),
        ("https://user:pass@example.com/", "https://example.com/"),
        ("https://example.com/?q=keep&access_token=secret", "https://example.com/?q=keep"),
        ("https://example.com/?v=abc", "https://example.com/?v=abc"),
    ])
    func scrubs(input: String, expected: String) {
        #expect(URLScrubber.scrub(URL(string: input)!) == expected)
    }
}
