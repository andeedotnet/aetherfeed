import SwiftUI

struct CategorySettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(Localizer.self) private var l10n

    /// Category currently hovered as a drop target — draws the insertion line.
    @State private var dropTarget: Int64?

    var body: some View {
        Form {
            if store.sidebar.categories.isEmpty {
                Text(l10n[.settingsCategoriesEmpty])
                    .foregroundStyle(.secondary)
            } else {
                // Reordering by hand instead of List's .onMove: only a Form
                // gives the grouped card the other settings tabs use, and a
                // Form does not support .onMove.
                ForEach(Array(store.sidebar.categories.enumerated()), id: \.element.id) {
                    index, group in
                    CategoryRow(
                        categoryId: group.id,
                        initialName: group.name,
                        initialColorHex: group.colorHex,
                        feedCount: group.feeds.count
                    )
                    // .id forces fresh row state after rename/delete.
                    .id("\(group.id)-\(group.name)")
                    .draggable(String(group.id))
                    .dropDestination(for: String.self) { items, _ in
                        dropTarget = nil
                        guard let dragged = items.first.flatMap(Int64.init) else { return false }
                        return move(dragged, to: index)
                    } isTargeted: { targeted in
                        if targeted {
                            dropTarget = group.id
                        } else if dropTarget == group.id {
                            dropTarget = nil
                        }
                    }
                    .overlay(alignment: .top) {
                        if dropTarget == group.id {
                            Rectangle()
                                .fill(.tint)
                                .frame(height: 2)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// `move(fromOffsets:toOffset:)` inserts *before* the target index, so
    /// dragging downwards needs the index after the target row.
    private func move(_ categoryId: Int64, to index: Int) -> Bool {
        guard let source = store.sidebar.categories.firstIndex(where: { $0.id == categoryId }),
              source != index
        else { return false }
        store.moveCategories(
            from: IndexSet(integer: source), to: source < index ? index + 1 : index)
        return true
    }
}

private struct CategoryRow: View {
    let categoryId: Int64
    let feedCount: Int
    @State private var name: String
    /// Last picked color — only shown while `hasColor` is true.
    @State private var color: Color
    /// A category without a color must show the neutral sidebar color
    /// instead of faking one, and must not persist a color until the user
    /// actually picks one.
    @State private var hasColor: Bool
    @Environment(Localizer.self) private var l10n

    init(categoryId: Int64, initialName: String, initialColorHex: String?, feedCount: Int) {
        self.categoryId = categoryId
        self.feedCount = feedCount
        _name = State(initialValue: initialName)
        _color = State(initialValue: Color(hex: initialColorHex) ?? .secondary)
        _hasColor = State(initialValue: initialColorHex != nil)
    }

    /// Reading yields the category's actual color (neutral when it has
    /// none); writing only happens on a user pick — so clearing the color
    /// can reset the well without persisting anything back.
    private var pickedColor: Binding<Color> {
        Binding(
            get: { hasColor ? color : .secondary },
            set: { newColor in
                color = newColor
                hasColor = true
                Task {
                    try? await Repository.shared.setCategoryColor(
                        id: categoryId, hex: newColor.hexString)
                }
            }
        )
    }

    var body: some View {
        HStack {
            // Affordance for the list's drag-and-drop ordering; the whole
            // row is draggable, this only makes that discoverable.
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help(l10n[.settingsCategoryReorderHint])

            TextField(text: $name) { EmptyView() }
                .labelsHidden()
                .onSubmit {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    Task { try? await Repository.shared.renameCategory(id: categoryId, to: trimmed) }
                }

            // Round swatch: the stock well is a wide pill, so it is clipped
            // to a circle of its own height.
            ColorPicker(selection: pickedColor, supportsOpacity: false) { EmptyView() }
                .labelsHidden()
                .frame(width: 22, height: 22)
                .clipShape(Circle())
                .help(l10n[.settingsCategoryColor])

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
