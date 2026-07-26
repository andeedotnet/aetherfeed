import Testing
import WebKit

@testable import AetherFeed

@Suite struct AdblockConverterTests {
    @Test func convertsAnchoredDomainToBlockRule() throws {
        let result = AdblockConverter.convert("||ads.example.com^")
        #expect(result.rules.count == 1)
        let rule = try #require(result.rules.first)
        #expect(rule.action.type == "block")
        #expect(rule.trigger.urlFilter == "^https?://([^/]*\\.)?ads\\.example\\.com[:/]")
    }

    @Test func exceptionBecomesIgnorePreviousRules() throws {
        let result = AdblockConverter.convert("@@||good.example.com^")
        let rule = try #require(result.rules.first)
        #expect(rule.action.type == "ignore-previous-rules")
    }

    @Test func skipsCommentsHeadersAndCosmetic() {
        let text = """
            ! Title: Test list
            [Adblock Plus 2.0]
            example.com##.banner
            example.org#@#.ad

            ||tracker.net^
            """
        let result = AdblockConverter.convert(text)
        // Only the network rule survives.
        #expect(result.rules.count == 1)
        #expect(result.rules.first?.trigger.urlFilter.contains("tracker\\.net") == true)
    }

    @Test func ignoresOptionsAndParsesHostsStyle() {
        let block = AdblockConverter.convert("||ad.example.com^$third-party,image")
        #expect(block.rules.count == 1)

        let hosts = AdblockConverter.convert("0.0.0.0 doubleclick.net")
        #expect(hosts.rules.count == 1)
        #expect(hosts.rules.first?.trigger.urlFilter.contains("doubleclick\\.net") == true)
    }

    @Test func filterDoesNotMatchPartialWords() {
        // The regex must anchor at a dot so "mydomain.com" ≠ "domain.com".
        let filter = AdblockConverter.urlFilter(for: "domain.com")
        #expect(filter == "^https?://([^/]*\\.)?domain\\.com[:/]")
    }

    /// End-to-end: converted JSON must be accepted by WebKit's compiler,
    /// which validates the url-filter regex.
    @MainActor
    @Test func compiledRuleListIsAcceptedByWebKit() async throws {
        let result = AdblockConverter.convert(
            """
            ||ads.example.com^
            @@||safe.example.com^
            0.0.0.0 tracker.example.net
            """)
        let json = try AdblockConverter.json(for: result.rules)
        let store = try #require(WKContentRuleListStore.default())
        let identifier = "aetherfeed-test-adblock"
        let list = try await store.compileContentRuleList(
            forIdentifier: identifier, encodedContentRuleList: json)
        #expect(list != nil)
        try? await store.removeContentRuleList(forIdentifier: identifier)
    }
}
