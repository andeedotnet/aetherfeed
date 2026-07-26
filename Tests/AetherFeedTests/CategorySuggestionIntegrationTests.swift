import Foundation
import Testing

@testable import AetherFeed

/// Live test of the AI category suggestion via the real path
/// (feed preview → Ollama structured output). Skips itself when no
/// Ollama server is reachable (OLLAMA_TEST_HOST or localhost).
@Suite struct CategorySuggestionIntegrationTests {
    @Test func suggestsCategoryAgainstLiveOllama() async throws {
        let host = ProcessInfo.processInfo.environment["OLLAMA_TEST_HOST"] ?? "localhost"
        let probe = OllamaClient(config: OllamaConfig(host: host, port: 11434, model: ""))
        guard
            let models = try? await probe.listModels(),
            let model = models.first(where: { !$0.hasPrefix("bge") })
        else {
            // No reachable Ollama server — nothing to test.
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(host, forKey: "ollamaHost")
        defaults.set(11434, forKey: "ollamaPort")
        defaults.set(model, forKey: "ollamaModel")
        defer {
            ["ollamaHost", "ollamaPort", "ollamaModel"]
                .forEach { defaults.removeObject(forKey: $0) }
        }

        let suggestion = try await LLMPipeline.shared.suggestCategory(
            urlString: "https://www.heise.de/rss/heise-atom.xml")
        #expect(!suggestion.category.isEmpty)
    }
}
