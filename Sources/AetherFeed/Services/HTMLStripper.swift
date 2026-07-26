import Foundation

/// Converts feed HTML to plain text for FTS indexing and LLM inputs.
/// Deliberately avoids WebKit/NSAttributedString so it is Sendable and usable off-main.
enum HTMLStripper {
    static func strip(_ html: String) -> String {
        var text = ""
        text.reserveCapacity(html.count)

        var index = html.startIndex
        while index < html.endIndex {
            let character = html[index]

            if character == "<" {
                if html[index...].hasPrefix("<!--") {
                    if let end = html.range(of: "-->", range: index..<html.endIndex) {
                        index = end.upperBound
                    } else {
                        index = html.endIndex
                    }
                    continue
                }
                // A stray `<` in prose ("a < b") is text, not a tag — dropping
                // the rest of the document here would silently truncate the
                // article.
                guard let tagEnd = html[index...].firstIndex(of: ">") else {
                    text.append(character)
                    index = html.index(after: index)
                    continue
                }
                let tag = html[html.index(after: index)..<tagEnd]
                let (name, isClosing) = tagName(of: tag)
                index = html.index(after: tagEnd)

                // Only an *opening* script/style tag starts a skipped block.
                // Treating a stray `</script>` as an opener used to swallow
                // everything after it.
                if !isClosing, name == "script" || name == "style" {
                    if let closing = html.range(
                        of: "</\(name)", options: .caseInsensitive, range: index..<html.endIndex
                    ), let closingEnd = html[closing.upperBound...].firstIndex(of: ">") {
                        index = html.index(after: closingEnd)
                    } else {
                        index = html.endIndex
                    }
                } else if blockTags.contains(name) {
                    text.append("\n")
                }
                continue
            }

            if character == "&" {
                let (decoded, next) = decodeEntity(in: html, from: index)
                text.append(decoded)
                index = next
                continue
            }

            text.append(character)
            index = html.index(after: index)
        }

        return collapseWhitespace(text)
    }

    private static let blockTags: Set<Substring> = [
        "p", "br", "div", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6",
        "tr", "table", "blockquote", "section", "article", "header", "footer",
        "figure", "figcaption", "pre", "hr",
    ]

    private static func tagName(of tag: Substring) -> (name: Substring, isClosing: Bool) {
        var body = tag
        let isClosing = body.hasPrefix("/")
        if isClosing { body = body.dropFirst() }
        return (body.prefix { $0.isLetter || $0.isNumber }.lowercased()[...], isClosing)
    }

    private static let namedEntities: [Substring: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "mdash": "—", "ndash": "–", "hellip": "…",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü",
        "szlig": "ß", "eacute": "é", "egrave": "è", "agrave": "à", "ccedil": "ç",
        "copy": "©", "reg": "®", "trade": "™", "euro": "€", "deg": "°", "sect": "§",
        "laquo": "«", "raquo": "»", "shy": "",
    ]

    /// Decodes an entity starting at `start` (pointing at `&`). Returns the decoded
    /// text and the index past the entity; unknown entities are left as is.
    private static func decodeEntity(
        in html: String, from start: String.Index
    ) -> (String, String.Index) {
        let afterAmp = html.index(after: start)
        let searchEnd = html.index(afterAmp, offsetBy: 12, limitedBy: html.endIndex) ?? html.endIndex
        guard let semicolon = html[afterAmp..<searchEnd].firstIndex(of: ";") else {
            return ("&", afterAmp)
        }
        let body = html[afterAmp..<semicolon]
        let next = html.index(after: semicolon)

        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let scalarValue: UInt32? =
                if digits.hasPrefix("x") || digits.hasPrefix("X") {
                    UInt32(digits.dropFirst(), radix: 16)
                } else {
                    UInt32(digits)
                }
            if let value = scalarValue, let scalar = Unicode.Scalar(value) {
                return (String(Character(scalar)), next)
            }
            return ("&", afterAmp)
        }

        if let replacement = namedEntities[body] {
            return (replacement, next)
        }
        return ("&", afterAmp)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var pendingNewlines = 0
        var pendingSpace = false

        for character in text {
            if character == "\n" || character == "\r" {
                pendingNewlines = min(pendingNewlines + 1, 2)
                pendingSpace = false
            } else if character.isWhitespace {
                pendingSpace = true
            } else {
                if pendingNewlines > 0, !result.isEmpty {
                    result.append(pendingNewlines == 1 ? "\n" : "\n\n")
                } else if pendingSpace, !result.isEmpty {
                    result.append(" ")
                }
                pendingNewlines = 0
                pendingSpace = false
                result.append(character)
            }
        }
        return result
    }
}
