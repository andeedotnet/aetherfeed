import Foundation
import Observation

/// Every visible UI string gets a key here; translations live in
/// Strings+de.swift / Strings+en.swift. No `.xcstrings`, because the UI language
/// must be switchable at runtime and the project builds without Xcode.
enum L10nKey: String {
    case welcomeTitle
    case welcomeSubtitle

    case settingsGeneral
    case settingsOllama
    case uiLanguage
    case summaryLanguage
    case languageGerman
    case languageEnglish
    case summaryLanguageOriginal
    case refreshInterval
    case refreshOff
    case refreshOnLaunch
    case refreshEveryMinutes

    case ollamaSectionConnection
    case ollamaHost
    case ollamaPort
    case ollamaModel

    case sidebarAll
    case sidebarUnread
    case sidebarCategories
    case sidebarNoCategory
    case addFeed
    case addFeedURL
    case addFeedCategory
    case addFeedNoCategory
    case addFeedNewCategory
    case addFeedAdd
    case cancel
    case deleteFeed
    case refresh
    case openInBrowser
    case noArticleSelected
    case emptyListTitle
    case untitledArticle
    case errorInvalidURL
    case errorHTTP
    case errorNotAFeed

    case sidebarTags
    case settingsOllamaTest
    case settingsOllamaTestSuccess
    case aiSummary
    case aiProcessing
    case aiPaused
    case retry
    case errorLLMNotConfigured
    case errorLLMNoModel
    case errorLLMUnreachable
    case errorLLMUnauthorized
    case errorLLMBadResponse

    case settingsAI
    case llmProvider
    case providerOllama
    case providerOpenAI
    case openaiBaseURL
    case openaiAPIKey

    case sidebarHome
    case digestTitle
    case digestUpdated
    case digestEmpty
    case digestEmptyHint
    case digestEmptyCreating
    case addFeedSuggest

    case searchPrompt
    case opmlImport
    case opmlExport
    case settingsCategories
    case settingsCategoriesEmpty
    case settingsCategoryDelete

    case markAllRead
    case settingsRetention
    case retentionUnlimited
    case retentionDaysFormat
    case settingsNotifications
    case notifyNewArticlesBody

    case digestGenerating
    case digestNoArticles
    case uiLanguageRestartHint
    case digestOverviewTitle
    case digestOverviewEmpty
    case detailShowWebPage
    case detailShowFeedText
    case shareLink
    case pendingSummariesHelp
    case settingsCategoryColor
    case settingsCategoryColorClear

    case settingsAdBlock
    case adBlockEnable
    case adBlockLists
    case adBlockNoLists
    case adBlockAddPlaceholder
    case adBlockUpdateNow
    case adBlockUpdating
    case adBlockActiveRules
    case adBlockHint
    case adBlockTurnOn
    case adBlockTurnOff

    case providerApple
    case appleModelName
    case appleStatus
    case settingsAppleTestSuccess
    case errorAppleNotSupported
    case errorAppleNotEnabled
    case errorAppleModelNotReady
    case errorAppleOSTooOld
    case errorAppleUnavailable
    case errorAppleRejected

    case digestReadAloud
    case digestStopReading

    case settingsNotifySummaries
    case notifyDigestReadyBody

    case aiFailedTitle
    case aiFailedUnknown
    case feedErrorHelp
    case markRead
    case markUnread
    case copyLink
    case renameFeed
    case renameFeedSave
    case moveToCategory
    case sidebarStarred
    case star
    case unstar
    case exportMenu
    case exportMarkdown
    case exportPDF
}

extension L10nKey {
    /// Localization outside the MainActor (e.g. LocalizedError in actors):
    /// reads the UI language directly from UserDefaults instead of via the Localizer.
    static func localizedOffMain(_ key: L10nKey) -> String {
        let language = UserDefaults.standard.string(forKey: "uiLanguage")
            .flatMap(AppLanguage.init(rawValue:)) ?? .systemDefault
        let table = language == .de ? german : english
        return table[key] ?? english[key] ?? key.rawValue
    }
}

@MainActor
@Observable
final class Localizer {
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var language: AppLanguage { settings.uiLanguage }

    subscript(_ key: L10nKey) -> String {
        table[key] ?? L10nKey.english[key] ?? key.rawValue
    }

    subscript(_ key: L10nKey, _ args: CVarArg...) -> String {
        String(format: self[key], arguments: args)
    }

    private var table: [L10nKey: String] {
        switch language {
        case .de: L10nKey.german
        case .en: L10nKey.english
        }
    }
}
