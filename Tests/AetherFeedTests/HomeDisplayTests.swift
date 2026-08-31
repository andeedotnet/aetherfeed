import Foundation
import GRDB
import Testing

@testable import AetherFeed

/// The home page has to show something from the first launch on: until a
/// category has been summarized it lists that category's newest articles,
/// and it swaps to topic cards one category at a time.
@Suite struct HomeDisplayTests {
    private func makeRepository() throws -> (Repository, DatabasePool) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherfeed-home-\(UUID().uuidString).sqlite").path
        let pool = try DatabasePool(path: path)
        try Migrations.migrator.migrate(pool)
        return (Repository(pool: pool), pool)
    }

    /// One feed per category; `count` articles each, oldest first so the
    /// newest carries the highest number.
    private func seed(
        _ names: [String], articlesEach count: Int, repository: Repository
    ) async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for (index, name) in names.enumerated() {
            let items = (0..<count).map { number in
                ParsedItem(
                    guid: "\(name)-\(number)", url: nil, title: "\(name) \(number)",
                    author: nil,
                    publishedAt: start.addingTimeInterval(Double(number) * 3600),
                    contentHTML: "<p>Inhalt \(name) \(number)</p>")
            }
            _ = try await repository.insertFeed(
                url: "https://example.com/\(index)",
                parsed: ParsedFeed(title: name, description: nil, siteURL: nil, items: items),
                categoryId: nil, newCategoryName: name, etag: nil, lastModified: nil)
        }
    }

    private func display(_ pool: DatabasePool) async throws -> DigestDisplay {
        try await pool.read { db in try DigestModel.fetchDisplay(db) }
    }

    @Test func withoutADigestEveryCategoryListsItsNewestArticles() async throws {
        let (repository, pool) = try makeRepository()
        try await seed(["Alpha", "Beta"], articlesEach: 5, repository: repository)

        let display = try await display(pool)
        #expect(display.sections.map(\.name) == ["Alpha", "Beta"])
        #expect(display.generatedAt == nil)
        #expect(display.overview.isEmpty)

        guard case .latest(let cards) = display.sections[0].content else {
            Issue.record("expected fallback cards")
            return
        }
        // Capped at three, newest first.
        #expect(cards.map(\.title) == ["Alpha 4", "Alpha 3", "Alpha 2"])
        #expect(cards[0].feedTitle == "Alpha")
        #expect(cards[0].snippet.contains("Inhalt Alpha 4"))
    }

    @Test func fallbackCardsLeaveOutAdvertorials() async throws {
        let (repository, pool) = try makeRepository()
        try await seed(["Alpha"], articlesEach: 4, repository: repository)

        let newestId = try await pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM article WHERE title = 'Alpha 3'")
        }
        try await repository.applyLLMResult(
            articleId: try #require(newestId), summary: nil, tags: [.advertising],
            isAdvertising: true, markRead: false)

        let display = try await display(pool)
        guard case .latest(let cards) = display.sections[0].content else {
            Issue.record("expected fallback cards")
            return
        }
        #expect(cards.map(\.title) == ["Alpha 2", "Alpha 1", "Alpha 0"])
    }

    /// The core of the progressive home page: a digest covering only one
    /// category turns exactly that one into topic cards.
    @Test func summarizedCategorySwapsToTopicsWhileTheRestKeepsArticles() async throws {
        let (repository, pool) = try makeRepository()
        try await seed(["Alpha", "Beta"], articlesEach: 3, repository: repository)

        let alphaId = try await pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM article WHERE title = 'Alpha 2'")
        }
        try await repository.saveDigest(
            DigestPayload(
                overview: "",
                sections: [
                    DigestPayload.Section(
                        category: "Alpha",
                        topics: [
                            DigestPayload.Topic(
                                headline: "H", summary: "S",
                                articleIds: [try #require(alphaId)])
                        ],
                        generatedAt: Date())
                ]),
            articleCount: 6, isPartial: true)

        let display = try await display(pool)
        #expect(display.isPartial)
        #expect(display.completionStamp == nil)
        #expect(display.sections.map(\.name) == ["Alpha", "Beta"])

        guard case .topics(let topics) = display.sections[0].content else {
            Issue.record("expected topic cards for Alpha")
            return
        }
        #expect(topics.map(\.headline) == ["H"])
        #expect(topics[0].id == "Alpha#0")
        #expect(topics[0].articles.map(\.title) == ["Alpha 2"])

        guard case .latest = display.sections[1].content else {
            Issue.record("expected Beta to still show articles")
            return
        }
    }

    /// A category whose feeds hold nothing would only add an empty heading.
    @Test func categoriesWithoutArticlesAreLeftOut() async throws {
        let (repository, pool) = try makeRepository()
        try await seed(["Alpha"], articlesEach: 2, repository: repository)
        try await pool.write { db in
            var empty = FeedCategory(name: "Leer", sortOrder: 99)
            try empty.insert(db)
        }

        let display = try await display(pool)
        #expect(display.sections.map(\.name) == ["Alpha"])
    }

    /// Renaming a category must not make its section vanish from the page
    /// before the next generation has caught up.
    @Test func sectionsOfARenamedCategoryStayVisible() async throws {
        let (repository, pool) = try makeRepository()
        try await seed(["Alpha"], articlesEach: 2, repository: repository)
        try await repository.saveDigest(
            DigestPayload(
                overview: "Überblick",
                sections: [
                    DigestPayload.Section(
                        category: "Alpha",
                        topics: [
                            DigestPayload.Topic(headline: "H", summary: "S", articleIds: [])
                        ],
                        generatedAt: Date())
                ]),
            articleCount: 2)

        let categoryId = try await pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM category WHERE name = 'Alpha'")
        }
        try await repository.renameCategory(id: try #require(categoryId), to: "Omega")

        let display = try await display(pool)
        #expect(display.overview == "Überblick")
        // The renamed category lists its articles again, the old section is
        // kept behind it instead of disappearing.
        #expect(display.sections.map(\.name) == ["Omega", "Alpha"])
        guard case .latest = display.sections[0].content,
              case .topics = display.sections[1].content
        else {
            Issue.record("expected fresh articles for Omega and the old section for Alpha")
            return
        }
    }
}
