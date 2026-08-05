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
    /// Distinguishes the battery pause from an error pause: it resolves by
    /// plugging in, not by retrying.
    private(set) var pausedOnBattery = false

    var isPaused: Bool { pauseMessage != nil }

    fileprivate func update(processing: Bool, pause: String?, onBattery: Bool = false) {
        isProcessing = processing
        pauseMessage = pause
        pausedOnBattery = onBattery
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
        if await stopForBattery() { return }
        await LLMStatusStore.shared.update(processing: true, pause: nil)

        while true {
            while true {
                // Checked before every claim: unplugging stops the queue after
                // the article in flight, and nothing is left stuck in
                // `processing` because no article has been claimed yet.
                if await stopForBattery() { return }
                guard let article = try? await repository.claimNextPendingArticle() else { break }
                guard let articleId = article.id else { continue }
                do {
                    let result = try await analyze(article, with: client)
                    // Advertorials keep no summary and only the "Werbung" tag —
                    // whatever the model wrote for them is dropped here.
                    try await repository.applyLLMResult(
                        articleId: articleId,
                        summary: result.isAdvertising ? nil : result.summary,
                        tags: result.isAdvertising ? [.advertising] : result.tags,
                        isAdvertising: result.isAdvertising,
                        markRead: result.isAdvertising && Self.markAdvertisingReadEnabled)
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
            // The digest is the longest run of model calls, so the battery
            // gate decides here whether it starts at all.
            if await stopForBattery() { return }
            await DigestService.shared.generateIfNeeded()

            // Kicks are swallowed while this worker runs, and the digest
            // generation above takes a while — pick up late arrivals
            // instead of dropping them until the next kick.
            let hasPending = (try? await repository.hasPendingArticles()) ?? false
            guard hasPending else { return }
            await LLMStatusStore.shared.update(processing: true, pause: nil)
        }
    }

    /// Publishes the battery pause and reports whether this run has to stop.
    /// The banner only goes up while articles are actually waiting —
    /// otherwise nothing is being withheld and a permanent banner for the
    /// whole time on battery would just be noise. Resuming happens through
    /// `kick()` — from `PowerMonitor` when the charger is back, or from the
    /// settings toggle.
    private func stopForBattery() async -> Bool {
        guard AIPowerGate.isBlocking else { return false }
        let waiting = (try? await repository.hasPendingArticles()) ?? false
        await LLMStatusStore.shared.update(
            processing: false, pause: waiting ? AIPowerGate.message : nil, onBattery: waiting)
        return true
    }

    /// Category suggestion when adding a feed: loads the feed (without storing
    /// it) and lets the LLM choose from existing categories or propose a new
    /// one — the user makes the final decision in the dialog.
    func suggestCategory(urlString: String) async throws -> CategorySuggestion {
        guard !AIPowerGate.isBlocking else { throw LLMError.pausedOnBattery }
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
    ) async throws -> (summary: String, tags: [GeneratedTag], isAdvertising: Bool) {
        let text = Self.truncate(article.contentText ?? "", limit: 8000)
        let user = "Title: \(article.title)\n\nArticle:\n\(text)"
        let analysis: ArticleAnalysis = try await client.structured(
            system: Self.analysisPrompt(), user: user, schema: ArticleAnalysis.schema,
            numCtx: 8192, timeout: nil)
        let isAdvertising = Self.isVerifiedAdvertising(
            flag: analysis.isAdvertising, marker: analysis.adMarker,
            in: "\(article.title) \(text)")

        let tags = analysis.tags.compactMap { tag -> GeneratedTag? in
            let de = tag.de.trimmingCharacters(in: .whitespacesAndNewlines)
            let en = tag.en.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = de.isEmpty ? en : de
            guard !canonical.isEmpty else { return nil }
            return GeneratedTag(de: canonical, en: en.isEmpty ? canonical : en)
        }
        return (analysis.summary, tags, isAdvertising)
    }

    /// Words that actually mark advertising. The model supplies the evidence,
    /// this list decides whether the evidence *is* one — left to itself a
    /// small model happily cites a headline as proof. Compared against the
    /// diacritic-folded quote, so entries stay unaccented.
    ///
    /// Feeds come in any language, hence the same three marker classes (ad
    /// label, call to buy, commission disclosure) per language. Entries are
    /// deliberately narrow: a bare "discount" or "offer" also occurs in
    /// ordinary reporting, an imperative "buy now" does not.
    private static let adMarkerVocabulary = [
        // Ad labels.
        "anzeige", "werbung", "gesponsert", "werbepartner", "advertorial",
        "sponsored", "sponsor", "advertisement", "promoted", "paid post",
        "publicite", "sponsorise", "en partenariat avec",
        "pubblicita", "sponsorizzato", "in collaborazione con",
        "publicidad", "patrocinado", "en colaboracion con",
        "promotion", "partnerschaft",
        // Calls to buy. "zugreifen" alone is ordinary German ("Interessenten
        // sollten zugreifen" in a property article) — only imperatives count.
        "jetzt zugreifen", "jetzt bestellen", "jetzt sichern", "jetzt kaufen",
        "gutschein", "rabattcode", "rabatt", "bestpreis",
        "buy now", "shop now", "order now", "discount code", "voucher code",
        "achetez maintenant", "commandez maintenant", "code promo",
        "acquista ora", "ordina ora", "codice sconto",
        "compra ahora", "compre ahora", "codigo de descuento",
        // Commission disclosures.
        "provision", "affiliate", "affilie", "affiliazione", "afiliado",
        "commission sur", "comision por", "commissione su",
    ]

    /// Trusts the advertising flag only when the model quoted a phrase that
    /// both reads like an advertising marker and really occurs in the
    /// article. An unverifiable quote fails towards "not advertising" — the
    /// harmless direction, since a detected ad loses its summary and is
    /// marked read by default.
    static func isVerifiedAdvertising(flag: Bool?, marker: String?, in text: String) -> Bool {
        guard flag == true, let marker else { return false }
        let needle = Self.normalized(marker)
        // Two characters would match almost anything.
        guard needle.count >= 3,
            Self.adMarkerVocabulary.contains(where: { needle.contains($0) })
        else { return false }
        return Self.normalized(text).contains(needle)
    }

    /// Comparison form for the quote: case, accents, whitespace and
    /// punctuation are dropped, because models reflow line breaks, rewrite
    /// dashes and quotation marks and drop accents when citing.
    private static func normalized(_ text: String) -> String {
        let folded = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
        return String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// System prompt for the per-article analysis. Not private so the live
    /// tests exercise the real wording instead of a drifting copy.
    ///
    /// The advertising rule is deliberately mechanical and biased towards
    /// `false`: a wrong `true` costs the reader a real article (no summary,
    /// auto-marked read), a wrong `false` costs nothing but a grey row.
    static func analysisPrompt() -> String {
        """
        You are a news assistant.

        First fill "adMarker". Copy into it, word for word, the phrase from \
        the title or article that marks the text as advertising:
        1. an advertising label ("Anzeige", "Werbung", "Sponsored", \
        "Advertorial", "Publicité", "Pubblicità", "Publicidad", \
        "In Partnerschaft mit", "En partenariat avec");
        2. a call to buy or order ("jetzt zugreifen", "buy now", \
        "achetez maintenant", "acquista ora", "compra ahora");
        3. a disclosure that the publisher earns a commission on purchases.
        The article can be in any language — quote the phrase in the language \
        of the article, exactly as it appears. Do not translate, paraphrase or \
        invent one. If no such phrase is in the text, set "adMarker" to an \
        empty string.

        Then set "isAdvertising" to true only if you quoted such a phrase, \
        otherwise false. Whatever the article is about does not matter: \
        company news, earnings, market reports, interviews, product \
        announcements, reviews, tests, service articles and guides all get \
        false when no phrase was quoted. Calling a product expensive, cheap or \
        worthwhile is not a call to buy.

        Then summarize the article in 2-3 concise sentences; if it is \
        advertising, one short sentence is enough. \
        \(summaryLanguageInstruction()) Also assign up to 5 short topic \
        tags (single words or very short phrases, no hashtags). For EACH tag \
        provide both a German label ("de") and an English label ("en").
        """
    }

    /// Mirrors `SettingsStore.markAdvertisingRead`, including its `true`
    /// default — read straight from UserDefaults like the other settings
    /// this actor consumes.
    private static var markAdvertisingReadEnabled: Bool {
        UserDefaults.standard.object(forKey: "markAdvertisingRead") as? Bool ?? true
    }

    private static func summaryLanguageInstruction() -> String {
        let raw = UserDefaults.standard.string(forKey: "summaryLanguage") ?? ""
        return switch SummaryLanguage(rawValue: raw) ?? .de {
        case .de: "Write the summary in German."
        case .en: "Write the summary in English."
        case .it: "Write the summary in Italian."
        case .fr: "Write the summary in French."
        case .es: "Write the summary in Spanish."
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
