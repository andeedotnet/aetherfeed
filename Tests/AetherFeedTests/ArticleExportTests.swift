import Foundation
import Testing
import WebKit

@testable import AetherFeed

@Suite struct ArticleExportTests {
    @Test func pageMarkdownReplacesFeedBody() {
        let article = Article(
            feedId: 1, guid: "g", title: "T",
            contentText: "Nur der Feed-Auszug.", createdAt: Date())
        let markdown = ArticleExport.markdown(
            for: article, pageMarkdown: "## Voller Seiteninhalt\n\nAbsatz.")
        #expect(markdown.contains("## Voller Seiteninhalt"))
        #expect(!markdown.contains("Nur der Feed-Auszug."))
    }

    @Test @MainActor func readerExtractorSerializesMainContent() async throws {
        let html = """
            <html><body>
            <nav><a href="/home">Navigation</a></nav>
            <article>
              <h1>Überschrift</h1>
              <p>Erster Absatz mit <strong>wichtig</strong> und
                 <a href="/ziel">einem Link</a>. \(String(repeating: "Fülltext. ", count: 40))</p>
              <ul><li>Punkt eins</li><li>Punkt zwei</li></ul>
              <blockquote>Ein Zitat.</blockquote>
              <pre>let code = 1</pre>
            </article>
            <footer>Impressum</footer>
            </body></html>
            """
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        // Right after loadHTMLString the OLD (blank) document still reports
        // readyState "complete" — wait until our content is actually there.
        for _ in 0..<100 {
            let loaded = try? await webView.evaluateJavaScript(
                "document.querySelector('article') !== null") as? Bool
            if loaded == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let markdown = try #require(await ReaderExtractor.markdown(from: webView))
        #expect(markdown.contains("# Überschrift"))
        #expect(markdown.contains("**wichtig**"))
        #expect(markdown.contains("[einem Link](https://example.com/ziel)"))
        #expect(markdown.contains("- Punkt eins\n- Punkt zwei"))
        #expect(markdown.contains("> Ein Zitat."))
        #expect(markdown.contains("```\nlet code = 1\n```"))
        #expect(!markdown.contains("Navigation"))
        #expect(!markdown.contains("Impressum"))
    }

    @Test func markdownContainsTitleMetaSummaryAndBody() {
        let article = Article(
            feedId: 1, guid: "g", url: "https://example.com/artikel",
            title: "Ein Titel",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentText: "Der eigentliche Artikeltext.",
            summary: "Erste Zeile.\nZweite Zeile.",
            createdAt: Date())

        let markdown = ArticleExport.markdown(for: article, feedTitle: "Mein Feed")
        #expect(markdown.hasPrefix("# Ein Titel\n\n"))
        #expect(markdown.contains("- Mein Feed"))
        #expect(markdown.contains("- <https://example.com/artikel>"))
        // Multi-line summary stays a blockquote on every line.
        #expect(markdown.contains("> Erste Zeile.\n> Zweite Zeile."))
        #expect(markdown.hasSuffix("Der eigentliche Artikeltext.\n"))
    }

    @Test func markdownFallsBackToStrippedHTML() {
        let article = Article(
            feedId: 1, guid: "g", title: "T",
            contentHTML: "<p>Nur <b>HTML</b>-Inhalt.</p>",
            createdAt: Date())
        let markdown = ArticleExport.markdown(for: article)
        #expect(markdown.contains("Nur HTML-Inhalt."))
        #expect(!markdown.contains("<p>"))
    }

    @Test func filenameStripsHostileCharactersAndCaps() {
        let article = Article(
            feedId: 1, guid: "g",
            title: "Wie: geht/das? \"Alles\" über A|B <und> C — "
                + String(repeating: "x", count: 100),
            createdAt: Date())
        let name = ArticleExport.filename(for: article)
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(!name.contains("\""))
        #expect(!name.contains("|"))
        #expect(name.count <= 80)

        let untitled = Article(feedId: 1, guid: "g", createdAt: Date())
        #expect(ArticleExport.filename(for: untitled) == "article")
    }
}
