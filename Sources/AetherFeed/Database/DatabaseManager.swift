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

    static func open() throws -> DatabasePool {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = appSupport.appendingPathComponent("AetherFeed", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let dbURL = directory.appendingPathComponent("aetherfeed.sqlite")
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
