import SwiftUI

struct SidebarView: View {
    @Bindable var store: AppStore
    @Environment(Localizer.self) private var l10n

    @State private var renameTarget: SidebarFeedInfo?
    @State private var renameText = ""

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                Label(l10n[.sidebarHome], systemImage: "sparkles")
                    .tag(SidebarSelection.home)
                Label(l10n[.sidebarAll], systemImage: "tray.full")
                    .badge(store.sidebar.totalCount)
                    .tag(SidebarSelection.all)
                Label(l10n[.sidebarUnread], systemImage: "circle.fill")
                    .badge(store.sidebar.unreadCount)
                    .tag(SidebarSelection.unread)
                Label(l10n[.sidebarStarred], systemImage: "star.fill")
                    .badge(store.sidebar.starredCount)
                    .tag(SidebarSelection.starred)
            }

            if store.sidebar.hasFeeds || !store.sidebar.categories.isEmpty {
                Section(l10n[.sidebarCategories]) {
                    ForEach(store.sidebar.categories) { group in
                        DisclosureGroup {
                            ForEach(group.feeds) { feed in
                                feedRow(feed)
                            }
                        } label: {
                            Label {
                                Text(group.name)
                            } icon: {
                                categoryIcon(colorHex: group.colorHex)
                            }
                                .badge(group.unreadCount)
                                .tag(SidebarSelection.category(group.id))
                                .contextMenu {
                                    Button {
                                        markAllRead(.category(group.id))
                                    } label: {
                                        Label(l10n[.markAllRead], systemImage: "checkmark.circle")
                                    }
                                }
                        }
                    }
                    .onMove { source, destination in
                        store.moveCategories(from: source, to: destination)
                    }
                    ForEach(store.sidebar.uncategorized) { feed in
                        feedRow(feed)
                    }
                }
            }

            if !store.sidebar.tags.isEmpty {
                Section(l10n[.sidebarTags]) {
                    ForEach(store.sidebar.tags) { tag in
                        Label(tag.display(l10n.language), systemImage: "number")
                            .badge(tag.count)
                            .tag(SidebarSelection.tag(tag.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .alert(
            l10n[.renameFeed],
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField(l10n[.renameFeed], text: $renameText)
            Button(l10n[.renameFeedSave]) {
                if let feed = renameTarget {
                    Task { try? await Repository.shared.renameFeed(id: feed.id, customTitle: renameText) }
                }
                renameTarget = nil
            }
            Button(l10n[.cancel], role: .cancel) { renameTarget = nil }
        }
        .overlay {
            if store.isRefreshing {
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private func feedRow(_ feed: SidebarFeedInfo) -> some View {
        Label {
            HStack(spacing: 4) {
                Text(feed.title)
                if let error = feed.lastError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help(l10n[.feedErrorHelp, error])
                }
            }
        } icon: {
            if let data = feed.faviconData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "dot.radiowaves.up.forward")
            }
        }
            .badge(feed.unreadCount)
            .tag(SidebarSelection.feed(feed.id))
            .contextMenu {
                Button {
                    markAllRead(.feed(feed.id))
                } label: {
                    Label(l10n[.markAllRead], systemImage: "checkmark.circle")
                }
                Button {
                    renameText = feed.title
                    renameTarget = feed
                } label: {
                    Label(l10n[.renameFeed], systemImage: "pencil")
                }
                Menu {
                    Button(l10n[.sidebarNoCategory]) {
                        assign(feed.id, to: nil)
                    }
                    ForEach(store.sidebar.categories) { group in
                        Button(group.name) {
                            assign(feed.id, to: group.id)
                        }
                    }
                } label: {
                    Label(l10n[.moveToCategory], systemImage: "folder")
                }
                Button(role: .destructive) {
                    store.deleteFeed(id: feed.id)
                } label: {
                    Label(l10n[.deleteFeed], systemImage: "trash")
                }
            }
    }

    private func assign(_ feedId: Int64, to categoryId: Int64?) {
        Task { try? await Repository.shared.assignFeedCategory(feedId: feedId, categoryId: categoryId) }
    }

    private func markAllRead(_ selection: SidebarSelection) {
        Task { try? await Repository.shared.markAllRead(matching: selection) }
    }

    /// Always the outline folder — a category color tints its stroke
    /// instead of filling the whole glyph; without a color the icon keeps
    /// the default foreground style.
    private func categoryIcon(colorHex: String?) -> some View {
        Image(systemName: "folder")
            .foregroundStyle(
                Color(hex: colorHex).map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
    }

    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { store.selection },
            set: { store.selection = $0 ?? .all }
        )
    }
}
