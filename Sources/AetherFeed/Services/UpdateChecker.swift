import AppKit
import Observation
import os

/// Checks the GitHub releases of this app at launch (opt-out via settings)
/// and performs the in-place self-update once the user clicks the toolbar
/// indicator: download the release zip, swap the app bundle, relaunch.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    private static let repo = "andeedotnet/aetherfeed"

    /// Newer version available on GitHub (e.g. "0.2.0"); nil = up to date
    /// or not checked. Drives the toolbar indicator.
    private(set) var availableVersion: String?
    private(set) var isUpdating = false

    private var downloadURL: URL?
    private var releaseURL: URL?

    /// Launch checks must never annoy: every failure (offline, rate limit,
    /// no release yet) only lands here.
    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "AetherFeed", category: "updates")

    private struct Release: Decodable {
        struct Asset: Decodable {
            var name: String
            var browserDownloadUrl: URL
        }

        var tagName: String
        var htmlUrl: URL
        var assets: [Asset]
    }

    /// Compares the latest GitHub release against the running version.
    /// Skipped in bare-binary runs (no version, no swappable bundle) and
    /// when the settings toggle is off.
    func checkAtLaunch() async {
        guard UserDefaults.standard.object(forKey: "checkUpdatesAtLaunch") as? Bool ?? true,
              Bundle.main.bundleIdentifier != nil,
              let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")
        else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                log.info("release check: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(Release.self, from: data)

            let remote = release.tagName
            guard Self.isNewer(remote, than: current) else {
                log.info("release check: up to date (\(current, privacy: .public))")
                return
            }
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
                log.error("release \(remote, privacy: .public) has no zip asset")
                return
            }
            availableVersion = remote.hasPrefix("v") ? String(remote.dropFirst()) : remote
            downloadURL = asset.browserDownloadUrl
            releaseURL = release.htmlUrl
            log.info("update available: \(remote, privacy: .public)")
        } catch {
            log.info("release check failed: \(error)")
        }
    }

    /// Downloads the release zip, swaps the running bundle, relaunches.
    /// Our own URLSession download carries no quarantine attribute, so the
    /// swapped ad-hoc signed app launches without Gatekeeper involvement.
    /// On failure the old bundle is restored and the release page opens in
    /// the browser as a manual fallback.
    func performUpdate() async {
        guard !isUpdating, let downloadURL else { return }
        isUpdating = true
        defer { isUpdating = false }

        do {
            let (zipFile, _) = try await URLSession.shared.download(from: downloadURL)
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("AetherFeed-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true)
            try await Self.run("/usr/bin/ditto", "-x", "-k", zipFile.path, staging.path)

            guard
                let newApp = try FileManager.default
                    .contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" })
            else { throw CocoaError(.fileNoSuchFile) }

            let target = Bundle.main.bundleURL
            let parked = FileManager.default.temporaryDirectory
                .appendingPathComponent("AetherFeed-old-\(UUID().uuidString).app")
            try FileManager.default.moveItem(at: target, to: parked)
            do {
                try FileManager.default.moveItem(at: newApp, to: target)
            } catch {
                // Put the old bundle back — a broken swap must not leave
                // the user without any app.
                try? FileManager.default.moveItem(at: parked, to: target)
                throw error
            }

            log.info("update installed, relaunching")
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; open \"\(target.path)\""]
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            log.error("update failed: \(error)")
            if let releaseURL {
                NSWorkspace.shared.open(releaseURL)
            }
        }
    }

    private static func run(_ executable: String, _ arguments: String...) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    // MARK: - Version comparison

    /// "v0.1.0" / "0.1.0" → [0, 1, 0]; nil when the tag has no leading
    /// numeric component at all.
    nonisolated static func parseVersion(_ tag: String) -> [Int]? {
        var text = tag.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text = String(text.dropFirst()) }
        let parts = text.split(separator: ".").map { component in
            Int(component.prefix(while: \.isNumber))
        }
        guard let first = parts.first, first != nil else { return nil }
        return parts.compactMap { $0 }
    }

    /// Numeric semver comparison, shorter versions padded with zeros —
    /// "0.10.0" beats "0.9.9", "0.1" equals "0.1.0". Unparsable input is
    /// never "newer".
    nonisolated static func isNewer(_ remote: String, than current: String) -> Bool {
        guard let remote = parseVersion(remote), let current = parseVersion(current) else {
            return false
        }
        let count = max(remote.count, current.count)
        let pad = { (v: [Int]) in v + Array(repeating: 0, count: count - v.count) }
        return pad(remote).lexicographicallyPrecedes(pad(current)) == false
            && pad(remote) != pad(current)
    }
}
