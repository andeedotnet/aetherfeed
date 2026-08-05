import Foundation
import GRDB

/// Opens the SQLite database and runs migrations. The `DatabasePool`
/// is Sendable and shared between the UI (ValueObservation) and actors.
enum DatabaseManager {
    static let shared: DatabasePool = {
        do {
            return try open()
        } catch {
            fatalError("Database could not be opened: \(error)")
        }
    }()

    /// Directory holding the SQLite file. Development and test runs must
    /// never write to the installed app's data, so the location splits three
    /// ways:
    /// - `AETHERFEED_DATA_DIR` overrides everything (useful to point a dev
    ///   build at a copy of real data),
    /// - test processes get a throwaway directory, so `swift test` and
    ///   `Scripts/test.sh` are equally harmless,
    /// - debug builds use `AetherFeed-dev`, release builds `AetherFeed`.
    /// `environment` is injectable so the override can be tested without
    /// mutating the process environment, which tests share.
    static func dataDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let fileManager = FileManager.default
        let directory: URL
        if let override = environment["AETHERFEED_DATA_DIR"], !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else if isRunningTests {
            directory = testDirectory
        } else {
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                create: true)
            #if DEBUG
                let name = "AetherFeed-dev"
            #else
                let name = "AetherFeed"
            #endif
            directory = appSupport.appendingPathComponent(name, isDirectory: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// One throwaway directory per test process — shared by every test that
    /// reaches for `DatabaseManager.shared`.
    private static let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AetherFeed-tests-\(UUID().uuidString)", isDirectory: true)

    /// SwiftPM runs Swift Testing through `swiftpm-testing-helper`; Xcode and
    /// plain XCTest hosts show up as `xctest`.
    private static var isRunningTests: Bool {
        let process = ProcessInfo.processInfo
        return process.processName == "swiftpm-testing-helper"
            || process.processName == "xctest"
            || process.processName.hasSuffix(".xctest")
            || process.environment["XCTestConfigurationFilePath"] != nil
    }

    static func open() throws -> DatabasePool {
        let dbURL = try dataDirectory().appendingPathComponent("aetherfeed.sqlite")
        let pool = try DatabasePool(path: dbURL.path)
        try Migrations.migrator.migrate(pool)
        // The digest is session-scoped: a restart starts with an empty home
        // page ("being created" hint) until the article pipeline finishes
        // and rebuilds it. Cleared here, before any UI observation starts.
        try pool.write { db in
            try db.execute(sql: "DELETE FROM digest")
        }
        return pool
    }
}
