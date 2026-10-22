import XCTest
@testable import BurstCore

final class BurstCapturePlanTests: XCTestCase {
    private func plan(_ mode: CaptureMode, duration: Double = 1.0 / 30, iso: Double = 640,
                      maximum: Double = 0.5) throws -> BurstCapturePlan {
        try XCTUnwrap(BurstCapturePlan.make(mode: mode, previewDuration: duration, previewISO: iso,
                      minDuration: 1.0 / 100000, maxDuration: maximum, minISO: 22, maxISO: 2112))
    }

    func testNightTradesISOForShutterWithoutChangingRequestedExposureProduct() throws {
        let photo = try plan(.photo), night = try plan(.night)
        XCTAssertEqual(photo.config.frameCount, 8)
        XCTAssertEqual(night.config.frameCount, 16)
        XCTAssertEqual(night.duration, 0.5)
        XCTAssertLessThan(night.iso, 32)
        XCTAssertEqual(night.duration * night.iso, photo.duration * photo.iso, accuracy: 1e-10)
        XCTAssertEqual(night.integrationSeconds, 8)
        XCTAssertGreaterThan(night.integrationSeconds / photo.integrationSeconds, 40)
        XCTAssertTrue(night.config.usesRobustMerge)
    }

    func testExplicitLongExposureUsesAllSamplesAndKeepsPreviewExposureProduct() throws {
        let long = try plan(.longExposure)
        XCTAssertFalse(long.config.usesRobustMerge)
        XCTAssertEqual(long.integrationSeconds, 8)
        XCTAssertEqual(long.duration * long.iso, 640.0 / 30, accuracy: 1e-10)
    }

    func testBrightSceneDoesNotForceHalfSecondAndClipHighlights() throws {
        let night = try plan(.night, duration: 0.001, iso: 32)
        XCTAssertLessThan(night.duration, 0.002)
        XCTAssertEqual(night.iso, 22, accuracy: 1e-10)
        XCTAssertEqual(night.duration * night.iso, 0.001 * 32 * pow(2, -0.5), accuracy: 1e-10)
    }

    func testActiveFormatLimitOverridesHistoricalHalfSecond() throws {
        let night = try plan(.night, maximum: 0.125)
        XCTAssertEqual(night.duration, 0.125)
        XCTAssertGreaterThan(night.iso, 100)
        XCTAssertEqual(night.integrationSeconds, 2)
        XCTAssertGreaterThan(night.timeoutSeconds, night.integrationSeconds + 2)
    }

    func testPhotoPolicyAndSixteenFrameRawBudget() throws {
        let photo = try plan(.photo)
        XCTAssertEqual(photo.duration, pow(2, -0.5) / 30, accuracy: 1e-10)
        XCTAssertEqual(photo.iso, 640)
        let bytes = 4032 * 3024 * 2 * (try plan(.night)).config.frameCount
        XCTAssertEqual(bytes, 390_168_576)
        // This is retained RAW payload only, not a measured resident peak.
        XCTAssertLessThan(bytes, 512 * 1024 * 1024)
    }

    func testInvalidOrOverflowingDeviceLimitsRejectCapturePlan() {
        XCTAssertNil(BurstCapturePlan.make(mode: .night, previewDuration: .nan, previewISO: 640,
                     minDuration: 0.001, maxDuration: 0.5, minISO: 22, maxISO: 2112))
        XCTAssertNil(BurstCapturePlan.make(mode: .night, previewDuration: 1, previewISO: 640,
                     minDuration: 0.6, maxDuration: 0.5, minISO: 22, maxISO: 2112))
        XCTAssertNil(BurstCapturePlan.make(mode: .night, previewDuration: 1e308, previewISO: 1e308,
                     minDuration: 0.001, maxDuration: 0.5, minISO: 22, maxISO: 2112))
    }

    func testNightBracketReservesFourShortFramesWithoutChangingOtherModes() throws {
        var night = try plan(.night)
        XCTAssertEqual(night.integrationSeconds, 8)
        night.bracketsHighlights = true
        XCTAssertEqual(night.shortIndices, [3, 7, 11, 15])
        XCTAssertEqual(night.duration(for: 3), 0.03125)
        XCTAssertEqual(night.integrationSeconds, 6.125)
        XCTAssertFalse(night.shortIndices.contains(0))
        var long = try plan(.longExposure); long.bracketsHighlights = true
        XCTAssertEqual(long.shortIndices, [])
        XCTAssertEqual(long.integrationSeconds, 8)
    }
}
