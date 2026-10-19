import AVFoundation
import Foundation
import UIKit

struct BurstFrame {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: Data
}

struct BurstProcessResult {
    let jpegData: Data
    let width: Int
    let height: Int
    let frameCount: Int
    let shifts: [(dx: Int, dy: Int)]
    let whiteGain: Float
    let exposureScale: Float
    let elapsedSeconds: Double
}

enum BurstProcessor {
    static let blackLevel: Float = 2112
    static let whiteLevel: Float = 16383
    static let usefullRange: Float = whiteLevel - blackLevel

    struct Shift {
        let dx: Int
        let dy: Int
    }

    enum BurstError: LocalizedError {
        case noFrames
        case invalidDimensions
        case lockedBuffer
        case jpegEncoding

        var errorDescription: String? {
            switch self {
            case .noFrames: return "nenhum frame capturado"
            case .invalidDimensions: return "dimensoes invalidas"
            case .lockedBuffer: return "buffer RAW inacessivel"
            case .jpegEncoding: return "falha ao gerar JPEG"
            }
        }
    }

    static func process(frames: [BurstFrame], underExposureEV: Double) throws -> BurstProcessResult {
        guard let reference = frames.first else { throw BurstError.noFrames }
        let width = reference.width
        let height = reference.height
        guard width > 1, height > 1 else { throw BurstError.invalidDimensions }

        let started = CFAbsoluteTimeGetCurrent()
        let pixelCount = width * height

        let sums = UnsafeMutablePointer<UInt32>.allocate(capacity: pixelCount)
        sums.initialize(repeating: 0, count: pixelCount)
        let counts = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        counts.initialize(repeating: 0, count: pixelCount)

        var shifts: [Shift] = []
        shifts.reserveCapacity(frames.count)
        for (index, frame) in frames.enumerated() {
            let shift: Shift
            if index == 0 {
                shift = Shift(dx: 0, dy: 0)
            } else {
                shift = estimateShift(reference: reference, frame: frame)
            }
            shifts.append(shift)
            accumulate(frame: frame, into: sums, counts: counts, width: width, height: height, shift: shift)
        }

        let merged = UnsafeMutablePointer<UInt16>.allocate(capacity: pixelCount)
        for index in 0..<pixelCount {
            let count = UInt32(counts[index])
            if count == 0 {
                merged[index] = UInt16(blackLevel)
            } else {
                merged[index] = UInt16(min(65535, (sums[index] + count / 2) / count))
            }
        }
        sums.deinitialize(count: pixelCount)
        sums.deallocate()
        counts.deinitialize(count: pixelCount)
        counts.deallocate()
        defer {
            merged.deinitialize(count: pixelCount)
            merged.deallocate()
        }

        var phaseSum = [Double](repeating: 0, count: 4)
        var phaseCount = [Int](repeating: 0, count: 4)
        var histogram = [Int](repeating: 0, count: 16384)
        let lowCut = Int(blackLevel) + 64
        let highCut = 16000
        for y in stride(from: 0, to: height - 1, by: 4) {
            let top = y * width
            let bottom = (y + 1) * width
            for x in stride(from: 0, to: width - 1, by: 4) {
                let red = Int(merged[top + x])
                let greenA = Int(merged[top + x + 1])
                let greenB = Int(merged[bottom + x])
                let blue = Int(merged[bottom + x + 1])
                if red > lowCut && red < highCut { phaseSum[0] += Double(red); phaseCount[0] += 1 }
                if greenA > lowCut && greenA < highCut { phaseSum[1] += Double(greenA); phaseCount[1] += 1 }
                if greenB > lowCut && greenB < highCut { phaseSum[2] += Double(greenB); phaseCount[2] += 1 }
                if blue > lowCut && blue < highCut { phaseSum[3] += Double(blue); phaseCount[3] += 1 }
                if greenA >= 0 && greenA <= 16383 { histogram[greenA] += 1 }
                if greenB >= 0 && greenB <= 16383 { histogram[greenB] += 1 }
            }
        }

        let meanRed = phaseCount[0] > 0 ? phaseSum[0] / Double(phaseCount[0]) : Double(blackLevel)
        let meanGreenA = phaseCount[1] > 0 ? phaseSum[1] / Double(phaseCount[1]) : Double(blackLevel)
        let meanGreenB = phaseCount[2] > 0 ? phaseSum[2] / Double(phaseCount[2]) : Double(blackLevel)
        let meanBlue = phaseCount[3] > 0 ? phaseSum[3] / Double(phaseCount[3]) : Double(blackLevel)
        let meanGreen = max((meanGreenA + meanGreenB) / 2, Double(blackLevel) + 1)
        var redGain = Float(meanGreen / max(meanRed, Double(blackLevel) + 1))
        var blueGain = Float(meanGreen / max(meanBlue, Double(blackLevel) + 1))
        redGain = min(max(redGain, 0.5), 2.5)
        blueGain = min(max(blueGain, 0.5), 2.5)

        let greenSamples = histogram.reduce(0, +)
        var medianGreen = Double(blackLevel)
        if greenSamples > 0 {
            let target = greenSamples / 2
            var accumulated = 0
            for value in 0..<16384 {
                accumulated += histogram[value]
                if accumulated >= target {
                    medianGreen = Double(value)
                    break
                }
            }
        }
        let medianNorm = max((medianGreen - Double(blackLevel)) / Double(usefullRange), 0.002)
        let exposureScale = Float(min(max(0.18 / medianNorm, 0.5), 24.0))

        let redLUT = makeLUT(gain: redGain, scale: exposureScale)
        let greenLUT = makeLUT(gain: 1, scale: exposureScale)
        let blueLUT = makeLUT(gain: blueGain, scale: exposureScale)

        let rgbBytes = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount * 3)
        rgbBytes.initialize(repeating: 0, count: pixelCount * 3)
        defer {
            rgbBytes.deinitialize(count: pixelCount * 3)
            rgbBytes.deallocate()
        }

