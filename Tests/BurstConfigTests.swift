import XCTest
@testable import BurstCore

final class BurstConfigTests: XCTestCase {
    func testFrameCountClampsToSupportedRange() {
        XCTAssertEqual(BurstConfig(mode: .photo, frameCount: 0, underExposureEV: 0).frameCount, 1)
        XCTAssertEqual(BurstConfig(mode: .photo, frameCount: 99, underExposureEV: 0).frameCount, 32)
        XCTAssertEqual(BurstConfig(mode: .photo, frameCount: 12, underExposureEV: 0).frameCount, 12)
    }

    func testModeDefaults() {
        XCTAssertEqual(BurstConfig.defaults(for: .photo), BurstConfig(mode: .photo, frameCount: 8, underExposureEV: -1.5))
        XCTAssertEqual(BurstConfig.defaults(for: .night), BurstConfig(mode: .night, frameCount: 16, underExposureEV: -1.0))
        XCTAssertEqual(BurstConfig.defaults(for: .longExposure), BurstConfig(mode: .longExposure, frameCount: 16, underExposureEV: 0))
        XCTAssertTrue(BurstConfig.defaults(for: .photo).usesRobustMerge)
        XCTAssertTrue(BurstConfig.defaults(for: .night).usesRobustMerge)
        XCTAssertFalse(BurstConfig.defaults(for: .longExposure).usesRobustMerge)
    }

    func testTwelveMegapixelFrameBudget() {
        let budget = FrameMemoryBudget(width: 4032, height: 3024, budgetBytes: 256 * 1024 * 1024)
        XCTAssertEqual(budget.bytesPerFrame, 24_385_536)
        XCTAssertEqual(budget.maxFramesInBudget, 11)
    }

    func testTinyBudgetNeverDropsBelowOneFrame() {
        let budget = FrameMemoryBudget(width: 4032, height: 3024, budgetBytes: 1_000_000)
        XCTAssertEqual(budget.maxFramesInBudget, 1)
    }
}
