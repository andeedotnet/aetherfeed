import SwiftUI
import UniformTypeIdentifiers

struct OPMLDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.xml]

    var text = ""

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(
            decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct ContentView: View {
    @Environment(Localizer.self) private var l10n
    @Environment(SettingsStore.self) private var settings
    @Environment(AppStore.self) private var store

    @State private var listModel = ArticleListModel()
    @State private var scheduler: RefreshScheduler?
    @State private var searchText = ""

    /// The home page gets the full width (sidebar + digest, without the
    /// list/detail columns). Deliberately independent of the search text:
    /// swapping the split-view structure mid-typing would recreate the
    /// search field and drop its focus.
    private var showsFullWidthHome: Bool {
        store.selection == .home
    }

    var body: some View {
        @Bindable var store = store
        Group {
            if showsFullWidthHome {
                NavigationSplitView {
                    sidebarColumn
                } detail: {
                    // While searching, results replace the digest in place —
                    // the split-view structure (and the search field) stay put.
                    if searchText.isEmpty {
                        DigestView()
                    } else {
                        ArticleListView(store: store, model: listModel)
                    }
                }
                .searchable(text: $searchText, prompt: l10n[.searchPrompt])
                .toolbar { mainToolbar }
            } else {
                NavigationSplitView {
                    sidebarColumn
                } content: {
                    ArticleListView(store: store, model: listModel)
                        .navigationSplitViewColumnWidth(min: 300, ideal: 380)
                } detail: {
                    if let articleId = store.selectedArticleId {
                        ArticleDetailView(articleId: articleId)
                    } else {
                        ContentUnavailableView(
                            l10n[.noArticleSelected],
                            systemImage: "doc.richtext"
                        )
                    }
                }
                .searchable(text: $searchText, prompt: l10n[.searchPrompt])
                .toolbar { mainToolbar }
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .onChange(of: store.selection, initial: true) { _, selection in
            listModel.observe(selection, search: searchText)
        }
        .onChange(of: searchText) { _, search in
            listModel.observe(store.selection, search: search)
        }
        .onChange(of: store.selectedArticleId) { _, articleId in
            // A search result picked on the home page: jump to the list view,
            // which has a detail column to actually show the article.
            guard store.selection == .home, let articleId else { return }
            store.openArticle(id: articleId)
        }
        .task {
            if scheduler == nil {
                let scheduler = RefreshScheduler(settings: settings, store: store)
                scheduler.start()
                self.scheduler = scheduler
                await NotificationService.setUpAtLaunch()
                await UpdateChecker.shared.checkAtLaunch()
                PowerMonitor.shared.startAtLaunch()
                await LLMPipeline.shared.startAtLaunch()
                await AdBlockManager.shared.startAtLaunch()
            }
        }
        .sheet(isPresented: $store.showAddFeed) {
            AddFeedSheet()
        }
        .fileImporter(
            isPresented: $store.showOPMLImporter,
            allowedContentTypes: [.xml, UTType(filenameExtension: "opml") ?? .xml]
        ) { result in
            if case .success(let url) = result {
                store.importOPML(from: url)
            }
        }
        .fileExporter(
            isPresented: $store.showOPMLExporter,
            document: OPMLDocument(text: store.opmlExportText),
            contentType: .xml,
            defaultFilename: "AetherFeed.opml"
        ) { _ in }
    }

    private var sidebarColumn: some View {
        SidebarView(store: store)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                store.refreshAll()
            } label: {
                Label(l10n[.refresh], systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.isRefreshing || !store.sidebar.hasFeeds)
        }
        ToolbarItem {
            // Live count of articles still awaiting an AI summary; hidden at zero.
            if store.sidebar.pendingSummaryCount > 0 {
                HStack(spacing: 5) {
                    if LLMStatusStore.shared.isProcessing {
                        ProgressView().controlSize(.small)
                    } else if LLMStatusStore.shared.pausedOnBattery {
                        // Otherwise a battery pause looks exactly like idle.
                        Image(systemName: "battery.25")
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text("\(store.sidebar.pendingSummaryCount)")
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .help(l10n[.pendingSummariesHelp, store.sidebar.pendingSummaryCount])
            }
        }
        ToolbarItem {
            Button {
                store.markAllRead()
            } label: {
                Label(l10n[.markAllRead], systemImage: "checkmark.circle")
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(store.sidebar.unreadCount == 0)
        }
        ToolbarItem {
            Button {
                store.showAddFeed = true
            } label: {
                Label(l10n[.addFeed], systemImage: "plus")
            }
        }
        ToolbarItem {
            Button {
                settings.adBlockEnabled.toggle()
                Task { await AdBlockManager.shared.reload() }
            } label: {
                Label(
                    l10n[settings.adBlockEnabled ? .adBlockTurnOff : .adBlockTurnOn],
                    systemImage: settings.adBlockEnabled ? "shield" : "shield.slash")
            }
            .help(l10n[settings.adBlockEnabled ? .adBlockTurnOff : .adBlockTurnOn])
        }
        ToolbarItem {
            // Update indicator, rightmost slot: only visible when GitHub has
            // a newer release; the update runs exactly when the user clicks.
            // Blue instead of the toolbar's monochrome so it stands out.
            if let version = UpdateChecker.shared.availableVersion {
                Button {
                    Task { await UpdateChecker.shared.performUpdate() }
                } label: {
                    if UpdateChecker.shared.isUpdating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.blue)
                    }
                }
                .disabled(UpdateChecker.shared.isUpdating)
                .help(l10n[.updateAvailableHelp, version])
            }
        }
    }
}
