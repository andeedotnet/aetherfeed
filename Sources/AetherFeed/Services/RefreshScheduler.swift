import Foundation
import Observation

/// Automatic feed refresh: once shortly after launch, then cyclically
/// according to the setting. Interval changes restart the loop;
/// 0 means "manual only", -1 "once at launch only".
@MainActor
final class RefreshScheduler {
    private let settings: SettingsStore
    private let store: AppStore
    private var loop: Task<Void, Never>?

    init(settings: SettingsStore, store: AppStore) {
        self.settings = settings
        self.store = store
    }

    func start() {
        observeIntervalChanges()

        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.settings.refreshIntervalMinutes != 0 else { return }
            self.store.refreshAll()
            await self.runLoop()
        }
    }

    private func restart() {
        loop?.cancel()
        loop = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let minutes = settings.refreshIntervalMinutes
            if minutes > 0 {
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled else { return }
                store.refreshAll()
            } else {
                // Manual / launch-only mode: sleep until an interval change
                // restarts the loop.
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// `withObservationTracking` fires exactly once per change — re-register afterwards.
    private func observeIntervalChanges() {
        withObservationTracking {
            _ = settings.refreshIntervalMinutes
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.restart()
                self.observeIntervalChanges()
            }
        }
    }
}
