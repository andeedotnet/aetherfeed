import Foundation
import Testing

@testable import AetherFeed

/// Stub URLProtocol that captures the outgoing request and returns a canned
/// response, so the OpenAI wire format is verified without a live server.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol strips httpBody into httpBodyStream; read it back.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }

        let (status, body) = Self.responder?(request) ?? (200, Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// Serialized: the tests share StubURLProtocol's static responder state.
@Suite(.serialized) struct OpenAIClientTests {
    @Test func listModelsParsesDataArray() async throws {
        StubURLProtocol.responder = { _ in
            (200, Data(#"{"data":[{"id":"gpt-4o"},{"id":"gpt-4o-mini"}]}"#.utf8))
        }
        let client = OpenAIClient(
            config: OpenAIConfig(baseURL: "https://api.example.com/v1", apiKey: "k", model: ""),
            session: StubURLProtocol.session())
        let models = try await client.listModels()
        #expect(models == ["gpt-4o", "gpt-4o-mini"])
    }

    @Test func structuredSendsOpenAIFormatAndDecodesContent() async throws {
        // The model's reply is a JSON string nested inside the chat response;
        // build it via JSONSerialization so the escaping is exact.
        let inner = #"{"summary":"Bayern gewinnt.","tags":[{"de":"Fußball","en":"Football"}]}"#
        let responseObject: [String: Any] = ["choices": [["message": ["content": inner]]]]
        let responseData = try JSONSerialization.data(withJSONObject: responseObject)
        StubURLProtocol.responder = { _ in (200, responseData) }
        let client = OpenAIClient(
            config: OpenAIConfig(
                baseURL: "https://api.example.com/v1", apiKey: "secret", model: "gpt-4o"),
            session: StubURLProtocol.session())

        let analysis: ArticleAnalysis = try await client.structured(
            system: "sys", user: "usr", schema: ArticleAnalysis.schema, numCtx: nil, timeout: nil)
        #expect(analysis.summary == "Bayern gewinnt.")
        #expect(analysis.tags.first?.de == "Fußball")
        #expect(analysis.tags.first?.en == "Football")

        // Verify the request used OpenAI's Chat Completions shape.
        let sent = try #require(StubURLProtocol.lastBody)
        let json = try #require(
            try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(json["model"] as? String == "gpt-4o")
        let responseFormat = json["response_format"] as? [String: Any]
        #expect(responseFormat?["type"] as? String == "json_object")
        let messages = json["messages"] as? [[String: Any]]
        #expect(messages?.count == 2)
        // The schema is embedded in the system prompt.
        #expect((messages?.first?["content"] as? String)?.contains("JSON Schema") == true)
    }

    /// LM Studio rejects `response_format: json_object` with HTTP 400 and
    /// only accepts `json_schema` — the client must fall back automatically.
    @Test func fallsBackToJSONSchemaWhenJSONObjectRejected() async throws {
        let inner = #"{"summary":"Ok.","tags":[]}"#
        let responseObject: [String: Any] = ["choices": [["message": ["content": inner]]]]
        let responseData = try JSONSerialization.data(withJSONObject: responseObject)
        let lmStudioError = Data(
            #"{"error":{"message":"'response_format.type' must be 'json_schema'"}}"#.utf8)
        StubURLProtocol.responder = { _ in
            let body = StubURLProtocol.lastBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let format = body?["response_format"] as? [String: Any]
            return format?["type"] as? String == "json_schema"
                ? (200, responseData) : (400, lmStudioError)
        }
        let client = OpenAIClient(
            config: OpenAIConfig(
                baseURL: "https://lmstudio.example.com/v1", apiKey: "", model: "qwen"),
            session: StubURLProtocol.session())

        let analysis: ArticleAnalysis = try await client.structured(
            system: "sys", user: "usr", schema: ArticleAnalysis.schema, numCtx: nil, timeout: nil)
        #expect(analysis.summary == "Ok.")

        // The retried request carries the schema with camelCase keys intact.
        let sent = try #require(StubURLProtocol.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        let format = try #require(json["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let wrapper = try #require(format["json_schema"] as? [String: Any])
        let schema = try #require(wrapper["schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let tagsSchema = try #require(properties["tags"] as? [String: Any])
        #expect(tagsSchema["maxItems"] as? Int == 5)
    }

    /// The server's error message must survive into the thrown error so the
    /// UI can show more than a bare status code.
    @Test func httpErrorCarriesServerMessage() async throws {
        StubURLProtocol.responder = { _ in
            (400, Data(#"{"error":{"message":"model not found"}}"#.utf8))
        }
        let client = OpenAIClient(
            config: OpenAIConfig(
                baseURL: "https://broken.example.com/v1", apiKey: "", model: "x"),
            session: StubURLProtocol.session())
        do {
            let _: ArticleAnalysis = try await client.structured(
                system: "s", user: "u", schema: ArticleAnalysis.schema, numCtx: nil, timeout: nil)
            Issue.record("expected an error to be thrown")
        } catch LLMError.httpStatus(let code, let detail) {
            #expect(code == 400)
            #expect(detail == "model not found")
        }
    }

    @Test func unauthorizedStatusMapsToError() async throws {
        StubURLProtocol.responder = { _ in (401, Data("unauthorized".utf8)) }
        let client = OpenAIClient(
            config: OpenAIConfig(baseURL: "https://api.example.com/v1", apiKey: "", model: "m"),
            session: StubURLProtocol.session())
        await #expect(throws: LLMError.self) {
            let _: ArticleAnalysis = try await client.structured(
                system: "s", user: "u", schema: ArticleAnalysis.schema, numCtx: nil, timeout: nil)
        }
    }
}
