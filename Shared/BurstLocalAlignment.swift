import Foundation
#if canImport(Accelerate)

/// Small residual translations on a green-quad guide. Raw sampling stays on the
/// same Bayer phase; this is local registration, not super-resolution.
public enum BurstLocalAlignment {
    public struct Field {
        public let columns: Int
        public let rows: Int
        public let offsets: [BurstOffset]
        public let refinedTiles: Int
        public func offset(x: Int, y: Int) -> BurstOffset {
            let col = min(max(x / 32, 0), columns - 1)
            let row = min(max(y / 32, 0), rows - 1)
            return offsets[row * columns + col]
        }
    }

    public static func estimate(reference: [Float], current: [Float], width: Int, height: Int,
                                seed: BurstOffset, noiseProfile: [Double]) -> Field {
        let columns = max(1, (width + 15) / 16), rows = max(1, (height + 15) / 16)
        var offsets = [BurstOffset](repeating: seed, count: columns * rows)
        guard width >= 16, height >= 16, reference.count == width * height, current.count == reference.count,
              noiseProfile.count == 2, noiseProfile.allSatisfy({ $0.isFinite && $0 >= 0 }),
              noiseProfile[0] + noiseProfile[1] > 0 else {
            return Field(columns: columns, rows: rows, offsets: offsets, refinedTiles: 0)
        }
        let sx = seed.dx / 2, sy = seed.dy / 2
        var refined = 0
        for row in 0..<rows {
            let y0 = row * 16
            for col in 0..<columns {
                let x0 = col * 16
                // Fixed support for every candidate, never replicate a border
                // into an apparently perfect registration match.
                guard x0 + 16 <= width, y0 + 16 <= height,
                      x0 + sx - 3 >= 0, y0 + sy - 3 >= 0,
                      x0 + sx + 18 < width, y0 + sy + 18 < height else { continue }
                var signal: Float = 0
                for y in stride(from: 0, to: 16, by: 2) {
                    for x in stride(from: 0, to: 16, by: 2) { signal += max(reference[(y0 + y) * width + x0 + x], 0) }
                }
                // A guide point averages the two independent green CFA sites.
                let variance = Float((noiseProfile[0] * Double(signal / 64) / 14271 + noiseProfile[1]) * 14271 * 14271 * 0.5)
                func cost(_ dx: Int, _ dy: Int) -> Float {
                    var sum: Float = 0
                    for y in stride(from: 0, to: 16, by: 2) {
                        let a = (y0 + y) * width + x0
                        let b = (y0 + y + sy + dy) * width + x0 + sx + dx
                        for x in stride(from: 0, to: 16, by: 2) {
                            let delta = reference[a + x] - current[b + x]
                            sum += delta * delta
                        }
                    }
                    return sum / 64 + variance * 0.02 * Float(dx * dx + dy * dy)
                }
                let base = cost(0, 0)
                var best = base, bx = 0, by = 0
                for dy in -3...3 {
                    for dx in -3...3 {
                        let candidate = cost(dx, dy)
                        if candidate < best { best = candidate; bx = dx; by = dy }
                    }
                }
                // Do not chase noise in a uniform patch. Poor matches still go
                // through the reference-anchored temporal rejection operator.
                if base - best > variance, best < base * 0.9 {
                    offsets[row * columns + col] = BurstOffset(dx: seed.dx + 2 * bx, dy: seed.dy + 2 * by)
                    refined += 1
                }
            }
        }
        return Field(columns: columns, rows: rows, offsets: offsets, refinedTiles: refined)
    }

    public static func fields(frames: [BurstRawFrame], offsets: [BurstOffset], noiseProfile: [Double]?) -> [Field]? {
        guard let first = frames.first, frames.count == offsets.count,
              let noiseProfile, noiseProfile.count == 2,
              noiseProfile.allSatisfy({ $0.isFinite && $0 >= 0 }), noiseProfile[0] + noiseProfile[1] > 0 else { return nil }
        let width = first.width / 2, height = first.height / 2
        func guide(_ frame: BurstRawFrame) -> [Float] {
            frame.data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                var values = [Float](repeating: 0, count: width * height)
                for y in 0..<height {
                    for x in 0..<width {
                        let a = bytes.loadUnaligned(fromByteOffset: y * 2 * frame.bytesPerRow + (x * 2 + 1) * 2, as: UInt16.self)
                        let b = bytes.loadUnaligned(fromByteOffset: (y * 2 + 1) * frame.bytesPerRow + x * 4, as: UInt16.self)
                        values[y * width + x] = (Float(a) + Float(b)) * 0.5 - 2112
                    }
                }
                return values
            }
        }
        let reference = guide(first)
        return frames.indices.map { i in
            if i == 0 {
                let columns = (width + 15) / 16, rows = (height + 15) / 16
                return Field(columns: columns, rows: rows,
                             offsets: [BurstOffset](repeating: offsets[0], count: columns * rows), refinedTiles: 0)
            }
            return estimate(reference: reference, current: guide(frames[i]), width: width, height: height,
                            seed: offsets[i], noiseProfile: noiseProfile)
        }
    }
}
#endif