        for y in 0..<height {
            let y0 = y * width
            let yUp = max(y - 1, 0) * width
            let yDown = min(y + 1, height - 1) * width
            let yUp2 = max(y - 2, 0) * width
            let yDown2 = min(y + 2, height - 1) * width
            let evenRow = (y & 1) == 0
            for x in 0..<width {
                let xm2 = x > 1 ? x - 2 : 0
                let xm1 = x > 0 ? x - 1 : 0
                let xp1 = x + 1 < width ? x + 1 : width - 1
                let xp2 = x + 2 < width ? x + 2 : width - 1
                let center = Int(merged[y0 + x])
                let north = Int(merged[yUp + x])
                let south = Int(merged[yDown + x])
                let east = Int(merged[y0 + xp1])
                let west = Int(merged[y0 + xm1])
                let north2 = Int(merged[yUp2 + x])
                let south2 = Int(merged[yDown2 + x])
                let east2 = Int(merged[y0 + xp2])
                let west2 = Int(merged[y0 + xm2])
                let northEast = Int(merged[yUp + xp1])
                let northWest = Int(merged[yUp + xm1])
                let southEast = Int(merged[yDown + xp1])
                let southWest = Int(merged[yDown + xm1])

                var red = 0
                var green = 0
                var blue = 0
                if evenRow && (x & 1) == 0 {
                    red = center
                    green = (4 * center + 2 * (north + south + east + west) - (north2 + south2 + east2 + west2) + 4) / 8
                    blue = (12 * center + 4 * (northEast + northWest + southEast + southWest)
                            - 3 * (north2 + south2 + east2 + west2) + 8) / 16
                } else if evenRow {
                    green = center
                    red = (10 * center + 8 * (east + west) - 2 * (east2 + west2)
                           - 2 * (northEast + northWest + southEast + southWest)
                           + (north2 + south2) + 8) / 16
                    blue = (10 * center + 8 * (north + south) - 2 * (north2 + south2)
                            - 2 * (northEast + northWest + southEast + southWest)
                            + (east2 + west2) + 8) / 16
                } else if (x & 1) == 0 {
                    green = center
                    red = (10 * center + 8 * (north + south) - 2 * (north2 + south2)
                           - 2 * (northEast + northWest + southEast + southWest)
                           + (east2 + west2) + 8) / 16
                    blue = (10 * center + 8 * (east + west) - 2 * (east2 + west2)
                            - 2 * (northEast + northWest + southEast + southWest)
                            + (north2 + south2) + 8) / 16
                } else {
                    blue = center
                    green = (4 * center + 2 * (north + south + east + west) - (north2 + south2 + east2 + west2) + 4) / 8
                    red = (12 * center + 4 * (northEast + northWest + southEast + southWest)
                           - 3 * (north2 + south2 + east2 + west2) + 8) / 16
                }

                let offset = (y0 + x) * 3
                rgbBytes[offset] = redLUT[min(max(red, 0), 65535)]
                rgbBytes[offset + 1] = greenLUT[min(max(green, 0), 65535)]
                rgbBytes[offset + 2] = blueLUT[min(max(blue, 0), 65535)]
            }
        }

