import XCTest
@testable import BurstCore

final class BurstPreviewSpatialToneTests: XCTestCase {
    private let w = 48, h = 36
    private var scene: [Double] { (0..<1728).map { i in 0.005 + 0.8 * pow(Double(i % 48) / 47, 2) } }

    func testSamePreviewRetainsCloudGradientAndBlackAndWhiteHeadroom() throws {
        let input = scene
        let map = try XCTUnwrap(BurstPreviewSpatialTone(luminances: input, width: w, height: h,
            reference: .init(luminances: input, width: w, height: h)))
        XCTAssertGreaterThan(map.correlation, 0.99)
        for x in [8, 16, 24, 32, 40] {
            let y = input[18 * w + x], expected = y * exp2(0.15 * pow(1 - y, 2))
            XCTAssertEqual(map.luminance(y, x: Double(x), y: 18), expected, accuracy: 0.012)
        }
        XCTAssertEqual(map.luminance(0, x: 10, y: 10), 0)
        XCTAssertLessThan(map.luminance(20, x: 10, y: 10), 1)
        XCTAssertGreaterThan(map.luminance(20, x: 10, y: 10), map.luminance(10, x: 10, y: 10))
    }

    func testEqualSceneLuminanceCanHaveDifferentLocalPreviewIntent() throws {
        let input = scene
        let target = input.enumerated().map { i, y in y * (i / 48 < 18 ? 0.55 : 1.0) }
        let map = try XCTUnwrap(BurstPreviewSpatialTone(luminances: input, width: w, height: h,
            reference: .init(luminances: target, width: w, height: h)))
        XCTAssertLessThan(map.luminance(0.3, x: 30, y: 0), map.luminance(0.3, x: 30, y: 35) * 0.8)
        // Fixed-position point curve remains monotone, with detail modulation.
        var previous = 0.0
        for i in 0...1000 {
            let output = map.luminance(Double(i) / 500, x: 30, y: 10)
            XCTAssertGreaterThanOrEqual(output + 1e-12, previous)
            XCTAssertTrue((0...1).contains(output))
            previous = output
        }
    }

    func testProductionRenderUsesSceneLinearColorBeforeAnyHighlightCompression() throws {
        let input = scene.map { $0 * 1.4 }, target = scene.map { $0 * 0.65 }
        let map = try XCTUnwrap(BurstPreviewSpatialTone(luminances: input, width: w, height: h,
            reference: .init(luminances: target, width: w, height: h)))
        let expected = map.luminance(0.2126 * 1.2 + 0.7152 * 0.6 + 0.0722 * 0.3, x: 35, y: 18)
        let rgb = BurstToneMap.render(red: 1.2, green: 0.6, blue: 0.3, gain: 0.0625,
                                      spatialTone: map, x: 35, y: 18)
        XCTAssertEqual(0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2, expected, accuracy: 1e-8)
        XCTAssertEqual(rgb.0 / rgb.1, 2, accuracy: 1e-7)
        XCTAssertEqual(rgb.1 / rgb.2, 2, accuracy: 1e-7)
    }

    func testUnrelatedInvalidFlatOrCroppedProxyFallsBack() {
        let input = scene
        for values in [Array(input.reversed()), [Double](repeating: 0.2, count: input.count),
                       [Double](repeating: .nan, count: input.count)] {
            XCTAssertNil(BurstPreviewSpatialTone(luminances: input, width: w, height: h,
                reference: .init(luminances: values, width: w, height: h)))
        }
        XCTAssertNil(BurstPreviewSpatialTone(luminances: input, width: w, height: h,
            reference: .init(luminances: Array(input.prefix(48 * 27)), width: 48, height: 27)))
        XCTAssertNil(BurstPreviewSpatialTone(luminances: [Double](repeating: .infinity, count: input.count),
            width: w, height: h, reference: .init(luminances: input, width: w, height: h)))
    }
}
