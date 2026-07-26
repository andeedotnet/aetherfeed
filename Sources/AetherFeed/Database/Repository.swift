import CryptoKit
import Foundation
import GRDB

/// All write accesses and one-off reads on the database.
/// Live data for the UI flows through ValueObservation in the stores instead.
struct Repository: Sendable {
    let pool: DatabasePool

    static let shared = Repository(pool: DatabaseManager.shared)

    // MARK: - Feeds

    func allFeeds() async throws -> [Feed] {
        try await pool.read { db in try Feed.fetchAll(db) }
    }

    /// Creates a new feed including its articles. `newCategoryName` wins over
    /// `categoryId`; both nil means "no category".
    func insertFeed(
        url: String,
        parsed: ParsedFeed,
        categoryId: Int64?,
        newCategoryName: String?,
        etag: String?,
        lastModified: String?
    ) async throws -> Int64 {
        try await pool.write { db in
            var resolvedCategoryId = categoryId
            if let name = newCategoryName, !name.isEmpty {
                resolvedCategoryId = try Self.findOrCreateCategory(named: name, in: db).id
            }

            let now = Date()
            var feed = Feed(
                url: url,
                title: parsed.title.isEmpty ? url : parsed.title,
                feedDescription: parsed.description,
                siteURL: parsed.siteURL,
                categoryId: resolvedCategoryId,
                etag: etag,
                lastModified: lastModified,
                lastFetchedAt: now,
                createdAt: now
            )
            try feed.insert(db)
            guard let feedId = feed.id else { throw DatabaseError() }

            try Self.insertArticles(parsed.items, feedId: feedId, in: db)
            return feedId
        }
    }

