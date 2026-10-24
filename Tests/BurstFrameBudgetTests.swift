import XCTest
@testable import BurstCore

final class BurstFrameBudgetTests: XCTestCase {
    let profile = [0.0000333465826225, 0.000000455325349284]
    let bytes = 4032 * 3024 * 2
    func testQualityPriorityUsesTwelveInBrightSceneAndTwentyForLiftedShadows() {
        let bright = BurstFrameBudget.select(signal: 500, noiseProfile: profile, bytesPerFrame: bytes)
        let shadows = BurstFrameBudget.select(signal: 28, noiseProfile: profile, bytesPerFrame: bytes)
        XCTAssertEqual(bright.frames, 12)
        XCTAssertEqual(shadows.frames, 20)
        XCTAssertTrue(shadows.usedNoiseModel)
        XCTAssertGreaterThan(shadows.sigma, 9)
        XCTAssertLessThan(shadows.frames * bytes + 32 * 1024 * 1024, Int(BurstDiagnosticStorage.limitBytes))
    }
    func testDarkerSignalNeverSelectsFewerSamplesAndAllBudgetsAreBounded() {
        var previous = 20
        for signal in stride(from: 0.0, through: 1000, by: 10) {
            let decision = BurstFrameBudget.select(signal: signal, noiseProfile: profile, bytesPerFrame: bytes)
            XCTAssertLessThanOrEqual(decision.frames, previous)
            XCTAssertTrue((12...20).contains(decision.frames))
            XCTAssertEqual(decision.frames % 4, 0)
            previous = decision.frames
        }
        XCTAssertLessThanOrEqual(BurstFrameBudget.select(signal: 0, noiseProfile: profile,
                                                       bytesPerFrame: 100 * 1024 * 1024).frames, 4)
    }
    func testMissingInvalidOrOverflowingNoiseUsesBoundedFallback() {
        for profile in [nil, [], [.nan, 1], [-1, 2], [0, 0], [1e308, 1e308]] as [[Double]?] {
            let decision = BurstFrameBudget.select(signal: 100, noiseProfile: profile, bytesPerFrame: bytes)
            XCTAssertEqual(decision.frames, 16)
            XCTAssertFalse(decision.usedNoiseModel)
        }
        XCTAssertEqual(BurstFrameBudget.select(signal: .nan, noiseProfile: profile, bytesPerFrame: bytes).frames, 16)
    }
}
