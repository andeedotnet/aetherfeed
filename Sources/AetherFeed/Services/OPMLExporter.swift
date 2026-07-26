import Foundation

enum OPMLExporter {
    /// Builds an OPML document: categories as groups with their feeds nested inside.
    static func build(categories: [FeedCategory], feeds: [Feed]) -> String {
        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(#"<opml version="2.0">"#)
        lines.append("  <head><title>AetherFeed</title></head>")
        lines.append("  <body>")

        for category in categories {
            let inCategory = feeds.filter { $0.categoryId == category.id }
            guard !inCategory.isEmpty else { continue }
            lines.append(#"    <outline text="\#(escape(category.name))">"#)
            for feed in inCategory {
                lines.append("      " + outline(for: feed))
            }
            lines.append("    </outline>")
        }
        for feed in feeds where feed.categoryId == nil {
            lines.append("    " + outline(for: feed))
        }

        lines.append("  </body>")
        lines.append("</opml>")
        return lines.joined(separator: "\n")
    }

    private static func outline(for feed: Feed) -> String {
        var attributes = #"type="rss" text="\#(escape(feed.displayTitle))" xmlUrl="\#(escape(feed.url))""#
        if let siteURL = feed.siteURL {
            attributes += #" htmlUrl="\#(escape(siteURL))""#
        }
        return "<outline \(attributes)/>"
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
