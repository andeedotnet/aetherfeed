import FoundationModels
import SwiftUI

struct SettingsView: View {
    @Environment(Localizer.self) private var l10n

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label(l10n[.settingsGeneral], systemImage: "gearshape") }
            AISettingsView()
                .tabItem { Label(l10n[.settingsAI], systemImage: "brain") }
            CategorySettingsView()
                .tabItem { Label(l10n[.settingsCategories], systemImage: "folder") }
            AdBlockSettingsView()
                .tabItem { Label(l10n[.settingsAdBlock], systemImage: "shield") }
        }
        .frame(width: 480)
    }
}

private struct GeneralSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(Localizer.self) private var l10n

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker(l10n[.appearance], selection: $settings.appearance) {
                    Text(l10n[.appearanceSystem]).tag(AppAppearance.system)
                    Text(l10n[.appearanceLight]).tag(AppAppearance.light)
                    Text(l10n[.appearanceDark]).tag(AppAppearance.dark)
                }
                Picker(l10n[.uiLanguage], selection: $settings.uiLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Picker(l10n[.summaryLanguage], selection: $settings.summaryLanguage) {
                    Text(l10n[.languageGerman]).tag(SummaryLanguage.de)
                    Text(l10n[.languageEnglish]).tag(SummaryLanguage.en)
                    Text(l10n[.languageItalian]).tag(SummaryLanguage.it)
                    Text(l10n[.languageFrench]).tag(SummaryLanguage.fr)
                    Text(l10n[.languageSpanish]).tag(SummaryLanguage.es)
                    Text(l10n[.summaryLanguageOriginal]).tag(SummaryLanguage.original)
                }
            } header: {
                Text(l10n[.settingsSectionAppearance])
            } footer: {
                Text(l10n[.uiLanguageRestartHint])
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(l10n[.settingsSectionFeeds]) {
                Picker(l10n[.refreshInterval], selection: $settings.refreshIntervalMinutes) {
                    Text(l10n[.refreshOff]).tag(0)
                    Text(l10n[.refreshOnLaunch]).tag(-1)
                    ForEach([5, 15, 30, 60, 120], id: \.self) { minutes in
                        Text(l10n[.refreshEveryMinutes, minutes]).tag(minutes)
                    }
                }
                Picker(l10n[.settingsRetention], selection: $settings.retentionDays) {
                    Text(l10n[.retentionUnlimited]).tag(0)
                    ForEach([7, 30, 90], id: \.self) { days in
                        Text(l10n[.retentionDaysFormat, days]).tag(days)
                    }
                }
            }

            Section(l10n[.settingsSectionNotifications]) {
                Toggle(l10n[.settingsNotifications], isOn: $settings.notifyNewArticles)
                    .onChange(of: settings.notifyNewArticles) { _, enabled in
                        if enabled {
                            Task { await NotificationService.requestAuthorization() }
                        }
                    }
                Toggle(l10n[.settingsNotifySummaries], isOn: $settings.notifySummaryReady)
                    .onChange(of: settings.notifySummaryReady) { _, enabled in
                        if enabled {
                            Task { await NotificationService.requestAuthorization() }
                        }
                    }
            }

            Section(l10n[.settingsSectionUpdates]) {
                Toggle(l10n[.settingsCheckUpdates], isOn: $settings.checkUpdatesAtLaunch)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AISettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(Localizer.self) private var l10n

    @State private var models: [String] = []
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testFailed = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker(l10n[.llmProvider], selection: $settings.llmProvider) {
                    if #available(macOS 26.0, *) {
                        Text(l10n[.providerApple]).tag(LLMProvider.appleIntelligence)
                    }
                    Text(l10n[.providerOllama]).tag(LLMProvider.ollama)
                    Text(l10n[.providerOpenAI]).tag(LLMProvider.openai)
                }
                .onChange(of: settings.llmProvider) {
                    models = []
                    testMessage = nil
                    Task { await LLMPipeline.shared.kick() }
                }
            }

            Section(l10n[.ollamaSectionConnection]) {
                switch settings.llmProvider {
                case .ollama:
                    TextField(
                        l10n[.ollamaHost], text: $settings.ollamaHost,
                        prompt: Text(verbatim: "ollama.example.com"))
                    Text(l10n[.ollamaHostHint])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        l10n[.ollamaPort], value: $settings.ollamaPort,
                        format: .number.grouping(.never))
                case .openai:
                    TextField(
                        l10n[.openaiBaseURL], text: $settings.openaiBaseURL,
                        prompt: Text(verbatim: "https://api.openai.com/v1"))
                    SecureField(
                        l10n[.openaiAPIKey], text: $settings.openaiAPIKey,
                        prompt: Text(verbatim: "sk-…"))
                case .appleIntelligence:
                    // On-device model: nothing to configure, just show status.
                    LabeledContent(l10n[.appleStatus]) {
                        Text(appleStatusText)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        if isTesting { ProgressView().controlSize(.small) }
                        if let testMessage {
                            Text(testMessage)
                                .font(.callout)
                                .foregroundStyle(
                                    testFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        }
                        Spacer()
                        Button(l10n[.settingsOllamaTest]) { testConnection() }
                            .disabled(isTesting || !canTest)
                    }
                } label: {
                    EmptyView()
                }
            }

            Section {
                if settings.llmProvider == .appleIntelligence {
                    // Exactly one on-device model — nothing to pick.
                    LabeledContent(l10n[.ollamaModel]) {
                        Text(l10n[.appleModelName])
                            .foregroundStyle(.secondary)
                    }
                    // Only the on-device model spends this Mac's own energy.
                    Toggle(l10n[.settingsPauseOnBattery], isOn: $settings.pauseLLMOnBattery)
                        .onChange(of: settings.pauseLLMOnBattery) {
                            // Switching it off resumes right away.
                            Task { await LLMPipeline.shared.kick() }
                        }
                    Text(l10n[.settingsPauseOnBatteryHint])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker(l10n[.ollamaModel], selection: modelBinding) {
                        let current = modelBinding.wrappedValue
                        if current.isEmpty {
                            Text(verbatim: "–").tag("")
                        } else if !models.contains(current) {
                            Text(current).tag(current)
                        }
                        ForEach(models, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .onChange(of: modelBinding.wrappedValue) {
                        Task { await LLMPipeline.shared.kick() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: settings.llmProvider) {
            // Quietly preload models when the provider is configured.
            guard canTest, models.isEmpty,
                settings.llmProvider != .appleIntelligence else { return }
            models = (try? await currentClient().listModels()) ?? []
        }
    }

    private var canTest: Bool {
        switch settings.llmProvider {
        case .ollama: !settings.ollamaHost.trimmingCharacters(in: .whitespaces).isEmpty
        case .openai: !settings.openaiBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
        case .appleIntelligence: true
        }
    }

    private var appleStatusText: String {
        guard #available(macOS 26.0, *) else { return l10n[.errorAppleOSTooOld] }
        let model = SystemLanguageModel(
            useCase: .general, guardrails: .permissiveContentTransformations)
        return switch model.availability {
        case .available: l10n[.settingsAppleTestSuccess]
        case .unavailable(.deviceNotEligible): l10n[.errorAppleNotSupported]
        case .unavailable(.appleIntelligenceNotEnabled): l10n[.errorAppleNotEnabled]
        case .unavailable(.modelNotReady): l10n[.errorAppleModelNotReady]
        case .unavailable: l10n[.errorAppleUnavailable]
        }
    }

    /// The model field of the currently selected provider.
    private var modelBinding: Binding<String> {
        switch settings.llmProvider {
        case .ollama:
            Binding(get: { settings.ollamaModel }, set: { settings.ollamaModel = $0 })
        case .openai:
            Binding(get: { settings.openaiModel }, set: { settings.openaiModel = $0 })
        case .appleIntelligence:
            // No persisted model name; the on-device model is fixed.
            Binding(get: { "" }, set: { _ in })
        }
    }

    private func currentClient() -> any LLMClient {
        switch settings.llmProvider {
        case .ollama:
            OllamaClient(
                config: OllamaConfig(
                    host: settings.ollamaHost, port: settings.ollamaPort,
                    model: settings.ollamaModel))
        case .openai:
            OpenAIClient(
                config: OpenAIConfig(
                    baseURL: settings.openaiBaseURL, apiKey: settings.openaiAPIKey,
                    model: settings.openaiModel))
        case .appleIntelligence:
            if #available(macOS 26.0, *) {
                AppleIntelligenceClient()
            } else {
                UnavailableLLMClient()
            }
        }
    }

    private func testConnection() {
        guard
            !AIPowerGate.blocks(
                provider: settings.llmProvider, settingEnabled: settings.pauseLLMOnBattery,
                onBattery: PowerMonitor.shared.isOnBattery)
        else {
            testMessage = l10n[.aiPausedOnBattery]
            testFailed = true
            return
        }
        isTesting = true
        testMessage = nil
        let client = currentClient()
        Task {
            do {
                let list = try await client.listModels()
                models = list
                testMessage = settings.llmProvider == .appleIntelligence
                    ? l10n[.settingsAppleTestSuccess]
                    : l10n[.settingsOllamaTestSuccess, list.count]
                testFailed = false
                if modelBinding.wrappedValue.isEmpty, let first = list.first {
                    modelBinding.wrappedValue = first
                }
                await LLMPipeline.shared.kick()
            } catch {
                testMessage = error.localizedDescription
                testFailed = true
            }
            isTesting = false
        }
    }
}
