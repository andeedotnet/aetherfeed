import Foundation
import GRDB

enum LLMStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case pending
    case processing
    case done
    case failed
}

struct Article: Codable, Identifiable, Hashable, Sendable {
    var id: Int64?
    var feedId: Int64
    var guid: String
    var url: String?
    var title: String = ""
    var author: String?
    var publishedAt: Date?
    var contentHTML: String?
    var contentText: String?
    var isRead: Bool = false
    var isStarred: Bool = false
    var summary: String?
    var llmStatus: LLMStatus = .pending
    var llmAttempts: Int = 0
    var llmError: String?
    var llmProcessedAt: Date?
    var createdAt: Date
}

extension Article: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "article"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
