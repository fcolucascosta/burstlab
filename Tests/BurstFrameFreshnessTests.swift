import XCTest
@testable import BurstCore
#if canImport(Accelerate) && canImport(CryptoKit)
final class BurstFrameFreshnessTests: XCTestCase {
    private func frame(value: UInt16, padding: UInt16 = 0) -> BurstRawFrame {
        var data = Data()
        for _ in 0..<4 {
            for _ in 0..<4 { var x = value.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
            var pad = padding.littleEndian; withUnsafeBytes(of: &pad) { data.append(contentsOf: $0) }
        }
        return BurstRawFrame(width: 4, height: 4, bytesPerRow: 10, data: data)
    }

    func testSixteenCallbacksWithTwoImagesCountAsTwoExposures() throws {
        var freshness = BurstFrameFreshness()
        var accepted = 0
        for i in 0..<16 {
            if try freshness.accept(frame(value: i < 7 ? 2200 : 2210), timestamp: Double(i)) { accepted += 1 }
        }
        XCTAssertEqual(accepted, 2)
        XCTAssertEqual(freshness.hashes.count, 2)
        XCTAssertEqual(freshness.rejectedCount, 14)
    }

    func testPaddingDoesNotMakeCachedPixelsLookNew() throws {
        var freshness = BurstFrameFreshness()
        XCTAssertTrue(try freshness.accept(frame(value: 2200, padding: 0), timestamp: 1))
        XCTAssertFalse(try freshness.accept(frame(value: 2200, padding: 555), timestamp: 2))
        XCTAssertTrue(try freshness.accept(frame(value: 2201), timestamp: 3))
    }

    func testOldTimestampIsRejectedWithoutConsumingThatNewImage() throws {
        var freshness = BurstFrameFreshness()
        XCTAssertTrue(try freshness.accept(frame(value: 2200), timestamp: 2))
        XCTAssertFalse(try freshness.accept(frame(value: 2201), timestamp: 1))
        XCTAssertTrue(try freshness.accept(frame(value: 2201), timestamp: 3))
        XCTAssertThrowsError(try freshness.accept(frame(value: 2202), timestamp: .nan))
        XCTAssertEqual(Set(freshness.hashes).count, 2)
    }

    func testLongExposureIsNotDrivenByFastCallbacks() {
        XCTAssertEqual(BurstFrameFreshness.tripodWait(elapsed: 0.05, previousExposure: 0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(BurstFrameFreshness.tripodWait(elapsed: 0.6, previousExposure: 0.5), 0)
        XCTAssertEqual(BurstFrameFreshness.tripodWait(elapsed: 0.05, previousExposure: 1.0 / 32), 0.03125, accuracy: 1e-12)
    }
}
#endif
