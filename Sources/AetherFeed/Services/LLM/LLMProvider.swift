import Foundation

/// Selectable LLM backends. OpenAI covers OpenAI itself and any
/// OpenAI-compatible server (LM Studio, llama.cpp, groq, vLLM, …).
/// Apple Intelligence is the on-device FoundationModels backend (macOS 26+).
enum LLMProvider: String, CaseIterable, Identifiable, Sendable {
    case ollama
    case openai
    case appleIntelligence

    var id: String { rawValue }

    static var current: LLMProvider {
        UserDefaults.standard.string(forKey: "llmProvider")
            .flatMap(LLMProvider.init(rawValue:)) ?? defaultProvider
    }

    /// First-launch default: the on-device model where the OS supports it,
    /// since it needs no configuration at all.
    static var defaultProvider: LLMProvider {
        if #available(macOS 26.0, *) { .appleIntelligence } else { .ollama }
    }
}

/// Why the on-device Apple Intelligence model can't be used right now.
/// Deliberately free of FoundationModels types so it exists on macOS < 26.
enum AppleUnavailableReason: Sendable, Equatable {
    case osTooOld
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case other
}

/// Provider-neutral error type shared by all LLM clients.
enum LLMError: Error, LocalizedError, Sendable {
    case notConfigured
    case noModel
    case unreachable(String)
    case httpStatus(Int, detail: String?)
    case unauthorized
    case badResponse
    case appleUnavailable(AppleUnavailableReason)
    case contentRejected

    /// Connection/configuration errors pause the whole pipeline;
    /// `badResponse` and `contentRejected` (a guardrail refusing one
    /// article) only count as a failed attempt for the single article.
    var pausesPipeline: Bool {
        switch self {
        case .badResponse, .contentRejected: false
        default: true
        }
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured: L10nKey.localizedOffMain(.errorLLMNotConfigured)
        case .noModel: L10nKey.localizedOffMain(.errorLLMNoModel)
        case .unreachable(let detail):
            String(format: L10nKey.localizedOffMain(.errorLLMUnreachable), detail)
        case .httpStatus(let code, let detail):
            String(format: L10nKey.localizedOffMain(.errorHTTP), code)
                + (detail.map { " – \($0)" } ?? "")
        case .unauthorized: L10nKey.localizedOffMain(.errorLLMUnauthorized)
        case .badResponse: L10nKey.localizedOffMain(.errorLLMBadResponse)
        case .appleUnavailable(let reason):
            switch reason {
            case .osTooOld: L10nKey.localizedOffMain(.errorAppleOSTooOld)
            case .deviceNotEligible: L10nKey.localizedOffMain(.errorAppleNotSupported)
            case .notEnabled: L10nKey.localizedOffMain(.errorAppleNotEnabled)
            case .modelNotReady: L10nKey.localizedOffMain(.errorAppleModelNotReady)
            case .other: L10nKey.localizedOffMain(.errorAppleUnavailable)
            }
        case .contentRejected: L10nKey.localizedOffMain(.errorAppleRejected)
        }
    }
}

extension LLMError {
    /// Human-readable message from a JSON error body — OpenAI style
    /// (`{"error":{"message":…}}`), Ollama style (`{"error":"…"}`), or the
    /// raw body as a fallback so 4xx replies are diagnosable in the UI.
    static func serverDetail(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = object["error"] as? String { return message }
            if let error = object["error"] as? [String: Any],
                let message = error["message"] as? String {
                return message
            }
        }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(300))
    }
}

/// A backend that can list models and produce schema-constrained JSON output.
protocol LLMClient: Sendable {
    /// Whether multiple `structured` calls may run at the same time.
    /// Remote servers handle that fine; the on-device Apple Intelligence
    /// model rejects concurrent requests.
    var supportsConcurrentRequests: Bool { get }

    func listModels() async throws -> [String]

    /// `numCtx` is Ollama-specific (context window); other providers ignore it.
    func structured<T: Decodable & Sendable>(
        system: String, user: String, schema: JSONValue, numCtx: Int?, timeout: TimeInterval?
    ) async throws -> T
}

extension LLMClient {
    var supportsConcurrentRequests: Bool { true }

    func structured<T: Decodable & Sendable>(
        system: String, user: String, schema: JSONValue
    ) async throws -> T {
        try await structured(
            system: system, user: user, schema: schema, numCtx: nil, timeout: nil)
    }
}

enum LLMClientFactory {
    /// The client for the configured provider, or nil if it isn't set up yet
    /// (missing host/base URL or model). Callers treat nil as "not configured".
    static func current() -> (any LLMClient)? {
        switch LLMProvider.current {
        case .ollama:
            let config = OllamaConfig.current()
            guard config.baseURL != nil, !config.model.isEmpty else { return nil }
            return OllamaClient(config: config)
        case .openai:
            let config = OpenAIConfig.current()
            guard config.url != nil, !config.model.isEmpty else { return nil }
            return OpenAIClient(config: config)
        case .appleIntelligence:
            // Availability is checked per call; an unavailable model surfaces
            // as an actionable pause banner instead of silent inactivity.
            if #available(macOS 26.0, *) {
                return AppleIntelligenceClient()
            }
            return nil
        }
    }
}

/// Placeholder when Apple Intelligence is selected on macOS < 26, where the
/// settings connection test still needs a client to report the reason.
struct UnavailableLLMClient: LLMClient {
    func listModels() async throws -> [String] {
        throw LLMError.appleUnavailable(.osTooOld)
    }

    func structured<T: Decodable & Sendable>(
        system: String, user: String, schema: JSONValue, numCtx: Int?, timeout: TimeInterval?
    ) async throws -> T {
        throw LLMError.appleUnavailable(.osTooOld)
    }
}
