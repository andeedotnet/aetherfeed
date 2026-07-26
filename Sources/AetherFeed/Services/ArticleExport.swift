import SwiftUI
import UniformTypeIdentifiers

/// Pure Markdown assembly for the article export, unit-testable without UI.
enum ArticleExport {
    /// `pageMarkdown` is the reader-extracted full page (ReaderExtractor);
    /// without it the body falls back to the feed's own content.
    static func markdown(
        for article: Article, feedTitle: String? = nil, pageMarkdown: String? = nil
    ) -> String {
        var parts: [String] = ["# \(article.title)"]
        var meta: [String] = []
        if let feedTitle, !feedTitle.isEmpty {
            meta.append("- \(feedTitle)")
        }
        if let url = article.url {
            meta.append("- <\(url)>")
        }
        if let date = article.publishedAt {
            meta.append("- \(date.formatted(.iso8601))")
        }
        if !meta.isEmpty {
            parts.append(meta.joined(separator: "\n"))
        }
        if let summary = article.summary, !summary.isEmpty {
            parts.append("> " + summary.replacingOccurrences(of: "\n", with: "\n> "))
        }
        let body = pageMarkdown
            ?? article.contentText
            ?? article.contentHTML.map(HTMLStripper.strip)
            ?? ""
        if !body.isEmpty {
            parts.append(body)
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// Article title without filesystem-hostile characters, length-capped.
    static func filename(for article: Article) -> String {
        let base = article.title.isEmpty ? "article" : article.title
        let cleaned = base.map { "/\\:?%*|\"<>".contains($0) ? "-" : $0 }
        return String(String(cleaned).prefix(80))
    }
}

/// One document for both export formats. A view supports only one
/// `.fileExporter` presentation — two modifiers on the same view shadow
/// each other — so Markdown and PDF share this document and the caller
/// picks the content type per export.
struct ExportDocument: FileDocument {
    static let markdownType =
        UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
    static let readableContentTypes: [UTType] = [markdownType, .pdf]

    var data = Data()
    var contentType: UTType = ExportDocument.markdownType

    init(markdown: String) {
        data = Data(markdown.utf8)
        contentType = Self.markdownType
    }

    init(pdf: Data) {
        data = pdf
        contentType = .pdf
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
