import Foundation

/// Configuration of the remote Ollama server. Read from UserDefaults on
/// each call (thread-safe) so actors can access the current settings
/// without a MainActor hop.
struct OllamaConfig: Sendable {
    var host: String
    var port: Int
    var model: String

    static func current() -> OllamaConfig {
        let defaults = UserDefaults.standard
        return OllamaConfig(
            host: defaults.string(forKey: "ollamaHost") ?? "",
            port: defaults.object(forKey: "ollamaPort") as? Int ?? 11434,
            model: defaults.string(forKey: "ollamaModel") ?? ""
        )
    }

    var baseURL: URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") {
            return URL(string: trimmed)
        }
        return URL(string: "http://\(trimmed):\(port)")
    }
}

struct OllamaClient: LLMClient {
    var config: OllamaConfig

    /// Generations on large models can take minutes — in addition,
    /// requests may wait in Ollama's queue behind the article pipeline.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration)
    }()

    init(config: OllamaConfig = .current()) {
        self.config = config
    }

    func listModels() async throws -> [String] {
        let url = try endpoint("api/tags")
        do {
            let (data, response) = try await Self.session.data(from: url)
            try Self.check(response, data: data)
            return try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
                .models.map(\.name).sorted()
        } catch let error as LLMError {
            throw error
        } catch is DecodingError {
            throw LLMError.badResponse
        } catch {
            throw LLMError.unreachable(error.localizedDescription)
        }
    }

    /// Chat with structured output: enforces machine-readable answers via a
    /// JSON schema; one automatic retry when the result cannot be decoded.
    /// `numCtx` raises Ollama's default context window (otherwise long
    /// prompts are silently truncated), `timeout` sets the request timeout.
    func structured<T: Decodable & Sendable>(
        system: String,
        user: String,
        schema: JSONValue,
        numCtx: Int? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> T {
        guard !config.model.isEmpty else { throw LLMError.noModel }
        let url = try endpoint("api/chat")

        for attempt in 0..<2 {
            var userContent = user
            if attempt > 0 {
                userContent += "\n\nReturn ONLY valid JSON matching the required schema."
            }
            let body = OllamaChatRequest(
                model: config.model,
                messages: [
                    .init(role: "system", content: system),
                    .init(role: "user", content: userContent),
                ],
                format: schema,
                options: .init(temperature: 0.3, numCtx: numCtx)
            )

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
            if let timeout {
                request.timeoutInterval = timeout
            }

            let data: Data
            do {
                let (received, response) = try await Self.session.data(for: request)
                try Self.check(response, data: received)
                data = received
            } catch let error as LLMError {
                throw error
            } catch {
                throw LLMError.unreachable(error.localizedDescription)
            }

            do {
                let chat = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
                return try JSONDecoder().decode(T.self, from: Data(chat.message.content.utf8))
            } catch {
                continue
            }
        }
        throw LLMError.badResponse
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let base = config.baseURL else { throw LLMError.notConfigured }
        return base.appending(path: path)
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw LLMError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.httpStatus(http.statusCode, detail: LLMError.serverDetail(from: data))
        }
    }
}
