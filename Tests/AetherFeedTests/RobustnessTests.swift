import Foundation
import GRDB
import Testing

@testable import AetherFeed

/// Covers the failure-surfacing batch: LLM failure reason + retry, feed
/// fetch errors, and the periodic VACUUM guard.
@Suite struct RobustnessTests {
    private func makeRepository() throws -> (Repository, DatabasePool) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherfeed-robustness-\(UUID().uuidString).sqlite").path
        let pool = try DatabasePool(path: path)
        try Migrations.migrator.migrate(pool)
        return (Repository(pool: pool), pool)
    }

    private func insertArticle(
        _ repository: Repository, _ pool: DatabasePool, guid: String = "a1"
    ) async throws -> Int64 {
        let parsed = ParsedFeed(
            title: "Test", description: nil, siteURL: nil,
            items: [
                ParsedItem(
                    guid: guid, url: nil, title: "Artikel",
                    author: nil, publishedAt: Date(), contentHTML: nil)
            ])
        _ = try await repository.insertFeed(
            url: "https://example.com/feed-\(guid)", parsed: parsed,
            categoryId: nil, newCategoryName: nil, etag: nil, lastModified: nil)
        let id = try await pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM article WHERE guid = ?", arguments: [guid])
        }
        return try #require(id)
    }

    @Test func threeFailuresMarkFailedWithReasonAndRetryResets() async throws {
        let (repository, pool) = try makeRepository()
        let articleId = try await insertArticle(repository, pool)

        for _ in 0..<3 {
            try await repository.recordLLMFailure(id: articleId, message: "boom")
        }
        var article = try await pool.read { db in try Article.fetchOne(db, key: articleId) }
        #expect(article?.llmStatus == .failed)
        #expect(article?.llmError == "boom")
        // Failed articles are never claimed by the pipeline.
        #expect(try await repository.claimNextPendingArticle() == nil)

        try await repository.retryArticleLLM(id: articleId)
        article = try await pool.read { db in try Article.fetchOne(db, key: articleId) }
        #expect(article?.llmStatus == .pending)
        #expect(article?.llmAttempts == 0)
        #expect(article?.llmError == nil)
        // Now the pipeline picks it up again.
        #expect(try await repository.claimNextPendingArticle()?.id == articleId)
    }

    @Test func successClearsStoredFailureReason() async throws {
        let (repository, pool) = try makeRepository()
        let articleId = try await insertArticle(repository, pool)

        try await repository.recordLLMFailure(id: articleId, message: "transient")
        try await repository.applyLLMResult(
            articleId: articleId, summary: "Zusammenfassung.",
            tags: [GeneratedTag(de: "Test", en: "Test")])

        let article = try await pool.read { db in try Article.fetchOne(db, key: articleId) }
        #expect(article?.llmStatus == .done)
        #expect(article?.llmError == nil)
    }

    @Test func feedErrorIsStoredAndClearedOnSuccess() async throws {
        let (repository, pool) = try makeRepository()
        let parsed = ParsedFeed(title: "Test", description: nil, siteURL: nil, items: [])
        let feedId = try await repository.insertFeed(
            url: "https://example.com/feed", parsed: parsed,
            categoryId: nil, newCategoryName: nil, etag: nil, lastModified: nil)

        try await repository.touchFeed(id: feedId, error: "HTTP 404")
        var lastError = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT lastError FROM feed WHERE id = ?", arguments: [feedId])
        }
        #expect(lastError == "HTTP 404")

        _ = try await repository.applyFetchedFeed(
            feedId: feedId, parsed: parsed, etag: nil, lastModified: nil)
        lastError = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT lastError FROM feed WHERE id = ?", arguments: [feedId])
        }
        #expect(lastError == nil)
    }

    /// A republished item with a broken far-future pubDate (CMS typo, seen
    /// live from Handelsblatt) must not pin itself to the top of "newest"
    /// sorts — the import stores the fetch time instead. Dates only slightly
    /// ahead (timezone skew) stay untouched.
    @Test func farFuturePubDatesAreClampedToFetchTime() async throws {
        let (repository, pool) = try makeRepository()
        let farFuture = Date(timeIntervalSinceNow: 150 * 86_400)
        let nearFuture = Date(timeIntervalSinceNow: 3_600)
        let parsed = ParsedFeed(
            title: "Test", description: nil, siteURL: nil,
            items: [
                ParsedItem(
                    guid: "kaputt", url: nil, title: "Tippfehler im Verlags-CMS",
                    author: nil, publishedAt: farFuture, contentHTML: nil),
                ParsedItem(
                    guid: "ok", url: nil, title: "Leicht voraus",
                    author: nil, publishedAt: nearFuture, contentHTML: nil),
            ])
        _ = try await repository.insertFeed(
            url: "https://example.com/feed", parsed: parsed,
            categoryId: nil, newCategoryName: nil, etag: nil, lastModified: nil)

        let dates = try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT guid, publishedAt FROM article")
                .reduce(into: [String: Date]()) { $0[$1["guid"]] = $1["publishedAt"] }
        }
        let clamped = try #require(dates["kaputt"])
        let kept = try #require(dates["ok"])
        #expect(abs(clamped.timeIntervalSinceNow) < 60)
        #expect(abs(kept.timeIntervalSince(nearFuture)) < 1)
    }

    @Test func vacuumRunsAtMostOncePerInterval() async throws {
        let (repository, _) = try makeRepository()
        let key = "vacuumTest-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let start = Date()

        #expect(try await repository.vacuumIfDue(now: start, defaultsKey: key) == true)
        #expect(try await repository.vacuumIfDue(now: start, defaultsKey: key) == false)
        let eightDaysLater = start.addingTimeInterval(8 * 86_400)
        #expect(try await repository.vacuumIfDue(now: eightDaysLater, defaultsKey: key) == true)
    }
}
