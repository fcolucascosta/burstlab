import Foundation

/// Edge-aware local rendering intent from the video proxy. The proxy supplies
/// low-frequency brightness, never RGB pixels or full-resolution image detail.
public struct BurstPreviewSpatialTone {
    public let correlation: Double
    public let medianCorrectionEV: Double
    private let width: Int
    private let height: Int
    private let slopes: [Double]
    private let intercepts: [Double]

    public init?(luminances: [Double], width: Int, height: Int, reference: BurstPreviewReference) {
        guard width >= 4, height >= 4, width <= 1024, height <= 1024,
              luminances.count == width * height,
              luminances.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 64 }),
              abs(Double(width) / Double(height) - Double(reference.width) / Double(max(reference.height, 1))) < 0.015,
              let assessment = BurstPreviewTone(rendered: luminances.map { min($0, 1) }, width: width, height: height,
                                                 reference: reference), assessment.usesContrastCurve else { return nil }
        self.width = width; self.height = height
        correlation = assessment.correlation; medianCorrectionEV = assessment.medianCorrectionEV
        let guide = luminances.map { log(max($0, 1e-5)) }
        var delta = [Double](repeating: 0, count: guide.count)
        for y in 0..<height {
            for x in 0..<width {
                let px = (Double(x) + 0.5) * Double(reference.width) / Double(width) - 0.5
                let py = (Double(y) + 0.5) * Double(reference.height) / Double(height) - 0.5
                let target = Self.interpolate(reference.luminances, width: reference.width, height: reference.height, x: px, y: py)
                let desired = target * exp2(0.15 * pow(1 - target, 2))
                delta[y * width + x] = log(max(desired, 1e-5)) - guide[y * width + x]
            }
        }
        // Guided filter on log exposure correction. Local output slope stays
        // positive and bounded: do not invert contrast or strongly amplify noise.
        let mean = Self.box(guide, width, height), meanDelta = Self.box(delta, width, height)
        let squares = Self.box(guide.map { $0 * $0 }, width, height)
        let product = Self.box(guide.indices.map { guide[$0] * delta[$0] }, width, height)
        let a = guide.indices.map { i -> Double in
            let variance = max(squares[i] - mean[i] * mean[i], 0)
            return min(max((product[i] - mean[i] * meanDelta[i]) / (variance + 0.04), -0.75), 0.5)
        }
        let b = guide.indices.map { meanDelta[$0] - a[$0] * mean[$0] }
        slopes = Self.box(a, width, height)
        intercepts = Self.box(b, width, height)
    }

    public func luminance(_ value: Double, x: Double, y: Double) -> Double {
        guard value.isFinite, value > 0, x.isFinite, y.isFinite else { return 0 }
        let a = Self.interpolate(slopes, width: width, height: height, x: x, y: y)
        let b = Self.interpolate(intercepts, width: width, height: height, x: x, y: y)
        let logGain = min(max(a * log(max(value, 1e-5)) + b, -log(64)), log(4))
        let output = value * exp(logGain)
        // Most proxy values need no shoulder. Roll off only the top 5% and
        // out-of-proxy highlights rather than compressing clouds a second time.
        let excess = max(output - 0.95, 0)
        return output <= 0.95 ? output : 0.95 + 0.05 * excess / (excess + 0.05)
    }

    private static func interpolate(_ values: [Double], width: Int, height: Int, x: Double, y: Double) -> Double {
        let xx = min(max(x, 0), Double(width - 1)), yy = min(max(y, 0), Double(height - 1))
        let x0 = Int(xx), y0 = Int(yy), x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = xx - Double(x0), fy = yy - Double(y0)
        let top = values[y0 * width + x0] * (1 - fx) + values[y0 * width + x1] * fx
        let bottom = values[y1 * width + x0] * (1 - fx) + values[y1 * width + x1] * fx
        return top * (1 - fy) + bottom * fy
    }

    private static func box(_ values: [Double], _ width: Int, _ height: Int) -> [Double] {
        let stride = width + 1
        var integral = [Double](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var sum = 0.0
            for x in 0..<width { sum += values[y * width + x]; integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + sum }
        }
        var result = values
        for y in 0..<height {
            let y0 = max(0, y - 8), y1 = min(height, y + 9)
            for x in 0..<width {
                let x0 = max(0, x - 8), x1 = min(width, x + 9)
                let sum = integral[y1 * stride + x1] - integral[y0 * stride + x1]
                    - integral[y1 * stride + x0] + integral[y0 * stride + x0]
                result[y * width + x] = sum / Double((y1 - y0) * (x1 - x0))
            }
        }
        return result
    }
}
