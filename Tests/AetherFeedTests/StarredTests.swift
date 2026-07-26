import Foundation
import GRDB
import Testing

@testable import AetherFeed

@Suite struct StarredTests {
    private func makeRepository() throws -> (Repository, DatabasePool) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherfeed-starred-\(UUID().uuidString).sqlite").path
        let pool = try DatabasePool(path: path)
        try Migrations.migrator.migrate(pool)
        return (Repository(pool: pool), pool)
    }

    private func insertArticles(
        _ repository: Repository, _ pool: DatabasePool, guids: [String],
        publishedAt: Date = Date()
    ) async throws -> [String: Int64] {
        let items = guids.map {
            ParsedItem(
                guid: $0, url: nil, title: "Artikel \($0)",
                author: nil, publishedAt: publishedAt, contentHTML: nil)
        }
        _ = try await repository.insertFeed(
            url: "https://example.com/feed", parsed: ParsedFeed(
                title: "Test", description: nil, siteURL: nil, items: items),
            categoryId: nil, newCategoryName: nil, etag: nil, lastModified: nil)
        return try await pool.read { db in
            var ids: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, guid FROM article") {
                ids[row["guid"]] = row["id"]
            }
            return ids
        }
    }

    @Test func starToggleAndFilter() async throws {
        let (repository, pool) = try makeRepository()
        let ids = try await insertArticles(repository, pool, guids: ["a", "b"])

        try await repository.setArticleStarred(id: try #require(ids["a"]), starred: true)
        let starred = try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT guid FROM article WHERE isStarred = 1")
        }
        #expect(starred == ["a"])

        try await repository.setArticleStarred(id: try #require(ids["a"]), starred: false)
        let after = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article WHERE isStarred = 1")
        }
        #expect(after == 0)
    }

    @Test func markAllReadStarredOnlyTouchesStarred() async throws {
        let (repository, pool) = try makeRepository()
        let ids = try await insertArticles(repository, pool, guids: ["a", "b"])
        try await repository.setArticleStarred(id: try #require(ids["a"]), starred: true)

        try await repository.markAllRead(matching: .starred)

        let readGuids = try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT guid FROM article WHERE isRead = 1")
        }
        #expect(readGuids == ["a"])
    }

    @Test func retentionSparesStarredArticles() async throws {
        let (repository, pool) = try makeRepository()
        let old = Date(timeIntervalSinceNow: -40 * 86400)
        let ids = try await insertArticles(
            repository, pool, guids: ["alt-stern", "alt-normal"], publishedAt: old)

        for id in ids.values {
            try await repository.markArticle(id: id, read: true)
        }
        try await repository.setArticleStarred(id: try #require(ids["alt-stern"]), starred: true)

        try await repository.pruneArticles(olderThanDays: 30)

        let remaining = try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT guid FROM article")
        }
        #expect(remaining == ["alt-stern"])
    }
}
