import Testing

@testable import AetherFeed

@Suite struct UpdateCheckerTests {
    @Test func parsesTagsWithAndWithoutPrefix() {
        #expect(UpdateChecker.parseVersion("v0.1.0") == [0, 1, 0])
        #expect(UpdateChecker.parseVersion("0.1.0") == [0, 1, 0])
        #expect(UpdateChecker.parseVersion("V2.10") == [2, 10])
        #expect(UpdateChecker.parseVersion("release") == nil)
        #expect(UpdateChecker.parseVersion("") == nil)
    }

    @Test func comparesNumericallyNotLexicographically() {
        #expect(UpdateChecker.isNewer("v0.2.0", than: "0.1.0"))
        #expect(UpdateChecker.isNewer("0.10.0", than: "0.9.9"))
        #expect(!UpdateChecker.isNewer("v0.1.0", than: "0.1.0"))
        #expect(!UpdateChecker.isNewer("0.0.9", than: "0.1.0"))
    }

    @Test func padsShorterVersionsWithZeros() {
        #expect(!UpdateChecker.isNewer("0.1", than: "0.1.0"))
        #expect(UpdateChecker.isNewer("0.1.1", than: "0.1"))
        #expect(!UpdateChecker.isNewer("garbage", than: "0.1.0"))
    }
}
