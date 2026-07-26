import Foundation
import GRDB
import Testing

@testable import AetherFeed

@Suite struct FeedCustomizationTests {
    private func makeRepository() throws -> (Repository, DatabasePool) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherfeed-feedcustom-\(UUID().uuidString).sqlite").path
        let pool = try DatabasePool(path: path)
        try Migrations.migrator.migrate(pool)
        return (Repository(pool: pool), pool)
    }

    private func insertFeed(
        _ repository: Repository, url: String = "https://example.com/feed",
        siteURL: String? = nil
    ) async throws -> Int64 {
        try await repository.insertFeed(
            url: url,
            parsed: ParsedFeed(title: "Original", description: nil, siteURL: siteURL, items: []),
            categoryId: nil, newCategoryName: nil, etag: nil, lastModified: nil)
    }

    @Test func renameSurvivesRefreshAndClearsOnEmpty() async throws {
        let (repository, pool) = try makeRepository()
        let feedId = try await insertFeed(repository)

        try await repository.renameFeed(id: feedId, customTitle: "Mein Name")
        // A refresh overwrites `title` but must keep the override.
        _ = try await repository.applyFetchedFeed(
            feedId: feedId,
            parsed: ParsedFeed(title: "Neuer Feed-Titel", description: nil, siteURL: nil, items: []),
            etag: nil, lastModified: nil)

        let displayed = try await pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(NULLIF(customTitle, ''), title) FROM feed WHERE id = ?
                    """,
                arguments: [feedId])
        }
        #expect(displayed == "Mein Name")

        try await repository.renameFeed(id: feedId, customTitle: "   ")
        let cleared = try await pool.read { db in
            try Feed.fetchOne(db, key: feedId)
        }
        #expect(cleared?.customTitle == nil)
        #expect(cleared?.displayTitle == "Neuer Feed-Titel")
    }

    @Test func assignFeedCategoryMovesAndClears() async throws {
        let (repository, pool) = try makeRepository()
        let feedId = try await insertFeed(repository)
        let categoryId = try await pool.write { db in
            try db.execute(
                sql: "INSERT INTO category (name, sortOrder) VALUES ('Technik', 0)")
            return db.lastInsertedRowID
        }

        try await repository.assignFeedCategory(feedId: feedId, categoryId: categoryId)
        var stored = try await pool.read { db in try Feed.fetchOne(db, key: feedId) }
        #expect(stored?.categoryId == categoryId)

        try await repository.assignFeedCategory(feedId: feedId, categoryId: nil)
        stored = try await pool.read { db in try Feed.fetchOne(db, key: feedId) }
        #expect(stored?.categoryId == nil)
    }

    @Test func faviconURLPrefersSiteHost() {
        let withSite = Feed(
            url: "https://cdn.feedhost.io/rss.xml", siteURL: "https://example.org/news",
            createdAt: Date())
        #expect(
            FeedFetcher.faviconURL(for: withSite)?.absoluteString
                == "https://example.org/favicon.ico")

        let withoutSite = Feed(url: "http://blog.example.com/feed", createdAt: Date())
        #expect(
            FeedFetcher.faviconURL(for: withoutSite)?.absoluteString
                == "http://blog.example.com/favicon.ico")

        let garbage = Feed(url: "not a url", createdAt: Date())
        #expect(FeedFetcher.faviconURL(for: garbage) == nil)
    }

    @Test func faviconAttemptIsStampedWithoutErasingData() async throws {
        let (repository, pool) = try makeRepository()
        let feedId = try await insertFeed(repository)

        // Fresh feed needs a favicon.
        var needing = try await repository.feedsNeedingFavicon(olderThanDays: 30)
        #expect(needing.map(\.id) == [feedId])

        try await repository.saveFavicon(feedId: feedId, data: Data([0x01, 0x02]))
        // A later failed attempt (nil) keeps the stored icon.
        try await repository.saveFavicon(feedId: feedId, data: nil)

        let stored = try await pool.read { db in try Feed.fetchOne(db, key: feedId) }
        #expect(stored?.faviconData == Data([0x01, 0x02]))
        #expect(stored?.faviconFetchedAt != nil)

        // Recently stamped → not due again.
        needing = try await repository.feedsNeedingFavicon(olderThanDays: 30)
        #expect(needing.isEmpty)
    }
}
