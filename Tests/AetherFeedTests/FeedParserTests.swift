import Foundation
import Testing

@testable import AetherFeed

@Suite struct FeedParserTests {
    @Test func parsesRSS2() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
            <channel>
              <title>Test-Feed</title>
              <link>https://example.com</link>
              <description>Beschreibung</description>
              <item>
                <title>Erster Artikel</title>
                <link>https://example.com/1</link>
                <guid>artikel-1</guid>
                <pubDate>Mon, 20 Jul 2026 10:00:00 +0200</pubDate>
                <description>Kurz</description>
                <content:encoded><![CDATA[<p>Voller <b>Inhalt</b></p>]]></content:encoded>
              </item>
            </channel>
            </rss>
            """
        let parsed = try FeedParser.parse(data: Data(xml.utf8))
        #expect(parsed.title == "Test-Feed")
        #expect(parsed.siteURL == "https://example.com")
        #expect(parsed.items.count == 1)

        let item = try #require(parsed.items.first)
        #expect(item.guid == "artikel-1")
        #expect(item.url == "https://example.com/1")
        #expect(item.contentHTML == "<p>Voller <b>Inhalt</b></p>")
        #expect(item.publishedAt != nil)
    }

    @Test func parsesAtom() throws {
        let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <title>Atom-Feed</title>
              <link rel="alternate" href="https://example.org"/>
              <entry>
                <title>Eintrag</title>
                <id>tag:example.org,2026:1</id>
                <link rel="alternate" href="https://example.org/eintrag"/>
                <published>2026-07-20T10:00:00Z</published>
                <summary>Zusammenfassung</summary>
              </entry>
            </feed>
            """
        let parsed = try FeedParser.parse(data: Data(xml.utf8))
        #expect(parsed.title == "Atom-Feed")

        let item = try #require(parsed.items.first)
        #expect(item.guid == "tag:example.org,2026:1")
        #expect(item.url == "https://example.org/eintrag")
        #expect(item.contentHTML == "Zusammenfassung")
    }
}
