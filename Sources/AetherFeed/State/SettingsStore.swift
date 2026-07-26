import AppKit
import Foundation
import Observation

/// App appearance override. `system` (the default) follows the system
/// setting; the others pin the app to light or dark regardless of it.
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// nil = follow the system setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The stored choice, readable without the settings store (at launch).
    static var current: AppAppearance {
        UserDefaults.standard.string(forKey: "appAppearance")
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    /// Setting it on NSApp — not `.preferredColorScheme` — is what also
    /// covers the AppKit chrome: title bar, toolbar, menus, and the
    /// separate settings window. SwiftUI views and the article WebView
    /// inherit from it.
    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }
}

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case de
    case en
    case it
    case fr
    case es

    var id: String { rawValue }

    /// Endonym for the language picker (the same in every UI language).
    var displayName: String {
        switch self {
        case .de: "Deutsch"
        case .en: "English"
        case .it: "Italiano"
        case .fr: "Français"
        case .es: "Español"
        }
    }

    static var systemDefault: AppLanguage {
        AppLanguage(rawValue: Locale.current.language.languageCode?.identifier ?? "") ?? .en
    }
}

enum SummaryLanguage: String, CaseIterable, Identifiable, Sendable {
    case de
    case en
    case it
    case fr
    case es
    /// Summary in the original language of the respective article.
    case original

    var id: String { rawValue }
}

@MainActor
@Observable
final class SettingsStore {
    private static let defaults = UserDefaults.standard

    var llmProvider: LLMProvider {
        didSet { Self.defaults.set(llmProvider.rawValue, forKey: "llmProvider") }
    }
    var ollamaHost: String {
        didSet { Self.defaults.set(ollamaHost, forKey: "ollamaHost") }
    }
    var ollamaPort: Int {
        didSet { Self.defaults.set(ollamaPort, forKey: "ollamaPort") }
    }
    var ollamaModel: String {
        didSet { Self.defaults.set(ollamaModel, forKey: "ollamaModel") }
    }
    var openaiBaseURL: String {
        didSet { Self.defaults.set(openaiBaseURL, forKey: "openaiBaseURL") }
    }
    var openaiAPIKey: String {
        didSet { Self.defaults.set(openaiAPIKey, forKey: "openaiAPIKey") }
    }
    var openaiModel: String {
        didSet { Self.defaults.set(openaiModel, forKey: "openaiModel") }
    }
    /// Light/dark override; takes effect immediately, no restart needed.
    var appearance: AppAppearance {
        didSet {
            Self.defaults.set(appearance.rawValue, forKey: "appAppearance")
            appearance.apply()
        }
    }
    var uiLanguage: AppLanguage {
        didSet {
            Self.defaults.set(uiLanguage.rawValue, forKey: "uiLanguage")
            Self.syncSystemLanguage(uiLanguage)
        }
    }
    var summaryLanguage: SummaryLanguage {
        didSet { Self.defaults.set(summaryLanguage.rawValue, forKey: "summaryLanguage") }
    }
    /// 0 = manual only; -1 = once at launch; > 0 = at launch and every N minutes.
    var refreshIntervalMinutes: Int {
        didSet { Self.defaults.set(refreshIntervalMinutes, forKey: "refreshIntervalMinutes") }
    }
    /// 0 = keep forever; otherwise read articles are deleted after N days.
    var retentionDays: Int {
        didSet { Self.defaults.set(retentionDays, forKey: "retentionDays") }
    }
    var notifyNewArticles: Bool {
        didSet { Self.defaults.set(notifyNewArticles, forKey: "notifyNewArticles") }
    }

    var notifySummaryReady: Bool {
        didSet { Self.defaults.set(notifySummaryReady, forKey: "notifySummaryReady") }
    }
    /// Query GitHub releases once at launch; the update itself always
    /// stays a manual click.
    var checkUpdatesAtLaunch: Bool {
        didSet { Self.defaults.set(checkUpdatesAtLaunch, forKey: "checkUpdatesAtLaunch") }
    }
    /// Detail view preference: feed text instead of the article's web page.
    var showFeedTextInDetail: Bool {
        didSet { Self.defaults.set(showFeedTextInDetail, forKey: "showFeedTextInDetail") }
    }
    var adBlockEnabled: Bool {
        didSet { Self.defaults.set(adBlockEnabled, forKey: "adBlockEnabled") }
    }
    /// Adblock-format blocklist URLs applied to the article WebView.
    var blocklistURLs: [String] {
        didSet { Self.defaults.set(blocklistURLs, forKey: "blocklistURLs") }
    }

    init() {
        let defaults = Self.defaults
        llmProvider = defaults.string(forKey: "llmProvider")
            .flatMap(LLMProvider.init(rawValue:)) ?? .defaultProvider
        ollamaHost = defaults.string(forKey: "ollamaHost") ?? ""
        ollamaPort = defaults.object(forKey: "ollamaPort") as? Int ?? 11434
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? ""
        openaiBaseURL = defaults.string(forKey: "openaiBaseURL") ?? "https://api.openai.com/v1"
        openaiAPIKey = defaults.string(forKey: "openaiAPIKey") ?? ""
        openaiModel = defaults.string(forKey: "openaiModel") ?? ""
        // No apply() here — NSApp is not reliably up yet; the AppDelegate
        // applies the stored appearance at launch.
        appearance = AppAppearance.current
        uiLanguage = defaults.string(forKey: "uiLanguage")
            .flatMap(AppLanguage.init(rawValue:)) ?? .systemDefault
        summaryLanguage = defaults.string(forKey: "summaryLanguage")
            .flatMap(SummaryLanguage.init(rawValue:)) ?? .de
        refreshIntervalMinutes = defaults.object(forKey: "refreshIntervalMinutes") as? Int ?? 30
        retentionDays = defaults.object(forKey: "retentionDays") as? Int ?? 0
        notifyNewArticles = defaults.bool(forKey: "notifyNewArticles")
        notifySummaryReady = defaults.bool(forKey: "notifySummaryReady")
        checkUpdatesAtLaunch = defaults.object(forKey: "checkUpdatesAtLaunch") as? Bool ?? true
        showFeedTextInDetail = defaults.bool(forKey: "showFeedTextInDetail")
        adBlockEnabled = defaults.bool(forKey: "adBlockEnabled")
        blocklistURLs = defaults.stringArray(forKey: "blocklistURLs") ?? []

        Self.syncSystemLanguage(uiLanguage)
    }

    /// System menus (File/Ablage …) come from AppKit and follow the app
    /// localization, not our Localizer. AppleLanguages overrides the
    /// language choice per app — takes effect from the next launch.
    private static func syncSystemLanguage(_ language: AppLanguage) {
        defaults.set([language.rawValue], forKey: "AppleLanguages")
    }
}
