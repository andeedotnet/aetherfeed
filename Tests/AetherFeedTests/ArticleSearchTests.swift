import Foundation
import GRDB
import Testing

@testable import AetherFeed

@Suite struct ArticleSearchTests {
    private func makeRepository() throws -> (Repository, DatabasePool) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherfeed-search-\(UUID().uuidString).sqlite").path
        let pool = try DatabasePool(path: path)
        try Migrations.migrator.migrate(pool)
        return (Repository(pool: pool), pool)
    }

    /// One feed per category, each with an article mentioning "Quartalszahlen".
    private func seed(_ repository: Repository) async throws {
        for name in ["Wirtschaft", "Technik"] {
            let items = [
                ParsedItem(
                    guid: "\(name)-1", url: nil, title: "\(name): Quartalszahlen",
                    author: nil, publishedAt: Date(),
                    contentHTML: "<p>Bericht über Quartalszahlen aus \(name).</p>")
            ]
            _ = try await repository.insertFeed(
                url: "https://example.com/\(name)",
                parsed: ParsedFeed(title: name, description: nil, siteURL: nil, items: items),
                categoryId: nil, newCategoryName: name, etag: nil, lastModified: nil)
        }
    }

    /// The search field sits above the filtered list, so a search inside a
    /// category must not surface other categories' articles.
    @Test func searchStaysWithinTheSelectedCategory() async throws {
        let (repository, pool) = try makeRepository()
        try await seed(repository)

        let categoryId = try await pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM category WHERE name = 'Technik'")
        }
        let (all, scoped) = try await pool.read { db in
            (
                try ArticleListModel.searchRows(db, query: "Quartalszahlen", selection: .all),
                try ArticleListModel.searchRows(
                    db, query: "Quartalszahlen", selection: .category(try #require(categoryId)))
            )
        }

        #expect(all.count == 2)
        #expect(scoped.count == 1)
        #expect(scoped.first?.feedTitle == "Technik")
    }

    @Test func searchStaysWithinTheSelectedFeed() async throws {
        let (repository, pool) = try makeRepository()
        try await seed(repository)

        let feedId = try await pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM feed WHERE title = 'Wirtschaft'")
        }
        let rows = try await pool.read { db in
            try ArticleListModel.searchRows(
                db, query: "Quartalszahlen", selection: .feed(try #require(feedId)))
        }

        #expect(rows.count == 1)
        #expect(rows.first?.feedTitle == "Wirtschaft")
    }

    /// Unread/starred selections filter the search as well.
    @Test func searchRespectsUnreadSelection() async throws {
        let (repository, pool) = try makeRepository()
        try await seed(repository)

        let readId = try await pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM article WHERE guid = 'Technik-1'")
        }
        try await repository.markArticle(id: try #require(readId), read: true)

        let rows = try await pool.read { db in
            try ArticleListModel.searchRows(db, query: "Quartalszahlen", selection: .unread)
        }
        #expect(rows.count == 1)
        #expect(rows.first?.feedTitle == "Wirtschaft")
    }
}
