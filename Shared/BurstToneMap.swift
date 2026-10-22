import Foundation

/// Bounded local shadow lift in linear light, followed by a smooth shoulder and
/// luminance-preserving gamut compression. Output is SDR linear sRGB.
public struct BurstToneMap {
    public enum Failure: Error { case invalidThumbnail }
    public let width: Int
    public let height: Int
    public let compression: Double
    let logGains: [Double]

    public init(luminances: [Double], width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= Int.max / height,
              luminances.count == width * height,
              luminances.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw Failure.invalidThumbnail
        }
        self.width = width; self.height = height
        let logs = luminances.map { log(max($0, 1e-5)) }
        let mean = Self.boxMean(logs, width: width, height: height, radius: 8)
        let squareMean = Self.boxMean(logs.map { $0 * $0 }, width: width, height: height, radius: 8)
        let a = logs.indices.map { i -> Double in
            let variance = max(squareMean[i] - mean[i] * mean[i], 0)
            return variance / (variance + 0.04)
        }
        let b = logs.indices.map { mean[$0] * (1 - a[$0]) }
        let meanA = Self.boxMean(a, width: width, height: height, radius: 8)
        let meanB = Self.boxMean(b, width: width, height: height, radius: 8)
        let base = logs.indices.map { meanA[$0] * logs[$0] + meanB[$0] }
        let sorted = base.sorted()
        func percentile(_ p: Double) -> Double {
            let position = Double(sorted.count - 1) * p
            let lo = Int(position), hi = min(lo + 1, sorted.count - 1)
            return sorted[lo] + (sorted[hi] - sorted[lo]) * (position - Double(lo))
        }
        let amount = min(1, 5.5 * log(2) / max(percentile(0.99) - percentile(0.01), 1e-5))
        compression = amount
        // At most one stop of lift; bright regions are not darkened by the map.
        logGains = base.map { min(max((amount - 1) * ($0 - log(0.18)), 0), log(2)) }
    }

    /// Coordinates are in thumbnail space; callers map sensor block centers here.
    public func gain(x: Double, y: Double) -> Double {
        guard x.isFinite, y.isFinite else { return 1 }
        let xx = min(max(x, 0), Double(width - 1))
        let yy = min(max(y, 0), Double(height - 1))
        let x0 = Int(xx), y0 = Int(yy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = xx - Double(x0), fy = yy - Double(y0)
        let top = logGains[y0 * width + x0] * (1 - fx) + logGains[y0 * width + x1] * fx
        let bottom = logGains[y1 * width + x0] * (1 - fx) + logGains[y1 * width + x1] * fx
        return exp(top * (1 - fy) + bottom * fy)
    }

    public static func render(red: Double, green: Double, blue: Double, gain: Double) -> (Double, Double, Double) {
        guard red.isFinite, green.isFinite, blue.isFinite, gain.isFinite else { return (0, 0, 0) }
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        guard luminance > 1e-5 else { return (0, 0, 0) }
        let lifted = luminance * min(max(gain, 1), 2)
        let output = lifted <= 0.65 ? lifted : 0.65 + 0.35 * (1 - exp(-(lifted - 0.65) / 0.35))
        let scale = output / luminance
        // Gamut compression here; perceptual chroma follows denoising later.
        let dr = red * scale - output
        let dg = green * scale - output
        let db = blue * scale - output
        var saturation = 1.0
        for delta in [dr, dg, db] {
            if delta > 1e-8 { saturation = min(saturation, (1 - output) / delta) }
            if delta < -1e-8 { saturation = min(saturation, -output / delta) }
        }
        saturation = max(saturation, 0)
        return (min(max(output + dr * saturation, 0), 1),
                min(max(output + dg * saturation, 0), 1),
                min(max(output + db * saturation, 0), 1))
    }

    private static func boxMean(_ input: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        let stride = width + 1
        var integral = [Double](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var rowSum = 0.0
            for x in 0..<width {
                rowSum += input[y * width + x]
                integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + rowSum
            }
        }
        var result = [Double](repeating: 0, count: input.count)
        for y in 0..<height {
            let y0 = max(y - radius, 0), y1 = min(y + radius + 1, height)
            for x in 0..<width {
                let x0 = max(x - radius, 0), x1 = min(x + radius + 1, width)
                let sum = integral[y1 * stride + x1] - integral[y0 * stride + x1]
                    - integral[y1 * stride + x0] + integral[y0 * stride + x0]
                result[y * width + x] = sum / Double((y1 - y0) * (x1 - x0))
            }
        }
        return result
    }
}
