import Foundation
import GRDB
import Testing

@testable import AetherFeed

@Suite struct RetentionTests {
    private func makeRepository() throws -> (Repository, DatabasePool) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherfeed-retention-\(UUID().uuidString).sqlite").path
        let pool = try DatabasePool(path: path)
        try Migrations.migrator.migrate(pool)
        return (Repository(pool: pool), pool)
    }

    @Test func prunesOldReadArticlesAndBlocksReimport() async throws {
        let (repository, pool) = try makeRepository()
        let old = Date(timeIntervalSinceNow: -40 * 86400)
        let items = [
            ParsedItem(guid: "alt-gelesen", url: nil, title: "Alt gelesen",
                       author: nil, publishedAt: old, contentHTML: nil),
            ParsedItem(guid: "alt-ungelesen", url: nil, title: "Alt ungelesen",
                       author: nil, publishedAt: old, contentHTML: nil),
            ParsedItem(guid: "neu", url: nil, title: "Neu",
                       author: nil, publishedAt: Date(), contentHTML: nil),
        ]
        let parsed = ParsedFeed(title: "Test", description: nil, siteURL: nil, items: items)
        let feedId = try await repository.insertFeed(
            url: "https://example.com/feed", parsed: parsed,
            categoryId: nil, newCategoryName: nil, etag: nil, lastModified: nil)

        let readId = try await pool.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT id FROM article WHERE guid = 'alt-gelesen'")
        }
        try await repository.markArticle(id: try #require(readId), read: true)

        try await repository.pruneArticles(olderThanDays: 30)

        let (guids, tombstones) = try await pool.read { db in
            (
                try String.fetchAll(db, sql: "SELECT guid FROM article ORDER BY guid"),
                try String.fetchAll(db, sql: "SELECT guid FROM articleTombstone")
            )
        }
        #expect(guids == ["alt-ungelesen", "neu"])
        #expect(tombstones == ["alt-gelesen"])

        // The feed still lists the deleted article — it must not come back.
        let reinserted = try await repository.applyFetchedFeed(
            feedId: feedId, parsed: parsed, etag: nil, lastModified: nil)
        let countAfter = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article WHERE guid = 'alt-gelesen'") ?? -1
        }
        #expect(reinserted == 0)
        #expect(countAfter == 0)
    }

    @Test func digestInputsGroupByCategoryAndIgnoreAge() async throws {
        let (repository, _) = try makeRepository()
        // Old, already read articles — e.g. a document feed that rarely
        // publishes: the category sections must still receive inputs,
        // only the 24h overview stays empty.
        let old = Date(timeIntervalSinceNow: -10 * 86400)
        let items = (1...3).map { index in
            ParsedItem(guid: "d\(index)", url: nil, title: "Dokument \(index)",
                       author: nil, publishedAt: old, contentHTML: "<p>Inhalt \(index)</p>")
        }
        _ = try await repository.insertFeed(
            url: "https://example.com/docs",
            parsed: ParsedFeed(title: "Docs", description: nil, siteURL: nil, items: items),
            categoryId: nil, newCategoryName: "Dokumente", etag: nil, lastModified: nil)
        try await repository.markAllRead(matching: .all)

        let groups = try await repository.digestInputsByCategory()
        #expect(groups.count == 1)
        #expect(groups.first?.category == "Dokumente")
        #expect(groups.first?.articles.count == 3)
        #expect(groups.first?.articles.allSatisfy { !$0.snippet.isEmpty } == true)

        let recentIds = try await repository.recentArticleIds(withinHours: 24)
        #expect(recentIds.isEmpty)
    }

    @Test func categoryOrderPersistsAndNewCategoriesAppend() async throws {
        let (repository, pool) = try makeRepository()
        for name in ["Alpha", "Beta", "Gamma"] {
            _ = try await pool.write { db in
                try Repository.findOrCreateCategory(named: name, in: db)
            }
        }
        // Newly created categories are appended at the end (sortOrder 0,1,2).
        let initial = try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM category ORDER BY sortOrder")
        }
        #expect(initial == ["Alpha", "Beta", "Gamma"])

        let ids = try await pool.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM category ORDER BY sortOrder")
        }
        try await repository.updateCategoryOrder([ids[2], ids[0], ids[1]])

        let reordered = try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM category ORDER BY sortOrder, name")
        }
        #expect(reordered == ["Gamma", "Alpha", "Beta"])
    }

    @Test func markAllReadRespectsSelection() async throws {
        let (repository, pool) = try makeRepository()
        let items = (1...4).map { index in
            ParsedItem(guid: "g\(index)", url: nil, title: "A\(index)",
                       author: nil, publishedAt: Date(), contentHTML: nil)
        }
        let feedId = try await repository.insertFeed(
            url: "https://example.com/feed",
            parsed: ParsedFeed(title: "Test", description: nil, siteURL: nil, items: items),
            categoryId: nil, newCategoryName: nil, etag: nil, lastModified: nil)

        try await repository.markAllRead(matching: .feed(feedId + 1))
        let unreadWrongFeed = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article WHERE isRead = 0") ?? -1
        }
        #expect(unreadWrongFeed == 4)

        try await repository.markAllRead(matching: .feed(feedId))
        let unread = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article WHERE isRead = 0") ?? -1
        }
        #expect(unread == 0)
    }
}
