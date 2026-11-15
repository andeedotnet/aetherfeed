import SwiftUI

struct ArticleListView: View {
    @Bindable var store: AppStore
    var model: ArticleListModel
    @Environment(Localizer.self) private var l10n
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        // Interposed instead of binding straight to the store: pinning has to
        // happen before `selectedArticleId` schedules the mark-read write,
        // otherwise the row can blink out and back in. Covers keyboard
        // navigation too.
        let selection = Binding<Int64?>(
            get: { store.selectedArticleId },
            set: { id in
                if let id { model.keepVisible(id: id) }
                store.selectedArticleId = id
            })
        return List(selection: selection) {
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
        .columnHeaderBar {
            filterBar(showUnreadOnly: $settings.showUnreadOnly)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AIPauseBanner()
        }
    }

    /// Sits directly above the list rather than in the window toolbar: the
    /// filter belongs to this column, not to the whole window.
    private func filterBar(showUnreadOnly: Binding<Bool>) -> some View {
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
    }

    @ViewBuilder
    private func rowMenu(for row: ArticleListRow) -> some View {
        Button {
            // Same as a click: a row marked read from the menu keeps its place.
            if !row.isRead { model.keepVisible(id: row.id) }
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


extension View {
    /// Pins a bar below the column's toolbar. On macOS 26+ `safeAreaBar`
    /// merges it into the toolbar's scroll edge effect, so title and bar read
    /// as one header; an own material band would stop at the column edge
    /// while the toolbar background extends under the floating sidebar,
    /// leaving the two visibly offset. Older systems keep the classic
    /// material band with a divider.
    @ViewBuilder
    fileprivate func columnHeaderBar(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(macOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0) { content() }
        } else {
            safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    content()
                    Divider()
                }
                .background(.bar)
            }
        }
    }
}
