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
