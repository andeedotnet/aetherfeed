import SwiftUI

@main
struct AetherFeedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var settings: SettingsStore
    @State private var localizer: Localizer
    @State private var store: AppStore

    init() {
        // Open and migrate the database immediately — errors should surface
        // at startup, not on first access.
        _ = DatabaseManager.shared

        let settings = SettingsStore()
        _settings = State(initialValue: settings)
        _localizer = State(initialValue: Localizer(settings: settings))
        _store = State(initialValue: AppStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(localizer)
                .environment(store)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(localizer[.addFeed] + " …") {
                    store.showAddFeed = true
                }
                // ⌘N belongs to the system's "New Window".
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button(localizer[.opmlImport]) {
                    store.showOPMLImporter = true
                }
                Button(localizer[.opmlExport]) {
                    store.prepareOPMLExport()
                }
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(localizer)
                .environment(store)
        }
    }
}
