import Foundation

/// The pipeline consumes even-sized, unpacked 16-bit Bayer frames.
public enum BurstRawLayout {
    public static func isValid(width: Int, height: Int, bytesPerRow: Int, byteCount: Int) -> Bool {
        guard width >= 4, height >= 4, width % 2 == 0, height % 2 == 0,
              width <= Int.max / 2, bytesPerRow >= width * 2,
              bytesPerRow % 2 == 0, height <= Int.max / bytesPerRow,
              width <= Int.max / height / 4 else { return false }
        return byteCount >= bytesPerRow * height
    }
}

public enum BurstAlignment {
    /// Search only even offsets: odd offsets mix Bayer color phases.
    /// Prefer zero (then the smallest displacement) when evidence is tied.
    public static func bestShift(_ reference: [Float], _ current: [Float], maxShift: Int) -> Int {
        let count = min(reference.count, current.count)
        guard maxShift >= 0, count > 4, reference.allSatisfy({ $0.isFinite }),
              current.allSatisfy({ $0.isFinite }) else { return 0 }
        let limit = min(maxShift, (count - 1) / 4) / 2 * 2
        var best = 0
        var bestScore = Double.greatestFiniteMagnitude
        for shift in stride(from: -limit, through: limit, by: 2) {
            var score = 0.0
            // Same overlap for every candidate so borders cannot bias the score.
            for index in limit..<(count - limit) {
                score += abs(Double(reference[index]) - Double(current[index + shift]))
            }
            if score < bestScore || (score == bestScore && abs(shift) < abs(best)) {
                bestScore = score
                best = shift
            }
        }
        return best
    }
}

public enum CaptureMode: String, CaseIterable, Sendable {
    case photo
    case night
    case longExposure

    public var title: String {
        switch self {
        case .photo: return "Foto"
        case .night: return "Noite"
        case .longExposure: return "Longa"
        }
    }
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
            return BurstConfig(mode: .photo, frameCount: 12, underExposureEV: -0.5)
        case .night:
            return BurstConfig(mode: .night, frameCount: 16, underExposureEV: -0.5)
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
    private static let bradford: [[Double]] = [
        [0.8951, 0.2664, -0.1614],
        [-0.7502, 1.7135, 0.0367],
        [0.0389, -0.0685, 1.0296]
    ]
    private static let xyzToSRGB: [[Double]] = [
        [3.2404542, -1.5371385, -0.4985314],
        [-0.9692660, 1.8760108, 0.0415560],
        [0.0556434, -0.2040259, 1.0572252]
    ]
    private static let d65White: [Double] = [0.95047, 1.0, 1.08883]
    private static let d50XY = (x: 0.3457, y: 0.3585)

    public static func temperature(forIlluminant illuminant: Int) -> Double? {
        switch illuminant {
        case 17: return 2856
        case 20: return 5503
        case 21: return 6504
        case 22: return 7504
        case 23: return 5003
        case 11: return 4230
        case 15: return 6500
        case 18: return 4000
        default: return nil
        }
    }

    /// Builds the camera to linear sRGB transform following the DNG SDK fallback:
    /// interpolate XYZ-to-camera matrices by CCT, invert, adapt the white to D65.
    public static func cameraToSRGB(
        matrix1: [Double],
        matrix2: [Double],
        neutral: [Double],
        temperature1: Double = 2856,
        temperature2: Double = 6504
    ) -> [Double]? {
        guard matrix1.count == 9, matrix2.count == 9,
              matrix1.allSatisfy({ $0.isFinite }), matrix2.allSatisfy({ $0.isFinite }),
              neutral.count == 3, neutral.allSatisfy({ $0.isFinite && $0 > 0 }),
              temperature1.isFinite, temperature2.isFinite,
              temperature1 > 0, temperature2 > 0,
              temperature1 != temperature2 else {
            return nil
        }
        let first = matrix3x3(from: temperature1 <= temperature2 ? matrix1 : matrix2)
        let second = matrix3x3(from: temperature1 <= temperature2 ? matrix2 : matrix1)
        let lower = min(temperature1, temperature2)
        let upper = max(temperature1, temperature2)

        var white = d50XY
        var matrix = interpolated(first: first, second: second, white: white, lower: lower, upper: upper)
        for _ in 0..<30 {
            guard let inverse = invert(matrix) else { return nil }
            let xyz = multiply(inverse, neutral)
            let sum = xyz[0] + xyz[1] + xyz[2]
            guard sum > 1e-9 else { return nil }
            let next = (x: xyz[0] / sum, y: xyz[1] / sum)
            let delta = abs(next.x - white.x) + abs(next.y - white.y)
            white = next
            if delta < 1e-7 {
                break
            }
            matrix = interpolated(first: first, second: second, white: white, lower: lower, upper: upper)
        }
        matrix = interpolated(first: first, second: second, white: white, lower: lower, upper: upper)
        guard let inverse = invert(matrix) else { return nil }
        let xyzWhite = multiply(inverse, neutral)
        guard xyzWhite[1] > 1e-9 else { return nil }
        let adaptedWhite = [xyzWhite[0] / xyzWhite[1], 1.0, xyzWhite[2] / xyzWhite[1]]
        let adaptation = bradfordAdaptation(from: adaptedWhite, to: d65White)
        let transform = multiply(xyzToSRGB, multiply(adaptation, inverse))
        var result = flatten(transform)
        for row in 0..<3 {
            let dot = result[row * 3] * neutral[0]
                + result[row * 3 + 1] * neutral[1]
                + result[row * 3 + 2] * neutral[2]
            guard abs(dot) > 1e-9 else { return nil }
            result[row * 3] /= dot
            result[row * 3 + 1] /= dot
            result[row * 3 + 2] /= dot
        }
        return result.allSatisfy({ $0.isFinite }) ? result : nil
    }

