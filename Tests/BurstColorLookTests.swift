import XCTest
@testable import BurstCore

final class BurstColorLookTests: XCTestCase {
    func testPublishedOklabRedAndRoundTrip() {
        let red = BurstColorLook.toLab(1, 0, 0)
        XCTAssertEqual(red.l, 0.6279553606, accuracy: 1e-8)
        XCTAssertEqual(red.a, 0.2248630611, accuracy: 1e-8)
        XCTAssertEqual(red.b, 0.1258462985, accuracy: 1e-8)
        for input in [(0.3, 0.4, 0.2), (0.01, 0.02, 0.08), (0.8, 0.15, 0.03)] {
            let result = BurstColorLook.fromLab(BurstColorLook.toLab(input.0, input.1, input.2), chromaScale: 1)
            XCTAssertEqual(result.0, input.0, accuracy: 1e-7)
            XCTAssertEqual(result.1, input.1, accuracy: 1e-7)
            XCTAssertEqual(result.2, input.2, accuracy: 1e-7)
        }
    }

    func testNeutralRampAndDeepShadowDoNotReceiveColorBoost() {
        for i in 0...255 {
            let value = Double(i) / 255
            let result = BurstColorLook.apply(red: value, green: value, blue: value)
            XCTAssertEqual(result.0, value); XCTAssertEqual(result.1, value); XCTAssertEqual(result.2, value)
        }
        let shadow = BurstColorLook.apply(red: 0.002, green: 0.003, blue: 0.004)
        XCTAssertEqual(shadow.0, 0.002); XCTAssertEqual(shadow.1, 0.003); XCTAssertEqual(shadow.2, 0.004)
    }

    func testMutedColorGainsChromaWithoutLightnessOrHueShift() {
        let before = BurstColorLook.toLab(0.4, 0.3, 0.25)
        let rgb = BurstColorLook.apply(red: 0.4, green: 0.3, blue: 0.25)
        let after = BurstColorLook.toLab(rgb.0, rgb.1, rgb.2)
        XCTAssertGreaterThan(hypot(after.a, after.b), hypot(before.a, before.b) * 1.25)
        XCTAssertEqual(after.l, before.l, accuracy: 1e-7)
        XCTAssertEqual(atan2(after.b, after.a), atan2(before.b, before.a), accuracy: 1e-5)
    }

    func testGamutLimitsAcrossRGBAndWarmSkinLikeSwatches() {
        for r in [0.0, 0.03, 0.15, 0.4, 0.8, 1] {
            for g in [0.0, 0.03, 0.15, 0.4, 0.8, 1] {
                for b in [0.0, 0.03, 0.15, 0.4, 0.8, 1] {
                    let before = BurstColorLook.toLab(r, g, b)
                    let out = BurstColorLook.apply(red: r, green: g, blue: b)
                    for c in [out.0, out.1, out.2] { XCTAssertTrue((0...1).contains(c)) }
                    let after = BurstColorLook.toLab(out.0, out.1, out.2)
                    XCTAssertEqual(after.l, before.l, accuracy: 2e-6)
                    if hypot(before.a, before.b) > 1e-4 {
                        let cross = before.a * after.b - before.b * after.a
                        XCTAssertEqual(cross, 0, accuracy: 2e-7)
                    }
                }
            }
        }
    }
}
