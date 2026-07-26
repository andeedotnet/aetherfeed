import GRDB

enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "category") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique().collate(.nocase)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                // User-defined color (hex string, e.g. "#FF3B30").
                t.column("colorHex", .text)
            }

            try db.create(table: "feed") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull().unique()
                t.column("title", .text).notNull().defaults(to: "")
                // User override; feed refreshes keep overwriting `title`.
                t.column("customTitle", .text)
                t.column("feedDescription", .text)
                t.column("siteURL", .text)
                t.belongsTo("category", onDelete: .setNull)
                t.column("etag", .text)
                t.column("lastModified", .text)
                t.column("lastFetchedAt", .datetime)
                t.column("lastError", .text)
                // Locally cached favicon; the fetch attempt is stamped even
                // on failure so hosts without one aren't retried constantly.
                t.column("faviconData", .blob)
                t.column("faviconFetchedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "article") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("feed", onDelete: .cascade).notNull()
                t.column("guid", .text).notNull()
                t.column("url", .text)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("author", .text)
                t.column("publishedAt", .datetime)
                t.column("contentHTML", .text)
                t.column("contentText", .text)
                t.column("isRead", .boolean).notNull().defaults(to: false)
                // A star also protects the article from retention pruning.
                t.column("isStarred", .boolean).notNull().defaults(to: false)
                t.column("summary", .text)
                t.column("llmStatus", .text).notNull().defaults(to: "pending")
                t.column("llmAttempts", .integer).notNull().defaults(to: 0)
                // Failure reason of the last LLM attempt (list badge + retry).
                t.column("llmError", .text)
                t.column("llmProcessedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["feedId", "guid"])
            }
            try db.create(indexOn: "article", columns: ["feedId", "publishedAt"])
            try db.create(
                index: "article_unread",
                on: "article",
                columns: ["isRead"],
                condition: Column("isRead") == false
            )
            try db.create(
                index: "article_llm_pending",
                on: "article",
                columns: ["llmStatus"],
                condition: Column("llmStatus") == "pending"
            )
            try db.create(
                index: "article_starred",
                on: "article",
                columns: ["isStarred"],
                condition: Column("isStarred") == true
            )

            // Bilingual tags: `name` is the primary/German label (dedup key),
            // `nameEn` the English label.
            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique().collate(.nocase)
                t.column("nameEn", .text)
            }

            try db.create(table: "articleTag") { t in
                t.belongsTo("article", onDelete: .cascade).notNull()
                t.belongsTo("tag", onDelete: .cascade).notNull()
                t.primaryKey(["articleId", "tagId"])
            }

            // Deleted (read, old) articles leave a tombstone so they don't
            // come back as "new" while the feed still lists them.
            try db.create(table: "articleTombstone") { t in
                t.belongsTo("feed", onDelete: .cascade).notNull()
                t.column("guid", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["feedId", "guid"])
            }

            // Single-row cache of the AI briefing on the home page.
            try db.create(table: "digest") { t in
                t.column("id", .integer).primaryKey().check { $0 == 1 }
                t.column("generatedAt", .datetime).notNull()
                t.column("contentJSON", .text).notNull()
                t.column("articleCount", .integer).notNull()
            }

            try db.create(virtualTable: "article_ft", using: FTS5()) { t in
                t.synchronize(withTable: "article")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("contentText")
                t.column("summary")
            }
        }

        return migrator
    }
}
