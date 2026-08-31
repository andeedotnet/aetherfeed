import SwiftUI

struct ArticleListView: View {
    @Bindable var store: AppStore
    var model: ArticleListModel
    @Environment(Localizer.self) private var l10n
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        return List(selection: $store.selectedArticleId) {
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
                if settings.showUnreadOnly {
                    ContentUnavailableView(
                        l10n[.filterNoUnread],
                        systemImage: "checkmark.circle"
                    )
                } else {
                    ContentUnavailableView(
                        l10n[.emptyListTitle],
                        systemImage: "tray"
                    )
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            filterBar(showUnreadOnly: $settings.showUnreadOnly)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AIPauseBanner()
        }
    }

    /// Sits directly above the list rather than in the window toolbar: the
    /// filter belongs to this column, not to the whole window.
    private func filterBar(showUnreadOnly: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: showUnreadOnly) {
                    Text(l10n[.filterAll]).tag(false)
                    Text(l10n[.filterUnread]).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                // Two keys instead of a plural rule: "1 articles" would be
                // wrong in four of the five languages.
                Text(
                    l10n[
                        model.rows.count == 1 ? .filterArticleCountOne : .filterArticleCount,
                        model.rows.count])
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
        }
        .background(.bar)
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
