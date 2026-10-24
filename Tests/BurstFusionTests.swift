import XCTest
@testable import BurstCore
#if canImport(Accelerate)
final class BurstFusionTests: XCTestCase {
    func testResidualNoiseFinishPreservesDCAndStrongFineTexture() throws {
        let constant = [Float](repeating: 2400, count: 256)
        let flat = try BurstFusion.mergePatch(reference: constant, alternates: [constant], variance: 144, spatialFactor: 1)
        for value in flat { XCTAssertEqual(value, 2400, accuracy: 0.01) }
        let texture = (0..<256).map { i in Float(2400 + ((i % 16) % 2 == 0 ? 200 : -200)) }
        let finished = try BurstFusion.mergePatch(reference: texture, alternates: [texture], variance: 144, spatialFactor: 1)
        for i in texture.indices { XCTAssertEqual(finished[i], texture[i], accuracy: 1) }
    }

    func testResidualNoiseFinishReducesStaticNoiseBeyondTemporalMerge() throws {
        var state: UInt64 = 20261024
        var frames: [[Float]] = []
        for _ in 0..<12 {
            frames.append((0..<256).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return 2400 + Float((state >> 32) & 65535) / 65535 * 80 - 40
            })
        }
        let temporal = try BurstFusion.mergePatch(reference: frames[0], alternates: Array(frames.dropFirst()), variance: 533.33)
        let finished = try BurstFusion.mergePatch(reference: frames[0], alternates: Array(frames.dropFirst()), variance: 533.33, spatialFactor: 1)
        func mse(_ values: [Float]) -> Float { values.reduce(0) { $0 + ($1 - 2400) * ($1 - 2400) } / 256 }
        XCTAssertLessThan(mse(finished), mse(temporal) * 0.7)
        XCTAssertEqual(finished.reduce(0, +) / 256, temporal.reduce(0, +) / 256, accuracy: 0.01)
    }

    func testResidualFinishDoesNotTurnRejectedMotionIntoGhosts() throws {
        let reference = [Float](repeating: 2400, count: 256), alternate = [Float](repeating: 10000, count: 256)
        let result = try BurstFusion.mergePatch(reference: reference, alternates: [alternate, alternate, alternate],
                                               variance: 64, spatialFactor: 1)
        for value in result { XCTAssertEqual(value, 2400, accuracy: 1) }
    }

    func testFFTTwoDimensionalRoundTripPreservesEverySample() throws {
        let input: [Float] = (0..<256).map { Float(($0 * 37) % 71) + 2000 }
        let result = try BurstFusion.mergePatch(reference: input, alternates: [], variance: 64)
        for i in input.indices { XCTAssertEqual(result[i], input[i], accuracy: 0.005) }
    }

    func testMatchesPublishedFrequencyOperatorGoldenFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "spectral-patch", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reference = try XCTUnwrap(fixture["reference"] as? [Double]).map { Float($0) }
        let alternates = try XCTUnwrap(fixture["alternates"] as? [[Double]]).map { $0.map { Float($0) } }
        let expected = try XCTUnwrap(fixture["expected"] as? [Double])
        let result = try BurstFusion.mergePatch(reference: reference, alternates: alternates, variance: 64, debiasNoise: false)
        for i in expected.indices { XCTAssertEqual(Double(result[i]), expected[i], accuracy: 0.01) }
    }

    func testDisagreeingMovingContentFallsBackTowardReference() throws {
        let reference = [Float](repeating: 2400, count: 256)
        let alternate = [Float](repeating: 10000, count: 256)
        let result = try BurstFusion.mergePatch(reference: reference,
                                                alternates: [alternate, alternate, alternate], variance: 64)
        // An arithmetic mean would be 8100, forming a very strong ghost.
        for value in result { XCTAssertEqual(value, 2400, accuracy: 1) }
    }

    func testStaticNoisyPatchReducesErrorWithoutSpatialBlur() throws {
        let truth: [Float] = (0..<256).map { Float(($0 * 7) % 29) * 4 + 2400 }
        var samples: [[Float]] = []
        var state: UInt64 = 20261022
        for _ in 0..<8 {
            samples.append((0..<256).map { i in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let noise = Float((state >> 32) & 65535) / 65535 * 60 - 30
                return truth[i] + noise
            })
        }
        let result = try BurstFusion.mergePatch(reference: samples[0], alternates: Array(samples.dropFirst()), variance: 310)
        let before = zip(samples[0], truth).reduce(Float(0)) { $0 + pow($1.0 - $1.1, 2) }
        let after = zip(result, truth).reduce(Float(0)) { $0 + pow($1.0 - $1.1, 2) }
        XCTAssertLessThan(after, before * 0.5)
    }

    func testFullBayerOverlapAndPaddedStridePreserveIdenticalFrames() throws {
        let width = 48, height = 40, stride = width * 2 + 8
        var data = Data(count: stride * height)
        var expected = [UInt16](repeating: 0, count: width * height)
        data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for y in 0..<height {
                for x in 0..<width {
                    let value = UInt16(2200 + (y & 1) * 300 + (x & 1) * 800 + (x + y) % 37)
                    expected[y * width + x] = value
                    bytes.storeBytes(of: value, toByteOffset: y * stride + x * 2, as: UInt16.self)
                }
            }
        }
        let frame = BurstRawFrame(width: width, height: height, bytesPerRow: stride, data: data)
        var result = [UInt16](repeating: 0, count: width * height)
        try result.withUnsafeMutableBufferPointer { output in
            try BurstFusion.fill(frames: [frame, frame], offsets: [.init(dx: 0, dy: 0), .init(dx: 0, dy: 0)], output: output)
        }
        XCTAssertEqual(result, expected)
    }

    func testRejectsMalformedPatchAndNonFiniteVariance() {
        XCTAssertThrowsError(try BurstFusion.mergePatch(reference: [1], alternates: [], variance: 64))
        XCTAssertThrowsError(try BurstFusion.mergePatch(reference: [Float](repeating: 1, count: 256), alternates: [], variance: .nan))
    }

    func testNoiseDebiasedOperatorMatchesIndependentFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "debiased-patch", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let reference = try XCTUnwrap(fixture["reference"] as? [Double]).map { Float($0) }
        let alternates = try XCTUnwrap(fixture["alternates"] as? [[Double]]).map { $0.map { Float($0) } }
        let expected = try XCTUnwrap(fixture["expected"] as? [Double])
        let result = try BurstFusion.mergePatch(reference: reference, alternates: alternates, variance: 64)
        for i in expected.indices { XCTAssertEqual(Double(result[i]), expected[i], accuracy: 0.01) }
    }

    func testNoiseFloorCorrectionImprovesStaticNoiseAndPreservesTexture() throws {
        let truth: [Float] = (0..<256).map { i in 2600 + 100 * sin(Float(i % 16) * .pi / 4) }
        var state: UInt64 = 20261023
        var beforeError: Float = 0, afterError: Float = 0
        var amplitude: Float = 0, amplitudeCount: Float = 0
        for _ in 0..<32 {
            let samples: [[Float]] = (0..<8).map { _ in truth.map { value in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return value + Float((state >> 32) & 65535) / 65535 * 120 - 60
            } }
            let old = try BurstFusion.mergePatch(reference: samples[0], alternates: Array(samples.dropFirst()), variance: 1200, debiasNoise: false)
            let new = try BurstFusion.mergePatch(reference: samples[0], alternates: Array(samples.dropFirst()), variance: 1200)
            for i in truth.indices {
                beforeError += pow(old[i] - truth[i], 2); afterError += pow(new[i] - truth[i], 2)
                let signal = truth[i] - 2600
                amplitude += (new[i] - 2600) * signal; amplitudeCount += signal * signal
            }
        }
        XCTAssertLessThan(afterError, beforeError * 0.9)
        XCTAssertEqual(amplitude / amplitudeCount, 1, accuracy: 0.02)
    }
}
#endif
