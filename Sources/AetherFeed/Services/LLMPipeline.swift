import Foundation
import Observation

/// Visible state of LLM processing for banners/indicators in the UI.
/// (`LLMStatus` is already the article's column enum, hence "Store".)
@MainActor
@Observable
final class LLMStatusStore {
    static let shared = LLMStatusStore()

    private(set) var isProcessing = false
    private(set) var pauseMessage: String?

    var isPaused: Bool { pauseMessage != nil }

    fileprivate func update(processing: Bool, pause: String?) {
        isProcessing = processing
        pauseMessage = pause
    }
}

/// Serial background worker: takes the newest `pending` article,
/// fetches summary + tags from the Ollama server, and writes both
/// to the DB — the UI updates itself via ValueObservation.
actor LLMPipeline {
    static let shared = LLMPipeline()

    private let repository: Repository
    private var running = false

    init(repository: Repository = .shared) {
        self.repository = repository
    }

    /// At app launch: reset `processing` articles left stuck by a force quit,
    /// then kick off processing.
    func startAtLaunch() async {
        try? await repository.resetProcessingArticles()
        kick()
    }

    /// Kicks off processing if it isn't already running. Idempotent —
    /// called after every refresh and after settings changes.
    func kick() {
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    private func drain() async {
        defer { running = false }

        guard let client = LLMClientFactory.current() else {
            // Not configured: stay quiet, no error banner on first launch.
            await LLMStatusStore.shared.update(processing: false, pause: nil)
            return
        }
        await LLMStatusStore.shared.update(processing: true, pause: nil)

        while true {
            while let article = try? await repository.claimNextPendingArticle() {
                guard let articleId = article.id else { continue }
                do {
                    let (summary, tags) = try await analyze(article, with: client)
                    try await repository.applyLLMResult(
                        articleId: articleId, summary: summary, tags: tags)
                } catch let error as LLMError where error.pausesPipeline {
                    try? await repository.releaseClaimedArticle(id: articleId)
                    await LLMStatusStore.shared.update(
                        processing: false, pause: error.errorDescription)
                    return
                } catch {
                    try? await repository.recordLLMFailure(
                        id: articleId, message: error.localizedDescription)
                }
            }
            await LLMStatusStore.shared.update(processing: false, pause: nil)
            // Queue fully drained — now the digest can cover processed
            // articles (regenerates when missing or outdated). The
            // "digest ready" notification fires in there, after saving.
            await DigestService.shared.generateIfNeeded()

            // Kicks are swallowed while this worker runs, and the digest
            // generation above takes a while — pick up late arrivals
            // instead of dropping them until the next kick.
            let hasPending = (try? await repository.hasPendingArticles()) ?? false
            guard hasPending else { return }
            await LLMStatusStore.shared.update(processing: true, pause: nil)
        }
    }

    /// Category suggestion when adding a feed: loads the feed (without storing
    /// it) and lets the LLM choose from existing categories or propose a new
    /// one — the user makes the final decision in the dialog.
    func suggestCategory(urlString: String) async throws -> CategorySuggestion {
        guard let client = LLMClientFactory.current() else { throw LLMError.notConfigured }
        let parsed = try await FeedFetcher.shared.preview(urlString: urlString)
        let existing = (try? await repository.allCategoryNames()) ?? []

        let system = """
            You categorize RSS feeds. Given a feed's title, description and sample \
            headlines, pick the best matching category from the existing list — or \
            propose ONE new, short category name if none fits. Set isExisting \
            accordingly. Answer the category name in the same language as the \
            existing categories, or German if the list is empty.
            """
        let sampleTitles = parsed.items.prefix(5).map { "- \($0.title)" }.joined(separator: "\n")
        let user = """
            Feed title: \(parsed.title)
            Feed description: \(parsed.description ?? "-")
            Sample headlines:
            \(sampleTitles)

            Existing categories: \(existing.isEmpty ? "(none)" : existing.joined(separator: ", "))
            """

        var suggestion: CategorySuggestion = try await client.structured(
            system: system, user: user, schema: CategorySuggestion.schema)
        suggestion.category = suggestion.category.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only trust isExisting if the name actually exists.
        suggestion.isExisting = existing.contains { $0.caseInsensitiveCompare(suggestion.category) == .orderedSame }
        return suggestion
    }

    private func analyze(
        _ article: Article, with client: any LLMClient
    ) async throws -> (summary: String, tags: [GeneratedTag]) {
        let text = Self.truncate(article.contentText ?? "", limit: 8000)
        let system = """
            You are a news assistant. Summarize the given article in 2-3 concise \
            sentences. \(Self.summaryLanguageInstruction()) Also assign up to 5 \
            short topic tags (single words or very short phrases, no hashtags). \
            For EACH tag provide both a German label ("de") and an English label \
            ("en").
            """
        let user = "Title: \(article.title)\n\nArticle:\n\(text)"
        let analysis: ArticleAnalysis = try await client.structured(
            system: system, user: user, schema: ArticleAnalysis.schema, numCtx: 8192, timeout: nil)

        let tags = analysis.tags.compactMap { tag -> GeneratedTag? in
            let de = tag.de.trimmingCharacters(in: .whitespacesAndNewlines)
            let en = tag.en.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = de.isEmpty ? en : de
            guard !canonical.isEmpty else { return nil }
            return GeneratedTag(de: canonical, en: en.isEmpty ? canonical : en)
        }
        return (analysis.summary, tags)
    }

    private static func summaryLanguageInstruction() -> String {
        let raw = UserDefaults.standard.string(forKey: "summaryLanguage") ?? ""
        return switch SummaryLanguage(rawValue: raw) ?? .de {
        case .de: "Write the summary in German."
        case .en: "Write the summary in English."
        case .original: "Write the summary in the article's original language."
        }
    }

    /// Truncates at a sentence boundary near the limit (context window of
    /// small models). Also used by `AppleIntelligenceClient` to shrink
    /// prompts that exceed the on-device context window.
    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let hardCut = text.index(text.startIndex, offsetBy: limit)
        let slice = text[..<hardCut]
        if let sentenceEnd = slice.lastIndex(where: { ".!?\n".contains($0) }) {
            return String(slice[...sentenceEnd]) + " …"
        }
        return String(slice) + " …"
    }
}
