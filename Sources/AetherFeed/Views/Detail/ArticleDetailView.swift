import GRDB
import Observation
import SwiftUI

/// Observes a single article so that LLM results (summary/tags) appear
/// live in the detail view as soon as the pipeline has written them.
@MainActor
@Observable
final class ArticleDetailModel {
    private(set) var article: Article?
    private(set) var tags: [LocalizedTag] = []
    private var observation: Task<Void, Never>?
    private var currentId: Int64?

    func observe(_ articleId: Int64) {
        guard articleId != currentId else { return }
        currentId = articleId
        observation?.cancel()
        article = nil
        tags = []

        let valueObservation = ValueObservation.tracking { db in
            let article = try Article.fetchOne(db, key: articleId)
            let tags: [LocalizedTag] = article == nil
                ? []
                : try Row.fetchAll(
                    db,
                    sql: """
                        SELECT tag.name, tag.nameEn FROM tag
                        JOIN articleTag ON articleTag.tagId = tag.id
                        WHERE articleTag.articleId = ?
                        ORDER BY tag.name COLLATE NOCASE
                        """,
                    arguments: [articleId]
                ).map { LocalizedTag(name: $0["name"], nameEn: $0["nameEn"]) }
            return (article, tags)
        }
        observation = Task { [weak self] in
            do {
                for try await (article, tags) in valueObservation.values(in: DatabaseManager.shared) {
                    guard let self else { return }
                    self.article = article
                    self.tags = tags
                }
            } catch {
                // Cancelled on article switch — nothing to do.
            }
        }
    }
}

struct ArticleDetailView: View {
    let articleId: Int64
    @State private var model = ArticleDetailModel()
    /// Transient per-article fallback when the web page fails to load;
    /// does not touch the persisted preference.
    @State private var loadFailed = false
    @State private var isPageLoading = false
    @State private var webProxy = WebViewProxy()
    @State private var exportDocument: ExportDocument?
    @State private var showExporter = false
    @Environment(Localizer.self) private var l10n
    @Environment(SettingsStore.self) private var settings
    private var adBlock: AdBlockManager { AdBlockManager.shared }

    private var showsFeedText: Bool {
        settings.showFeedTextInDetail || loadFailed
    }

