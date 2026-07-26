import Foundation

enum FeedFetchError: Error, LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case notAFeed

    var errorDescription: String? {
        switch self {
        case .invalidURL: L10nKey.localizedOffMain(.errorInvalidURL)
        case .httpStatus(let code): String(format: L10nKey.localizedOffMain(.errorHTTP), code)
        case .notAFeed: L10nKey.localizedOffMain(.errorNotAFeed)
        }
    }
}

/// Loads and parses feeds (max. 5 in parallel) and persists the results.
actor FeedFetcher {
    static let shared = FeedFetcher()

    private let session: URLSession
    private let repository: Repository

    init(repository: Repository = .shared) {
        self.repository = repository
        let config = URLSessionConfiguration.ephemeral
        // We do conditional GET ourselves via ETag/Last-Modified in the DB.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        // Present as the installed Safari; some hosts block non-browser clients.
        config.httpAdditionalHeaders = [
            "User-Agent": SafariUserAgent.value,
            "Accept": SafariUserAgent.accept,
            "Accept-Language": SafariUserAgent.acceptLanguage,
        ]
        session = URLSession(configuration: config)
    }

    private struct FetchResult {
        var parsed: ParsedFeed?
        var etag: String?
        var lastModified: String?
        var notModified = false
    }

    /// Creates a new feed (loads, parses, stores) and returns its ID.
    func addFeed(urlString: String, categoryId: Int64?, newCategoryName: String?) async throws -> Int64 {
        let normalized = Self.normalize(urlString)
        let result = try await fetch(urlString: normalized, etag: nil, lastModified: nil)
        guard let parsed = result.parsed else { throw FeedFetchError.notAFeed }
        let feedId = try await repository.insertFeed(
            url: normalized,
            parsed: parsed,
            categoryId: categoryId,
            newCategoryName: newCategoryName,
            etag: result.etag,
            lastModified: result.lastModified
        )
        await LLMPipeline.shared.kick()
        return feedId
    }

    /// Loads and parses a feed without storing anything (for preview/AI suggestion).
    func preview(urlString: String) async throws -> ParsedFeed {
        let result = try await fetch(
            urlString: Self.normalize(urlString), etag: nil, lastModified: nil)
        guard let parsed = result.parsed else { throw FeedFetchError.notAFeed }
        return parsed
    }

    /// Refreshes all feeds, at most 5 at a time. Errors land per feed
    /// in `feed.lastError`; a single broken feed stops nothing.
    /// Returns the total number of new articles.
    @discardableResult
    func refreshAll() async -> Int {
        guard let feeds = try? await repository.allFeeds(), !feeds.isEmpty else { return 0 }

        var newArticles = 0
        await withTaskGroup(of: Int.self) { group in
            var next = 0
            while next < min(5, feeds.count) {
                let feed = feeds[next]
                group.addTask { await self.refresh(feed) }
                next += 1
            }
            while let inserted = await group.next() {
                newArticles += inserted
                if next < feeds.count {
                    let feed = feeds[next]
                    group.addTask { await self.refresh(feed) }
                    next += 1
                }
            }
        }
        await updateFavicons()
        await LLMPipeline.shared.kick()
        return newArticles
    }

    /// Fetches missing/stale favicons — plain `<scheme>://<host>/favicon.ico`,
    /// no external favicon service. Failures are recorded silently (the
    /// attempt timestamp prevents retrying every refresh). Capped per run
    /// so the work spreads across refresh cycles.
    func updateFavicons(olderThanDays days: Int = 30) async {
        guard let feeds = try? await repository.feedsNeedingFavicon(olderThanDays: days) else {
            return
        }
        for feed in feeds.prefix(10) {
            guard let feedId = feed.id, let url = Self.faviconURL(for: feed) else { continue }
            var data: Data?
            if let (body, response) = try? await session.data(from: url),
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                !body.isEmpty, body.count <= 256 * 1024 {
                data = body
            }
            try? await repository.saveFavicon(feedId: feedId, data: data)
        }
    }

    /// Site URL wins over the feed URL (feeds often live on CDN hosts).
    static func faviconURL(for feed: Feed) -> URL? {
        guard let base = URL(string: feed.siteURL ?? feed.url),
            let host = base.host
        else { return nil }
        return URL(string: "\(base.scheme ?? "https")://\(host)/favicon.ico")
    }

    /// Returns the number of newly inserted articles (0 on 304/error).
    @discardableResult
    func refresh(_ feed: Feed) async -> Int {
        guard let feedId = feed.id else { return 0 }
        do {
            let result = try await fetch(
                urlString: feed.url, etag: feed.etag, lastModified: feed.lastModified
            )
            if result.notModified {
                try await repository.touchFeed(id: feedId, error: nil)
            } else if let parsed = result.parsed {
                return try await repository.applyFetchedFeed(
                    feedId: feedId,
                    parsed: parsed,
                    etag: result.etag,
                    lastModified: result.lastModified
                )
            }
        } catch {
            try? await repository.touchFeed(id: feedId, error: error.localizedDescription)
        }
        return 0
    }

    // MARK: - Internal

    private func fetch(urlString: String, etag: String?, lastModified: String?) async throws -> FetchResult {
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
            throw FeedFetchError.invalidURL
        }
        var request = URLRequest(url: url)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FeedFetchError.invalidURL }

        if http.statusCode == 304 {
            return FetchResult(notModified: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FeedFetchError.httpStatus(http.statusCode)
        }

        let parsed: ParsedFeed
        do {
            parsed = try FeedParser.parse(data: data)
        } catch {
            throw FeedFetchError.notAFeed
        }
        return FetchResult(
            parsed: parsed,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified")
        )
    }

    private static func normalize(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("://") ? trimmed : "https://" + trimmed
    }
}