    private static func interpolated(
        first: [[Double]],
        second: [[Double]],
        white: (x: Double, y: Double),
        lower: Double,
        upper: Double
    ) -> [[Double]] {
        let temperature = correlatedColorTemperature(x: white.x, y: white.y)
        let weight: Double
        if temperature <= lower {
            weight = 1
        } else if temperature >= upper {
            weight = 0
        } else {
            let inverseTemperature = 1.0 / temperature
            weight = (inverseTemperature - 1.0 / upper) / (1.0 / lower - 1.0 / upper)
        }
        var result = [[Double]](repeating: [0, 0, 0], count: 3)
        for row in 0..<3 {
            for column in 0..<3 {
                let firstValue = first[row][column]
                let secondValue = second[row][column]
                result[row][column] = firstValue * weight + secondValue * (1 - weight)
            }
        }
        return result
    }

    private static func correlatedColorTemperature(x: Double, y: Double) -> Double {
        let denominator = 0.1858 - y
        guard abs(denominator) > 1e-6 else { return 5500 }
        let n = (x - 0.3320) / denominator
        let value = 437.0 * n * n * n + 3601.0 * n * n + 6861.0 * n + 5517.0
        return value.isFinite ? value : 5500
    }

    private static func bradfordAdaptation(from source: [Double], to destination: [Double]) -> [[Double]] {
        let sourceCone = multiply(bradford, source)
        let destinationCone = multiply(bradford, destination)
        var scale = [[Double]](repeating: [0, 0, 0], count: 3)
        for index in 0..<3 {
            scale[index][index] = abs(sourceCone[index]) > 1e-9
                ? destinationCone[index] / sourceCone[index]
                : 1
        }
        guard let inverseBradford = invert(bradford) else { return identity }
        return multiply(inverseBradford, multiply(scale, bradford))
    }

    private static var identity: [[Double]] {
        [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    }

    private static func matrix3x3(from values: [Double]) -> [[Double]] {
        [
            [values[0], values[1], values[2]],
            [values[3], values[4], values[5]],
            [values[6], values[7], values[8]]
        ]
    }

    private static func flatten(_ values: [[Double]]) -> [Double] {
        values.flatMap { $0 }
    }

    private static func multiply(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        var result = [[Double]](repeating: [0, 0, 0], count: 3)
        for row in 0..<3 {
            for column in 0..<3 {
                let first = a[row][0] * b[0][column]
                let second = a[row][1] * b[1][column]
                let third = a[row][2] * b[2][column]
                result[row][column] = first + second + third
            }
        }
        return result
    }

    private static func multiply(_ a: [[Double]], _ v: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: 3)
        for row in 0..<3 {
            let first = a[row][0] * v[0]
            let second = a[row][1] * v[1]
            let third = a[row][2] * v[2]
            result[row] = first + second + third
        }
        return result
    }

    private static func invert(_ m: [[Double]]) -> [[Double]]? {
        let a = m[0][0], b = m[0][1], c = m[0][2]
        let d = m[1][0], e = m[1][1], f = m[1][2]
        let g = m[2][0], h = m[2][1], i = m[2][2]
        let ei = e * i, fh = f * h
        let di = d * i, fg = f * g
        let dh = d * h, eg = e * g
        let determinant = a * (ei - fh) - b * (di - fg) + c * (dh - eg)
        guard abs(determinant) > 1e-12 else { return nil }
        let inverse = 1.0 / determinant
        let m00 = (ei - fh) * inverse
        let m01 = (c * h - b * i) * inverse
        let m02 = (b * f - c * e) * inverse
        let m10 = (fg - di) * inverse
        let m11 = (a * i - c * g) * inverse
        let m12 = (c * d - a * f) * inverse
        let m20 = (dh - eg) * inverse
        let m21 = (b * g - a * h) * inverse
        let m22 = (a * e - b * d) * inverse
        return [
            [m00, m01, m02],
            [m10, m11, m12],
            [m20, m21, m22]
        ]
    }
}
