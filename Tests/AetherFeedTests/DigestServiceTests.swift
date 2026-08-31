import Foundation
import GRDB
import Testing

@testable import AetherFeed

/// Deterministic stand-in for a backend: answers category calls with one
/// topic covering the first listed article, overview calls with a fixed
/// text, and records concurrency plus the prompts it received.
private final class MockLLMClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var _maxInFlight = 0
    private var _topicCalls = 0
    private var _overviewUsers: [String] = []
    private let concurrent: Bool
    /// The first N category calls answer with structure dumped into the
    /// string slots (the on-device failure mode) instead of clean topics.
    private var malformedCallsLeft: Int
    /// 1-based index of the category call that aborts the whole run with a
    /// pipeline-pausing error; 0 = never.
    private let failingCall: Int
    /// 1-based index of the category call that is refused the way a guardrail
    /// refuses content — that category is skipped, the run continues.
    private let rejectedCall: Int

    init(
        concurrent: Bool, malformedCalls: Int = 0, failingCall: Int = 0,
        rejectedCall: Int = 0
    ) {
        self.concurrent = concurrent
        self.malformedCallsLeft = malformedCalls
        self.failingCall = failingCall
        self.rejectedCall = rejectedCall
    }

    var supportsConcurrentRequests: Bool { concurrent }
    var maxInFlight: Int { lock.withLock { _maxInFlight } }
    var topicCalls: Int { lock.withLock { _topicCalls } }
    var overviewUsers: [String] { lock.withLock { _overviewUsers } }

    func listModels() async throws -> [String] { ["mock"] }

    func structured<T: Decodable & Sendable>(
        system: String, user: String, schema: JSONValue, numCtx: Int?, timeout: TimeInterval?
    ) async throws -> T {
        lock.withLock {
            inFlight += 1
            _maxInFlight = max(_maxInFlight, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }
        // Long enough that a parallel window visibly overlaps.
        try? await Task.sleep(for: .milliseconds(50))

        let json: String
        if system.contains("Group them") {
            let (malformed, callIndex) = lock.withLock {
                _topicCalls += 1
                guard malformedCallsLeft > 0 else { return (false, _topicCalls) }
                malformedCallsLeft -= 1
                return (true, _topicCalls)
            }
            if callIndex == failingCall { throw LLMError.notConfigured }
            if callIndex == rejectedCall { throw LLMError.contentRejected }
            let id = Self.firstArticleId(in: user)
            json =
                malformed
                ? #"{"topics":[{"headline":"**Überschrift:** X\n**Zusammenfassung:** Y","summary":"Z }, {","articleIds":[\#(id)]}]}"#
                : #"{"topics":[{"headline":"H","summary":"S","articleIds":[\#(id)]}]}"#
        } else {
            lock.withLock { _overviewUsers.append(system + "\n" + user) }
            json = #"{"paragraph":"P"}"#
        }
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// The article lists format entries as "[<id>] <title> — <snippet>".
    private static func firstArticleId(in user: String) -> Int64 {
        guard let open = user.firstIndex(of: "["),
              let close = user[open...].firstIndex(of: "]"),
              let id = Int64(user[user.index(after: open)..<close])
        else { return 0 }
        return id
    }
}

/// Counts the "digest ready" notifications a run would post.
private final class NotifyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    var handler: @Sendable () async -> Void {
        { self.lock.withLock { self._count += 1 } }
    }
}

