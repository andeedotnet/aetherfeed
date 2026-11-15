import Foundation
import FoundationModels

/// On-device Apple Intelligence backend (macOS 26+, FoundationModels).
/// No network and no configuration; "configured" is defined solely by the
/// availability of the system model. Uses permissive guardrails —
/// summarizing third-party news is exactly the content-transformation use
/// case they exist for.
@available(macOS 26.0, *)
struct AppleIntelligenceClient: LLMClient {
    /// The on-device context window is small (4096 tokens on AFM 3 Core);
    /// below this prompt size further shrinking is pointless and the call
    /// fails for the single item.
    private static let minimumPromptChars = 1000
    private static let maxAttempts = 3
    /// Tokens kept free for the structured response. The largest outputs
    /// (a digest section with up to 4 topic cards) stay well below this.
    static let responseReserveTokens = 1024

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
        return [Self.displayName(variant: Self.variantName, localize: L10nKey.localizedOffMain)]
    }

    /// Generation of the installed on-device model (e.g. "AFM 3 Core");
    /// nil before macOS 27, which does not expose it, or while the model is
    /// unavailable.
    static var variantName: String? {
        guard #available(macOS 27.0, *) else { return nil }
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }
        let name = model.variant.displayName
        return name.isEmpty ? nil : name
    }

    /// Settings label for the on-device model, naming its generation when
    /// the OS reports one. `localize` abstracts over the MainActor
    /// `Localizer` and the off-main lookup.
    static func displayName(variant: String?, localize: (L10nKey) -> String) -> String {
        guard let variant else { return localize(.appleModelName) }
        return String(format: localize(.appleModelNameVariant), variant)
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

        // Callers size prompts for server models (8k/16k ctx). Fit the prompt
        // up front where the OS can count tokens; the halving below remains
        // the fallback for older systems and for miscounts.
        var prompt = user
        if #available(macOS 26.4, *) {
            prompt = await Self.fitPrompt(
                user, system: system, schema: generationSchema, model: model)
        }
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
                    // Still too large (no token counting, or the estimate
                    // fell short): shrink instead of failing outright.
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

    // MARK: - Context budget

    /// Token budget left for the user prompt once instructions, schema and
    /// the response reserve are subtracted from the model's context window.
    @available(macOS 26.4, *)
    static func promptBudget(
        system: String, schema: GenerationSchema, model: SystemLanguageModel
    ) async throws -> Int {
        let fixed = try await model.tokenCount(for: Instructions(system))
            + model.tokenCount(for: schema)
        return model.contextSize - fixed - responseReserveTokens
    }

    /// Truncates `prompt` (at a sentence boundary) until its token count fits
    /// the budget. Token counting is only an optimization: any failure
    /// returns the prompt unchanged and the retry loop takes over.
    @available(macOS 26.4, *)
    static func fitPrompt(
        _ prompt: String, system: String, schema: GenerationSchema, model: SystemLanguageModel
    ) async -> String {
        do {
            let budget = try await promptBudget(system: system, schema: schema, model: model)
            guard budget > 0 else { return prompt }
            var fitted = prompt
            for _ in 0..<3 {
                let tokens = try await model.tokenCount(for: fitted)
                guard tokens > budget, fitted.count > minimumPromptChars else { return fitted }
                // Scale by the overshoot with 10% slack: characters per token
                // vary across the text (markup, numbers, names).
                let limit = Int(Double(fitted.count) * Double(budget) / Double(tokens) * 0.9)
                fitted = LLMPipeline.truncate(fitted, limit: max(limit, minimumPromptChars))
            }
            return fitted
        } catch {
            return prompt
        }
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
