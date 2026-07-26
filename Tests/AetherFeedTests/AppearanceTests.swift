import AppKit
import Foundation
import Testing

@testable import AetherFeed

@Suite struct AppearanceTests {
    @Test func systemFollowsTheSystemSettingOthersPinIt() {
        #expect(AppAppearance.system.nsAppearance == nil)
        #expect(AppAppearance.light.nsAppearance?.name == .aqua)
        #expect(AppAppearance.dark.nsAppearance?.name == .darkAqua)
    }

    @Test func storedChoiceRoundTripsAndDefaultsToSystem() {
        let defaults = UserDefaults.standard
        let key = "appAppearance"
        let previous = defaults.string(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.set(AppAppearance.dark.rawValue, forKey: key)
        #expect(AppAppearance.current == .dark)

        // Never set, and a stale value from a future version, both fall back.
        defaults.removeObject(forKey: key)
        #expect(AppAppearance.current == .system)
        defaults.set("sepia", forKey: key)
        #expect(AppAppearance.current == .system)
    }
}
