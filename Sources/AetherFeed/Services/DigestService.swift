import Foundation
import Observation
import os

@MainActor
@Observable
final class DigestStatusStore {
    static let shared = DigestStatusStore()
    private(set) var isGenerating = false
    /// Error or notice text of the last generation; nil = all good.
    private(set) var message: String?

    fileprivate func set(_ generating: Bool) {
        isGenerating = generating
    }

    fileprivate func finish(message: String?) {
        isGenerating = false
        self.message = message
    }
}

/// Generates the home page digest: an LLM overview of the new (unread)
/// articles, grouped by topics with references to the article IDs.
actor DigestService {
    static let shared = DigestService()

    /// Category requests in flight at once against a backend that
    /// supports concurrency (remote servers; on-device stays serial).
    private static let maxParallelRequests = 3

    private let repository: Repository
    private let clientProvider: @Sendable () -> (any LLMClient)?
    private var generating = false
    /// Non-pausing errors are deliberately swallowed (a guardrail refusal
    /// must not kill the digest) — log them so failures stay diagnosable.
    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "AetherFeed", category: "digest")

    init(
        repository: Repository = .shared,
        clientProvider: @escaping @Sendable () -> (any LLMClient)? = {
            LLMClientFactory.current()
        }
    ) {
        self.repository = repository
        self.clientProvider = clientProvider
    }

    /// Called whenever the article pipeline drains its queue: regenerates
    /// when no digest exists (every app start clears it) or when articles
    /// arrived after the current one was built. Failed generations leave
    /// the digest stale, so the next drain retries automatically.
    func generateIfNeeded() async {
        guard (try? await repository.digestIsStale()) ?? false else { return }
        await generate()
    }

    /// Regenerates the home page digest.
    /// Never fails silently: notices/errors end up in the DigestStatusStore.
    ///
    /// Structure: one LLM call per feed category over its newest articles
    /// (clean attribution instead of one big mixed prompt), followed by an
    /// overall overview built from the sections' topics. Incremental:
    /// categories without new arrivals reuse their previous section, the
    /// rest regenerate — in parallel where the backend allows it.
    func generate() async {
        guard !generating else { return }
        guard let client = clientProvider() else {
            await DigestStatusStore.shared.finish(
                message: LLMError.notConfigured.errorDescription)
            return
        }
        guard let groups = try? await repository.digestInputsByCategory(), !groups.isEmpty else {
            await DigestStatusStore.shared.finish(
                message: L10nKey.localizedOffMain(.digestNoArticles))
            return
        }

        generating = true
        await DigestStatusStore.shared.set(true)
        defer { generating = false }

        do {
            let names = groups.map {
                $0.category ?? L10nKey.localizedOffMain(.sidebarNoCategory)
            }
            // Previous sections by category name: the reuse pool for
            // incremental regeneration, and the fallback when a guardrail
            // skips a category (old section beats no section).
            let previousSections: [String: DigestPayload.Section] =
                ((try? await repository.loadDigestPayload())?.sections ?? [])
                .reduce(into: [:]) { $0[$1.category] = $1 }

            var reused: [Int: DigestPayload.Section] = [:]
            var jobs: [(index: Int, name: String, group: Repository.DigestCategoryGroup)] = []
            for (index, group) in groups.enumerated() {
                if let previous = previousSections[names[index]],
                   let generatedAt = previous.generatedAt,
                   let newestArrival = group.newestArrival,
                   newestArrival <= generatedAt
                {
                    reused[index] = previous
                } else {
                    jobs.append((index, names[index], group))
                }
            }

            // A single category failing on a content-specific error (e.g. an
            // Apple Intelligence guardrail refusing political news) should
            // not kill the whole digest — skip it and keep the rest.
            var fresh: [Int: DigestPayload.Section] = [:]
            var skippedError: LLMError?
            var skippedCount = 0
            try await withThrowingTaskGroup(of: SectionResult.self) { taskGroup in
                var pending = jobs.makeIterator()
                let window = client.supportsConcurrentRequests ? Self.maxParallelRequests : 1
                func startNext() {
                    guard let job = pending.next() else { return }
                    taskGroup.addTask {
                        try await Self.generateSection(
                            index: job.index, name: job.name, group: job.group,
                            client: client)
                    }
                }
                for _ in 0..<window { startNext() }
                while let result = try await taskGroup.next() {
                    if let section = result.section { fresh[result.index] = section }
                    if let error = result.skipped {
                        skippedError = error
                        skippedCount += 1
                        log.error(
                            "category \(result.name, privacy: .public) skipped: \(error.errorDescription ?? "\(error)")"
                        )
                    } else if result.section == nil {
                        log.error(
                            "category \(result.name, privacy: .public) produced no usable topics"
                        )
                    }
                    startNext()
                }
            }

            var sections: [DigestPayload.Section] = []
            for index in groups.indices {
                if let section = fresh[index] ?? reused[index] {
                    sections.append(section)
                } else if let previous = previousSections[names[index]] {
                    sections.append(previous)
                }
            }
            log.info(
                "sections: \(reused.count) reused, \(fresh.count) regenerated, \(skippedCount) skipped"
            )

            // Every category failed → surface why instead of an empty digest.
            if sections.isEmpty, let skippedError {
                await DigestStatusStore.shared.finish(
                    message: skippedError.errorDescription)
                return
            }

            let overview = await generateOverview(from: sections, client: client)

            let payload = DigestPayload(overview: overview, sections: sections)
            let articleCount = groups.reduce(0) { $0 + $1.articles.count }
            try await repository.saveDigest(payload, articleCount: articleCount)
            await DigestStatusStore.shared.finish(message: nil)
            await NotificationService.postDigestReady()
        } catch {
            // The old digest stays in place; the error is shown on the home page.
            await DigestStatusStore.shared.finish(message: error.localizedDescription)
        }
    }

    private struct SectionResult: Sendable {
        var index: Int
        var name: String
        var section: DigestPayload.Section?
        var skipped: LLMError?
    }

    /// One category call. Non-pausing errors (a guardrail refusing the
    /// content) are returned instead of thrown so the other categories keep
    /// going; pausing errors abort the whole generation.
    private static func generateSection(
        index: Int, name: String, group: Repository.DigestCategoryGroup,
        client: any LLMClient
    ) async throws -> SectionResult {
        let system = """
            You are a news-briefing assistant. You get a numbered list of \
            the latest articles from the category "\(name)". Group them \
            into 1-4 topics. For each topic provide a short headline, a \
            1-3 sentence summary, and the ids of the articles it covers. \
            Use each article at most once and only ids from the list. \
            \(Self.languageInstruction())
            """
        let validIds = Set(group.articles.map(\.id))
        for _ in 1...2 {
            let result: CategoryTopicsResult
            do {
                result = try await client.structured(
                    system: system,
                    user: Self.articleList(group.articles),
                    schema: CategoryTopicsResult.schema,
                    numCtx: 16384, timeout: 600)
            } catch let error as LLMError where !error.pausesPipeline {
                return SectionResult(index: index, name: name, section: nil, skipped: error)
            }

            // Discard structurally polluted topics and hallucinated IDs;
            // drop topics without valid articles.
            let topics = result.topics.compactMap { topic -> DigestPayload.Topic? in
                guard !Self.isMalformed(topic) else { return nil }
                var topic = topic
                topic.articleIds = topic.articleIds.filter(validIds.contains)
                return topic.articleIds.isEmpty ? nil : topic
            }
            if !topics.isEmpty {
                return SectionResult(
                    index: index, name: name,
                    section: DigestPayload.Section(
                        category: name, topics: topics, generatedAt: Date()),
                    skipped: nil
                )
            }
            // Nothing usable (all topics malformed or invalid): sample once
            // more — at temperature 0.3 the second attempt usually is clean.
        }
        return SectionResult(index: index, name: name, section: nil, skipped: nil)
    }

    /// True when the model dumped structure into a string slot instead of
    /// clean prose — seen live from the on-device model, which wrote
    /// "**Überschrift:** … **Zusammenfassung:** …" plus JSON remnants into
    /// `headline`/`summary`. Such markers never occur in clean output.
    private static func isMalformed(_ topic: DigestPayload.Topic) -> Bool {
        let structural = ["**", "{", "}"]
        if structural.contains(where: {
            topic.headline.contains($0) || topic.summary.contains($0)
        }) {
            return true
        }
        return topic.headline.contains("\n")
    }

    /// Overall overview built from the sections' topic cards instead of raw
    /// articles: far fewer tokens (no mid-sentence cutoff in the on-device
    /// ~4k window), already guardrail-sanitized wording, and the category
    /// order is inherited from the sections. Only topics referencing at
    /// least one article from the last 24 hours take part.
    private func generateOverview(
        from sections: [DigestPayload.Section], client: any LLMClient
    ) async -> String {
        let placeholder = L10nKey.localizedOffMain(.digestOverviewEmpty)
        let recentIds = (try? await repository.recentArticleIds(withinHours: 24)) ?? []
        let recentTopics = sections.compactMap {
            section -> (category: String, topics: [DigestPayload.Topic])? in
            let topics = section.topics.filter { topic in
                topic.articleIds.contains(where: recentIds.contains)
            }
            return topics.isEmpty ? nil : (section.category, topics)
        }
        guard !recentTopics.isEmpty else { return placeholder }

        let system = """
            You are a news-briefing assistant. You get today's news topics \
            as short bullet points, grouped by category. Write a news \
            overview of 6-8 sentences in flowing prose: go through the \
            categories in the given order and give each one roughly equal \
            weight. Summarize in your own words; never copy the bullet \
            points verbatim. Your first sentence must immediately report a \
            concrete development — filler openings such as "In the last 24 \
            hours there were several developments" are forbidden. \
            \(Self.languageInstruction())
            """
        // Guardrail rejections (Apple Intelligence) are deterministic for
        // identical input — retrying verbatim is useless. The fallback
        // attempt sends the headlines only. A second refusal keeps the
        // placeholder; the sections still count.
        let variants = [true, false].map { withSummaries in
            recentTopics.map { entry in
                "# \(entry.category)\n"
                    + entry.topics.map {
                        withSummaries ? "- \($0.headline) — \($0.summary)" : "- \($0.headline)"
                    }.joined(separator: "\n")
            }.joined(separator: "\n\n")
        }
        for (attempt, user) in variants.enumerated() {
            do {
                let result: OverviewResult = try await client.structured(
                    system: system,
                    user: user,
                    schema: OverviewResult.schema,
                    numCtx: 16384, timeout: 600)
                return result.overview
            } catch let error as LLMError where !error.pausesPipeline {
                log.error(
                    "overview attempt \(attempt + 1) skipped: \(error.errorDescription ?? "\(error)")"
                )
            } catch {
                log.error("overview failed: \(error)")
                break
            }
        }
        return placeholder
    }

    private static func articleList(_ articles: [Repository.DigestInput]) -> String {
        articles.map { "[\($0.id)] \($0.title) — \($0.snippet)" }.joined(separator: "\n")
    }

    private static func languageInstruction() -> String {
        let raw = UserDefaults.standard.string(forKey: "summaryLanguage") ?? ""
        return switch SummaryLanguage(rawValue: raw) ?? .de {
        case .de: "Write everything in German."
        case .en: "Write everything in English."
        case .it: "Write everything in Italian."
        case .fr: "Write everything in French."
        case .es: "Write everything in Spanish."
        case .original: "Write in the dominant language of the articles."
        }
    }
}
