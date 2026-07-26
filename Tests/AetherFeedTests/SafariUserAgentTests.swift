import Testing

@testable import AetherFeed

@Suite struct SafariUserAgentTests {
    @Test func looksLikeARealSafariUserAgent() {
        let ua = SafariUserAgent.value
        #expect(ua.hasPrefix("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"))
        #expect(ua.contains("AppleWebKit/605.1.15 (KHTML, like Gecko)"))
        #expect(ua.contains("Version/"))
        #expect(ua.hasSuffix("Safari/605.1.15"))
        // No hint of the app itself.
        #expect(!ua.localizedCaseInsensitiveContains("aetherfeed"))
    }

    @Test func acceptLanguageIsBrowserStyle() {
        let value = SafariUserAgent.acceptLanguage
        #expect(!value.isEmpty)
        #expect(!value.hasPrefix(";"))
    }
}
