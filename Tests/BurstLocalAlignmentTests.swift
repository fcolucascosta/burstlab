import XCTest
@testable import BurstCore
#if canImport(Accelerate)
final class BurstLocalAlignmentTests: XCTestCase {
    func testRecoversDifferentTranslationsInDifferentRegionsWithoutMixingBayerPhases() {
        let w = 128, h = 96
        let reference: [Float] = (0..<(w * h)).map { i in
            let x = Double(i % w), y = Double(i / w)
            return Float(600 + 130 * sin(x * 0.41) + 90 * cos(y * 0.37) + 50 * sin(x * 0.17 + y * 0.23))
        }
        var current = reference
        for y in 4..<(h - 4) { for x in 4..<(w - 4) {
            let dx = x < w / 2 ? 2 : -2, dy = x < w / 2 ? -1 : 1
            current[y * w + x] = reference[(y - dy) * w + x - dx]
        } }
        let field = BurstLocalAlignment.estimate(reference: reference, current: current, width: w, height: h,
                                                seed: .init(dx: 0, dy: 0), noiseProfile: [0, 1e-7])
        let left = field.offset(x: 48, y: 64), right = field.offset(x: 176, y: 64)
        XCTAssertEqual(left.dx, 4); XCTAssertEqual(left.dy, -2)
        XCTAssertEqual(right.dx, -4); XCTAssertEqual(right.dy, 2)
        XCTAssertGreaterThan(field.refinedTiles, 10)
        for offset in field.offsets { XCTAssertEqual(offset.dx % 2, 0); XCTAssertEqual(offset.dy % 2, 0) }
    }

    func testUniformImageDoesNotInventMotionAndMissingNoiseModelKeepsGlobalSeed() {
        let reference = [Float](repeating: 100, count: 64 * 64)
        let field = BurstLocalAlignment.estimate(reference: reference, current: reference, width: 64, height: 64,
                                                seed: .init(dx: 2, dy: -2), noiseProfile: [0, 1e-6])
        XCTAssertEqual(field.refinedTiles, 0)
        XCTAssertTrue(field.offsets.allSatisfy { $0.dx == 2 && $0.dy == -2 })
        let unknown = BurstLocalAlignment.estimate(reference: reference, current: reference, width: 64, height: 64,
                                                  seed: .init(dx: 4, dy: 0), noiseProfile: [])
        XCTAssertTrue(unknown.offsets.allSatisfy { $0.dx == 4 && $0.dy == 0 })
    }

    func testAlreadyRegisteredTextureIsKeptAndEdgesRetainSafeSeed() {
        let input = (0..<4096).map { Float(($0 * 37) % 713 + 2200) }
        let field = BurstLocalAlignment.estimate(reference: input, current: input, width: 64, height: 64,
                                                seed: .init(dx: 0, dy: 0), noiseProfile: [0.00003, 0.00000045])
        XCTAssertEqual(field.refinedTiles, 0)
        XCTAssertTrue(field.offsets.allSatisfy { $0.dx == 0 && $0.dy == 0 })
        XCTAssertEqual(field.offset(x: -100, y: -100).dx, 0)
        XCTAssertEqual(field.offset(x: 10000, y: 10000).dy, 0)
    }
}
#endif
