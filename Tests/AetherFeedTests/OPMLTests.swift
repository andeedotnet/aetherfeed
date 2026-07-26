import Foundation
import Testing

@testable import AetherFeed

@Suite struct OPMLTests {
    @Test func parsesNestedOutlines() throws {
        let opml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
            <head><title>Abo</title></head>
            <body>
              <outline text="Tech">
                <outline type="rss" text="heise" xmlUrl="https://heise.de/rss.xml" htmlUrl="https://heise.de"/>
                <outline type="rss" title="Golem" xmlUrl="https://golem.de/rss.xml"/>
              </outline>
              <outline type="rss" text="tagesschau" xmlUrl="https://tagesschau.de/rss"/>
            </body>
            </opml>
            """
        let entries = try OPMLImporter.parse(data: Data(opml.utf8))
        #expect(entries.count == 3)
        #expect(entries[0] == OPMLEntry(title: "heise", url: "https://heise.de/rss.xml", category: "Tech"))
        #expect(entries[1] == OPMLEntry(title: "Golem", url: "https://golem.de/rss.xml", category: "Tech"))
        #expect(entries[2] == OPMLEntry(title: "tagesschau", url: "https://tagesschau.de/rss", category: nil))
    }

    @Test func exportRoundTrips() throws {
        let categories = [FeedCategory(id: 1, name: "Nachrichten & \"Meinung\"")]
        let feeds = [
            Feed(id: 1, url: "https://a.de/rss", title: "A-Feed", siteURL: "https://a.de",
                 categoryId: 1, createdAt: Date()),
            Feed(id: 2, url: "https://b.de/rss", title: "B <Feed>", createdAt: Date()),
        ]
        let opml = OPMLExporter.build(categories: categories, feeds: feeds)
        let reparsed = try OPMLImporter.parse(data: Data(opml.utf8))
        #expect(reparsed.count == 2)
        #expect(reparsed[0].category == "Nachrichten & \"Meinung\"")
        #expect(reparsed[0].url == "https://a.de/rss")
        #expect(reparsed[1].title == "B <Feed>")
        #expect(reparsed[1].category == nil)
    }
}
