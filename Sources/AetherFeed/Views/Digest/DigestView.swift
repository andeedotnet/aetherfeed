import Foundation
import GRDB
import Observation
import SwiftUI

/// Home page content: one entry per feed category, each either the AI's
/// topic cards or — until that category has been summarized — its newest
/// articles.
struct DigestDisplay: Equatable, Sendable {
    struct ArticleRef: Equatable, Sendable, Identifiable {
        var id: Int64
        var title: String
    }

    struct Topic: Equatable, Sendable, Identifiable {
        /// Bound to the category name, not to a position: sections change
        /// their content one at a time while a digest is being generated,
        /// and positional ids would move expanded cards around.
        var id: String
        var headline: String
        var summary: String
        var articles: [ArticleRef]
    }

    /// Stand-in for a topic card while the category has no summary yet.
    struct Card: Equatable, Sendable, Identifiable {
        var id: Int64
        var title: String
        var snippet: String
        var feedTitle: String
        var publishedAt: Date?
    }

    enum Content: Equatable, Sendable {
        case topics([Topic])
        case latest([Card])
    }

    struct Section: Equatable, Sendable, Identifiable {
        /// The category name — the same key the digest payload uses.
        var id: String
        var name: String
        var content: Content
    }

    var generatedAt: Date?
    /// True while a generation is still running and only some categories
    /// have been written.
    var isPartial = false
    /// Empty until the overview has been generated (it comes last).
    var overview = ""
    var sections: [Section] = []

    /// Changes only when a generation *completes* — collapsing cards and
    /// stopping speech on every intermediate save would be unusable.
    var completionStamp: Date? { isPartial ? nil : generatedAt }
}

/// Observes the digest cache together with the articles behind it: topic
/// cards and fallback cards therefore always come from the same snapshot.
@MainActor
@Observable
final class DigestModel {
    private(set) var display = DigestDisplay()
    /// Distinguishes "nothing to show" from "not read yet" — without it the
    /// empty state flashes up for one frame at launch.
    private(set) var hasLoaded = false
    private var observation: Task<Void, Never>?

    /// Articles shown per category while it has no summary.
    nonisolated private static let fallbackLimit = 3

    func observe() {
        guard observation == nil else { return }
        // Explicit regions: once every category has topics, no fallback
        // query runs any more, and an inferred region would shrink to the
        // tables that happened to be read — arriving articles would then
        // stop refreshing the page.
        let valueObservation = ValueObservation
            .tracking(
                regions: [Table("digest"), Table("article"), Table("feed"), Table("category")],
                fetch: { db in try Self.fetchDisplay(db) })
            .removeDuplicates()
        observation = Task { [weak self] in
            do {
                for try await display in valueObservation.values(in: DatabaseManager.shared) {
                    guard let self else { return }
                    self.display = display
                    self.hasLoaded = true
                }
            } catch {
                // DB error: the last state stays visible.
            }
        }
    }

    nonisolated static func fetchDisplay(_ db: Database) throws -> DigestDisplay {
        let record = try DigestRecord.fetchOne(db, key: 1)
        let payload = record.flatMap {
            try? JSONDecoder().decode(DigestPayload.self, from: Data($0.contentJSON.utf8))
        }
        let payloadSections: [String: DigestPayload.Section] =
            (payload?.sections ?? []).reduce(into: [:]) { $0[$1.category] = $1 }
        let titles = try Self.articleTitles(db, payload: payload)

        // Feed categories in sidebar order plus the uncategorized bucket —
        // the same order the sidebar and `digestInputsByCategory` use.
        let categories = try FeedCategory
            .order(Column("sortOrder"), Column("name").collating(.nocase))
            .fetchAll(db)
        var buckets: [(name: String, condition: String, arguments: StatementArguments)] =
            categories.compactMap { category in
                guard let id = category.id else { return nil }
                return (category.name, "feed.categoryId = ?", [id])
            }
        buckets.append(
            (L10nKey.localizedOffMain(.sidebarNoCategory), "feed.categoryId IS NULL", []))

        var sections: [DigestDisplay.Section] = []
        var summarized: Set<String> = []
        for bucket in buckets {
            if let section = payloadSections[bucket.name] {
                summarized.insert(bucket.name)
                sections.append(
                    DigestDisplay.Section(
                        id: bucket.name, name: bucket.name,
                        content: .topics(Self.topics(of: section, titles: titles))))
                continue
            }
            let cards = try Self.latestCards(db, bucket: bucket)
            // Neither topics nor articles: nothing to put under a heading.
            guard !cards.isEmpty else { continue }
            sections.append(
                DigestDisplay.Section(
                    id: bucket.name, name: bucket.name, content: .latest(cards)))
        }
        // Sections whose category was renamed or deleted in the meantime:
        // keep them instead of dropping content that is on screen.
        for section in payload?.sections ?? [] where !summarized.contains(section.category) {
            sections.append(
                DigestDisplay.Section(
                    id: section.category, name: section.category,
                    content: .topics(Self.topics(of: section, titles: titles))))
        }

        return DigestDisplay(
            generatedAt: record?.generatedAt,
            isPartial: record?.isPartial ?? false,
            overview: payload?.overview ?? "",
            sections: sections
        )
    }

