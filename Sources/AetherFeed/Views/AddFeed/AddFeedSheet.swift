import SwiftUI

struct AddFeedSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Localizer.self) private var l10n
    @Environment(AppStore.self) private var store

    @State private var urlString = ""
    @State private var selectedCategoryId: Int64?
    @State private var newCategoryName = ""
    @State private var isAdding = false
    @State private var isSuggesting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n[.addFeed])
                .font(.title3.bold())

            Form {
                TextField(
                    l10n[.addFeedURL],
                    text: $urlString,
                    prompt: Text(verbatim: "https://example.com/feed.xml")
                )
                .autocorrectionDisabled()

                Picker(l10n[.addFeedCategory], selection: $selectedCategoryId) {
                    Text(l10n[.addFeedNoCategory]).tag(Int64?.none)
                    ForEach(store.sidebar.categories) { group in
                        Text(group.name).tag(Int64?.some(group.id))
                    }
                }
                .disabled(!trimmedNewCategory.isEmpty)

                TextField(l10n[.addFeedNewCategory], text: $newCategoryName)

                LabeledContent {
                    HStack(spacing: 8) {
                        if isSuggesting {
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                        Button {
                            suggestCategory()
                        } label: {
                            Label(l10n[.addFeedSuggest], systemImage: "sparkles")
                        }
                        .disabled(
                            urlString.trimmingCharacters(in: .whitespaces).isEmpty
                                || isSuggesting || isAdding)
                    }
                } label: {
                    EmptyView()
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(l10n[.cancel]) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    add()
                } label: {
                    if isAdding {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(l10n[.addFeedAdd])
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty || isAdding)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var trimmedNewCategory: String {
        newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func suggestCategory() {
        isSuggesting = true
        errorMessage = nil
        let url = urlString
        Task {
            do {
                let suggestion = try await LLMPipeline.shared.suggestCategory(urlString: url)
                if suggestion.isExisting,
                   let match = store.sidebar.categories.first(where: {
                       $0.name.caseInsensitiveCompare(suggestion.category) == .orderedSame
                   }) {
                    selectedCategoryId = match.id
                    newCategoryName = ""
                } else {
                    newCategoryName = suggestion.category
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSuggesting = false
        }
    }

    private func add() {
        isAdding = true
        errorMessage = nil
        let url = urlString
        let categoryId = selectedCategoryId
        let categoryName = trimmedNewCategory.isEmpty ? nil : trimmedNewCategory

        Task {
            do {
                let feedId = try await FeedFetcher.shared.addFeed(
                    urlString: url,
                    categoryId: categoryId,
                    newCategoryName: categoryName
                )
                store.selection = .feed(feedId)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isAdding = false
            }
        }
    }
}
