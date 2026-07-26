import GRDB

struct FeedCategory: Codable, Identifiable, Hashable, Sendable {
    var id: Int64?
    var name: String
    var sortOrder: Int = 0
    /// User-defined color as a hex string (e.g. "#FF3B30"); nil = no color set.
    var colorHex: String?
}

extension FeedCategory: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "category"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
