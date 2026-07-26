import SwiftUI

struct CategorySettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(Localizer.self) private var l10n

    var body: some View {
        Form {
            if store.sidebar.categories.isEmpty {
                Text(l10n[.settingsCategoriesEmpty])
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.sidebar.categories) { group in
                    CategoryRow(
                        categoryId: group.id,
                        initialName: group.name,
                        initialColorHex: group.colorHex,
                        feedCount: group.feeds.count
                    )
                    // .id forces fresh row state after rename/delete.
                    .id("\(group.id)-\(group.name)")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CategoryRow: View {
    let categoryId: Int64
    let feedCount: Int
    @State private var name: String
    @State private var color: Color
    /// A category without a color shows the accent color in the picker but
    /// must not persist one until the user actually changes it.
    @State private var hasColor: Bool
    @Environment(Localizer.self) private var l10n

    init(categoryId: Int64, initialName: String, initialColorHex: String?, feedCount: Int) {
        self.categoryId = categoryId
        self.feedCount = feedCount
        _name = State(initialValue: initialName)
        _color = State(initialValue: Color(hex: initialColorHex) ?? .accentColor)
        _hasColor = State(initialValue: initialColorHex != nil)
    }

    var body: some View {
        HStack {
            ColorPicker(selection: $color, supportsOpacity: false) { EmptyView() }
                .labelsHidden()
                .help(l10n[.settingsCategoryColor])
                .onChange(of: color) { _, newColor in
                    hasColor = true
                    Task {
                        try? await Repository.shared.setCategoryColor(
                            id: categoryId, hex: newColor.hexString)
                    }
                }

            TextField(text: $name) { EmptyView() }
                .labelsHidden()
                .onSubmit {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    Task { try? await Repository.shared.renameCategory(id: categoryId, to: trimmed) }
                }

            Text("\(feedCount)")
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if hasColor {
                Button {
                    hasColor = false
                    Task { try? await Repository.shared.setCategoryColor(id: categoryId, hex: nil) }
                } label: {
                    Image(systemName: "paintbrush")
                }
                .buttonStyle(.borderless)
                .help(l10n[.settingsCategoryColorClear])
            }

            Button {
                Task { try? await Repository.shared.deleteCategory(id: categoryId) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(l10n[.settingsCategoryDelete])
        }
    }
}
