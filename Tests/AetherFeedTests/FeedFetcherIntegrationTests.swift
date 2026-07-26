import Foundation
import GRDB
import Testing

@testable import AetherFeed

/// End-to-end against a real feed (network required), but into a
/// throwaway database — the app database stays untouched.
@Suite struct FeedFetcherIntegrationTests {
    @Test func addsRealFeedIntoTemporaryDatabase() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherfeed-test-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pool = try DatabasePool(path: path)
        try Migrations.migrator.migrate(pool)

        let fetcher = FeedFetcher(repository: Repository(pool: pool))
        let feedId = try await fetcher.addFeed(
            urlString: "https://www.heise.de/rss/heise-atom.xml",
            categoryId: nil,
            newCategoryName: "Tech"
        )
        #expect(feedId > 0)

        let (articleCount, categoryName, pendingCount) = try await pool.read { db in
            (
                try Article.fetchCount(db),
                try String.fetchOne(db, sql: "SELECT name FROM category LIMIT 1"),
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM article WHERE llmStatus = 'pending'") ?? 0
            )
        }
        #expect(articleCount > 0)
        #expect(categoryName == "Tech")
        #expect(pendingCount == articleCount)

        // FTS is populated synchronously via triggers.
        let ftsCount = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article_ft") ?? 0
        }
        #expect(ftsCount == articleCount)

        // Second fetch (conditional GET or dedup): no duplicates, no error.
        let feed = try await pool.read { db in try Feed.fetchOne(db, key: feedId) }
        await fetcher.refresh(try #require(feed))

        let (afterCount, lastError) = try await pool.read { db in
            (
                try Article.fetchCount(db),
                try Feed.fetchOne(db, key: feedId)?.lastError
            )
        }
        #expect(afterCount == articleCount)
        #expect(lastError == nil)
    }
}
