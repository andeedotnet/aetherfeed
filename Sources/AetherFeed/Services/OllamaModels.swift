import Foundation

/// Arbitrary JSON values, e.g. for Ollama's `format` field (JSON schema).
/// The literal conformances allow writing schemas directly as literals.
indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - Request/Response DTOs

struct OllamaChatRequest: Encodable, Sendable {
    struct Message: Encodable, Sendable {
        var role: String
        var content: String
    }

    struct Options: Encodable, Sendable {
        var temperature: Double
        var numCtx: Int?

        enum CodingKeys: String, CodingKey {
            case temperature
            case numCtx = "num_ctx"
        }
    }

    var model: String
    var messages: [Message]
    var stream = false
    var format: JSONValue
    var options: Options
}

struct OllamaChatResponse: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        var content: String
    }

    var message: Message
}

struct OllamaTagsResponse: Decodable, Sendable {
    struct Model: Decodable, Sendable {
        var name: String
    }

    var models: [Model]
}

// MARK: - Structured Results

struct ArticleAnalysis: Decodable, Sendable {
    /// A tag in both languages.
    struct Tag: Decodable, Sendable {
        var de: String
        var en: String
    }

    var summary: String
    var tags: [Tag]
    /// Optional on purpose: `OpenAIClient` only prompts the schema instead of
    /// enforcing it, so a model omitting the field must not break decoding.
    var isAdvertising: Bool?
    /// The phrase the model quotes as proof of advertising. Verified against
    /// the article text before the flag is trusted — small models otherwise
    /// call any product teaser an ad.
    var adMarker: String?

    static let schema: JSONValue = [
        "type": "object",
        "properties": [
            "adMarker": ["type": "string"],
            "isAdvertising": ["type": "boolean"],
            "summary": ["type": "string"],
            "tags": [
                "type": "array",
                "maxItems": 5,
                "items": [
                    "type": "object",
                    "properties": [
                        "de": ["type": "string"],
                        "en": ["type": "string"],
                    ],
                    "required": ["de", "en"],
                ],
            ],
        ],
        // Order matters: `JSONSchemaTranslator` derives the generation order
        // from `required`, so the model commits to the classification before
        // writing the summary.
        "required": ["adMarker", "isAdvertising", "summary", "tags"],
    ]
}

struct CategorySuggestion: Decodable, Sendable {
    var category: String
    var isExisting: Bool

    static let schema: JSONValue = [
        "type": "object",
        "properties": [
            "category": ["type": "string"],
            "isExisting": ["type": "boolean"],
        ],
        "required": ["category", "isExisting"],
    ]
}

/// Topics of a single category (one digest sub-call per category).
struct CategoryTopicsResult: Decodable, Sendable {
    var topics: [DigestPayload.Topic]

    static let schema: JSONValue = [
        "type": "object",
        "properties": [
            "topics": [
                "type": "array",
                "maxItems": 5,
                "items": [
                    "type": "object",
                    "properties": [
                        "headline": ["type": "string"],
                        "summary": ["type": "string"],
                        "articleIds": ["type": "array", "items": ["type": "integer"]],
                    ],
                    "required": ["headline", "summary", "articleIds"],
                ],
            ]
        ],
        "required": ["topics"],
    ]
}

/// One overview paragraph for a single category. The overview is built
/// from one small call per category — code guarantees that every category
/// appears exactly once and in order; a single big call reliably lost
/// categories with the on-device model.
struct OverviewResult: Decodable, Sendable {
    var paragraph: String

    static let schema: JSONValue = [
        "type": "object",
        "properties": ["paragraph": ["type": "string"]],
        "required": ["paragraph"],
    ]
}
