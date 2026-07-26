import Foundation
import GRDB
import Observation

struct ArticleListRow: Equatable, Sendable, Identifiable {
    var id: Int64
    var title: String
    var feedTitle: String
    var publishedAt: Date?
    var isRead: Bool
    var snippet: String
    var url: String?
    var llmFailed = false
    var isStarred = false
    var tags: [LocalizedTag] = []
}

/// Provides the article list for the current sidebar selection, live from the DB:
/// new articles and LLM results appear without manual reloading.
@MainActor
@Observable
final class ArticleListModel {
    private(set) var rows: [ArticleListRow] = []
    private(set) var currentSelection: SidebarSelection?
    private var currentSearch = ""

    private var observation: Task<Void, Never>?

    func observe(_ selection: SidebarSelection, search: String = "") {
        guard selection != currentSelection || search != currentSearch else { return }
        currentSelection = selection
        currentSearch = search
        observation?.cancel()
        rows = []

        let valueObservation = ValueObservation.tracking { db in
            search.isEmpty
                ? try Self.fetchRows(db, selection: selection)
                : try Self.searchRows(db, query: search)
        }
        observation = Task { [weak self] in
            do {
                for try await rows in valueObservation.values(in: DatabaseManager.shared) {
                    guard let self else { return }
                    self.rows = rows
                }
            } catch {
                // Cancelled on selection change or DB error — nothing to do.
            }
        }
    }

    nonisolated private static func fetchRows(
        _ db: Database, selection: SidebarSelection
    ) throws -> [ArticleListRow] {
        var joins = " JOIN feed ON feed.id = article.feedId"
        var condition = ""
        var arguments: StatementArguments = []

        switch selection {
        case .home, .all:
            break
        case .unread:
            condition = " WHERE article.isRead = 0"
        case .starred:
            condition = " WHERE article.isStarred = 1"
        case .feed(let id):
            condition = " WHERE article.feedId = ?"
            arguments = [id]
        case .category(let id):
            condition = " WHERE feed.categoryId = ?"
            arguments = [id]
        case .tag(let id):
            joins += " JOIN articleTag ON articleTag.articleId = article.id"
            condition = " WHERE articleTag.tagId = ?"
            arguments = [id]
        }

        let sql = """
            SELECT article.id, article.title, article.publishedAt, article.isRead,
                   article.summary, article.contentText, article.url,
                   article.llmStatus, article.isStarred,
                   COALESCE(NULLIF(feed.customTitle, ''), feed.title) AS feedTitle
            FROM article\(joins)\(condition)
            ORDER BY COALESCE(article.publishedAt, article.createdAt) DESC
            LIMIT 500
            """

        let tagRows = try Row.fetchAll(
            db,
            sql: """
                SELECT articleTag.articleId, tag.name, tag.nameEn
                FROM articleTag JOIN tag ON tag.id = articleTag.tagId
                ORDER BY tag.name COLLATE NOCASE
                """
        )
        var tagsByArticle: [Int64: [LocalizedTag]] = [:]
        for row in tagRows {
            tagsByArticle[row["articleId"], default: []].append(
                LocalizedTag(name: row["name"], nameEn: row["nameEn"]))
        }

        return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
            let id: Int64 = row["id"]
            let summary: String? = row["summary"]
            let contentText: String? = row["contentText"]
            return ArticleListRow(
                id: id,
                title: row["title"],
                feedTitle: row["feedTitle"],
                publishedAt: row["publishedAt"],
                isRead: row["isRead"],
                snippet: makeSnippet(summary ?? contentText),
                url: row["url"],
                llmFailed: row["llmStatus"] == LLMStatus.failed.rawValue,
                isStarred: row["isStarred"],
                tags: tagsByArticle[id] ?? []
            )
        }
    }

    /// Full-text search across title, content, and AI summary (FTS5, prefix match).
    nonisolated private static func searchRows(_ db: Database, query: String) throws -> [ArticleListRow] {
        let match = query
            .split(whereSeparator: \.isWhitespace)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
        guard !match.isEmpty else { return [] }

        return try Row.fetchAll(
            db,
            sql: """
                SELECT article.id, article.title, article.publishedAt, article.isRead,
                       article.summary, article.contentText, article.url,
                       article.llmStatus, article.isStarred,
                       COALESCE(NULLIF(feed.customTitle, ''), feed.title) AS feedTitle
                FROM article_ft
                JOIN article ON article.id = article_ft.rowid
                JOIN feed ON feed.id = article.feedId
                WHERE article_ft MATCH ?
                ORDER BY rank
                LIMIT 200
                """,
            arguments: [match]
        ).map { row in
            let summary: String? = row["summary"]
            let contentText: String? = row["contentText"]
            return ArticleListRow(
                id: row["id"],
                title: row["title"],
                feedTitle: row["feedTitle"],
                publishedAt: row["publishedAt"],
                isRead: row["isRead"],
                snippet: makeSnippet(summary ?? contentText),
                url: row["url"],
                llmFailed: row["llmStatus"] == LLMStatus.failed.rawValue,
                isStarred: row["isStarred"]
            )
        }
    }

    nonisolated private static func makeSnippet(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(flattened.prefix(220))
    }
}
