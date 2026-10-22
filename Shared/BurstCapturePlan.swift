import Foundation

/// Photo preserves the preview shutter/ISO policy. Explicit tripod modes trade
/// a longer shutter for lower ISO at the same requested exposure product.
public struct BurstCapturePlan {
    public let config: BurstConfig
    public let duration: Double
    public let iso: Double
    public var integrationSeconds: Double { duration * Double(config.frameCount) }
    public var timeoutSeconds: Double { max(15, Double(config.frameCount) * (duration + 2) + 5) }

    public static func make(mode: CaptureMode, previewDuration: Double, previewISO: Double,
                            minDuration: Double, maxDuration: Double, minISO: Double, maxISO: Double) -> Self? {
        let values = [previewDuration, previewISO, minDuration, maxDuration, minISO, maxISO]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }), minDuration <= maxDuration, minISO <= maxISO else { return nil }
        let config = BurstConfig.defaults(for: mode)
        let factor = pow(2, config.underExposureEV)
        let duration: Double, iso: Double
        if mode == .photo {
            duration = min(max(previewDuration * factor, minDuration), maxDuration)
            iso = min(max(previewISO, minISO), maxISO)
        } else {
            let product = previewDuration * previewISO * factor
            guard product.isFinite else { return nil }
            // Historical SE readback: maximum shutter is 0.5 s. Also respect the
            // current active format; do not claim a longer per-frame exposure.
            let longest = min(maxDuration, 0.5)
            guard longest >= minDuration else { return nil }
            duration = min(max(product / minISO, minDuration), longest)
            iso = min(max(product / duration, minISO), maxISO)
        }
        return Self(config: config, duration: duration, iso: iso)
    }
}
