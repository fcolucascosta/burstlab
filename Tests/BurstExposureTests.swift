import XCTest
@testable import BurstCore

final class BurstExposureTests: XCTestCase {
    func testUniformGrayMapsToMiddleGray() throws {
        let meter = try BurstExposure(luminances: [Double](repeating: 0.04, count: 1000))
        XCTAssertEqual(meter.scale * 0.04, 0.18, accuracy: 1e-12)
        XCTAssertEqual(meter.adjustmentEV, 0, accuracy: 1e-12)
    }

    func testKnownLogAverageOfTwoRegions() throws {
        let input = [Double](repeating: 0.01, count: 50) + [Double](repeating: 0.16, count: 50)
        let meter = try BurstExposure(luminances: input)
        XCTAssertEqual(meter.logAverage, 0.04, accuracy: 1e-12)
        XCTAssertEqual(meter.scale, 0.18 / 0.04, accuracy: 1e-12)
    }

    func testSmallReframingDoesNotJumpWhenBrightRegionCrossesHalfTheImage() throws {
        let a = try BurstExposure(luminances: [Double](repeating: 0.01, count: 490) + [Double](repeating: 0.16, count: 510))
        let b = try BurstExposure(luminances: [Double](repeating: 0.01, count: 510) + [Double](repeating: 0.16, count: 490))
        XCTAssertLessThan(abs(log2(a.scale / b.scale)), 0.1)
    }

    func testChangingCaptureExposurePreservesRenderedBrightnessUntilLimits() throws {
        let scene = (0..<1000).map { 0.02 + Double($0) / 1000 * 0.1 }
        let original = try BurstExposure(luminances: scene)
        let darker = try BurstExposure(luminances: scene.map { $0 / 2 })
        XCTAssertEqual(darker.scale, original.scale * 2, accuracy: 1e-10)
    }

    func testSmallHotPixelPopulationDoesNotMeterScene() throws {
        let plain = try BurstExposure(luminances: [Double](repeating: 0.04, count: 1000))
        let hot = try BurstExposure(luminances: [Double](repeating: 0.04, count: 990) + [Double](repeating: 1e6, count: 10))
        XCTAssertEqual(hot.scale, plain.scale, accuracy: 1e-10)
    }

    func testDarkAndBrightScenesRespectGainLimits() throws {
        XCTAssertEqual(try BurstExposure(luminances: [0, 0, 0]).scale, 24)
        XCTAssertEqual(try BurstExposure(luminances: [10, 10, 10]).scale, 0.5)
        XCTAssertThrowsError(try BurstExposure(luminances: []).scale)
        XCTAssertThrowsError(try BurstExposure(luminances: [.infinity]).scale)
        XCTAssertThrowsError(try BurstExposure(luminances: [-1]).scale)
    }
}
