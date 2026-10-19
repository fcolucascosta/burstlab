import Foundation

public enum CaptureMode: String, CaseIterable, Sendable {
    case photo
    case night
    case longExposure
}

public struct BurstConfig: Equatable, Sendable {
    public static let frameRange = 1...32

    public var mode: CaptureMode
    public var frameCount: Int
    public var underExposureEV: Double

    public init(mode: CaptureMode, frameCount: Int, underExposureEV: Double) {
        self.mode = mode
        self.frameCount = min(max(frameCount, Self.frameRange.lowerBound), Self.frameRange.upperBound)
        self.underExposureEV = underExposureEV
    }

    public static func defaults(for mode: CaptureMode) -> BurstConfig {
        switch mode {
        case .photo:
            return BurstConfig(mode: .photo, frameCount: 8, underExposureEV: -1.5)
        case .night:
            return BurstConfig(mode: .night, frameCount: 16, underExposureEV: -1.0)
        case .longExposure:
            return BurstConfig(mode: .longExposure, frameCount: 16, underExposureEV: 0)
        }
    }

    public var usesRobustMerge: Bool {
        mode != .longExposure
    }
}

public struct FrameMemoryBudget: Equatable, Sendable {
    public static let bytesPerPixel16Bit = 2

    public var width: Int
    public var height: Int
    public var budgetBytes: Int

    public init(width: Int, height: Int, budgetBytes: Int) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.budgetBytes = max(budgetBytes, 1)
    }

    public var bytesPerFrame: Int {
        width * height * Self.bytesPerPixel16Bit
    }

    public var maxFramesInBudget: Int {
        max(1, budgetBytes / max(bytesPerFrame, 1))
    }
}
