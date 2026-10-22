import XCTest
@testable import BurstCore

final class BurstConfigTests: XCTestCase {
    func testAlignmentKeepsFlatSceneAtZero() {
        let flat = [Float](repeating: 2112, count: 256)
        XCTAssertEqual(BurstAlignment.bestShift(flat, flat, maxShift: 64), 0)
    }

    func testAlignmentFindsBothDirectionsAndPreservesBayerPhase() {
        let reference: [Float] = (0..<256).map { (index: Int) -> Float in
            let quadratic = index * index * 17
            let linear = index * 31
            return Float((quadratic + linear) % 1009)
        }
        for offset in [-14, -2, 2, 14] {
            var shifted = [Float](repeating: 0, count: reference.count)
            for index in reference.indices where reference.indices.contains(index + offset) {
                shifted[index + offset] = reference[index]
            }
            XCTAssertEqual(BurstAlignment.bestShift(reference, shifted, maxShift: 32), offset)
        }
    }

    func testAlignmentRejectsNonFiniteProfiles() {
        XCTAssertEqual(BurstAlignment.bestShift([Float](repeating: .nan, count: 256),
                                               [Float](repeating: 1, count: 256), maxShift: 64), 0)
    }

    func testRawLayoutRejectsTruncationOddStrideAndOverflow() {
        XCTAssertTrue(BurstRawLayout.isValid(width: 4032, height: 3024, bytesPerRow: 8064, byteCount: 24_385_536))
        XCTAssertTrue(BurstRawLayout.isValid(width: 4, height: 4, bytesPerRow: 16, byteCount: 64))
        XCTAssertFalse(BurstRawLayout.isValid(width: 4, height: 4, bytesPerRow: 8, byteCount: 31))
        XCTAssertFalse(BurstRawLayout.isValid(width: 4, height: 4, bytesPerRow: 9, byteCount: 36))
        XCTAssertFalse(BurstRawLayout.isValid(width: 3, height: 4, bytesPerRow: 8, byteCount: 32))
        XCTAssertFalse(BurstRawLayout.isValid(width: Int.max - 1, height: 4, bytesPerRow: 8, byteCount: 32))
    }

    func testColorTransformRejectsNonFiniteMetadata() {
        var invalid = colorMatrix1
        invalid[0] = .nan
        XCTAssertNil(BurstColorMatrix.cameraToSRGB(matrix1: invalid, matrix2: colorMatrix2, neutral: [1, 1, 1]))
        XCTAssertNil(BurstColorMatrix.cameraToSRGB(matrix1: colorMatrix1, matrix2: colorMatrix2, neutral: [.infinity, 1, 1]))
        XCTAssertNil(BurstColorMatrix.cameraToSRGB(matrix1: colorMatrix1, matrix2: colorMatrix2, neutral: [1, 1, 1], temperature1: .infinity))
    }

    func testFrameCountClampsToSupportedRange() {
        XCTAssertEqual(BurstConfig(mode: .photo, frameCount: 0, underExposureEV: 0).frameCount, 1)
        XCTAssertEqual(BurstConfig(mode: .photo, frameCount: 99, underExposureEV: 0).frameCount, 32)
        XCTAssertEqual(BurstConfig(mode: .photo, frameCount: 12, underExposureEV: 0).frameCount, 12)
    }

    func testModeDefaults() {
        XCTAssertEqual(BurstConfig.defaults(for: .photo), BurstConfig(mode: .photo, frameCount: 8, underExposureEV: -0.5))
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

    private let colorMatrix1: [Double] = [
        1.5069, -0.8881, -0.1335,
        -0.5356, 1.5421, 0.1474,
        -0.0192, 0.0953, 0.7604
    ]
    private let colorMatrix2: [Double] = [
        0.8300, -0.2739, -0.0971,
        -0.5732, 1.3636, 0.1709,
        -0.0864, 0.1364, 0.5364
    ]

    func testCameraToSRGBMapsNeutralToWhite() {
        let neutral: [Double] = [0.4836, 1.0, 0.5069]
        guard let transform = BurstColorMatrix.cameraToSRGB(
            matrix1: colorMatrix1,
            matrix2: colorMatrix2,
            neutral: neutral
        ) else {
            return XCTFail("transformacao deveria ser valida")
        }
        for row in 0..<3 {
            let dot = transform[row * 3] * neutral[0]
                + transform[row * 3 + 1] * neutral[1]
                + transform[row * 3 + 2] * neutral[2]
            XCTAssertEqual(dot, 1.0, accuracy: 1e-9)
        }
    }

    func testCameraToSRGBRecoversD65Red() {
        let neutral: [Double] = [0.407281, 1.0, 0.635233]
        guard let transform = BurstColorMatrix.cameraToSRGB(
            matrix1: colorMatrix1,
            matrix2: colorMatrix2,
            neutral: neutral
        ) else {
            return XCTFail("transformacao deveria ser valida")
        }
        let cameraRed: [Double] = [0.28221, 0.056885, 0.003743]
        for row in 0..<3 {
            let value = transform[row * 3] * cameraRed[0]
                + transform[row * 3 + 1] * cameraRed[1]
                + transform[row * 3 + 2] * cameraRed[2]
            XCTAssertEqual(value, row == 0 ? 1.0 : 0.0, accuracy: 0.01)
        }
    }

    func testCameraToSRGBRejectsInvalidInput() {
        XCTAssertNil(BurstColorMatrix.cameraToSRGB(matrix1: [1, 2, 3], matrix2: colorMatrix2, neutral: [1, 1, 1]))
        XCTAssertNil(BurstColorMatrix.cameraToSRGB(matrix1: colorMatrix1, matrix2: colorMatrix2, neutral: [0, 1, 1]))
        XCTAssertNil(
            BurstColorMatrix.cameraToSRGB(
                matrix1: colorMatrix1,
                matrix2: colorMatrix2,
                neutral: [1, 1, 1],
                temperature1: 6504,
                temperature2: 6504
            )
        )
    }

    func testIlluminantTemperatures() {
        XCTAssertEqual(BurstColorMatrix.temperature(forIlluminant: 17), 2856)
        XCTAssertEqual(BurstColorMatrix.temperature(forIlluminant: 21), 6504)
        XCTAssertNil(BurstColorMatrix.temperature(forIlluminant: 0))
    }
}
