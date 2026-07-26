import Foundation
import Synchronization

/// Configuration for OpenAI or any OpenAI-compatible server. The base URL is
/// editable so it points at api.openai.com or a local/self-hosted endpoint.
struct OpenAIConfig: Sendable {
    var baseURL: String
    var apiKey: String
    var model: String

    static func current() -> OpenAIConfig {
        let defaults = UserDefaults.standard
        return OpenAIConfig(
            baseURL: defaults.string(forKey: "openaiBaseURL") ?? "https://api.openai.com/v1",
            apiKey: KeychainStore.string(for: KeychainStore.openaiAPIKeyAccount) ?? "",
            model: defaults.string(forKey: "openaiModel") ?? ""
        )
    }

    /// Normalized base URL without a trailing slash.
    var url: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withoutSlash = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: withoutSlash)
    }
}

/// Talks to the OpenAI Chat Completions API. Structured output prefers
/// `response_format: json_object` plus the JSON schema embedded in the prompt,
/// but OpenAI-compatible servers disagree on which `response_format` variants
/// they accept (LM Studio rejects `json_object` and wants `json_schema`,
/// others support neither) — on HTTP 400 the client walks down a fallback
/// chain and remembers per server which variant worked.
struct OpenAIClient: LLMClient {
    var config: OpenAIConfig
    private let session: URLSession

    /// Index into the response-format fallback chain that the server at a
    /// given base URL accepted, so the 400 probe happens once per app run.
    private static let acceptedFormatIndex = Mutex<[String: Int]>([:])

    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration)
    }()

    init(config: OpenAIConfig = .current(), session: URLSession = OpenAIClient.defaultSession) {
        self.config = config
        self.session = session
    }

    func listModels() async throws -> [String] {
        let url = try endpoint("models")
        var request = URLRequest(url: url)
        authorize(&request)
        do {
            let (data, response) = try await session.data(for: request)
            try Self.check(response, data: data)
            return try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
                .data.map(\.id).sorted()
        } catch let error as LLMError {
            throw error
        } catch is DecodingError {
            throw LLMError.badResponse
        } catch {
            throw LLMError.unreachable(error.localizedDescription)
        }
    }

    func structured<T: Decodable & Sendable>(
        system: String, user: String, schema: JSONValue, numCtx: Int?, timeout: TimeInterval?
    ) async throws -> T {
        guard !config.model.isEmpty else { throw LLMError.noModel }
        let url = try endpoint("chat/completions")

        // The schema is described in the system prompt; json_object mode then
        // forces a syntactically valid JSON object in the reply.
        let schemaJSON = (try? JSONEncoder().encode(schema)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let systemWithSchema = """
            \(system)

            Respond ONLY with a single JSON object that conforms to this JSON \
            Schema. Do not include any text outside the JSON.
            Schema: \(schemaJSON)
            """

        let formats: [OpenAIChatRequest.ResponseFormat?] = [
            .jsonObject,
            .jsonSchema(schema),
            nil,
        ]
        let cacheKey = config.baseURL
        var formatIndex = Self.acceptedFormatIndex.withLock { $0[cacheKey] } ?? 0

        for attempt in 0..<2 {
            var userContent = user
            if attempt > 0 {
                userContent += "\n\nReturn ONLY valid JSON matching the schema."
            }
            let messages: [OpenAIChatRequest.Message] = [
                .init(role: "system", content: systemWithSchema),
                .init(role: "user", content: userContent),
            ]

            var data: Data?
            while data == nil {
                let body = OpenAIChatRequest(
                    model: config.model,
                    messages: messages,
                    temperature: 0.3,
                    responseFormat: formats[formatIndex]
                )
                do {
                    data = try await send(body, to: url, timeout: timeout)
                } catch LLMError.httpStatus(400, _) where formatIndex + 1 < formats.count {
                    // Server rejected this response_format variant — try the
                    // next one before giving up.
                    formatIndex += 1
                }
            }
            Self.acceptedFormatIndex.withLock { $0[cacheKey] = formatIndex }

            do {
                let chat = try JSONDecoder().decode(OpenAIChatResponse.self, from: data ?? Data())
                guard let content = chat.choices.first?.message.content else {
                    throw LLMError.badResponse
                }
                return try JSONDecoder().decode(T.self, from: Data(content.utf8))
            } catch {
                continue
            }
        }
        throw LLMError.badResponse
    }

    private func send(_ body: OpenAIChatRequest, to url: URL, timeout: TimeInterval?)
        async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try JSONEncoder().encode(body)
        if let timeout { request.timeoutInterval = timeout }

        do {
            let (data, response) = try await session.data(for: request)
            try Self.check(response, data: data)
            return data
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.unreachable(error.localizedDescription)
        }
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let base = config.url else { throw LLMError.notConfigured }
        // An API key must never travel in the clear to a public host —
        // localhost/LAN servers (LM Studio, llama.cpp) stay allowed, and
        // without a key there is nothing to protect.
        guard config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
            || NetworkPolicy.isSecureOrLocal(base)
        else { throw LLMError.insecureEndpoint }
        return base.appending(path: path)
    }

    private func authorize(_ request: inout URLRequest) {
        let key = config.apiKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw LLMError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw LLMError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.httpStatus(http.statusCode, detail: LLMError.serverDetail(from: data))
        }
    }
}

// MARK: - DTOs

private struct OpenAIChatRequest: Encodable {
    struct Message: Encodable {
        var role: String
        var content: String
    }
    struct ResponseFormat: Encodable {
        struct SchemaWrapper: Encodable {
            var name: String
            var schema: JSONValue
        }
        var type: String
        var jsonSchema: SchemaWrapper?

        enum CodingKeys: String, CodingKey {
            case type
            case jsonSchema = "json_schema"
        }

        static let jsonObject = ResponseFormat(type: "json_object", jsonSchema: nil)
        static func jsonSchema(_ schema: JSONValue) -> ResponseFormat {
            ResponseFormat(
                type: "json_schema",
                jsonSchema: SchemaWrapper(name: "structured_output", schema: schema))
        }
    }
    var model: String
    var messages: [Message]
    var temperature: Double
    var responseFormat: ResponseFormat?

    // Explicit keys instead of .convertToSnakeCase: the encoder strategy
    // would also rewrite camelCase keys inside the embedded JSON schema
    // (e.g. maxItems, articleIds) and corrupt it.
    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case responseFormat = "response_format"
    }
}

private struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { var content: String }
        var message: Message
    }
    var choices: [Choice]
}

private struct OpenAIModelsResponse: Decodable {
    struct Model: Decodable { var id: String }
    var data: [Model]
}
