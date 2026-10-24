import Foundation
#if canImport(Accelerate)

/// Exposure-normalized RAW highlight recovery. The long group supplies shadows;
/// the short group supplies highlights only, with a shared weight per CFA cell.
public enum BurstHDR {
    public enum Failure: LocalizedError {
        case invalidBracket, invalidGeometry
        public var errorDescription: String? {
            switch self {
            case .invalidBracket: return "Exposicoes HDR ausentes ou inconsistentes; nao foi possivel normalizar os RAWs."
            case .invalidGeometry: return "Buffers ou alinhamento HDR invalidos."
            }
        }
    }
    public struct Statistics {
        public var blendedCells = 0
        public var motionRejectedCells = 0
        public var shortClippedCells = 0
    }

    public static func highlightFraction(_ frame: BurstRawFrame) -> Double {
        guard BurstRawLayout.isValid(width: frame.width, height: frame.height,
              bytesPerRow: frame.bytesPerRow, byteCount: frame.data.count) else { return 0 }
        return frame.data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var high = 0, count = 0
            for y in stride(from: 0, to: frame.height - 1, by: 16) {
                for x in stride(from: 0, to: frame.width - 1, by: 16) {
                    for dy in 0...1 { for dx in 0...1 {
                        let value = bytes.loadUnaligned(fromByteOffset: (y + dy) * frame.bytesPerRow + (x + dx) * 2, as: UInt16.self)
                        if value >= 15812 { high += 1 }
                        count += 1
                    } }
                }
            }
            return count > 0 ? Double(high) / Double(count) : 0
        }
    }

    public static func ratio(products: [Double], shortIndices: [Int]) throws -> Double {
        let selected = Set(shortIndices)
        guard products.count >= 6, products.count <= 32, selected.count == shortIndices.count,
              selected.count >= 2, products.count - selected.count >= 4, !selected.contains(0),
              selected.allSatisfy({ products.indices.contains($0) }),
              products.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw Failure.invalidBracket }
        let long = products.indices.filter { !selected.contains($0) }.map { products[$0] }.sorted()
        let short = shortIndices.map { products[$0] }.sorted()
        let l = long[long.count / 2], s = short[short.count / 2]
        let ratio = l / s
        guard ratio.isFinite, ratio >= 2, ratio <= 32,
              long.allSatisfy({ abs($0 / l - 1) <= 0.05 }),
              short.allSatisfy({ abs($0 / s - 1) <= 0.05 }) else { throw Failure.invalidBracket }
        return ratio
    }

    public static func fill(long: UnsafeBufferPointer<UInt16>, short: UnsafeBufferPointer<UInt16>,
                            width: Int, height: Int, shortOffset: BurstOffset, ratio: Double,
                            noiseProfile: [Double]?, output: UnsafeMutableBufferPointer<UInt32>) throws -> Statistics {
        guard width >= 4, height >= 4, width % 2 == 0, height % 2 == 0, width <= Int.max / height,
              long.count == width * height, short.count == long.count, output.count == long.count,
              ratio.isFinite, ratio >= 2, ratio <= 32, shortOffset.dx % 2 == 0, shortOffset.dy % 2 == 0,
              shortOffset.dx >= -64, shortOffset.dx <= 64,
              shortOffset.dy >= -64, shortOffset.dy <= 64 else { throw Failure.invalidGeometry }
        let black = 2112.0, range = 14271.0
        let profile: [Double]
        if let p = noiseProfile, p.count == 2, p.allSatisfy({ $0.isFinite && $0 >= 0 }) { profile = p }
        else { profile = [0, 256 / (range * range)] }
        func variance(_ signal: Double) -> Double {
            max((profile[0] * max(signal, 0) / range + profile[1]) * range * range, 1)
        }
        var stats = Statistics()
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let i = y * width + x
                let sy = y + shortOffset.dy, sx = x + shortOffset.dx
                let indices = SIMD4<Int>(i, i + 1, i + width, i + width + 1)
                guard sx >= 0, sy >= 0, sx + 1 < width, sy + 1 < height else {
                    for c in 0..<4 { output[indices[c]] = UInt32(long[indices[c]]) }
                    continue
                }
                let j = sy * width + sx
                let shortIndices = SIMD4<Int>(j, j + 1, j + width, j + width + 1)
                var l = SIMD4<Double>(repeating: 0), s = l
                for c in 0..<4 {
                    l[c] = Double(long[indices[c]]) - black
                    s[c] = Double(short[shortIndices[c]]) - black
                }
                let peak = max(max(l[0], l[1]), max(l[2], l[3]))
                let shortPeak = max(max(s[0], s[1]), max(s[2], s[3]))
                let t = min(max((peak / range - 0.70) / 0.25, 0), 1)
                var weight = t * t * (3 - 2 * t)
                if weight > 0 {
                    if shortPeak * ratio < 0.65 * peak {
                        // A bright object disappeared between groups: retain the
                        // anchor rather than replacing it with the background.
                        weight = 0; stats.motionRejectedCells += 1
                    } else {
                        var mismatch = 0.0, samples = 0
                        for c in 0..<4 where l[c] > 0.02 * range && l[c] < 0.90 * range {
                            let d = l[c] - s[c] * ratio
                            let tolerance = variance(l[c]) + ratio * ratio * variance(s[c]) + pow(0.1 * l[c], 2)
                            mismatch += d * d / tolerance; samples += 1
                        }
                        if samples > 0 {
                            let agreement = 1 / (1 + max(mismatch / Double(samples) - 4, 0))
                            weight *= agreement
                            if agreement < 0.5 { stats.motionRejectedCells += 1 }
                        }
                    }
                }
                if weight > 0 {
                    stats.blendedCells += 1
                    if shortPeak >= 0.99 * range { stats.shortClippedCells += 1 }
                }
                for c in 0..<4 {
                    let signal = l[c] + weight * (s[c] * ratio - l[c])
                    output[indices[c]] = UInt32(min(max((black + signal).rounded(), 0), Double(UInt32.max)))
                }
            }
        }
        return stats
    }
}
#endif
