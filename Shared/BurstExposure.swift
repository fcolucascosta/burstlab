import Foundation

/// Scene-wide rendering exposure; does not change sensor shutter speed or ISO.
/// Uses log-average linear sRGB luminance (Reinhard et al.). Absolute gain
/// limits preserve the previous pipeline's range; the median is diagnostic.
public struct BurstExposure {
    public enum Failure: Error { case invalidLuminances }
    public let scale: Double
    public let median: Double
    public let logAverage: Double
    public let adjustmentEV: Double

    public init(luminances: [Double]) throws {
        guard !luminances.isEmpty,
              luminances.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw Failure.invalidLuminances }
        let sorted = luminances.sorted()
        let middle = sorted.count / 2
        let measuredMedian = sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        median = measuredMedian
        // Trim the lowest/highest 1% so a few black pixels or lamps do not meter
        // the entire scene. The floor prevents log(0); it is not a noise model.
        let trim = sorted.count / 100
        let retained = sorted[trim..<(sorted.count - trim)]
        let average = exp(retained.reduce(0.0) { $0 + log(max($1, 1e-4)) } / Double(retained.count))
        logAverage = average
        let medianScale = 0.18 / max(measuredMedian, 0.002)
        let candidate = 0.18 / max(average, 0.002)
        scale = min(max(candidate, 0.5), 24)
        adjustmentEV = log2(scale / min(max(medianScale, 0.5), 24))
    }
}
