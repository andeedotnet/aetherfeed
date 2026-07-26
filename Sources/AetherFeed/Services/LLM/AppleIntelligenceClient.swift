import Foundation
import FoundationModels

/// On-device Apple Intelligence backend (macOS 26+, FoundationModels).
/// No network and no configuration; "configured" is defined solely by the
/// availability of the system model. Uses permissive guardrails —
/// summarizing third-party news is exactly the content-transformation use
/// case they exist for.
@available(macOS 26.0, *)
struct AppleIntelligenceClient: LLMClient {
    /// The on-device context window is ~4096 tokens; below this prompt size
    /// further halving is pointless and the call fails for the single item.
    private static let minimumPromptChars = 1000
    private static let maxAttempts = 3

    /// The single on-device model rejects concurrent requests.
    var supportsConcurrentRequests: Bool { false }

    private var model: SystemLanguageModel {
        SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    /// There is exactly one on-device model; the settings UI shows it as a
    /// static entry. Throwing here turns the settings "Test" button into an
    /// availability check with an actionable message.
    func listModels() async throws -> [String] {
        try Self.ensureAvailable(model)
        return [L10nKey.localizedOffMain(.appleModelName)]
    }

    func structured<T: Decodable & Sendable>(
        system: String, user: String, schema: JSONValue, numCtx: Int?, timeout: TimeInterval?
    ) async throws -> T {
        // numCtx/timeout are remote-server tuning knobs — ignored on-device.
        let model = self.model
        try Self.ensureAvailable(model)

        let generationSchema: GenerationSchema
        do {
            generationSchema = try JSONSchemaTranslator.generationSchema(from: schema)
        } catch {
            assertionFailure("untranslatable schema: \(error)")
            throw LLMError.badResponse
        }
        // No maximumResponseTokens: the schema already bounds the output
        // structurally, and an artificial cap truncates the JSON mid-stream,
        // which surfaces as a decodingFailure.
        let options = GenerationOptions(temperature: 0.3)

        var prompt = user
        for attempt in 0..<Self.maxAttempts {
            // Fresh session per call: stateless, and no transcript growth
            // eating into the small context window. Instructions carry the
            // system prompt (privileged over the user prompt).
            let session = LanguageModelSession(model: model, instructions: system)
            do {
                let response = try await session.respond(
                    to: prompt, schema: generationSchema, options: options)
                return try Self.decode(T.self, from: response.content.jsonString)
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error,
                    attempt + 1 < Self.maxAttempts,
                    prompt.count / 2 >= Self.minimumPromptChars {
                    // Callers size prompts for server models (8k/16k ctx);
                    // shrink locally instead of failing outright.
                    prompt = LLMPipeline.truncate(prompt, limit: prompt.count / 2)
                    continue
                }
                if case .decodingFailure = error, attempt + 1 < Self.maxAttempts {
                    // Malformed output is stochastic — a retry often succeeds.
                    continue
                }
                throw Self.map(error)
            } catch LLMError.badResponse where attempt + 1 < Self.maxAttempts {
                continue
            } catch let error as LLMError {
                throw error
            } catch {
                throw LLMError.badResponse
            }
        }
        throw LLMError.badResponse
    }

    // MARK: - Mapping

    private static func ensureAvailable(_ model: SystemLanguageModel) throws {
        switch model.availability {
        case .available:
            return
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                throw LLMError.appleUnavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled:
                throw LLMError.appleUnavailable(.notEnabled)
            case .modelNotReady:
                throw LLMError.appleUnavailable(.modelNotReady)
            @unknown default:
                throw LLMError.appleUnavailable(.other)
            }
        }
    }

    /// Internal (not private) so the mapping is unit-testable.
    static func map(_ error: LanguageModelSession.GenerationError) -> LLMError {
        switch error {
        case .guardrailViolation, .refusal, .unsupportedLanguageOrLocale:
            // Content-specific: fail the single article, never pause.
            .contentRejected
        case .exceededContextWindowSize, .decodingFailure, .unsupportedGuide:
            .badResponse
        case .assetsUnavailable:
            .appleUnavailable(.modelNotReady)
        case .rateLimited, .concurrentRequests:
            .unreachable(error.localizedDescription)
        @unknown default:
            .badResponse
        }
    }

    /// GeneratedContent stores every number as Double, so integers (e.g.
    /// articleIds) can serialize as "5.0". A JSONSerialization round-trip
    /// renders integral doubles as plain integers before decoding.
    private static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = Data(json.utf8)
        if let value = try? JSONDecoder().decode(T.self, from: data) {
            return value
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let normalized = try? JSONSerialization.data(withJSONObject: object),
            let value = try? JSONDecoder().decode(T.self, from: normalized)
        else { throw LLMError.badResponse }
        return value
    }
}
