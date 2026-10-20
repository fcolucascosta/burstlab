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
            return BurstConfig(mode: .photo, frameCount: 8, underExposureEV: -0.5)
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

public enum BurstGeometry {
    public static func rotateRGB(
        pixels: [UInt8],
        width: Int,
        height: Int,
        angleDegrees: Int
    ) -> (pixels: [UInt8], width: Int, height: Int) {
        precondition(width > 0 && height > 0, "dimensoes invalidas")
        precondition(pixels.count == width * height * 3, "buffer RGB de tamanho inesperado")
        let angle = ((angleDegrees % 360) + 360) % 360
        if angle == 0 || angle % 90 != 0 {
            return (pixels, width, height)
        }
        if angle == 180 {
            var out = [UInt8](repeating: 0, count: pixels.count)
            for y in 0..<height {
                let srcRow = (height - 1 - y) * width
                let dstRow = y * width
                for x in 0..<width {
                    let src = (srcRow + (width - 1 - x)) * 3
                    let dst = (dstRow + x) * 3
                    out[dst] = pixels[src]
                    out[dst + 1] = pixels[src + 1]
                    out[dst + 2] = pixels[src + 2]
                }
            }
            return (out, width, height)
        }
        let newWidth = height
        let newHeight = width
        var out = [UInt8](repeating: 0, count: pixels.count)
        for y in 0..<newHeight {
            for x in 0..<newWidth {
                let sx: Int
                let sy: Int
                if angle == 90 {
                    sx = y
                    sy = newWidth - 1 - x
                } else {
                    sx = newHeight - 1 - y
                    sy = x
                }
                let src = (sy * width + sx) * 3
                let dst = (y * newWidth + x) * 3
                out[dst] = pixels[src]
                out[dst + 1] = pixels[src + 1]
                out[dst + 2] = pixels[src + 2]
            }
        }
        return (out, newWidth, newHeight)
    }
}

public enum BurstColorMatrix {
    /// Normalizes a DNG color matrix so that the given camera neutral maps to pure white.
    public static func calibratedForNeutral(matrix: [Double], neutral: [Double]) -> [Double]? {
        guard matrix.count == 9, neutral.count == 3, neutral.allSatisfy({ $0 > 0 }) else {
            return nil
        }
        var result = matrix
        for row in 0..<3 {
            let dot = result[row * 3] * neutral[0]
                + result[row * 3 + 1] * neutral[1]
                + result[row * 3 + 2] * neutral[2]
            guard abs(dot) > 1e-6 else { return nil }
            result[row * 3] /= dot
            result[row * 3 + 1] /= dot
            result[row * 3 + 2] /= dot
        }
        return result
    }
}
