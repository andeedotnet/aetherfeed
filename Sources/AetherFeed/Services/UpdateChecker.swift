import AppKit
import CryptoKit
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
    private var checksumURL: URL?
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

    private enum UpdateError: Error {
        case untrustedURL
        case httpStatus(Int)
        case digestMismatch
        case noAppInArchive
    }

    /// The update replaces the running binary, so every URL taken from the
    /// API response must still point at GitHub over TLS — a redirected or
    /// substituted asset URL would otherwise be a code-execution channel.
    nonisolated static func isTrustedReleaseURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com")
            || host.hasSuffix(".githubusercontent.com")
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
            guard Self.isTrustedReleaseURL(asset.browserDownloadUrl) else {
                log.error("release \(remote, privacy: .public): asset URL is not a GitHub https URL")
                return
            }
            availableVersion = remote.hasPrefix("v") ? String(remote.dropFirst()) : remote
            downloadURL = asset.browserDownloadUrl
            // Optional companion asset "<zip>.sha256": guards against a
            // corrupted or swapped asset. It travels the same TLS-protected
            // API response, so it is no defence against a compromised
            // account — only signing/notarization would be.
            checksumURL = release.assets
                .first { $0.name == asset.name + ".sha256" }
                .map(\.browserDownloadUrl)
                .flatMap { Self.isTrustedReleaseURL($0) ? $0 : nil }
            releaseURL = Self.isTrustedReleaseURL(release.htmlUrl) ? release.htmlUrl : nil
            log.info("update available: \(remote, privacy: .public)")
        } catch {
            log.info("release check failed: \(error)")
        }
    }

    /// Downloads the release zip, swaps the running bundle, relaunches.
    /// Our own URLSession download carries no quarantine attribute, so the
    /// swapped ad-hoc signed app launches without Gatekeeper involvement —
    /// which is exactly why the URL is restricted to GitHub over TLS and
    /// the archive is checked against its published digest when there is
    /// one. On failure the old bundle is restored and the release page
    /// opens in the browser as a manual fallback.
    func performUpdate() async {
        guard !isUpdating, let downloadURL, Self.isTrustedReleaseURL(downloadURL) else { return }
        isUpdating = true
        defer { isUpdating = false }

        var staging: URL?
        do {
            let (zipFile, response) = try await URLSession.shared.download(from: downloadURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw UpdateError.httpStatus(status) }
            try await verifyDigest(of: zipFile)

            let stagingURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("AetherFeed-update-\(UUID().uuidString)")
            staging = stagingURL
            try FileManager.default.createDirectory(
                at: stagingURL, withIntermediateDirectories: true)
            try await Self.run("/usr/bin/ditto", "-x", "-k", zipFile.path, stagingURL.path)

            guard
                let newApp = try FileManager.default
                    .contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" })
            else { throw UpdateError.noAppInArchive }

            let target = Bundle.main.bundleURL
            let parked = FileManager.default.temporaryDirectory
                .appendingPathComponent("AetherFeed-old-\(UUID().uuidString).app")
            try FileManager.default.moveItem(at: target, to: parked)
            do {
                try FileManager.default.moveItem(at: newApp, to: target)
            } catch {
                // Put the old bundle back — a broken swap must not leave
                // the user without any app.
                do {
                    try FileManager.default.moveItem(at: parked, to: target)
                } catch {
                    log.error(
                        "restore failed, previous app kept at \(parked.path, privacy: .public)")
                }
                throw error
            }
            try? FileManager.default.removeItem(at: parked)
            try? FileManager.default.removeItem(at: stagingURL)

            log.info("update installed, relaunching")
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            // The path travels as an argument ($0), never inside the script
            // string — an install path containing quotes or $(…) must not
            // become shell syntax.
            relaunch.arguments = ["-c", "sleep 1; open \"$0\"", target.path]
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            if let staging { try? FileManager.default.removeItem(at: staging) }
            log.error("update failed: \(error)")
            if let releaseURL {
                WorkspaceOpener.open(releaseURL)
            }
        }
    }

    /// Compares the downloaded archive against the release's `.sha256`
    /// asset. No such asset (older releases) means no check.
    private func verifyDigest(of zipFile: URL) async throws {
        guard let checksumURL else { return }
        let (data, response) = try await URLSession.shared.data(from: checksumURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.httpStatus(status) }
        // Accepts both a bare digest and `shasum`'s "<digest>  <file>".
        guard
            let expected = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased()
        else { throw UpdateError.digestMismatch }

        let actual = SHA256.hash(data: try Data(contentsOf: zipFile))
            .map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            log.error("update rejected: archive digest does not match the published one")
            throw UpdateError.digestMismatch
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
