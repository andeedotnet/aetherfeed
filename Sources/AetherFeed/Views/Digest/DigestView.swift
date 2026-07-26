import Foundation
import GRDB
import Observation
import SwiftUI

struct DigestDisplay: Equatable, Sendable {
    struct ArticleRef: Equatable, Sendable, Identifiable {
        var id: Int64
        var title: String
    }

    struct Topic: Equatable, Sendable, Identifiable {
        var id: Int
        var headline: String
        var summary: String
        var articles: [ArticleRef]
    }

    struct Section: Equatable, Sendable, Identifiable {
        var id: Int
        var name: String
        var topics: [Topic]
    }

    var generatedAt: Date
    var overview: String
    var sections: [Section]
}

/// Observes the digest cache; article IDs are resolved to titles live.
@MainActor
@Observable
final class DigestModel {
    private(set) var display: DigestDisplay?
    private var observation: Task<Void, Never>?

    func observe() {
        guard observation == nil else { return }
        let valueObservation = ValueObservation.tracking { db in
            try Self.fetchDisplay(db)
        }
        observation = Task { [weak self] in
            do {
                for try await display in valueObservation.values(in: DatabaseManager.shared) {
                    guard let self else { return }
                    self.display = display
                }
            } catch {
                // DB error: the last state stays visible.
            }
        }
    }

    nonisolated private static func fetchDisplay(_ db: Database) throws -> DigestDisplay? {
        guard let record = try DigestRecord.fetchOne(db, key: 1),
              let payload = try? JSONDecoder().decode(
                DigestPayload.self, from: Data(record.contentJSON.utf8))
        else { return nil }

        let allIds = payload.sections.flatMap { $0.topics.flatMap(\.articleIds) }
        var titles: [Int64: String] = [:]
        if !allIds.isEmpty {
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, title FROM article WHERE id IN (\(databaseQuestionMarks(count: allIds.count)))",
                arguments: StatementArguments(allIds)
            )
            for row in rows { titles[row["id"]] = row["title"] }
        }

        let sections = payload.sections.enumerated().map { sectionIndex, section in
            DigestDisplay.Section(
                id: sectionIndex,
                name: section.category,
                topics: section.topics.enumerated().map { topicIndex, topic in
                    DigestDisplay.Topic(
                        id: sectionIndex * 100 + topicIndex,
                        headline: topic.headline,
                        summary: topic.summary,
                        articles: topic.articleIds.compactMap { id in
                            titles[id].map { DigestDisplay.ArticleRef(id: id, title: $0) }
                        }
                    )
                }
            )
        }
        return DigestDisplay(
            generatedAt: record.generatedAt,
            overview: payload.overview,
            sections: sections
        )
    }
}

struct DigestView: View {
    @Environment(Localizer.self) private var l10n
    @Environment(AppStore.self) private var store

    @State private var model = DigestModel()
    @State private var expandedTopics: Set<Int> = []

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

                if let display = model.display {
                    Text(l10n[.digestUpdated] + " ")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    + Text(display.generatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    // Overall overview (last 24 h) as a full-width card.
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

                    // Per feed category: heading + topic cards.
                    ForEach(display.sections) { section in
                        HStack {
                            Text(section.name)
                                .font(.title3.bold())
                            speechButton(
                                id: "section-\(section.id)",
                                text: Self.speechText(for: section))
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
                            ForEach(section.topics) { topic in
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
                        }
                    }
                } else {
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
        .onChange(of: model.display?.generatedAt) {
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
    private static func speechText(for section: DigestDisplay.Section) -> String {
        var parts = [section.name + "."]
        for topic in section.topics {
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
