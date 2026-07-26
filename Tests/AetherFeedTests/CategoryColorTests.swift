import Foundation
import GRDB
import SwiftUI
import Testing

@testable import AetherFeed

@Suite struct CategoryColorTests {
    @Test func hexRoundTrips() {
        #expect(Color(hex: "#FF8800")?.hexString == "#FF8800")
        #expect(Color(hex: "00AAFF")?.hexString == "#00AAFF")
    }

    @Test func rejectsInvalidHex() {
        #expect(Color(hex: nil) == nil)
        #expect(Color(hex: "") == nil)
        #expect(Color(hex: "#12") == nil)
        #expect(Color(hex: "#GGGGGG") == nil)
    }

    @Test func persistsCategoryColor() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherfeed-color-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pool = try DatabasePool(path: path)
        try Migrations.migrator.migrate(pool)
        let repository = Repository(pool: pool)

        let id = try await pool.write { db in
            try Repository.findOrCreateCategory(named: "Tech", in: db).id
        }
        let categoryId = try #require(id)

        try await repository.setCategoryColor(id: categoryId, hex: "#FF3B30")
        let stored = try await pool.read { db in
            try FeedCategory.fetchOne(db, key: categoryId)?.colorHex
        }
        #expect(stored == "#FF3B30")

        try await repository.setCategoryColor(id: categoryId, hex: nil)
        let cleared = try await pool.read { db in
            try FeedCategory.fetchOne(db, key: categoryId)?.colorHex
        }
        #expect(cleared == nil)
    }
}
