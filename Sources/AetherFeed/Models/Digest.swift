import Foundation
import GRDB

/// Single-row cache of the most recently generated home page digest (id is always 1).
struct DigestRecord: Codable, Sendable {
    var id: Int64 = 1
    var generatedAt: Date
    var contentJSON: String
    var articleCount: Int
}

extension DigestRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "digest"
}

/// Digest result delivered by the LLM; stored as JSON in `DigestRecord.contentJSON`.
/// Structured by feed categories: one section per category with
/// topic cards, plus an overall overview on top.
struct DigestPayload: Codable, Hashable, Sendable {
    struct Topic: Codable, Hashable, Sendable {
        var headline: String
        var summary: String
        var articleIds: [Int64]
    }

    struct Section: Codable, Hashable, Sendable {
        var category: String
        var topics: [Topic]
        /// When this section was generated — the basis for incremental
        /// regeneration (only categories with newer articles are redone).
        /// nil (pre-existing JSON) counts as "must regenerate".
        var generatedAt: Date?
    }

    var overview: String
    var sections: [Section]
}
