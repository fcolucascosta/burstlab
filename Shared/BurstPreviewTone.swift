import Foundation

/// A small SDR proxy from the live video path, in unrotated sensor coordinates.
/// It supplies rendering intent, never image detail for the full-resolution JPEG.
public struct BurstPreviewReference {
    public let luminances: [Double]
    public let width: Int
    public let height: Int
    public init(luminances: [Double], width: Int, height: Int) {
        self.luminances = luminances; self.width = width; self.height = height
    }
}

/// Monotone luminance calibration against the preview. Comparing coarse spatial
/// structure first prevents an unrelated/stale scene from imposing its histogram.
/// This does not infer whether a dark surface is a shadow or a black material.
public struct BurstPreviewTone {
    public let correlation: Double
    public let medianCorrectionEV: Double
    public var usesContrastCurve: Bool { flatGain == nil }
    private let input: [Double]
    private let output: [Double]
    private let flatGain: Double?

    public init?(rendered: [Double], width: Int, height: Int, reference: BurstPreviewReference) {
        func valid(_ values: [Double], _ w: Int, _ h: Int) -> Bool {
            w >= 4 && h >= 4 && w <= 1024 && h <= 1024 && values.count == w * h &&
                values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
        }
        guard valid(rendered, width, height), valid(reference.luminances, reference.width, reference.height) else { return nil }
        // Video may crop the sensor to a different aspect ratio. Compare only
        // their common centered field, with a fixed landscape orientation.
        let aspect = max(Double(width) / Double(height), Double(reference.width) / Double(reference.height))
        let rows = 18, columns = max(4, Int((Double(rows) * aspect).rounded()))
        let source = Self.grid(rendered, width, height, aspect: aspect, columns: columns, rows: rows)
        let target = Self.grid(reference.luminances, reference.width, reference.height,
                               aspect: aspect, columns: columns, rows: rows)
        let a = source.map { log(max($0, 1e-5)) }, b = target.map { log(max($0, 1e-5)) }
        let am = a.reduce(0, +) / Double(a.count), bm = b.reduce(0, +) / Double(b.count)
        var covariance = 0.0, va = 0.0, vb = 0.0
        for i in a.indices {
            covariance += (a[i] - am) * (b[i] - bm)
            va += pow(a[i] - am, 2); vb += pow(b[i] - bm, 2)
        }
        let sortedSource = source.sorted(), sortedTarget = target.sorted()
        let sourceMedian = sortedSource[sortedSource.count / 2]
        let targetMedian = sortedTarget[sortedTarget.count / 2]
        if va / Double(a.count) <= 0.02 || vb / Double(b.count) <= 0.02 {
            // Two uniform views still constrain brightness, e.g. a black panel.
            // A uniform proxy of a structured scene is not a usable reference.
            guard va / Double(a.count) <= 0.02, vb / Double(b.count) <= 0.02,
                  sourceMedian > 1e-5, targetMedian > 1e-5 else { return nil }
            let gain = targetMedian * exp2(0.15 * pow(1 - targetMedian, 2)) / sourceMedian
            guard gain >= 1.0 / 16, gain <= 4 else { return nil }
            input = []; output = []; flatGain = gain
            correlation = 0; medianCorrectionEV = log2(gain)
            return
        }
        let agreement = covariance / sqrt(va * vb)
        guard agreement >= 0.75 else { return nil }
        correlation = agreement
        func percentile(_ values: [Double], _ p: Double) -> Double {
            let position = p * Double(values.count - 1)
            let lo = Int(position), hi = min(lo + 1, values.count - 1)
            return values[lo] + (values[hi] - values[lo]) * (position - Double(lo))
        }
        // Slightly brighter midtones than the proxy; a black input stays black,
        // and the boost smoothly vanishes at white (no second white clipping).
        func desired(_ y: Double) -> Double { y * exp2(0.15 * pow(1 - y, 2)) }
        let medianGain = desired(percentile(sortedTarget, 0.5)) / max(percentile(sortedSource, 0.5), 1e-5)
        guard medianGain >= 1.0 / 16, medianGain <= 4 else { return nil }
        medianCorrectionEV = log2(medianGain)
        var xs: [Double] = [], ys: [Double] = []
        for p in [0.01, 0.05, 0.15, 0.30, 0.50, 0.70, 0.85, 0.95, 0.99] {
            let x = max(percentile(sortedSource, p), 1e-5)
            let y = max(desired(percentile(sortedTarget, p)), 1e-6)
            // Quantile plateaus must not create duplicate interpolation knots.
            if let last = xs.last, x <= last * 1.02 { continue }
            xs.append(x); ys.append(max(y, ys.last ?? 0))
        }
        guard xs.count >= 3 else { return nil }
        input = xs; output = ys; flatGain = nil
    }

    public func luminance(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        if let flatGain { return min(value * flatGain, 1) }
        let last = input.count - 1
        let mapped: Double
        if value <= input[0] {
            mapped = value * output[0] / input[0]
        } else if value >= input[last] {
            let slope = max((output[last] - output[last - 1]) / (input[last] - input[last - 1]), 1e-4)
            let headroom = max(1 - output[last], 1e-6)
            mapped = output[last] + headroom * (1 - exp(-slope * (value - input[last]) / headroom))
        } else {
            var hi = 1
            while input[hi] < value { hi += 1 }
            let lo = hi - 1
            let fraction = log(value / input[lo]) / log(input[hi] / input[lo])
            mapped = exp(log(output[lo]) * (1 - fraction) + log(output[hi]) * fraction)
        }
        // Bounds are monotone in luminance, including where a curve meets them.
        return min(max(mapped, value / 16), min(value * 4, 1))
    }

    public func apply(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        guard red.isFinite, green.isFinite, blue.isFinite else { return (0, 0, 0) }
        let y = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        guard y.isFinite, y > 1e-8 else { return (0, 0, 0) }
        return BurstToneMap.fitGamut(red: red, green: green, blue: blue, luminance: y, output: luminance(y))
    }

    private static func grid(_ values: [Double], _ width: Int, _ height: Int,
                             aspect: Double, columns: Int, rows: Int) -> [Double] {
        let cropHeight = min(Double(height), Double(width) / aspect)
        let cropWidth = cropHeight * aspect
        let xStart = (Double(width) - cropWidth) / 2, yStart = (Double(height) - cropHeight) / 2
        var result = [Double](repeating: 0, count: columns * rows)
        for y in 0..<rows {
            let y0 = Int(yStart + Double(y) * cropHeight / Double(rows))
            let y1 = min(height, max(y0 + 1, Int(yStart + Double(y + 1) * cropHeight / Double(rows))))
            for x in 0..<columns {
                let x0 = Int(xStart + Double(x) * cropWidth / Double(columns))
                let x1 = min(width, max(x0 + 1, Int(xStart + Double(x + 1) * cropWidth / Double(columns))))
                var sum = 0.0
                for yy in y0..<y1 { for xx in x0..<x1 { sum += values[yy * width + xx] } }
                result[y * columns + x] = sum / Double((y1 - y0) * (x1 - x0))
            }
        }
        return result
    }
}
