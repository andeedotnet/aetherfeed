import Foundation
import GRDB

struct Feed: Codable, Identifiable, Hashable, Sendable {
    var id: Int64?
    var url: String
    var title: String = ""
    var customTitle: String?
    var feedDescription: String?
    var siteURL: String?
    var categoryId: Int64?
    var etag: String?
    var lastModified: String?
    var lastFetchedAt: Date?
    var lastError: String?
    var faviconData: Data?
    var faviconFetchedAt: Date?
    var createdAt: Date

    /// User override wins over the title delivered by the feed itself.
    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { customTitle } else { title }
    }
}

extension Feed: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "feed"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
