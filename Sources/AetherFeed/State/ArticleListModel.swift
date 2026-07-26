import Foundation
import GRDB
import Observation
import os

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

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "AetherFeed", category: "search")

    func observe(_ selection: SidebarSelection, search: String = "") {
        guard selection != currentSelection || search != currentSearch else { return }
        currentSelection = selection
        currentSearch = search
        observation?.cancel()
        rows = []

        let valueObservation = ValueObservation.tracking { db in
            search.isEmpty
                ? try Self.fetchRows(db, selection: selection)
                : try Self.searchRows(db, query: search, selection: selection)
        }
        observation = Task { [weak self] in
            do {
                for try await rows in valueObservation.values(in: DatabaseManager.shared) {
                    guard let self else { return }
                    self.rows = rows
                }
            } catch is CancellationError {
                // Selection or search text changed — expected.
            } catch {
                // Without this the list would just stay empty, with no hint
                // as to why (e.g. an FTS syntax error).
                Self.log.error("article list observation failed: \(error)")
            }
        }
    }

    /// The joins/conditions a sidebar selection implies. Shared by the plain
    /// listing and the search so that searching inside a feed, category or
    /// tag stays scoped to it.
    private struct Scope {
        var joins = " JOIN feed ON feed.id = article.feedId"
        /// Without the `WHERE` keyword so callers can combine it.
        var predicate: String?
        var values: [(any DatabaseValueConvertible)?] = []
    }

    nonisolated private static func scope(for selection: SidebarSelection) -> Scope {
        var scope = Scope()
        switch selection {
        case .home, .all:
            break
        case .unread:
            scope.predicate = "article.isRead = 0"
        case .starred:
            scope.predicate = "article.isStarred = 1"
        case .feed(let id):
            scope.predicate = "article.feedId = ?"
            scope.values = [id]
        case .category(let id):
            scope.predicate = "feed.categoryId = ?"
            scope.values = [id]
        case .tag(let id):
            scope.joins += " JOIN articleTag ON articleTag.articleId = article.id"
            scope.predicate = "articleTag.tagId = ?"
            scope.values = [id]
        }
        return scope
    }

    nonisolated static func fetchRows(
        _ db: Database, selection: SidebarSelection
    ) throws -> [ArticleListRow] {
        let scope = Self.scope(for: selection)
        let joins = scope.joins
        let condition = scope.predicate.map { " WHERE \($0)" } ?? ""
        let arguments = StatementArguments(scope.values)

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

    /// Full-text search across title, content, and AI summary (FTS5, prefix
    /// match), restricted to the current sidebar selection — the search
    /// field sits above that list, so it must not return other feeds' hits.
    nonisolated static func searchRows(
        _ db: Database, query: String, selection: SidebarSelection
    ) throws -> [ArticleListRow] {
        let match = query
            .split(whereSeparator: \.isWhitespace)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
        guard !match.isEmpty else { return [] }

        let scope = Self.scope(for: selection)
        // `scope.joins` already contains the feed join the search needs.
        let condition = scope.predicate.map { " AND \($0)" } ?? ""
        let arguments = StatementArguments([match] + scope.values)

        return try Row.fetchAll(
            db,
            sql: """
                SELECT article.id, article.title, article.publishedAt, article.isRead,
                       article.summary, article.contentText, article.url,
                       article.llmStatus, article.isStarred,
                       COALESCE(NULLIF(feed.customTitle, ''), feed.title) AS feedTitle
                FROM article_ft
                JOIN article ON article.id = article_ft.rowid\(scope.joins)
                WHERE article_ft MATCH ?\(condition)
                ORDER BY rank
                LIMIT 200
                """,
            arguments: arguments
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
