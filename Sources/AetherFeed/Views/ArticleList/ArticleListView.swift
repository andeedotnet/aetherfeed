import SwiftUI

struct ArticleListView: View {
    @Bindable var store: AppStore
    var model: ArticleListModel
    @Environment(Localizer.self) private var l10n

    var body: some View {
        List(selection: $store.selectedArticleId) {
            ForEach(model.rows) { row in
                ArticleRowView(row: row)
                    .tag(row.id)
                    // Advertorials sit on a grey plate; it lies under the
                    // selection highlight, so selected rows stay readable.
                    .listRowBackground(
                        row.isAdvertising ? Color.secondary.opacity(0.08) : Color.clear)
                    .contextMenu { rowMenu(for: row) }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.rows.isEmpty {
                ContentUnavailableView(
                    l10n[.emptyListTitle],
                    systemImage: "tray"
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AIPauseBanner()
        }
    }

    @ViewBuilder
    private func rowMenu(for row: ArticleListRow) -> some View {
        Button {
            Task { try? await Repository.shared.markArticle(id: row.id, read: !row.isRead) }
        } label: {
            Label(
                l10n[row.isRead ? .markUnread : .markRead],
                systemImage: row.isRead ? "circle" : "checkmark.circle")
        }
        Button {
            Task { try? await Repository.shared.setArticleStarred(id: row.id, starred: !row.isStarred) }
        } label: {
            Label(
                l10n[row.isStarred ? .unstar : .star],
                systemImage: row.isStarred ? "star.slash" : "star")
        }
        if let url = row.url.flatMap(URL.init(string:)) {
            Button {
                WorkspaceOpener.open(url)
            } label: {
                Label(l10n[.openInBrowser], systemImage: "safari")
            }
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(url.absoluteString, forType: .string)
            } label: {
                Label(l10n[.copyLink], systemImage: "link")
            }
        }
    }
}
