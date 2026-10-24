import XCTest
@testable import BurstCore

final class BurstPreviewToneTests: XCTestCase {
    // Dark material + midtones + a lit display. A generic gray-world exposure
    // lifts the black region; the reference intentionally keeps that region dark.
    private var scene: [Double] {
        (0..<432).map { i in 0.003 + 0.9 * pow(Double(i) / 431, 3) }
    }

    private func map(_ source: [Double], _ target: [Double]) throws -> BurstPreviewTone {
        try XCTUnwrap(BurstPreviewTone(rendered: source, width: 24, height: 18,
            reference: BurstPreviewReference(luminances: target, width: 24, height: 18)))
    }

    func testBlackMaterialIsNotForcedToMiddleGray() throws {
        let source = scene.map { pow($0, 0.65) }
        let curve = try map(source, scene)
        XCTAssertEqual(curve.luminance(0), 0)
        XCTAssertLessThan(curve.luminance(source[30]), 0.006)
        XCTAssertLessThan(curve.luminance(source[30]), source[30] / 3)
        XCTAssertLessThan(curve.medianCorrectionEV, 0)
        for i in [30, 100, 200, 300, 400] {
            let target = scene[i] * exp2(0.15 * pow(1 - scene[i], 2))
            XCTAssertEqual(curve.luminance(source[i]), target, accuracy: max(0.002, target * 0.05))
        }
    }

    func testSimilarPreviewGetsSmallMidtoneLiftAndRetainsHighlightSteps() throws {
        let curve = try map(scene, scene)
        XCTAssertGreaterThan(curve.luminance(0.18), 0.18)
        XCTAssertLessThan(curve.luminance(0.18), 0.20)
        XCTAssertLessThan(curve.luminance(0.8), curve.luminance(0.9))
        XCTAssertLessThan(curve.luminance(0.9), curve.luminance(1))
        XCTAssertLessThan(curve.luminance(1), 1)
    }

    func testContinuousRampNeverReversesContrastOrLeavesGamut() throws {
        let curve = try map(scene.map { pow($0, 0.65) }, scene)
        var previous = 0.0
        for i in 0...10000 {
            let value = Double(i) / 10000
            let out = curve.luminance(value)
            XCTAssertGreaterThanOrEqual(out + 1e-12, previous)
            XCTAssertTrue((0...1).contains(out))
            XCTAssertLessThanOrEqual(out, value * 4 + 1e-12)
            XCTAssertGreaterThanOrEqual(out + 1e-12, value / 16)
            previous = out
        }
        // Fine texture modulation survives a global point curve.
        XCTAssertGreaterThan(curve.luminance(0.101), curve.luminance(0.100))
    }

    func testNeutralAndChromaticDirectionArePreserved() throws {
        let curve = try map(scene, scene.map { $0 * 0.5 })
        let gray = curve.apply(red: 0.04, green: 0.04, blue: 0.04)
        XCTAssertEqual(gray.0, gray.1, accuracy: 1e-12)
        XCTAssertEqual(gray.1, gray.2, accuracy: 1e-12)
        let out = curve.apply(red: 0.6, green: 0.3, blue: 0.15)
        XCTAssertEqual(out.0 / out.1, 2, accuracy: 1e-10)
        XCTAssertEqual(out.1 / out.2, 2, accuracy: 1e-10)
    }

    func testUnrelatedPreviewAndFlatOrInvalidFramesAreRejected() throws {
        XCTAssertNil(BurstPreviewTone(rendered: scene, width: 24, height: 18,
            reference: BurstPreviewReference(luminances: Array(scene.reversed()), width: 24, height: 18)))
        for bad in [[Double](repeating: 0.04, count: 432), [Double](repeating: 0, count: 432),
                    [Double](repeating: .nan, count: 432), [Double](repeating: 1.1, count: 432), [0.1]] {
            XCTAssertNil(BurstPreviewTone(rendered: scene, width: 24, height: 18,
                reference: BurstPreviewReference(luminances: bad, width: 24, height: 18)))
        }
        XCTAssertNil(BurstPreviewTone(rendered: scene, width: Int.max, height: 18,
            reference: BurstPreviewReference(luminances: scene, width: 24, height: 18)))
    }

    func testHugeExposureDisagreementFailsClosed() {
        XCTAssertNil(BurstPreviewTone(rendered: scene.map { $0 / 100 }, width: 24, height: 18,
            reference: BurstPreviewReference(luminances: scene, width: 24, height: 18)))
    }

    func testUniformBlackPanelUsesPreviewBrightnessWithoutInventingContrast() throws {
        let curve = try map([Double](repeating: 0.08, count: 432), [Double](repeating: 0.008, count: 432))
        XCTAssertFalse(curve.usesContrastCurve)
        XCTAssertLessThan(curve.luminance(0.08), 0.009)
        XCTAssertEqual(curve.luminance(0), 0)
        XCTAssertGreaterThan(curve.luminance(0.081), curve.luminance(0.08))
    }

    func testQuantilePlateausDoNotDivideByZero() throws {
        let values = (0..<432).map { i in Double(i / 80 + 1) * 0.08 }
        let curve = try map(values, values.map { $0 * 0.7 })
        for i in 0...100 { XCTAssertTrue(curve.luminance(Double(i) / 100).isFinite) }
    }

    func testVideoAspectCropUsesCommonSensorField() throws {
        let source: [Double] = (0..<3888).map { i -> Double in
            let row = Double(i / 72) / 53.0
            return 0.01 + 0.8 * row
        }
        // A centered 16:9 video view of a 4:3 photo sensor.
        let video = Array(source[(7 * 72)..<(47 * 72)])
        let curve = try XCTUnwrap(BurstPreviewTone(rendered: source, width: 72, height: 54,
            reference: BurstPreviewReference(luminances: video, width: 72, height: 40)))
        XCTAssertGreaterThan(curve.correlation, 0.999)
        XCTAssertLessThan(abs(curve.medianCorrectionEV), 0.15)
    }
}
