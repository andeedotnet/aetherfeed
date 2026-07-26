import CryptoKit
import Foundation
import Observation
import WebKit

/// Downloads Adblock-format blocklists, converts them to WebKit content rules,
/// compiles them (persistently cached in `WKContentRuleListStore`), and exposes
/// the compiled `[WKContentRuleList]` to the article WebView.
///
/// Reads its configuration (enabled flag + list URLs) directly from
/// UserDefaults, mirroring `OllamaConfig.current()`.
@MainActor
@Observable
final class AdBlockManager {
    static let shared = AdBlockManager()

    struct ListStatus: Identifiable, Sendable {
        var id: String { url }
        var url: String
        var ruleCount: Int
        var fetchedAt: Date?
        var error: String?
    }

    private(set) var ruleLists: [WKContentRuleList] = []
    /// Bumped whenever `ruleLists` changes so the WebView re-applies them.
    private(set) var version = 0
    private(set) var isUpdating = false
    private(set) var statuses: [ListStatus] = []

    var totalRuleCount: Int { statuses.reduce(0) { $0 + $1.ruleCount } }

    private let store = WKContentRuleListStore.default()!
    private var cache: [String: CacheEntry] = [:]

    private static let staleInterval: TimeInterval = 7 * 24 * 3600
    private static let chunkSize = 25_000

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.httpAdditionalHeaders = ["User-Agent": SafariUserAgent.value]
        return URLSession(configuration: config)
    }()

    private init() {
        cache = Self.loadCache()
    }

    // MARK: - Configuration (from UserDefaults)

    private var enabled: Bool { UserDefaults.standard.bool(forKey: "adBlockEnabled") }

    private var listURLs: [String] {
        (UserDefaults.standard.stringArray(forKey: "blocklistURLs") ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Lifecycle

    /// On launch: load cached compiled lists instantly, then refresh stale ones.
    func startAtLaunch() async {
        guard enabled else { return }
        await loadFromCache()
        if hasStaleOrMissing {
            await refresh(force: false)
        }
    }

    /// Called when the enabled flag or the URL list changes in Settings.
    func reload() async {
        guard enabled else {
            ruleLists = []
            statuses = []
            version += 1
            return
        }
        await loadFromCache()
        await refresh(force: false)
    }

    // MARK: - Refresh

    func refresh(force: Bool) async {
        guard enabled, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        var lists: [WKContentRuleList] = []
        var newStatuses: [ListStatus] = []
        let urls = listURLs

        for url in urls {
            do {
                let compiled = try await process(url: url, force: force)
                lists.append(contentsOf: compiled.lists)
                newStatuses.append(
                    ListStatus(
                        url: url, ruleCount: compiled.ruleCount,
                        fetchedAt: cache[url]?.fetchedAt, error: nil))
            } catch {
                // Keep previously compiled lists for this URL if we still have them.
                if let entry = cache[url],
                   let cached = try? await lookup(entry.chunkIdentifiers) {
                    lists.append(contentsOf: cached)
                }
                newStatuses.append(
                    ListStatus(
                        url: url, ruleCount: cache[url]?.ruleCount ?? 0,
                        fetchedAt: cache[url]?.fetchedAt,
                        error: error.localizedDescription))
            }
        }

        // Drop cache entries for URLs no longer configured.
        for staleURL in cache.keys where !urls.contains(staleURL) {
            if let ids = cache[staleURL]?.chunkIdentifiers { await remove(ids) }
            cache[staleURL] = nil
        }
        Self.saveCache(cache)

        ruleLists = lists
        statuses = newStatuses
        version += 1
    }

    private struct Compiled {
        var lists: [WKContentRuleList]
        var ruleCount: Int
    }

    private func process(url urlString: String, force: Bool) async throws -> Compiled {
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
            throw AdBlockError.invalidURL
        }

        var request = URLRequest(url: url)
        if !force, let etag = cache[urlString]?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AdBlockError.download }

        // 304 Not Modified → reuse the compiled lists.
        if http.statusCode == 304, let entry = cache[urlString] {
            var entry = entry
            entry.fetchedAt = Date()
            cache[urlString] = entry
            let lists = try await lookup(entry.chunkIdentifiers)
            return Compiled(lists: lists, ruleCount: entry.ruleCount)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AdBlockError.httpStatus(http.statusCode)
        }

        let text = String(decoding: data, as: UTF8.self)
        let hash = Self.sha256(text)
        let etag = http.value(forHTTPHeaderField: "ETag")

        // Content unchanged → reuse compiled lists, just refresh timestamp/etag.
        if !force, let entry = cache[urlString], entry.contentHash == hash,
           let lists = try? await lookup(entry.chunkIdentifiers) {
            cache[urlString] = CacheEntry(
                url: urlString, contentHash: hash, etag: etag ?? entry.etag,
                fetchedAt: Date(), ruleCount: entry.ruleCount,
                chunkIdentifiers: entry.chunkIdentifiers)
            return Compiled(lists: lists, ruleCount: entry.ruleCount)
        }

        // Convert + compile fresh.
        let result = AdblockConverter.convert(text)
        var identifiers: [String] = []
        var lists: [WKContentRuleList] = []
        let chunks = stride(from: 0, to: result.rules.count, by: Self.chunkSize).map {
            Array(result.rules[$0..<min($0 + Self.chunkSize, result.rules.count)])
        }
        for (index, chunk) in chunks.enumerated() {
            let identifier = "aetherfeed-\(hash)-\(index)"
            let json = try AdblockConverter.json(for: chunk)
            if let list = try await compile(identifier: identifier, json: json) {
                identifiers.append(identifier)
                lists.append(list)
            }
        }

        // Remove now-unused chunk identifiers from a previous version of this URL.
        if let old = cache[urlString]?.chunkIdentifiers {
            await remove(old.filter { !identifiers.contains($0) })
        }
        cache[urlString] = CacheEntry(
            url: urlString, contentHash: hash, etag: etag,
            fetchedAt: Date(), ruleCount: result.rules.count, chunkIdentifiers: identifiers)
        return Compiled(lists: lists, ruleCount: result.rules.count)
    }

    // MARK: - Cache loading (no network)

    private func loadFromCache() async {
        var lists: [WKContentRuleList] = []
        var loaded: [ListStatus] = []
        for url in listURLs {
            guard let entry = cache[url] else {
                loaded.append(ListStatus(url: url, ruleCount: 0, fetchedAt: nil, error: nil))
                continue
            }
            if let cached = try? await lookup(entry.chunkIdentifiers) {
                lists.append(contentsOf: cached)
                loaded.append(
                    ListStatus(
                        url: url, ruleCount: entry.ruleCount,
                        fetchedAt: entry.fetchedAt, error: nil))
            } else {
                loaded.append(ListStatus(url: url, ruleCount: 0, fetchedAt: nil, error: nil))
            }
        }
        ruleLists = lists
        statuses = loaded
        version += 1
    }

    private var hasStaleOrMissing: Bool {
        for url in listURLs {
            guard let entry = cache[url] else { return true }
            if Date().timeIntervalSince(entry.fetchedAt) > Self.staleInterval { return true }
        }
        return false
    }

    // MARK: - WKContentRuleListStore wrappers

    private func compile(identifier: String, json: String) async throws -> WKContentRuleList? {
        try await store.compileContentRuleList(
            forIdentifier: identifier, encodedContentRuleList: json)
    }

    private func lookup(_ identifiers: [String]) async throws -> [WKContentRuleList] {
        var lists: [WKContentRuleList] = []
        for identifier in identifiers {
            if let list = try await lookUp(identifier) {
                lists.append(list)
            } else {
                throw AdBlockError.cacheMiss
            }
        }
        return lists
    }

    /// The async `lookUpContentRuleList` isn't in this SDK; wrap the
    /// completion-handler variant. A missing identifier surfaces as an error.
    private func lookUp(_ identifier: String) async throws -> WKContentRuleList? {
        try await withCheckedThrowingContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: list)
                }
            }
        }
    }

    private func remove(_ identifiers: [String]) async {
        for identifier in identifiers {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
    }

    // MARK: - Persisted cache metadata

    private struct CacheEntry: Codable {
        var url: String
        var contentHash: String
        var etag: String?
        var fetchedAt: Date
        var ruleCount: Int
        var chunkIdentifiers: [String]
    }

    private static func loadCache() -> [String: CacheEntry] {
        guard let data = UserDefaults.standard.data(forKey: "adBlockCache"),
              let entries = try? JSONDecoder().decode([CacheEntry].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.url, $0) })
    }

    private static func saveCache(_ cache: [String: CacheEntry]) {
        guard let data = try? JSONEncoder().encode(Array(cache.values)) else { return }
        UserDefaults.standard.set(data, forKey: "adBlockCache")
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum AdBlockError: Error, LocalizedError {
    case invalidURL
    case download
    case httpStatus(Int)
    case cacheMiss

    var errorDescription: String? {
        switch self {
        case .invalidURL: L10nKey.localizedOffMain(.errorInvalidURL)
        case .download: L10nKey.localizedOffMain(.errorNotAFeed)
        case .httpStatus(let code): String(format: L10nKey.localizedOffMain(.errorHTTP), code)
        case .cacheMiss: "cache miss"
        }
    }
}
