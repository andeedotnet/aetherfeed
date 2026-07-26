import Foundation

struct OPMLEntry: Equatable, Sendable {
    var title: String
    var url: String
    var category: String?
}

/// Reads OPML files from other RSS readers. Nested `outline` groups
/// become categories (the topmost group level wins).
enum OPMLImporter {
    static func parse(data: Data) throws -> [OPMLEntry] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw delegate.error ?? CocoaError(.fileReadCorruptFile)
        }
        return delegate.entries
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [OPMLEntry] = []
        var error: Error?
        private var groupStack: [String] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            guard elementName == "outline" else { return }
            let title = attributes["title"] ?? attributes["text"] ?? ""

            if let url = attributes["xmlUrl"], !url.isEmpty {
                entries.append(
                    OPMLEntry(
                        title: title.isEmpty ? url : title,
                        url: url,
                        category: groupStack.first
                    ))
                // Feed outlines can in theory have children — maintain the stack anyway.
                groupStack.append("")
            } else {
                groupStack.append(title)
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            if elementName == "outline", !groupStack.isEmpty {
                groupStack.removeLast()
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            error = parseError
        }
    }
}
