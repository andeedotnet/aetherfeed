import Foundation
import IOKit.ps
import Observation

/// Tracks whether the Mac currently runs on battery. Desktops without a
/// battery always report AC power, so the battery gate never fires there.
@MainActor
@Observable
final class PowerMonitor {
    static let shared = PowerMonitor()

    private(set) var isOnBattery = PowerMonitor.currentlyOnBattery()
    private var source: CFRunLoopSource?

    /// Synchronous IOKit query, callable from any actor — no MainActor hop
    /// and no dependency on `startAtLaunch()` having run.
    nonisolated static func currentlyOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
                as String?
        else { return false }
        return type == kIOPSBatteryPowerValue
    }

    /// Subscribes to power source changes for the rest of the app's lifetime.
    /// Reconnecting the charger resumes the LLM pipeline without user action.
    func startAtLaunch() {
        guard source == nil,
            let source = IOPSNotificationCreateRunLoopSource(Self.changed, nil)?
                .takeRetainedValue()
        else { return }
        self.source = source
        // Common modes so the change also lands while a menu or sheet is up.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    /// C callback — captures nothing, so it converts to a function pointer.
    /// The run loop source is scheduled on the main run loop, hence the
    /// callback always arrives on the main thread.
    private static let changed: IOPowerSourceCallbackType = { _ in
        MainActor.assumeIsolated { PowerMonitor.shared.powerSourceChanged() }
    }

    private func powerSourceChanged() {
        // Fires for every power source update (charge level included) —
        // only the AC/battery transition is interesting.
        let onBattery = Self.currentlyOnBattery()
        guard onBattery != isOnBattery else { return }
        isOnBattery = onBattery
        if !onBattery {
            Task { await LLMPipeline.shared.kick() }
        }
    }
}

/// Single rule for "on-device AI has to stay idle right now". Only Apple
/// Intelligence computes on this Mac; Ollama and OpenAI run remotely and
/// cost no local energy, so they are never gated.
enum AIPowerGate {
    /// Pure form of the rule — the runtime inputs are passed in so views can
    /// evaluate it against observable state and tests against fixed values.
    static func blocks(provider: LLMProvider, settingEnabled: Bool, onBattery: Bool) -> Bool {
        provider == .appleIntelligence && settingEnabled && onBattery
    }

    /// Runtime evaluation for background workers, reading the setting straight
    /// from UserDefaults like the other off-MainActor settings consumers.
    static var isBlocking: Bool {
        blocks(
            provider: .current, settingEnabled: pauseOnBatteryEnabled,
            onBattery: PowerMonitor.currentlyOnBattery())
    }

    /// Mirrors `SettingsStore.pauseLLMOnBattery`, including its `true` default.
    static var pauseOnBatteryEnabled: Bool {
        UserDefaults.standard.object(forKey: "pauseLLMOnBattery") as? Bool ?? true
    }

    static var message: String { L10nKey.localizedOffMain(.aiPausedOnBattery) }
}