    var body: some View {
        Group {
            if let article = model.article {
                VStack(alignment: .leading, spacing: 0) {
                    header(for: article)
                    if article.summary != nil || article.llmStatus == .processing
                        || article.llmStatus == .failed {
                        summaryBox(for: article)
                            .padding([.horizontal, .bottom])
                    }
                    Divider()
                    ArticleWebView(
                        content: webContent(for: article),
                        isLoading: $isPageLoading,
                        onFailure: { loadFailed = true },
                        contentRuleLists: adBlock.ruleLists,
                        ruleListsVersion: adBlock.version,
                        proxy: webProxy
                    )
                    .overlay(alignment: .top) {
                        if isPageLoading {
                            ProgressView()
                                .controlSize(.small)
                                .padding(8)
                        }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: articleId) {
            loadFailed = false
            model.observe(articleId)
        }
        .onChange(of: articleId) { oldId, _ in
            if SpeechController.shared.activeID == "article-\(oldId)" {
                SpeechController.shared.stop()
            }
        }
        .onDisappear {
            if SpeechController.shared.activeID?.hasPrefix("article-") == true {
                SpeechController.shared.stop()
            }
        }
        .toolbar {
            if let article = model.article {
                ToolbarItem {
                    Button {
                        Task {
                            try? await Repository.shared.setArticleStarred(
                                id: articleId, starred: !article.isStarred)
                        }
                    } label: {
                        Label(
                            l10n[article.isStarred ? .unstar : .star],
                            systemImage: article.isStarred ? "star.fill" : "star")
                    }
                }
                ToolbarItem {
                    let speechId = "article-\(articleId)"
                    let isSpeaking = SpeechController.shared.activeID == speechId
                    Button {
                        SpeechController.shared.toggle(
                            id: speechId, text: Self.speechText(for: article))
                    } label: {
                        Label(
                            l10n[isSpeaking ? .digestStopReading : .digestReadAloud],
                            systemImage: isSpeaking ? "stop.fill" : "speaker.wave.2")
                    }
                }
                ToolbarItem {
                    Button {
                        // Persisted preference; also clears a transient failure
                        // fallback so switching back to the page retries it.
                        settings.showFeedTextInDetail = !showsFeedText
                        loadFailed = false
                    } label: {
                        Label(
                            l10n[showsFeedText ? .detailShowWebPage : .detailShowFeedText],
                            systemImage: showsFeedText ? "globe" : "doc.plaintext"
                        )
                    }
                    .disabled(article.url == nil)
                }
                ToolbarItem {
                    Button {
                        if let url = article.url.flatMap(URL.init(string:)) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label(l10n[.openInBrowser], systemImage: "safari")
                    }
                    .disabled(article.url == nil)
                }
                ToolbarItem {
                    if let url = article.url.flatMap(URL.init(string:)) {
                        ShareLink(item: url, subject: Text(article.title)) {
                            Label(l10n[.shareLink], systemImage: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem {
                    Menu {
                        Button(l10n[.exportMarkdown]) {
                            Task { @MainActor in
                                // Full rendered page, reader-extracted; the
                                // feed excerpt is only the fallback.
                                var pageMarkdown: String?
                                if let webView = webProxy.webView {
                                    pageMarkdown = await ReaderExtractor.markdown(from: webView)
                                }
                                exportDocument = ExportDocument(
                                    markdown: ArticleExport.markdown(
                                        for: article, pageMarkdown: pageMarkdown))
                                showExporter = true
                            }
                        }
                        .disabled(isPageLoading)
                        Button(l10n[.exportPDF]) {
                            guard let webView = webProxy.webView else { return }
                            Task { @MainActor in
                                if let data = try? await webView.pdf() {
                                    exportDocument = ExportDocument(pdf: data)
                                    showExporter = true
                                }
                            }
                        }
                        .disabled(isPageLoading)
                    } label: {
                        Label(l10n[.exportMenu], systemImage: "square.and.arrow.down")
                    }
                }
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: exportDocument?.contentType ?? ExportDocument.markdownType,
            defaultFilename: model.article.map(ArticleExport.filename(for:)) ?? "article"
        ) { _ in }
    }

    /// Title, then summary, then body — sentence punctuation gives natural
    /// pauses. Capped so very long articles stay a reasonable listen.
    static func speechText(for article: Article) -> String {
        var parts = [article.title + "."]
        if let summary = article.summary, !summary.isEmpty {
            parts.append(summary)
        }
        if let body = article.contentText, !body.isEmpty {
            parts.append(body)
        }
        return LLMPipeline.truncate(parts.joined(separator: "\n"), limit: 10_000)
    }

    /// The real article page is the default; the feed HTML serves as fallback
    /// (no URL, page failed to load, or manually toggled).
    private func webContent(for article: Article) -> ArticleWebView.Content {
        if !showsFeedText, let url = article.url.flatMap(URL.init(string:)) {
            return .remote(url)
        }
        return .html(
            article.contentHTML ?? "",
            baseURL: article.url.flatMap(URL.init(string:))
        )
    }

    private func summaryBox(for article: Article) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(l10n[.aiSummary], systemImage: "sparkles")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if let summary = article.summary {
                Text(summary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !model.tags.isEmpty {
                    TagChipRow(tags: model.tags.map { $0.display(l10n.language) })
                }
            } else if article.llmStatus == .failed {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n[.aiFailedTitle])
                            .font(.callout.bold())
                        Text(article.llmError ?? l10n[.aiFailedUnknown])
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(l10n[.retry]) {
                        Task {
                            try? await Repository.shared.retryArticleLLM(id: articleId)
                            await LLMPipeline.shared.kick()
                        }
                    }
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(l10n[.aiProcessing])
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func header(for article: Article) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(article.title.isEmpty ? l10n[.untitledArticle] : article.title)
                .font(.title2.bold())
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if let author = article.author, !author.isEmpty {
                    Text(author)
                }
                if let date = article.publishedAt {
                    Text(date, format: .dateTime.day().month(.wide).year().hour().minute())
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}
