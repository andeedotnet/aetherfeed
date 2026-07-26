import Foundation
import GRDB
import Testing

@testable import AetherFeed

@Suite struct BilingualTagTests {
    private func makeRepository() throws -> (Repository, DatabasePool, Int64) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherfeed-tags-\(UUID().uuidString).sqlite").path
        let pool = try DatabasePool(path: path)
        try Migrations.migrator.migrate(pool)
        let repository = Repository(pool: pool)
        return (repository, pool, 0)
    }

    @Test func storesBothLabelsAndDedupesByGerman() async throws {
        let (repository, pool, _) = try makeRepository()

        // Two articles in one feed.
        let feedId = try await repository.insertFeed(
            url: "https://example.com/feed",
            parsed: ParsedFeed(
                title: "Feed", description: nil, siteURL: nil,
                items: [
                    ParsedItem(guid: "a", url: nil, title: "A", author: nil,
                               publishedAt: Date(), contentHTML: "<p>x</p>"),
                    ParsedItem(guid: "b", url: nil, title: "B", author: nil,
                               publishedAt: Date(), contentHTML: "<p>y</p>"),
                ]),
            categoryId: nil, newCategoryName: nil, etag: nil, lastModified: nil)

        let ids = try await pool.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM article WHERE feedId = ? ORDER BY id",
                               arguments: [feedId])
        }

        try await repository.applyLLMResult(
            articleId: ids[0], summary: "s1",
            tags: [GeneratedTag(de: "Fußball", en: "Football")])
        // Same German label, different English → must reuse the existing tag.
        try await repository.applyLLMResult(
            articleId: ids[1], summary: "s2",
            tags: [GeneratedTag(de: "Fußball", en: "Soccer")])

        let tags = try await pool.read { db in try Tag.fetchAll(db) }
        #expect(tags.count == 1)
        #expect(tags.first?.name == "Fußball")
        #expect(tags.first?.nameEn == "Football")

        // Both articles link to the single shared tag.
        let links = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM articleTag") ?? 0
        }
        #expect(links == 2)
    }

    @Test func backfillsMissingEnglishLabel() async throws {
        let (repository, pool, _) = try makeRepository()
        // Simulate a pre-v4 tag: English label empty.
        let tagId = try await pool.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO tag (name, nameEn) VALUES ('Politik', '')")
            return db.lastInsertedRowID
        }

        let feedId = try await repository.insertFeed(
            url: "https://example.com/feed",
            parsed: ParsedFeed(
                title: "F", description: nil, siteURL: nil,
                items: [ParsedItem(guid: "a", url: nil, title: "A", author: nil,
                                   publishedAt: Date(), contentHTML: "<p>x</p>")]),
            categoryId: nil, newCategoryName: nil, etag: nil, lastModified: nil)
        let articleId = try await pool.read { db in
            try #require(try Int64.fetchOne(db, sql: "SELECT id FROM article WHERE feedId = ?",
                                            arguments: [feedId]))
        }

        try await repository.applyLLMResult(
            articleId: articleId, summary: "s",
            tags: [GeneratedTag(de: "Politik", en: "Politics")])

        let stored = try await pool.read { db in try Tag.fetchOne(db, key: tagId) }
        #expect(stored?.nameEn == "Politics")
    }

    @Test func displayPicksLanguage() {
        let tag = LocalizedTag(name: "Wirtschaft", nameEn: "Business")
        #expect(tag.display(.de) == "Wirtschaft")
        #expect(tag.display(.en) == "Business")

        // Missing English falls back to the primary label.
        let fallback = LocalizedTag(name: "Lokales", nameEn: nil)
        #expect(fallback.display(.en) == "Lokales")
    }
}
