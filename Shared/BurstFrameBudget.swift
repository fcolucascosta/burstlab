import Foundation

/// Quality-biased first-RAW policy. The SNR target is an initial calibration,
/// not a quality guarantee: registration/rejection reduces effective samples.
public enum BurstFrameBudget {
    public struct Decision {
        public let frames: Int
        public let signal: Double
        public let sigma: Double
        public let usedNoiseModel: Bool
    }
    public static func select(signal: Double, noiseProfile: [Double]?, bytesPerFrame: Int) -> Decision {
        // Reserve space for the reference DNG and manifest inside the RAW cap.
        let payloadBudget = Int(BurstDiagnosticStorage.limitBytes) - 32 * 1024 * 1024
        let possible = bytesPerFrame > 0 ? payloadBudget / bytesPerFrame : 1
        let cap = max(1, min(20, possible) / 4 * 4)
        let minimum = min(12, cap)
        guard signal.isFinite, signal >= 0, let noiseProfile, noiseProfile.count == 2,
              noiseProfile.allSatisfy({ $0.isFinite && $0 >= 0 }), noiseProfile[0] + noiseProfile[1] > 0 else {
            return Decision(frames: min(16, cap), signal: 0, sigma: 0, usedNoiseModel: false)
        }
        let bounded = min(signal, 14271)
        let variance = (noiseProfile[0] * bounded / 14271 + noiseProfile[1]) * 14271 * 14271
        guard variance.isFinite else {
            return Decision(frames: min(16, cap), signal: bounded, sigma: 0, usedNoiseModel: false)
        }
        let sigma = sqrt(variance)
        let needed = pow(25 * sigma / max(bounded, 1), 2)
        let chosen = needed >= Double(cap) ? cap : max(minimum, Int(ceil(needed / 4)) * 4)
        return Decision(frames: chosen, signal: bounded, sigma: sigma, usedNoiseModel: true)
    }
}
