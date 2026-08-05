import Testing

@testable import AetherFeed

struct PowerGateTests {
    @Test func onlyAppleIntelligenceIsGated() {
        // Ollama and OpenAI compute on a remote server — no local energy.
        #expect(
            AIPowerGate.blocks(provider: .ollama, settingEnabled: true, onBattery: true) == false)
        #expect(
            AIPowerGate.blocks(provider: .openai, settingEnabled: true, onBattery: true) == false)
        #expect(
            AIPowerGate.blocks(provider: .appleIntelligence, settingEnabled: true, onBattery: true))
    }

    @Test func settingOffNeverBlocks() {
        #expect(
            AIPowerGate.blocks(
                provider: .appleIntelligence, settingEnabled: false, onBattery: true) == false)
    }

    @Test func acPowerNeverBlocks() {
        #expect(
            AIPowerGate.blocks(
                provider: .appleIntelligence, settingEnabled: true, onBattery: false) == false)
    }

    /// Environment-dependent value — this only pins down that the IOKit query
    /// is callable off the MainActor and returns instead of trapping.
    @Test func powerSourceQueryIsCallable() {
        _ = PowerMonitor.currentlyOnBattery()
    }
}