    /// Applies the result of a refresh: metadata, validators, new articles.
    /// Returns the number of newly inserted articles.
    @discardableResult
    func applyFetchedFeed(
        feedId: Int64,
        parsed: ParsedFeed,
        etag: String?,
        lastModified: String?
    ) async throws -> Int {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE feed SET title = ?, feedDescription = ?, siteURL = ?,
                        etag = ?, lastModified = ?, lastFetchedAt = ?, lastError = NULL
                    WHERE id = ?
                    """,
                arguments: [
                    parsed.title, parsed.description, parsed.siteURL,
                    etag, lastModified, Date(), feedId,
                ]
            )
            return try Self.insertArticles(parsed.items, feedId: feedId, in: db)
        }
    }

    /// Updates only the fetch timestamp (304) or the last error.
    func touchFeed(id: Int64, error: String?) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE feed SET lastFetchedAt = ?, lastError = ? WHERE id = ?",
                arguments: [Date(), error, id]
            )
        }
    }

    func deleteFeed(id: Int64) async throws {
        _ = try await pool.write { db in try Feed.deleteOne(db, key: id) }
    }

    /// Empty/whitespace name clears the override back to the fetched title.
    func renameFeed(id: Int64, customTitle: String?) async throws {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE feed SET customTitle = ? WHERE id = ?",
                arguments: [(trimmed?.isEmpty == false) ? trimmed : nil, id]
            )
        }
    }

    /// nil moves the feed to "no category".
    func assignFeedCategory(feedId: Int64, categoryId: Int64?) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE feed SET categoryId = ? WHERE id = ?",
                arguments: [categoryId, feedId]
            )
        }
    }

    /// Feeds whose favicon was never fetched or is older than `days` days.
    func feedsNeedingFavicon(olderThanDays days: Int) async throws -> [Feed] {
        try await pool.read { db in
            try Feed.fetchAll(
                db,
                sql: """
                    SELECT * FROM feed
                    WHERE faviconFetchedAt IS NULL
                       OR faviconFetchedAt < datetime('now', ?)
                    """,
                arguments: ["-\(days) days"]
            )
        }
    }

    /// nil data keeps an existing icon (COALESCE) but still stamps the
    /// attempt, so a host without a favicon is not re-tried on every refresh.
    func saveFavicon(feedId: Int64, data: Data?) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE feed SET faviconData = COALESCE(?, faviconData),
                        faviconFetchedAt = ?
                    WHERE id = ?
                    """,
                arguments: [data, Date(), feedId]
            )
        }
    }

    // MARK: - Articles

    func markArticle(id: Int64, read: Bool) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE article SET isRead = ? WHERE id = ?",
                arguments: [read, id]
            )
        }
    }

    func setArticleStarred(id: Int64, starred: Bool) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE article SET isStarred = ? WHERE id = ?",
                arguments: [starred, id]
            )
        }
    }

    /// Marks all articles of the current sidebar selection as read.
    func markAllRead(matching selection: SidebarSelection) async throws {
        try await pool.write { db in
            switch selection {
            case .home, .all, .unread:
                try db.execute(sql: "UPDATE article SET isRead = 1 WHERE isRead = 0")
            case .feed(let id):
                try db.execute(
                    sql: "UPDATE article SET isRead = 1 WHERE isRead = 0 AND feedId = ?",
                    arguments: [id])
            case .category(let id):
                try db.execute(
                    sql: """
                        UPDATE article SET isRead = 1 WHERE isRead = 0
                        AND feedId IN (SELECT id FROM feed WHERE categoryId = ?)
                        """,
                    arguments: [id])
            case .tag(let id):
                try db.execute(
                    sql: """
                        UPDATE article SET isRead = 1 WHERE isRead = 0
                        AND id IN (SELECT articleId FROM articleTag WHERE tagId = ?)
                        """,
                    arguments: [id])
            case .starred:
                try db.execute(
                    sql: "UPDATE article SET isRead = 1 WHERE isRead = 0 AND isStarred = 1")
            }
        }
    }

    /// Retention limit: deletes read articles older than `days` days.
    /// Unread articles always stay. Tombstones prevent re-import.
    func pruneArticles(olderThanDays days: Int) async throws {
        guard days > 0 else { return }
        let cutoff = "-\(days) days"
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO articleTombstone (feedId, guid, createdAt)
                    SELECT feedId, guid, datetime('now') FROM article
                    WHERE isRead = 1 AND isStarred = 0
                      AND COALESCE(publishedAt, createdAt) < datetime('now', ?)
                    """,
                arguments: [cutoff]
            )
            // A star means "keep" — starred articles survive retention.
            try db.execute(
                sql: """
                    DELETE FROM article
                    WHERE isRead = 1 AND isStarred = 0
                      AND COALESCE(publishedAt, createdAt) < datetime('now', ?)
                    """,
                arguments: [cutoff]
            )
            // Clean up ancient tombstones — no feed lists articles for that long.
            try db.execute(
                sql: "DELETE FROM articleTombstone WHERE createdAt < datetime('now', '-365 days')")
        }
    }

    /// Runs a full VACUUM at most once per interval (default: weekly) so
    /// space freed by pruning is actually returned to the filesystem.
    /// GRDB's `vacuum()` runs outside a transaction, as VACUUM requires.
    /// Returns true when a VACUUM actually ran.
    @discardableResult
    func vacuumIfDue(
        now: Date = Date(),
        interval: TimeInterval = 7 * 86_400,
        defaultsKey: String = "lastVacuumTimestamp"
    ) async throws -> Bool {
        let last = UserDefaults.standard.double(forKey: defaultsKey)
        guard now.timeIntervalSince1970 - last >= interval else { return false }
        try await pool.vacuum()
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: defaultsKey)
        return true
    }

    /// Inserts new articles and returns the number of actually new rows.
    @discardableResult
    private static func insertArticles(_ items: [ParsedItem], feedId: Int64, in db: Database) throws -> Int {
        let tombstoned = try Set(
            String.fetchAll(
                db,
                sql: "SELECT guid FROM articleTombstone WHERE feedId = ?",
                arguments: [feedId]
            ))
        let now = Date()
        var inserted = 0
        for item in items {
            let key = dedupKey(for: item)
            guard !tombstoned.contains(key) else { continue }
            // Feeds occasionally republish an item with a broken far-future
            // pubDate (CMS typo) that would pin the article to the top of
            // every "newest" sort for months — store the fetch time instead.
            // dedupKey keeps the raw date: the key must stay stable.
            let publishedAt = item.publishedAt.map {
                $0 > now.addingTimeInterval(86_400) ? now : $0
            }
            var article = Article(
                feedId: feedId,
                guid: key,
                url: item.url,
                title: item.title,
                author: item.author,
                publishedAt: publishedAt,
                contentHTML: item.contentHTML,
                contentText: item.contentHTML.map(HTMLStripper.strip),
                createdAt: now
            )
            // Existing articles (same feedId+guid) stay untouched so that
            // isRead/summary are never overwritten.
            try article.insert(db, onConflict: .ignore)
            if db.changesCount > 0 { inserted += 1 }
        }
        return inserted
    }

    /// Stable dedup key: GUID ▸ link ▸ hash of title + date.
    private static func dedupKey(for item: ParsedItem) -> String {
        if let guid = item.guid, !guid.isEmpty { return guid }
        if let url = item.url, !url.isEmpty { return url }
        let seed = item.title + "|" + (item.publishedAt.map { String($0.timeIntervalSince1970) } ?? "")
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - LLM Pipeline

    /// Fetches the newest `pending` article and atomically marks it as
    /// `processing` — so no second worker can grab the same article.
    func claimNextPendingArticle() async throws -> Article? {
        try await pool.write { db in
            guard
                let article = try Article
                    .filter(Column("llmStatus") == LLMStatus.pending)
                    .order(Column("publishedAt").desc, Column("createdAt").desc)
                    .fetchOne(db),
                let id = article.id
            else { return nil }
            try db.execute(
                sql: "UPDATE article SET llmStatus = 'processing' WHERE id = ?",
                arguments: [id]
            )
            return article
        }
    }

    /// Returns a claimed article back to the queue
    /// (e.g. when the pipeline pauses due to connection errors).
    func releaseClaimedArticle(id: Int64) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE article SET llmStatus = 'pending' WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// After an app crash/force quit: reset stuck `processing` articles.
    func resetProcessingArticles() async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE article SET llmStatus = 'pending' WHERE llmStatus = 'processing'")
        }
    }

    /// Counts a failed attempt; after 3 attempts permanently `failed`.
    /// The message (last failure reason) is shown in the detail view.
    func recordLLMFailure(id: Int64, message: String?) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE article
                    SET llmAttempts = llmAttempts + 1,
                        llmError = ?,
                        llmStatus = CASE WHEN llmAttempts + 1 >= 3 THEN 'failed' ELSE 'pending' END
                    WHERE id = ?
                    """,
                arguments: [message, id]
            )
        }
    }

    /// Manual retry from the detail view: back to `pending` with a fresh
    /// attempt budget; the pipeline picks it up on the next kick.
    func retryArticleLLM(id: Int64) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE article
                    SET llmStatus = 'pending', llmAttempts = 0, llmError = NULL
                    WHERE id = ?
                    """,
                arguments: [id]
            )
        }
    }

    /// Writes summary + bilingual tags in one transaction and marks the article
    /// `done`. Tags are deduped by the German label (`tag.name`, UNIQUE NOCASE);
    /// a missing English label on an existing tag is backfilled.
    func applyLLMResult(articleId: Int64, summary: String, tags: [GeneratedTag]) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE article
                    SET summary = ?, llmStatus = 'done', llmError = NULL, llmProcessedAt = ?
                    WHERE id = ?
                    """,
                arguments: [summary, Date(), articleId]
            )
            for generated in tags.prefix(5) {
                var tag: Tag
                if let existing = try Tag
                    .filter(Column("name").collating(.nocase) == generated.de)
                    .fetchOne(db) {
                    tag = existing
                    if (existing.nameEn ?? "").isEmpty, !generated.en.isEmpty, let id = existing.id {
                        try db.execute(
                            sql: "UPDATE tag SET nameEn = ? WHERE id = ?",
                            arguments: [generated.en, id])
                    }
                } else {
                    tag = Tag(name: generated.de, nameEn: generated.en)
                    try tag.insert(db)
                }
                guard let tagId = tag.id else { continue }
                try ArticleTag(articleId: articleId, tagId: tagId).insert(db, onConflict: .ignore)
            }
        }
    }

    // MARK: - Digest

    struct DigestInput: Sendable {
        var id: Int64
        var title: String
        var snippet: String
    }

    struct DigestCategoryGroup: Sendable {
        /// nil = feeds without a category.
        var category: String?
        var articles: [DigestInput]
        /// Newest `createdAt` among `articles` — a section older than this
        /// has to be regenerated (same arrival semantics as `digestIsStale`).
        var newestArrival: Date?
    }

    /// Category sections of the home page: for each feed category simply the
    /// newest articles (regardless of age and read state), categories in
    /// sidebar order.
    func digestInputsByCategory(perCategoryLimit: Int = 12) async throws -> [DigestCategoryGroup] {
        try await pool.read { db in
            let categories = try FeedCategory
                .order(Column("sortOrder"), Column("name").collating(.nocase))
                .fetchAll(db)

            var buckets: [(name: String?, condition: String, arguments: StatementArguments)] =
                categories.compactMap { category in
                    guard let id = category.id else { return nil }
                    return (category.name, "feed.categoryId = ?", [id])
                }
            buckets.append((nil, "feed.categoryId IS NULL", []))

            var groups: [DigestCategoryGroup] = []
            for bucket in buckets {
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT article.id, article.title, article.summary,
                               article.contentText, article.createdAt
                        FROM article JOIN feed ON feed.id = article.feedId
                        WHERE \(bucket.condition)
                        ORDER BY COALESCE(article.publishedAt, article.createdAt) DESC
                        LIMIT \(perCategoryLimit)
                        """,
                    arguments: bucket.arguments
                )
                if rows.isEmpty { continue }
                groups.append(
                    DigestCategoryGroup(
                        category: bucket.name,
                        articles: rows.map(Self.digestInput(from:)),
                        newestArrival: rows.compactMap { $0["createdAt"] as Date? }.max()
                    ))
            }
            return groups
        }
    }

    /// IDs of the articles from the last N hours — used to pick the digest
    /// topics that belong into the "last 24 hours" overview.
    func recentArticleIds(withinHours: Int) async throws -> Set<Int64> {
        try await pool.read { db in
            Set(
                try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT id FROM article
                        WHERE COALESCE(publishedAt, createdAt) >= datetime('now', ?)
                        """,
                    arguments: ["-\(withinHours) hours"]
                ))
        }
    }

    /// The currently stored digest, or nil when none exists or its JSON no
    /// longer decodes (schema change) — callers regenerate from scratch then.
    func loadDigestPayload() async throws -> DigestPayload? {
        try await pool.read { db in
            guard let record = try DigestRecord.fetchOne(db, key: 1) else { return nil }
            return try? JSONDecoder().decode(
                DigestPayload.self, from: Data(record.contentJSON.utf8))
        }
    }

    /// The digest prompt lists articles as `[id] title — snippet`, one per
    /// line, so newlines have to go: a feed title containing one could
    /// otherwise forge additional `[id] …` entries in that list.
    private static func digestInput(from row: Row) -> DigestInput {
        let summary: String? = row["summary"]
        let contentText: String? = row["contentText"]
        let snippet = (summary ?? contentText ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(300)
        let title = (row["title"] as String? ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return DigestInput(id: row["id"], title: title, snippet: String(snippet))
    }

    /// True when no digest exists (fresh app start clears it) or articles
    /// arrived after it was generated — i.e. it needs regenerating.
    func digestIsStale() async throws -> Bool {
        try await pool.read { db in
            guard let record = try DigestRecord.fetchOne(db) else { return true }
            return try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM article WHERE createdAt > ?)",
                arguments: [record.generatedAt]
            ) ?? true
        }
    }

    /// Cheap check whether the pipeline still has work queued.
    func hasPendingArticles() async throws -> Bool {
        try await pool.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM article WHERE llmStatus = 'pending')"
            ) ?? false
        }
    }

    func saveDigest(_ payload: DigestPayload, articleCount: Int) async throws {
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        try await pool.write { db in
            try DigestRecord(
                id: 1, generatedAt: Date(), contentJSON: json, articleCount: articleCount
            ).insert(db, onConflict: .replace)
        }
    }

    // MARK: - OPML

    /// Creates imported feeds (without articles — the next refresh fetches those).
    /// Already existing URLs are skipped. Returns the number of new feeds.
    func importFeeds(_ entries: [OPMLEntry]) async throws -> Int {
        try await pool.write { db in
            var inserted = 0
            for entry in entries {
                var categoryId: Int64?
                if let name = entry.category, !name.isEmpty {
                    categoryId = try Self.findOrCreateCategory(named: name, in: db).id
                }
                var feed = Feed(
                    url: entry.url,
                    title: entry.title,
                    categoryId: categoryId,
                    createdAt: Date()
                )
                let before = db.changesCount
                try feed.insert(db, onConflict: .ignore)
                if db.changesCount > before { inserted += 1 }
            }
            return inserted
        }
    }

    func exportSnapshot() async throws -> (categories: [FeedCategory], feeds: [Feed]) {
        try await pool.read { db in
            (
                try FeedCategory.order(Column("sortOrder"), Column("name").collating(.nocase)).fetchAll(db),
                try Feed.order(Column("title").collating(.nocase)).fetchAll(db)
            )
        }
    }

    // MARK: - Categories

    /// Persists a new category order (index = sortOrder).
    func updateCategoryOrder(_ orderedIds: [Int64]) async throws {
        try await pool.write { db in
            for (index, id) in orderedIds.enumerated() {
                try db.execute(
                    sql: "UPDATE category SET sortOrder = ? WHERE id = ?",
                    arguments: [index, id])
            }
        }
    }

    func setCategoryColor(id: Int64, hex: String?) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE category SET colorHex = ? WHERE id = ?", arguments: [hex, id])
        }
    }

    func renameCategory(id: Int64, to name: String) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE category SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    /// Deletes the category; its feeds become "uncategorized" (ON DELETE SET NULL).
    func deleteCategory(id: Int64) async throws {
        _ = try await pool.write { db in try FeedCategory.deleteOne(db, key: id) }
    }

    func allCategoryNames() async throws -> [String] {
        try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM category ORDER BY name COLLATE NOCASE")
        }
    }

    static func findOrCreateCategory(named name: String, in db: Database) throws -> FeedCategory {
        if let existing = try FeedCategory
            .filter(Column("name").collating(.nocase) == name)
            .fetchOne(db) {
            return existing
        }
        // Append new categories at the end, not between the manually sorted ones.
        let maxOrder = try Int.fetchOne(
            db, sql: "SELECT COALESCE(MAX(sortOrder), -1) FROM category") ?? -1
        var category = FeedCategory(name: name, sortOrder: maxOrder + 1)
        try category.insert(db)
        return category
    }
}
