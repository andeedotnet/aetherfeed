import Testing

@testable import AetherFeed

@Suite struct LocalizationTests {
    private static let tables: [(language: String, table: [L10nKey: String])] = [
        ("de", L10nKey.german),
        ("en", L10nKey.english),
        ("it", L10nKey.italian),
        ("fr", L10nKey.french),
        ("es", L10nKey.spanish),
    ]

    @Test func everyTableCoversEveryKey() {
        for (language, table) in Self.tables {
            let missing = L10nKey.allCases.filter { table[$0] == nil }
            #expect(missing.isEmpty, "\(language) is missing \(missing.map(\.rawValue))")
        }
    }

    /// A translation with different format placeholders than English would
    /// crash `String(format:)` at runtime — catch it here instead.
    @Test func formatPlaceholdersMatchEnglish() {
        func placeholders(_ text: String) -> [String] {
            ["%d", "%@"].flatMap { marker in
                Array(repeating: marker, count: text.components(separatedBy: marker).count - 1)
            }
        }
        for (language, table) in Self.tables where language != "en" {
            for key in L10nKey.allCases {
                guard let text = table[key], let english = L10nKey.english[key] else { continue }
                #expect(
                    placeholders(text).sorted() == placeholders(english).sorted(),
                    "\(language).\(key.rawValue): placeholder mismatch")
            }
        }
    }

    @Test func everyAppLanguageHasATable() {
        for language in AppLanguage.allCases {
            #expect(!L10nKey.table(for: language).isEmpty)
        }
    }
}
