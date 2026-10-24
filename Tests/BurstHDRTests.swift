import XCTest
@testable import BurstCore
#if canImport(Accelerate)
final class BurstHDRTests: XCTestCase {
    private func recover(_ long: [UInt16], _ short: [UInt16], dx: Int = 0) throws -> [UInt32] {
        var out = [UInt32](repeating: 0, count: 16)
        try long.withUnsafeBufferPointer { l in try short.withUnsafeBufferPointer { s in
            try out.withUnsafeMutableBufferPointer {
                _ = try BurstHDR.fill(long: l, short: s, width: 4, height: 4, shortOffset: .init(dx: dx, dy: 0), ratio: 16,
                    noiseProfile: [0.0000333465826225, 0.000000455325349284], output: $0)
            }
        } }
        return out
    }

    func testRealExposureProductsDetermineRatioAndInvalidReadbackFailsClosed() throws {
        let shorts = [3, 7, 11, 15]
        let products = (0..<16).map { shorts.contains($0) ? 1.0 : 16.0 }
        XCTAssertEqual(try BurstHDR.ratio(products: products, shortIndices: shorts), 16)
        var bad = products; bad[0] = .nan
        XCTAssertThrowsError(try BurstHDR.ratio(products: bad, shortIndices: shorts))
        bad = products; bad[1] = 12
        XCTAssertThrowsError(try BurstHDR.ratio(products: bad, shortIndices: shorts))
        XCTAssertThrowsError(try BurstHDR.ratio(products: products, shortIndices: [0, 3, 7, 11]))
        XCTAssertThrowsError(try BurstHDR.ratio(products: products, shortIndices: [3, 3, 7, 11]))
    }

    func testShortFrameRecoversRadianceAboveSensorWhiteWithSharedCFAWeight() throws {
        let truth = [120000, 10000, 10000, 4000] // R, G, G, B signals, pedestal excluded.
        let values = (0..<16).map { i -> Int in truth[(i / 4 % 2) * 2 + i % 2] }
        let long = values.map { UInt16(2112 + min($0, 14271)) }
        let short = values.map { UInt16(2112 + ($0 + 8) / 16) }
        let output = try recover(long, short)
        for i in output.indices { XCTAssertEqual(Double(output[i]), Double(2112 + values[i]), accuracy: 8) }
        XCTAssertGreaterThan(output[0], 65535)
    }

    func testShadowsUseLongBurstExactlyAndMovingHighlightDoesNotDisappear() throws {
        let shadows = [UInt16](repeating: 2400, count: 16)
        let noisyShort = (0..<16).map { UInt16(2112 + $0 * 2) }
        XCTAssertEqual(try recover(shadows, noisyShort), shadows.map { UInt32($0) })
        let moving = [UInt16](repeating: 16000, count: 16)
        XCTAssertEqual(try recover(moving, [UInt16](repeating: 2112, count: 16)), moving.map { UInt32($0) })
    }

    func testUncoveredEdgeFallsBackToLongAndInvalidGeometryIsRejected() throws {
        let long = [UInt16](repeating: 16383, count: 16), short = [UInt16](repeating: 4112, count: 16)
        let result = try recover(long, short, dx: 2)
        for y in 0..<4 { for x in 2..<4 { XCTAssertEqual(result[y * 4 + x], 16383) } }
        XCTAssertThrowsError(try recover(long, short, dx: 1))
        XCTAssertThrowsError(try recover(long, short, dx: Int.min))
    }

    func testHighlightMeterSamplesEveryBayerPhase() {
        var values = [UInt16](repeating: 2112, count: 32 * 32)
        values[33] = 16383 // Blue phase; a red-only sample grid would miss it.
        let frame = BurstRawFrame(width: 32, height: 32, bytesPerRow: 64, data: values.withUnsafeBytes { Data($0) })
        XCTAssertGreaterThan(BurstHDR.highlightFraction(frame), 0)
    }
}
#endif
