import XCTest
@testable import BurstCore
#if canImport(Accelerate)
final class BurstLongExposureTests: XCTestCase {
    private func frame(_ values: [UInt16], padding: Int = 4) -> BurstRawFrame {
        let width = 4, stride = width * 2 + padding
        var data = Data(count: stride * 4)
        data.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) in
            for y in 0..<4 { for x in 0..<4 { b.storeBytes(of: values[y * 4 + x], toByteOffset: y * stride + x * 2, as: UInt16.self) } }
        }
        return BurstRawFrame(width: 4, height: 4, bytesPerRow: stride, data: data)
    }

    func testMovingContentContributesToExplicitLongExposure() throws {
        let base = [UInt16](repeating: 2400, count: 16)
        var moved = base; moved[4] = 10000
        var output = [UInt16](repeating: 0, count: 16)
        try output.withUnsafeMutableBufferPointer {
            try BurstFusion.fillAverage(frames: [frame(base), frame(moved)], offsets: [.init(dx: 0, dy: 0), .init(dx: 0, dy: 0)], output: $0)
        }
        XCTAssertEqual(output[4], 6200)
        for i in 0..<16 where i != 4 { XCTAssertEqual(output[i], 2400) }
    }

    func testSixteenFullScaleFramesDoNotOverflowAndBlackIsNotMultiplied() throws {
        for value in [UInt16(2112), UInt16.max] {
            let input = frame([UInt16](repeating: value, count: 16))
            var output = [UInt16](repeating: 0, count: 16)
            try output.withUnsafeMutableBufferPointer {
                try BurstFusion.fillAverage(frames: Array(repeating: input, count: 16),
                    offsets: Array(repeating: .init(dx: 0, dy: 0), count: 16), output: $0)
            }
            XCTAssertEqual(output, [UInt16](repeating: value, count: 16))
        }
    }

    func testEvenOffsetAndPaddedStrideUseReferenceAtUncoveredEdges() throws {
        let values: [UInt16] = (0..<16).map { UInt16(2200 + $0 * 10) }
        let input = frame(values)
        var output = [UInt16](repeating: 0, count: 16)
        try output.withUnsafeMutableBufferPointer {
            try BurstFusion.fillAverage(frames: [input, input], offsets: [.init(dx: 0, dy: 0), .init(dx: 2, dy: 0)], output: $0)
        }
        for y in 0..<4 { for x in 0..<4 {
            XCTAssertEqual(output[y * 4 + x], x < 2 ? values[y * 4 + x] + 10 : values[y * 4 + x])
        } }
    }

    func testLongExposureRejectsOddOffsets() {
        let input = frame([UInt16](repeating: 2400, count: 16))
        var output = [UInt16](repeating: 0, count: 16)
        XCTAssertThrowsError(try output.withUnsafeMutableBufferPointer {
            try BurstFusion.fillAverage(frames: [input, input], offsets: [.init(dx: 0, dy: 0), .init(dx: 1, dy: 0)], output: $0)
        })
    }
}
#endif
