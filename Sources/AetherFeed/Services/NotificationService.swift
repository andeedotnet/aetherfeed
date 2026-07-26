import AppKit
import UserNotifications
import os

/// System notifications, gated by the settings toggles. "N new articles"
/// posts only while the app is in the background (in the foreground the
/// refresh is visible anyway); "digest ready" also posts in the
/// foreground — it is a completion signal the user actively waits for.
enum NotificationService {
    /// UNUserNotificationCenter only works with a bundle (not in a bare-binary run).
    private static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Without a delegate macOS silently drops notifications while the
    /// posting app is frontmost; this one presents them as banners.
    /// Stateless, hence the unchecked Sendable.
    private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate,
        @unchecked Sendable
    {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner]
        }
    }

    private static let foregroundPresenter = ForegroundPresenter()

    /// Called once at app launch: installs the foreground presenter and
    /// re-requests authorization when a toggle is enabled. The toggle-time
    /// request alone is not enough — replacing the ad-hoc signed bundle can
    /// drop the registration, which leaves notifications silently disabled.
    @MainActor
    static func setUpAtLaunch() async {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = foregroundPresenter
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "notifyNewArticles")
            || defaults.bool(forKey: "notifySummaryReady")
        {
            await requestAuthorization()
        }
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "AetherFeed", category: "notifications")

    /// A silently failing request leaves notifications dead with no trace —
    /// log the outcome so `log show` can answer "why did nothing appear?".
    static func requestAuthorization() async {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge])
            let status = await center.notificationSettings().authorizationStatus
            log.info("authorization granted: \(granted), status: \(status.rawValue)")
        } catch {
            log.error("authorization request failed: \(error)")
        }
    }

    @MainActor
    static func postNewArticles(count: Int) async {
        await post(
            count: count, settingKey: "notifyNewArticles",
            bodyKey: .notifyNewArticlesBody, onlyInBackground: true)
    }

    /// After the home page digest was (re)generated successfully.
    @MainActor
    static func postDigestReady() async {
        await post(
            count: 1, settingKey: "notifySummaryReady",
            bodyKey: .notifyDigestReadyBody, onlyInBackground: false)
    }

    @MainActor
    private static func post(
        count: Int, settingKey: String, bodyKey: L10nKey, onlyInBackground: Bool
    ) async {
        guard count > 0,
              UserDefaults.standard.bool(forKey: settingKey),
              isAvailable,
              !(onlyInBackground && NSApp.isActive)
        else { return }

        let content = UNMutableNotificationContent()
        content.title = "AetherFeed"
        content.body = String(format: L10nKey.localizedOffMain(bodyKey), count)
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            log.info("posted \(settingKey, privacy: .public) (count: \(count))")
        } catch {
            log.error("posting \(settingKey, privacy: .public) failed: \(error)")
        }
    }
}