        let byteCount = pixelCount * 3
        let rgbData = Data(bytes: rgbBytes, count: byteCount)
        guard let provider = CGDataProvider(data: rgbData as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 24,
                  bytesPerRow: width * 3,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw BurstError.jpegEncoding
        }
        guard let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95) else {
            throw BurstError.jpegEncoding
        }

        return BurstProcessResult(
            jpegData: jpeg,
            width: width,
            height: height,
            frameCount: frames.count,
            shifts: shifts.map { ($0.dx, $0.dy) },
            whiteGain: redGain,
            exposureScale: exposureScale,
            elapsedSeconds: CFAbsoluteTimeGetCurrent() - started
        )
    }

    private static func makeLUT(gain: Float, scale: Float) -> [UInt8] {
        var lut = [UInt8](repeating: 0, count: 65536)
        let invGamma = 1.0 / 2.2
        for value in 0..<65536 {
            let linear = max(0, (Float(value) - blackLevel) / usefullRange * scale * gain)
            let clamped = min(1, linear)
            lut[value] = UInt8((pow(Double(clamped), invGamma) * 255.0).rounded())
        }
        return lut
    }

    private static func estimateShift(reference: BurstFrame, frame: BurstFrame) -> Shift {
        guard let referenceProfiles = profiles(for: reference),
              let frameProfiles = profiles(for: frame) else {
            return Shift(dx: 0, dy: 0)
        }
        let dy = bestShift(referenceProfiles.rows, frameProfiles.rows, maxShift: 64)
        let dx = bestShift(referenceProfiles.columns, frameProfiles.columns, maxShift: 64)
        return Shift(dx: (dx / 2) * 2, dy: (dy / 2) * 2)
    }

    private static func profiles(for frame: BurstFrame) -> (rows: [Float], columns: [Float])? {
        let width = frame.width
        let height = frame.height
        let rowBytes = frame.bytesPerRow
        guard rowBytes >= width * 2 else { return nil }
        return frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (rows: [Float], columns: [Float])? in
            guard let base = raw.baseAddress else { return nil }

            var rowSums = [UInt64](repeating: 0, count: height)
            var rowCounts = [UInt32](repeating: 0, count: height)
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
                var x = 0
                while x < width {
                    rowSums[y] += UInt64(row[x])
                    rowCounts[y] += 1
                    x += 8
                }
            }

            var columnSums = [UInt64](repeating: 0, count: width)
            var columnCounts = [UInt32](repeating: 0, count: width)
            var x = 0
            while x < width {
                var y = 0
                while y < height {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
                    columnSums[x] += UInt64(row[x])
                    columnCounts[x] += 1
                    y += 8
                }
                x += 8
            }

            let rows = (0..<height).map { Float(rowSums[$0]) / Float(max(rowCounts[$0], 1)) }
            let columns = (0..<width).map { Float(columnSums[$0]) / Float(max(columnCounts[$0], 1)) }
            return (rows, columns)
        }
    }

    private static func bestShift(_ reference: [Float], _ current: [Float], maxShift: Int) -> Int {
        let count = min(reference.count, current.count)
        guard count > maxShift * 4 else { return 0 }
        var best = 0
        var bestScore = Float.greatestFiniteMagnitude
        for shift in -maxShift...maxShift {
            var score: Double = 0
            var samples = 0
            var index = max(0, -shift)
            let end = min(count, count - shift)
            while index < end {
                score += abs(Double(reference[index]) - Double(current[index + shift]))
                samples += 1
                index += 1
            }
            guard samples > count / 2 else { continue }
            let average = score / Double(samples)
            if average < Double(bestScore) {
                bestScore = Float(average)
                best = shift
            }
        }
        return best
    }

    private static func accumulate(
        frame: BurstFrame,
        into sums: UnsafeMutablePointer<UInt32>,
        counts: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        shift: Shift
    ) {
        let rowBytes = frame.bytesPerRow
        guard rowBytes >= width * 2 else { return }
        frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let yStart = max(0, -shift.dy)
            let yEnd = min(height, height - shift.dy)
            let xStart = max(0, -shift.dx)
            let xEnd = min(width, width - shift.dx)
            guard xStart < xEnd, yStart < yEnd else { return }
            for y in yStart..<yEnd {
                let source = base.advanced(by: (y + shift.dy) * rowBytes).assumingMemoryBound(to: UInt16.self)
                let destination = y * width
                var x = xStart
                while x < xEnd {
                    sums[destination + x] += UInt32(source[x + shift.dx])
                    if counts[destination + x] < 255 {
                        counts[destination + x] += 1
                    }
                    x += 1
                }
            }
        }
    }
}
