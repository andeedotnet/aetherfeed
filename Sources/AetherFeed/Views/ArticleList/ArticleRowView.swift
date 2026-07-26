import SwiftUI

struct ArticleRowView: View {
    let row: ArticleListRow
    @Environment(Localizer.self) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // Always present so titles align; read articles fade to gray.
                Circle()
                    .fill(row.isRead ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                    .frame(width: 8, height: 8)
                Text(row.title.isEmpty ? l10n[.untitledArticle] : row.title)
                    .font(.headline)
                    .lineLimit(2)
                if row.llmFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(l10n[.aiFailedTitle])
                }
            }
            if !row.snippet.isEmpty {
                Text(row.snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !row.tags.isEmpty {
                TagChipRow(tags: row.tags.map { $0.display(l10n.language) })
            }
            HStack {
                Text(row.feedTitle)
                Spacer()
                if row.isStarred {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                if let date = row.publishedAt {
                    Text(date, format: .relative(presentation: .named))
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
