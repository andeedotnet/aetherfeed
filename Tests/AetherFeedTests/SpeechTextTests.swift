import Foundation
import Testing

@testable import AetherFeed

@Suite struct SpeechTextTests {
    @Test func speechTextOrdersTitleSummaryBodyAndCaps() {
        let longBody = String(repeating: "Ein weiterer Satz mit Inhalt. ", count: 500)
        let article = Article(
            feedId: 1, guid: "g", title: "Titel",
            contentText: longBody, summary: "Kurze Zusammenfassung.",
            createdAt: Date())

        let text = ArticleDetailView.speechText(for: article)
        #expect(text.hasPrefix("Titel.\nKurze Zusammenfassung.\n"))
        // Capped with the sentence-boundary ellipsis suffix.
        #expect(text.count <= 10_002)
        #expect(text.hasSuffix("…"))
    }

    @Test func speechTextSkipsMissingParts() {
        let article = Article(feedId: 1, guid: "g", title: "Nur Titel", createdAt: Date())
        #expect(ArticleDetailView.speechText(for: article) == "Nur Titel.")
    }
}
