import Foundation
import Testing

@testable import AetherFeed

/// Guards the separation between test/dev data and the installed app's
/// database — a test run must never write to what the user actually reads.
@Suite struct DataDirectoryTests {
    private var productionDirectory: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
            create: false
        ).appendingPathComponent("AetherFeed", isDirectory: true)
    }

    @Test func testsNeverUseTheProductionDirectory() throws {
        let directory = try DatabaseManager.dataDirectory()
        #expect(directory.standardizedFileURL != productionDirectory?.standardizedFileURL)
    }

    /// The singleton is what tests reach through `Repository.shared`, so the
    /// open database itself has to sit outside the production directory.
    @Test func sharedPoolLivesOutsideTheProductionDirectory() throws {
        let path = DatabaseManager.shared.path
        let production = try #require(productionDirectory).standardizedFileURL.path
        #expect(!path.hasPrefix(production + "/"))
    }

    @Test func explicitOverrideWinsAndIsCreated() throws {
        let wanted = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherfeed-override-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: wanted) }

        let directory = try DatabaseManager.dataDirectory(
            environment: ["AETHERFEED_DATA_DIR": wanted.path])

        #expect(directory.standardizedFileURL == wanted.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: wanted.path))
    }

    @Test func emptyOverrideIsIgnored() throws {
        let directory = try DatabaseManager.dataDirectory(
            environment: ["AETHERFEED_DATA_DIR": ""])
        #expect(directory.standardizedFileURL != productionDirectory?.standardizedFileURL)
    }
}
