import FeedKit
import Foundation

struct ParsedFeed: Sendable {
    var title: String
    var description: String?
    var siteURL: String?
    var items: [ParsedItem]
}

struct ParsedItem: Sendable {
    var guid: String?
    var url: String?
    var title: String
    var author: String?
    var publishedAt: Date?
    var contentHTML: String?
}

/// Fully encapsulates FeedKit: outside this file only our own Sendable DTOs
/// `ParsedFeed`/`ParsedItem` cross actor boundaries.
enum FeedParser {
    static func parse(data: Data) throws -> ParsedFeed {
        // FeedKit.Feed spelled out because our GRDB record is also named `Feed`.
        switch try FeedKit.Feed(data: data) {
        case .rss(let rss): parse(rss)
        case .atom(let atom): parse(atom)
        case .json(let json): parse(json)
        }
    }

    private static func parse(_ rss: RSSFeed) -> ParsedFeed {
        let channel = rss.channel
        let items = (channel?.items ?? []).map { item in
            ParsedItem(
                guid: item.guid?.text,
                url: item.link,
                title: cleaned(item.title),
                author: item.author ?? item.dublinCore?.creator,
                publishedAt: item.pubDate,
                contentHTML: item.content?.encoded ?? item.description
            )
        }
        return ParsedFeed(
            title: cleaned(channel?.title),
            description: channel?.description,
            siteURL: channel?.link,
            items: items
        )
    }

    private static func parse(_ atom: AtomFeed) -> ParsedFeed {
        let items = (atom.entries ?? []).map { entry in
            ParsedItem(
                guid: entry.id,
                url: alternateLink(in: entry.links),
                title: cleaned(entry.title),
                author: entry.authors?.first?.name,
                publishedAt: entry.published ?? entry.updated,
                contentHTML: entry.content?.text ?? entry.summary?.text
            )
        }
        return ParsedFeed(
            title: cleaned(atom.title?.text),
            description: atom.subtitle?.text,
            siteURL: alternateLink(in: atom.links),
            items: items
        )
    }

    private static func parse(_ json: JSONFeed) -> ParsedFeed {
        let items = (json.items ?? []).map { item in
            ParsedItem(
                guid: item.id,
                url: item.url ?? item.externalURL,
                title: cleaned(item.title),
                author: item.author?.name,
                publishedAt: item.datePublished,
                contentHTML: item.contentHtml ?? item.contentText
            )
        }
        return ParsedFeed(
            title: cleaned(json.title),
            description: json.description,
            siteURL: json.homePageURL,
            items: items
        )
    }

    private static func alternateLink(in links: [AtomFeedLink]?) -> String? {
        let alternate = links?.first { ($0.attributes?.rel ?? "alternate") == "alternate" }
        return (alternate ?? links?.first)?.attributes?.href
    }

    private static func cleaned(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
