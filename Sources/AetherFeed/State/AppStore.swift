import Foundation
import GRDB
import Observation

enum SidebarSelection: Hashable, Sendable {
    case home
    case all
    case unread
    case starred
    case category(Int64)
    case feed(Int64)
    case tag(Int64)
}

struct SidebarFeedInfo: Equatable, Sendable, Identifiable {
    var id: Int64
    var title: String
    var categoryId: Int64?
    var unreadCount: Int
    var lastError: String?
    var faviconData: Data?
}

struct SidebarSnapshot: Equatable, Sendable {
    struct CategoryGroup: Equatable, Sendable, Identifiable {
        var id: Int64
        var name: String
        var colorHex: String?
        var feeds: [SidebarFeedInfo]
        var unreadCount: Int { feeds.reduce(0) { $0 + $1.unreadCount } }
    }

    struct TagInfo: Equatable, Sendable, Identifiable {
        var id: Int64
        var name: String
        var nameEn: String?
        var count: Int

        func display(_ language: AppLanguage) -> String {
            language == .en ? (nameEn.flatMap { $0.isEmpty ? nil : $0 } ?? name) : name
        }
    }

    var categories: [CategoryGroup] = []
    var uncategorized: [SidebarFeedInfo] = []
    var tags: [TagInfo] = []
    var totalCount = 0
    var unreadCount = 0
    var starredCount = 0
    /// Articles still awaiting an AI summary (llmStatus pending or processing).
    var pendingSummaryCount = 0

    var hasFeeds: Bool { !uncategorized.isEmpty || categories.contains { !$0.feeds.isEmpty } }
}

/// Global UI state: sidebar selection, article selection, sidebar data
/// (live via ValueObservation), and refresh status.
@MainActor
@Observable
final class AppStore {
    var selection: SidebarSelection = .home {
        didSet {
            if selection != oldValue { selectedArticleId = nil }
        }
    }
    var selectedArticleId: Int64? {
        didSet {
            guard let id = selectedArticleId, id != oldValue else { return }
            Task { try? await Repository.shared.markArticle(id: id, read: true) }
        }
    }

    private(set) var sidebar = SidebarSnapshot()
    private(set) var isRefreshing = false

    var showAddFeed = false
    var showOPMLImporter = false
    var showOPMLExporter = false
    private(set) var opmlExportText = ""

    private var sidebarObservation: Task<Void, Never>?

    init() {
        observeSidebar()
    }

    func refreshAll() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let newArticles = await FeedFetcher.shared.refreshAll()

            let retentionDays = UserDefaults.standard.integer(forKey: "retentionDays")
            if retentionDays > 0 {
                try? await Repository.shared.pruneArticles(olderThanDays: retentionDays)
            }
            _ = try? await Repository.shared.vacuumIfDue()
            await NotificationService.postNewArticles(count: newArticles)
            isRefreshing = false
        }
    }

    func markAllRead() {
        let selection = selection
        Task { try? await Repository.shared.markAllRead(matching: selection) }
    }

    /// Open an article from the digest: the home page has no detail column,
    /// so switch to the list view and select it there.
    func openArticle(id: Int64) {
        if selection == .home { selection = .all }
        selectedArticleId = id
    }

    /// Drag-and-drop sorting of the sidebar categories. First reorder locally
    /// and optimistically (no snap-back), then persist — the observation
    /// subsequently confirms the same order.
    func moveCategories(from source: IndexSet, to destination: Int) {
        var groups = sidebar.categories
        groups.move(fromOffsets: source, toOffset: destination)
        sidebar.categories = groups
        let orderedIds = groups.map(\.id)
        Task { try? await Repository.shared.updateCategoryOrder(orderedIds) }
    }

    func deleteFeed(id: Int64) {
        if selection == .feed(id) { selection = .all }
        Task { try? await Repository.shared.deleteFeed(id: id) }
    }

    // MARK: - OPML

    func importOPML(from url: URL) {
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            guard
                let data = try? Data(contentsOf: url),
                let entries = try? OPMLImporter.parse(data: data)
            else { return }
            _ = try? await Repository.shared.importFeeds(entries)
            refreshAll()
        }
    }

    func prepareOPMLExport() {
        Task {
            guard let snapshot = try? await Repository.shared.exportSnapshot() else { return }
            opmlExportText = OPMLExporter.build(
                categories: snapshot.categories, feeds: snapshot.feeds)
            showOPMLExporter = true
        }
    }

    // MARK: - Sidebar Observation

    private func observeSidebar() {
        sidebarObservation = Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                try Self.fetchSidebar(db)
            }
            do {
                for try await snapshot in observation.values(in: DatabaseManager.shared) {
                    guard let self else { return }
                    self.sidebar = snapshot
                }
            } catch {
                // Observation only aborts on DB errors; the UI keeps the last state.
            }
        }
    }

    nonisolated private static func fetchSidebar(_ db: Database) throws -> SidebarSnapshot {
        let categories = try FeedCategory
            .order(Column("sortOrder"), Column("name").collating(.nocase))
            .fetchAll(db)

        let feedRows = try Row.fetchAll(
            db,
            sql: """
                SELECT feed.id,
                       COALESCE(NULLIF(feed.customTitle, ''), feed.title) AS title,
                       feed.categoryId, feed.lastError, feed.faviconData,
                       (SELECT COUNT(*) FROM article
                        WHERE article.feedId = feed.id AND article.isRead = 0) AS unreadCount
                FROM feed
                ORDER BY title COLLATE NOCASE
                """
        )
        let feeds = feedRows.map { row in
            SidebarFeedInfo(
                id: row["id"], title: row["title"],
                categoryId: row["categoryId"], unreadCount: row["unreadCount"],
                lastError: row["lastError"], faviconData: row["faviconData"]
            )
        }

        let groups = categories.compactMap { category -> SidebarSnapshot.CategoryGroup? in
            guard let id = category.id else { return nil }
            return SidebarSnapshot.CategoryGroup(
                id: id, name: category.name, colorHex: category.colorHex,
                feeds: feeds.filter { $0.categoryId == id }
            )
        }

        let tagRows = try Row.fetchAll(
            db,
            sql: """
                SELECT tag.id, tag.name, tag.nameEn, COUNT(articleTag.articleId) AS count
                FROM tag JOIN articleTag ON articleTag.tagId = tag.id
                GROUP BY tag.id
                ORDER BY count DESC, tag.name COLLATE NOCASE
                LIMIT 30
                """
        )

        return SidebarSnapshot(
            categories: groups,
            uncategorized: feeds.filter { $0.categoryId == nil },
            tags: tagRows.map {
                SidebarSnapshot.TagInfo(
                    id: $0["id"], name: $0["name"], nameEn: $0["nameEn"], count: $0["count"])
            },
            totalCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article") ?? 0,
            unreadCount: try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM article WHERE isRead = 0") ?? 0,
            starredCount: try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM article WHERE isStarred = 1") ?? 0,
            pendingSummaryCount: try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM article WHERE llmStatus IN ('pending', 'processing')"
            ) ?? 0
        )
    }
}
