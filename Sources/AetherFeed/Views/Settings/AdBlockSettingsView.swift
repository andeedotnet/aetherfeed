import SwiftUI

struct AdBlockSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(Localizer.self) private var l10n
    private var manager: AdBlockManager { AdBlockManager.shared }

    @State private var newURL = ""

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(l10n[.adBlockEnable], isOn: $settings.adBlockEnabled)
                    .onChange(of: settings.adBlockEnabled) {
                        Task { await manager.reload() }
                    }
            }

            Section(l10n[.adBlockLists]) {
                if settings.blocklistURLs.isEmpty {
                    Text(l10n[.adBlockNoLists])
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(settings.blocklistURLs.enumerated()), id: \.offset) { index, url in
                    listRow(url: url, index: index, settings: settings)
                }

                HStack {
                    TextField(
                        l10n[.adBlockAddPlaceholder], text: $newURL,
                        prompt: Text(verbatim: "https://example.com/blocklist.txt")
                    )
                    .autocorrectionDisabled()
                    .onSubmit { addURL(settings: settings) }
                    Button(l10n[.addFeedAdd]) { addURL(settings: settings) }
                        .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                HStack {
                    Button {
                        Task { await manager.refresh(force: true) }
                    } label: {
                        Label(l10n[.adBlockUpdateNow], systemImage: "arrow.clockwise")
                    }
                    .disabled(!settings.adBlockEnabled || manager.isUpdating
                        || settings.blocklistURLs.isEmpty)

                    if manager.isUpdating {
                        ProgressView().controlSize(.small)
                        Text(l10n[.adBlockUpdating]).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !manager.isUpdating && manager.totalRuleCount > 0 {
                        Text(l10n[.adBlockActiveRules, manager.totalRuleCount])
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(l10n[.adBlockHint]).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func listRow(url: String, index: Int, settings: SettingsStore) -> some View {
        let status = manager.statuses.first { $0.url == url }
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(url)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    settings.blocklistURLs.remove(at: index)
                    Task { await manager.reload() }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            if let status {
                if let error = status.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if status.ruleCount > 0 {
                    Text(l10n[.adBlockActiveRules, status.ruleCount])
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func addURL(settings: SettingsStore) {
        let trimmed = newURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !settings.blocklistURLs.contains(trimmed) else { return }
        settings.blocklistURLs.append(trimmed)
        newURL = ""
        Task { await manager.reload() }
    }
}
