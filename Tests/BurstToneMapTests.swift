import XCTest
@testable import BurstCore

final class BurstToneMapTests: XCTestCase {
    func testGuidedShadowMapMatchesIndependentNumpyFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tone-map", withExtension: "json", subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let input = try XCTUnwrap(object["luminances"] as? [Double])
        let expected = try XCTUnwrap(object["gains"] as? [Double])
        let map = try BurstToneMap(luminances: input, width: 40, height: 32)
        XCTAssertEqual(map.compression, try XCTUnwrap(object["compression"] as? Double), accuracy: 1e-9)
        for i in input.indices {
            XCTAssertEqual(map.gain(x: Double(i % 40), y: Double(i / 40)), expected[i], accuracy: 1e-8)
        }
    }

    func testFlatSceneDoesNotReceiveAdaptiveLift() throws {
        let map = try BurstToneMap(luminances: [Double](repeating: 0.02, count: 30), width: 6, height: 5)
        XCTAssertEqual(map.compression, 1)
        XCTAssertEqual(map.gain(x: 2.3, y: -5), 1)
    }

    func testNeutralRampIsNeutralMonotonicAndHasSmoothHighlightShoulder() {
        var previous = -1.0
        for i in 0...1000 {
            let input = Double(i) / 100
            let out = BurstToneMap.render(red: input, green: input, blue: input, gain: 1)
            XCTAssertEqual(out.0, out.1, accuracy: 1e-12)
            XCTAssertEqual(out.1, out.2, accuracy: 1e-12)
            XCTAssertGreaterThanOrEqual(out.0, previous)
            XCTAssertLessThanOrEqual(out.0, 1)
            previous = out.0
        }
        let mid = BurstToneMap.render(red: 0.18, green: 0.18, blue: 0.18, gain: 1)
        XCTAssertEqual(mid.0, 0.18, accuracy: 1e-12)
        let bright = BurstToneMap.render(red: 1.2, green: 1.2, blue: 1.2, gain: 1)
        XCTAssertGreaterThan(bright.0, 0.65)
        XCTAssertLessThan(bright.0, 1)
    }

    func testOutOfGamutCompressionPreservesLuminanceAndChromaDirection() {
        let r = 1.8, g = 0.3, b = -0.1
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let out = BurstToneMap.render(red: r, green: g, blue: b, gain: 1)
        XCTAssertEqual(0.2126 * out.0 + 0.7152 * out.1 + 0.0722 * out.2, y, accuracy: 1e-12)
        XCTAssertEqual((out.0 - y) / (r - y), (out.2 - y) / (b - y), accuracy: 1e-12)
        for c in [out.0, out.1, out.2] { XCTAssertTrue((0...1).contains(c)) }
    }

    func testInvalidInputIsRejectedAndGainIsBounded() throws {
        XCTAssertThrowsError(try BurstToneMap(luminances: [.nan], width: 1, height: 1))
        XCTAssertThrowsError(try BurstToneMap(luminances: [1], width: 2, height: 1))
        let out = BurstToneMap.render(red: 0.01, green: 0.01, blue: 0.01, gain: 100)
        XCTAssertEqual(out.0, 0.02, accuracy: 1e-12)
    }

    func testHighlightCompressionRetainsEightBitStepsAndShadowLift() throws {
        let map = try BurstToneMap(luminances: (0..<400).map { exp(-8 + Double($0) / 399 * 12) }, width: 40, height: 10)
        XCTAssertGreaterThan(map.gain(x: 0, y: 0), 1)
        XCTAssertLessThan(map.gain(x: 39, y: 9), 1)
        func code(_ value: Double) -> Int {
            let y = BurstToneMap.render(red: value, green: value, blue: value, gain: 1).0
            return Int((255 * (1.055 * pow(y, 1 / 2.4) - 0.055)).rounded())
        }
        XCTAssertLessThan(code(2), code(4))
        XCTAssertLessThan(code(4), code(8))
        XCTAssertLessThan(code(8), 255)
        let dimmed = BurstToneMap.render(red: 0.18, green: 0.18, blue: 0.18, gain: 0.5)
        XCTAssertEqual(dimmed.0, 0.09, accuracy: 1e-12)
    }

    func testBrightOrangeKeepsColorWhenPreviewLowersItsOutputLuminance() throws {
        let levels = (0..<432).map { 0.005 + Double($0) / 431.0 * 0.94 }
        let reference = BurstPreviewReference(luminances: levels.map { $0 * 0.3 }, width: 24, height: 18)
        let curve = try XCTUnwrap(BurstPreviewTone(rendered: levels, width: 24, height: 18, reference: reference))
        let raw = (2.6, 1.0, 0.1)
        let intermediate = BurstToneMap.render(red: raw.0, green: raw.1, blue: raw.2, gain: 1)
        let old = curve.apply(red: intermediate.0, green: intermediate.1, blue: intermediate.2)
        let corrected = BurstToneMap.render(red: raw.0, green: raw.1, blue: raw.2, gain: 1, previewTone: curve)
        XCTAssertLessThan(old.0 / old.1, 2)
        XCTAssertEqual(corrected.0 / corrected.1, raw.0 / raw.1, accuracy: 1e-10)
        XCTAssertEqual(corrected.2 / corrected.1, raw.2 / raw.1, accuracy: 1e-10)
        func y(_ rgb: (Double, Double, Double)) -> Double { 0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2 }
        XCTAssertEqual(y(corrected), y(old), accuracy: 1e-12)
        // Recovering color must not flatten neighboring radiance values.
        let brighter = BurstToneMap.render(red: raw.0 * 1.01, green: raw.1 * 1.01, blue: raw.2 * 1.01, gain: 1, previewTone: curve)
        XCTAssertGreaterThan(y(brighter), y(corrected))
    }
}
