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

    private let red: [UInt8] = [255, 0, 0]
    private let blue: [UInt8] = [0, 0, 255]

    func testRotateRGB90ClockwiseMovesLeftPixelToTop() {
        let source = red + blue
        let rotated = BurstGeometry.rotateRGB(pixels: source, width: 2, height: 1, angleDegrees: 90)
        XCTAssertEqual(rotated.width, 1)
        XCTAssertEqual(rotated.height, 2)
        XCTAssertEqual(Array(rotated.pixels[0..<3]), red)
        XCTAssertEqual(Array(rotated.pixels[3..<6]), blue)
    }

    func testRotateRGB180ReversesPixels() {
        let source = red + blue
        let rotated = BurstGeometry.rotateRGB(pixels: source, width: 2, height: 1, angleDegrees: 180)
        XCTAssertEqual(rotated.width, 2)
        XCTAssertEqual(rotated.height, 1)
        XCTAssertEqual(Array(rotated.pixels[0..<3]), blue)
        XCTAssertEqual(Array(rotated.pixels[3..<6]), red)
    }

    func testRotateRGB270MovesLeftPixelToBottom() {
        let source = red + blue
        let rotated = BurstGeometry.rotateRGB(pixels: source, width: 2, height: 1, angleDegrees: 270)
        XCTAssertEqual(rotated.width, 1)
        XCTAssertEqual(rotated.height, 2)
        XCTAssertEqual(Array(rotated.pixels[0..<3]), blue)
        XCTAssertEqual(Array(rotated.pixels[3..<6]), red)
    }

    func testRotateRGBNormalizesAngleAndKeepsZero() {
        let source = red + blue
        let same = BurstGeometry.rotateRGB(pixels: source, width: 2, height: 1, angleDegrees: 0)
        XCTAssertEqual(same.pixels, source)
        let normalized = BurstGeometry.rotateRGB(pixels: source, width: 2, height: 1, angleDegrees: 450)
        XCTAssertEqual(normalized.width, 1)
        XCTAssertEqual(normalized.height, 2)
    }
}
