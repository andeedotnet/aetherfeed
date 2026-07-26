import Foundation
import FoundationModels
import Testing

@testable import AetherFeed

/// Serialized: the live tests share the single on-device model, which
/// rejects concurrent requests.
@Suite(.serialized) struct AppleIntelligenceTests {
    // MARK: - Schema translation (pure, no model required)

    @available(macOS 26.0, *)
    private func encodedSchema(_ schema: JSONValue) throws -> String {
        let generation = try JSONSchemaTranslator.generationSchema(from: schema)
        let data = try JSONEncoder().encode(generation)
        return String(decoding: data, as: UTF8.self)
    }

    @Test @available(macOS 26.0, *) func translatesAllProductionSchemas() throws {
        // Loose assertions on the encoded JSON: the exact encoded shape is
        // Apple's implementation detail; field names surviving is what matters.
        let article = try encodedSchema(ArticleAnalysis.schema)
        #expect(article.contains("summary"))
        #expect(article.contains("tags"))
        let category = try encodedSchema(CategorySuggestion.schema)
        #expect(category.contains("isExisting"))
        let topics = try encodedSchema(CategoryTopicsResult.schema)
        #expect(topics.contains("articleIds"))
        let overview = try encodedSchema(OverviewResult.schema)
        #expect(overview.contains("overview"))
    }

    @Test @available(macOS 26.0, *) func translatesEnumAndOptionalProperties() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "mood": ["enum": ["happy", "sad"]],
                "note": ["type": "string"],
            ],
            "required": ["mood"],
        ]
        let encoded = try encodedSchema(schema)
        #expect(encoded.contains("happy"))
        #expect(encoded.contains("note"))
    }

    @Test @available(macOS 26.0, *) func unsupportedSchemaNodeThrows() {
        let schema: JSONValue = [
            "type": "object",
            "properties": ["blob": ["type": "binary"]],
            "required": ["blob"],
        ]
        #expect(throws: JSONSchemaTranslator.UnsupportedSchema.self) {
            _ = try JSONSchemaTranslator.generationSchema(from: schema)
        }
    }

    // MARK: - Error mapping

    @Test @available(macOS 26.0, *) func contentErrorsDoNotPausePipeline() {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "test")

        let guardrail = AppleIntelligenceClient.map(.guardrailViolation(context))
        guard case .contentRejected = guardrail else {
            Issue.record("guardrailViolation should map to contentRejected")
            return
        }
        #expect(!guardrail.pausesPipeline)

        let refusal = AppleIntelligenceClient.map(
            .refusal(.init(transcriptEntries: []), context))
        guard case .contentRejected = refusal else {
            Issue.record("refusal should map to contentRejected")
            return
        }

        let assets = AppleIntelligenceClient.map(.assetsUnavailable(context))
        guard case .appleUnavailable(.modelNotReady) = assets else {
            Issue.record("assetsUnavailable should map to appleUnavailable(.modelNotReady)")
            return
        }
        #expect(assets.pausesPipeline)
    }

    @Test func unavailabilityPausesPipeline() {
        #expect(LLMError.appleUnavailable(.notEnabled).pausesPipeline)
        #expect(LLMError.appleUnavailable(.osTooOld).pausesPipeline)
        #expect(!LLMError.contentRejected.pausesPipeline)
    }

    // MARK: - Localization

    @Test func newKeysLocalizedInBothLanguages() {
        let keys: [L10nKey] = [
            .providerApple, .appleModelName, .appleStatus, .settingsAppleTestSuccess,
            .errorAppleNotSupported, .errorAppleNotEnabled, .errorAppleModelNotReady,
            .errorAppleOSTooOld, .errorAppleUnavailable, .errorAppleRejected,
        ]
        for key in keys {
            #expect(L10nKey.german[key] != nil, "missing German string for \(key)")
            #expect(L10nKey.english[key] != nil, "missing English string for \(key)")
        }
    }

    // MARK: - Live integration (skips itself when the model is unavailable)

    @Test @available(macOS 26.0, *) func structuredAgainstLiveModel() async throws {
        let model = SystemLanguageModel(
            useCase: .general, guardrails: .permissiveContentTransformations)
        guard model.isAvailable else { return }

        let client = AppleIntelligenceClient()
        let analysis: ArticleAnalysis = try await client.structured(
            system: """
                You are a news assistant. Summarize the article in one sentence \
                and assign 2 short topic tags, each with a German ("de") and an \
                English ("en") label.
                """,
            user: "Title: Solarausbau\n\nArticle:\nDeutschland hat 2025 rund 16 Gigawatt "
                + "Photovoltaik-Leistung zugebaut und damit den Rekord des Vorjahres übertroffen.",
            schema: ArticleAnalysis.schema)
        #expect(!analysis.summary.isEmpty)
        #expect(!analysis.tags.isEmpty)
    }

    /// `articleIds` are integers; GeneratedContent stores numbers as Double.
    /// A successful decode proves the client's integer normalization works.
    @Test @available(macOS 26.0, *) func integerIdsDecodeAgainstLiveModel() async throws {
        let model = SystemLanguageModel(
            useCase: .general, guardrails: .permissiveContentTransformations)
        guard model.isAvailable else { return }

        let client = AppleIntelligenceClient()
        let result: CategoryTopicsResult = try await client.structured(
            system: "Group the given articles into 1-2 topics. "
                + "Reference articles by their numeric id in articleIds.",
            user: """
                [101] Solarausbau erreicht Rekord — 16 GW Zubau in Deutschland
                [102] Windkraft stockt — Genehmigungen dauern weiter Jahre
                """,
            schema: CategoryTopicsResult.schema)
        #expect(!result.topics.isEmpty)
        #expect(result.topics.allSatisfy { !$0.articleIds.isEmpty })
    }
}
