import Testing

@testable import AetherFeed

@Suite struct HTMLStripperTests {
    @Test func stripsTagsAndDecodesEntities() {
        let html = "<p>Hallo &amp; willkommen<br>bei <b>AetherFeed</b> &ndash; sch&ouml;n!</p>"
        #expect(HTMLStripper.strip(html) == "Hallo & willkommen\nbei AetherFeed – schön!")
    }

    @Test func skipsScriptAndStyleContent() {
        let html = "<p>Sichtbar</p><script>var hidden = 1;</script><style>b{color:red}</style>Ende"
        #expect(HTMLStripper.strip(html) == "Sichtbar\nEnde")
    }

    /// A stray closing tag used to be treated as an opener, which swallowed
    /// the rest of the article — silently, in search, summaries and exports.
    @Test func keepsTextAfterAnOrphanedClosingTag() {
        // Paragraph breaks stay as they are; what matters is that "Ende"
        // survives at all — it used to be dropped with everything after it.
        #expect(HTMLStripper.strip("<p>Anfang</p></script><p>Ende</p>") == "Anfang\n\nEnde")
        #expect(HTMLStripper.strip("Vorher </style> Nachher") == "Vorher Nachher")
    }

    /// A bare `<` in prose is text; it must not eat the remaining document.
    @Test func keepsUnclosedAngleBracketAsText() {
        #expect(HTMLStripper.strip("2 < 3 und weiter") == "2 < 3 und weiter")
        #expect(HTMLStripper.strip("<p>Zahl</p>a < b") == "Zahl\na < b")
    }

    @Test func decodesNumericEntities() {
        #expect(HTMLStripper.strip("&#252;ber &#x2764; Feeds") == "über ❤ Feeds")
    }

    @Test func collapsesWhitespaceAndBlankLines() {
        // Paragraph separation is preserved as at most one blank line.
        let html = "<div>Erste   Zeile</div>\n\n\n<div>Zweite\t Zeile</div><div></div><div></div>"
        #expect(HTMLStripper.strip(html) == "Erste Zeile\n\nZweite Zeile")
    }

    @Test func keepsUnknownEntitiesLiteral() {
        #expect(HTMLStripper.strip("A &unbekannt; B") == "A &unbekannt; B")
    }

    @Test func ignoresComments() {
        #expect(HTMLStripper.strip("Vor<!-- <p>weg</p> -->Nach") == "VorNach")
    }
}