@Suite struct DigestServiceTests {
    private func makeRepository() throws -> (Repository, DatabasePool) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherfeed-digest-\(UUID().uuidString).sqlite").path
        let pool = try DatabasePool(path: path)
        try Migrations.migrator.migrate(pool)
        return (Repository(pool: pool), pool)
    }

    /// One feed with one fresh article per named category; category order
    /// follows creation order (sortOrder appends).
    private func seedCategories(
        _ names: [String], repository: Repository
    ) async throws {
        for (index, name) in names.enumerated() {
            let items = [
                ParsedItem(
                    guid: "\(name)-a\(index)", url: nil, title: "Artikel \(name)",
                    author: nil, publishedAt: Date(), contentHTML: "<p>Inhalt \(name)</p>")
            ]
            _ = try await repository.insertFeed(
                url: "https://example.com/\(index)",
                parsed: ParsedFeed(title: name, description: nil, siteURL: nil, items: items),
                categoryId: nil, newCategoryName: name, etag: nil, lastModified: nil)
        }
    }

    /// Seeded articles arrive as `pending`; the briefing only counts as
    /// finished once the queue has run dry.
    private func markArticlesProcessed(_ pool: DatabasePool) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE article SET llmStatus = 'done'")
        }
    }

    @Test func parallelWindowIsCappedAndSerialBackendStaysSerial() async throws {
        let names = ["A", "B", "C", "D", "E"]

        let (parallelRepo, _) = try makeRepository()
        try await seedCategories(names, repository: parallelRepo)
        let parallelClient = MockLLMClient(concurrent: true)
        await DigestService(
            repository: parallelRepo, clientProvider: { parallelClient }
        ).generate()
        #expect(parallelClient.topicCalls == names.count)
        #expect(parallelClient.maxInFlight >= 2)
        #expect(parallelClient.maxInFlight <= 3)

        let (serialRepo, _) = try makeRepository()
        try await seedCategories(names, repository: serialRepo)
        let serialClient = MockLLMClient(concurrent: false)
        await DigestService(
            repository: serialRepo, clientProvider: { serialClient }
        ).generate()
        #expect(serialClient.topicCalls == names.count)
        #expect(serialClient.maxInFlight == 1)
    }

    @Test func unchangedCategoriesAreReusedAndNewArticlesRegenerateOnlyTheirs() async throws {
        let (repository, pool) = try makeRepository()
        try await seedCategories(["Alpha", "Beta"], repository: repository)
        let client = MockLLMClient(concurrent: true)
        let service = DigestService(repository: repository, clientProvider: { client })

        await service.generate()
        #expect(client.topicCalls == 2)
        let firstPayload = try await repository.loadDigestPayload()
        #expect(firstPayload?.sections.count == 2)

        // No new arrivals: both sections are reused, zero category calls.
        await service.generate()
        #expect(client.topicCalls == 2)

        // A new article in Beta only regenerates the Beta section.
        let betaFeedId = try await pool.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT id FROM feed WHERE title = 'Beta'")
        }
        _ = try await repository.applyFetchedFeed(
            feedId: try #require(betaFeedId),
            parsed: ParsedFeed(
                title: "Beta", description: nil, siteURL: nil,
                items: [
                    ParsedItem(
                        guid: "beta-neu", url: nil, title: "Neu in Beta",
                        author: nil, publishedAt: Date(), contentHTML: "<p>Neu</p>")
                ]),
            etag: nil, lastModified: nil)
        await service.generate()
        #expect(client.topicCalls == 3)

        let payload = try await repository.loadDigestPayload()
        #expect(payload?.sections.map(\.category) == ["Alpha", "Beta"])
    }

    @Test func malformedTopicsAreDiscardedAndRetriedOnce() async throws {
        let (repository, _) = try makeRepository()
        try await seedCategories(["Alpha"], repository: repository)
        let client = MockLLMClient(concurrent: true, malformedCalls: 1)
        await DigestService(repository: repository, clientProvider: { client }).generate()

        // First answer polluted → one retry → clean section stored.
        #expect(client.topicCalls == 2)
        let payload = try await repository.loadDigestPayload()
        let topic = try #require(payload?.sections.first?.topics.first)
        #expect(topic.headline == "H")
        #expect(topic.summary == "S")
    }

    /// A generation that dies halfway must leave its finished sections
    /// behind *and* stay stale — otherwise the partial digest would look
    /// fresh and would never be retried.
    @Test func abortedGenerationKeepsFinishedSectionsAndStaysStale() async throws {
        let (repository, pool) = try makeRepository()
        try await seedCategories(["Alpha", "Beta"], repository: repository)
        // Serial backend: the second category call is reached only after the
        // first one has been stored as a snapshot.
        let client = MockLLMClient(concurrent: false, failingCall: 2)
        await DigestService(repository: repository, clientProvider: { client }).generate()

        let payload = try await repository.loadDigestPayload()
        #expect(payload?.sections.map(\.category) == ["Alpha"])
        #expect(try await repository.digestIsStale())
        let isPartial = try await pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT isPartial FROM digest WHERE id = 1")
        }
        #expect(isPartial == true)
    }

    @Test func completedDigestIsNotPartialAndNotStale() async throws {
        let (repository, pool) = try makeRepository()
        try await seedCategories(["Alpha"], repository: repository)
        let client = MockLLMClient(concurrent: true)
        await DigestService(repository: repository, clientProvider: { client }).generate()

        #expect(try await repository.digestIsStale() == false)
        let isPartial = try await pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT isPartial FROM digest WHERE id = 1")
        }
        #expect(isPartial == false)
    }

    /// Everything processed and every category covered: exactly one
    /// notification.
    @Test func digestReadyIsPostedOnceWhenEverythingIsDone() async throws {
        let (repository, pool) = try makeRepository()
        try await seedCategories(["Alpha", "Beta"], repository: repository)
        try await markArticlesProcessed(pool)

        let counter = NotifyCounter()
        await DigestService(
            repository: repository, clientProvider: { MockLLMClient(concurrent: true) },
            notifyReady: counter.handler
        ).generate()

        #expect(counter.count == 1)
    }

    /// The pipeline generates whenever the queue momentarily runs dry, so a
    /// refresh that is still delivering articles must not announce a briefing.
    @Test func digestReadyIsHeldBackWhileArticlesAreStillWaiting() async throws {
        let (repository, _) = try makeRepository()
        try await seedCategories(["Alpha", "Beta"], repository: repository)
        // Seeded articles stay `pending` — the queue still holds work.

        let counter = NotifyCounter()
        await DigestService(
            repository: repository, clientProvider: { MockLLMClient(concurrent: true) },
            notifyReady: counter.handler
        ).generate()

        #expect(counter.count == 0)
        // The digest itself was still written — only the notification waits.
        let payload = try await repository.loadDigestPayload()
        #expect(payload?.sections.count == 2)
    }

    @Test func digestReadyIsHeldBackWhenACategoryProducedNoSection() async throws {
        let (repository, pool) = try makeRepository()
        try await seedCategories(["Alpha", "Beta"], repository: repository)
        try await markArticlesProcessed(pool)

        let counter = NotifyCounter()
        // Serial, so the second call is reliably Beta's.
        await DigestService(
            repository: repository,
            clientProvider: { MockLLMClient(concurrent: false, rejectedCall: 2) },
            notifyReady: counter.handler
        ).generate()

        let payload = try await repository.loadDigestPayload()
        #expect(payload?.sections.map(\.category) == ["Alpha"])
        #expect(counter.count == 0)
    }

    /// The realistic launch sequence: the queue empties, the briefing is built
    /// while the refresh is still delivering, those articles are processed,
    /// and only then is the briefing announced — exactly once. Articles that
    /// arrive during a run carry a `createdAt` older than the digest's
    /// `generatedAt`, so the next pass finds nothing stale and has to announce
    /// from the stored state instead of regenerating.
    @Test func announcementSurvivesArticlesArrivingDuringTheRun() async throws {
        let (repository, pool) = try makeRepository()
        try await seedCategories(["Alpha", "Beta"], repository: repository)
        try await markArticlesProcessed(pool)

        let counter = NotifyCounter()
        let service = DigestService(
            repository: repository, clientProvider: { MockLLMClient(concurrent: true) },
            notifyReady: counter.handler)

        // A late arrival, still queued when the generation ends.
        let feedId = try await pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM feed LIMIT 1")
        }
        try await pool.write { db in
            try db.execute(
                sql: "INSERT INTO article (feedId, guid, title, llmStatus, createdAt)"
                    + " VALUES (?, 'late', 'Spaet', 'pending', ?)",
                arguments: [try #require(feedId), Date(timeIntervalSince1970: 1)])
        }

        await service.generateIfNeeded()
        #expect(counter.count == 0)

        // The pipeline works the queue off and asks again. The digest is not
        // stale (the article predates its timestamp), so nothing regenerates —
        // only the owed announcement can still fire.
        try await markArticlesProcessed(pool)
        #expect(try await repository.digestIsStale() == false)
        await service.generateIfNeeded()
        #expect(counter.count == 1)

        // Every further pass stays quiet.
        await service.generateIfNeeded()
        #expect(counter.count == 1)
    }

    @Test func overviewIsBuiltFromTopicsInCategoryOrder() async throws {
        let (repository, _) = try makeRepository()
        try await seedCategories(["Alpha", "Beta"], repository: repository)
        let client = MockLLMClient(concurrent: true)
        await DigestService(repository: repository, clientProvider: { client }).generate()

        // One overview call per category, in sidebar order.
        let prompts = client.overviewUsers
        #expect(prompts.count == 2)
        #expect(prompts[0].contains("Alpha"))
        #expect(prompts[1].contains("Beta"))
        // Topic bullet points, not raw article snippets.
        #expect(prompts[0].contains("- H — S"))
        #expect(!prompts.joined().contains("Inhalt"))

        // Per-category paragraphs land in the payload joined by blank lines.
        let payload = try await repository.loadDigestPayload()
        #expect(payload?.overview == "P\n\nP")
    }
}