    /// Live titles of every article the digest references; ids that no
    /// longer exist (retention pruning) simply drop out.
    nonisolated private static func articleTitles(
        _ db: Database, payload: DigestPayload?
    ) throws -> [Int64: String] {
        let ids = (payload?.sections ?? []).flatMap { $0.topics.flatMap(\.articleIds) }
        guard !ids.isEmpty else { return [:] }
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, title FROM article WHERE id IN (\(databaseQuestionMarks(count: ids.count)))",
            arguments: StatementArguments(ids)
        )
        return rows.reduce(into: [:]) { $0[$1["id"] as Int64] = $1["title"] as String }
    }

    nonisolated private static func topics(
        of section: DigestPayload.Section, titles: [Int64: String]
    ) -> [DigestDisplay.Topic] {
        section.topics.enumerated().map { index, topic in
            DigestDisplay.Topic(
                id: "\(section.category)#\(index)",
                headline: topic.headline,
                summary: topic.summary,
                articles: topic.articleIds.compactMap { id in
                    titles[id].map { DigestDisplay.ArticleRef(id: id, title: $0) }
                }
            )
        }
    }

    /// The newest articles of one category, advertorials excluded — the same
    /// rule the digest itself applies.
    nonisolated private static func latestCards(
        _ db: Database,
        bucket: (name: String, condition: String, arguments: StatementArguments)
    ) throws -> [DigestDisplay.Card] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT article.id, article.title, article.summary,
                       article.contentText, article.publishedAt,
                       COALESCE(NULLIF(feed.customTitle, ''), feed.title) AS feedTitle
                FROM article JOIN feed ON feed.id = article.feedId
                WHERE \(bucket.condition) AND article.isAdvertising = 0
                ORDER BY COALESCE(article.publishedAt, article.createdAt) DESC
                LIMIT \(Self.fallbackLimit)
                """,
            arguments: bucket.arguments
        ).map { row in
            let summary: String? = row["summary"]
            let contentText: String? = row["contentText"]
            return DigestDisplay.Card(
                id: row["id"],
                title: row["title"],
                snippet: Self.makeSnippet(summary ?? contentText),
                feedTitle: row["feedTitle"],
                publishedAt: row["publishedAt"]
            )
        }
    }

    nonisolated private static func makeSnippet(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        return String(
            text.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(220))
    }
}

struct DigestView: View {
    @Environment(Localizer.self) private var l10n
    @Environment(AppStore.self) private var store

    @State private var model = DigestModel()
    @State private var expandedTopics: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(l10n[.digestTitle], systemImage: "sparkles")
                        .font(.title2.bold())
                    Spacer()
                    if DigestStatusStore.shared.isGenerating {
                        ProgressView().controlSize(.small)
                        Text(l10n[.digestGenerating])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = DigestStatusStore.shared.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                let display = model.display

                if !display.isPartial, let generatedAt = display.generatedAt {
                    Text(l10n[.digestUpdated] + " ")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    + Text(generatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Overall overview (last 24 h) as a full-width card. It is
                // written last, so it stays hidden while the sections still
                // fill in.
                if !display.overview.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(l10n[.digestOverviewTitle], systemImage: "clock")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            speechButton(id: "overview", text: display.overview)
                        }
                        // One block per paragraph (the LLM delivers one per
                        // category, joined with \n\n) across the full card
                        // width — paragraph gaps carry the readability.
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(
                                Array(
                                    display.overview
                                        .components(separatedBy: "\n\n").enumerated()),
                                id: \.offset
                            ) { _, paragraph in
                                Text(paragraph)
                                    .font(.body)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }

                // Per feed category: heading plus either the topic cards or,
                // until this category has been summarized, its newest articles.
                ForEach(display.sections) { section in
                    HStack {
                        Text(section.name)
                            .font(.title3.bold())
                        switch section.content {
                        case .topics(let topics):
                            speechButton(
                                id: "section-\(section.id)",
                                text: Self.speechText(name: section.name, topics: topics))
                        case .latest:
                            Text(l10n[.digestLatestArticles])
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 320, maximum: 540),
                                     spacing: 12, alignment: .top)
                        ],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        switch section.content {
                        case .topics(let topics):
                            ForEach(topics) { topic in
                                TopicCard(
                                    topic: topic,
                                    isExpanded: expandedTopics.contains(topic.id)
                                ) {
                                    withAnimation(.snappy(duration: 0.22)) {
                                        if expandedTopics.contains(topic.id) {
                                            expandedTopics.remove(topic.id)
                                        } else {
                                            expandedTopics.insert(topic.id)
                                        }
                                    }
                                }
                            }
                        case .latest(let cards):
                            ForEach(cards) { card in
                                LatestCard(card: card)
                            }
                        }
                    }
                }

                if display.sections.isEmpty && model.hasLoaded {
                    // With feeds and a configured AI the digest is on its
                    // way; otherwise explain what is still missing.
                    let creating = store.sidebar.hasFeeds && LLMClientFactory.current() != nil
                    ContentUnavailableView(
                        l10n[.digestEmpty],
                        systemImage: "sparkles",
                        description: Text(l10n[creating ? .digestEmptyCreating : .digestEmptyHint])
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { model.observe() }
        // Only a *finished* generation resets the page — keying this on
        // `generatedAt` would collapse every card and cut the read-aloud
        // off on each intermediate save.
        .onChange(of: model.display.completionStamp) { _, stamp in
            guard stamp != nil else { return }
            expandedTopics.removeAll()
            SpeechController.shared.stop()
        }
        .onDisappear { SpeechController.shared.stop() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AIPauseBanner()
        }
    }

    /// Icon button toggling read-aloud for one digest part; shows a stop
    /// icon while its `id` is the one being spoken.
    private func speechButton(id: String, text: String) -> some View {
        let isActive = SpeechController.shared.activeID == id
        return Button {
            SpeechController.shared.toggle(id: id, text: text)
        } label: {
            Label(
                l10n[isActive ? .digestStopReading : .digestReadAloud],
                systemImage: isActive ? "stop.fill" : "speaker.wave.2")
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .help(l10n[isActive ? .digestStopReading : .digestReadAloud])
    }

    /// One category as spoken text: its name, then each topic's headline
    /// and summary. Sentence-ending punctuation gives natural pauses.
    private static func speechText(name: String, topics: [DigestDisplay.Topic]) -> String {
        var parts = [name + "."]
        for topic in topics {
            parts.append(topic.headline + ". " + topic.summary)
        }
        return parts.joined(separator: "\n")
    }
}

/// Topic card with uniform height: overflowing content is faded out;
/// clicking the card expands or collapses it.
private struct TopicCard: View {
    let topic: DigestDisplay.Topic
    let isExpanded: Bool
    let onToggle: () -> Void

    @Environment(AppStore.self) private var store
    @State private var contentHeight: CGFloat = 0

    private static let collapsedHeight: CGFloat = 190

    private var overflows: Bool {
        contentHeight > Self.collapsedHeight + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(topic.headline)
                    .font(.headline)
                Spacer(minLength: 4)
                if overflows || isExpanded {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
            Text(topic.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(topic.articles) { article in
                Button {
                    store.openArticle(id: article.id)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "arrow.right.circle")
                            .font(.caption)
                        Text(article.title)
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.link)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            contentHeight = height
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: isExpanded ? nil : Self.collapsedHeight, alignment: .top)
        .mask {
            if !isExpanded && overflows {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.8),
                        .init(color: .black.opacity(0), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            } else {
                Rectangle()
            }
        }
        .clipped()
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            if overflows || isExpanded { onToggle() }
        }
    }
}

/// Stand-in for a topic card while its category has no summary yet: one
/// article, same chrome as `TopicCard` but without the expand machinery —
/// the line limits keep the cards on a comparable height.
private struct LatestCard: View {
    let card: DigestDisplay.Card

    @Environment(Localizer.self) private var l10n
    @Environment(AppStore.self) private var store

    var body: some View {
        Button {
            store.openArticle(id: card.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(card.title.isEmpty ? l10n[.untitledArticle] : card.title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                if !card.snippet.isEmpty {
                    Text(card.snippet)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }
                HStack {
                    Text(card.feedTitle)
                    Spacer()
                    if let date = card.publishedAt {
                        Text(date, format: .relative(presentation: .named))
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}
