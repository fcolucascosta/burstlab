import AVFoundation
import Foundation
import UIKit

typealias BurstFrame = BurstRawFrame

struct BurstProcessResult {
    let jpegData: Data
    let width: Int
    let height: Int
    let frameCount: Int
    let shifts: [(dx: Int, dy: Int)]
    let whiteGain: Float
    let blueGain: Float
    let exposureScale: Float
    let usedCCM: Bool
    let denoised: Bool
    let elapsedSeconds: Double
}

enum BurstProcessor {
    static let blackLevel: Float = 2112
    static let whiteLevel: Float = 16383
    static let usefullRange: Float = whiteLevel - blackLevel

    typealias Shift = BurstOffset

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

    static func process(
        frames: [BurstFrame],
        underExposureEV: Double,
        rotationAngle: Int = 0,
        asShotNeutral: [Double]? = nil,
        colorTransform: [Double]? = nil,
        noiseProfile: [Double]? = nil
    ) throws -> BurstProcessResult {
        guard let reference = frames.first else { throw BurstError.noFrames }
        let width = reference.width
        let height = reference.height
        guard frames.count <= BurstConfig.frameRange.upperBound,
              BurstRawLayout.isValid(width: width, height: height,
                                     bytesPerRow: reference.bytesPerRow, byteCount: reference.data.count),
              frames.allSatisfy({
                  $0.width == width && $0.height == height &&
                  BurstRawLayout.isValid(width: $0.width, height: $0.height,
                                         bytesPerRow: $0.bytesPerRow, byteCount: $0.data.count)
              }) else { throw BurstError.invalidDimensions }

        let started = CFAbsoluteTimeGetCurrent()
        let pixelCount = width * height

        let shifts = frames.enumerated().map { index, frame in
            index == 0 ? Shift(dx: 0, dy: 0) : estimateShift(reference: reference, frame: frame)
        }
        let merged = UnsafeMutablePointer<UInt16>.allocate(capacity: pixelCount)
        merged.initialize(repeating: 0, count: pixelCount)
        do {
            try BurstFusion.fill(frames: frames, offsets: shifts,
                                 output: UnsafeMutableBufferPointer(start: merged, count: pixelCount),
                                 noiseProfile: noiseProfile)
        } catch {
            merged.deinitialize(count: pixelCount)
            merged.deallocate()
            throw error
        }
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
        var redGain: Float = 1
        var blueGain: Float = 1

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

        var ccm: [Double]? = nil
        if let transform = colorTransform, transform.count == 9, transform.allSatisfy({ $0.isFinite }) {
            ccm = transform
        }
        if ccm == nil {
            if let neutral = asShotNeutral, neutral.count == 3, neutral.allSatisfy({ $0.isFinite && $0 > 0 }) {
                redGain = min(max(Float(neutral[1] / neutral[0]), 0.25), 4.0)
                blueGain = min(max(Float(neutral[1] / neutral[2]), 0.25), 4.0)
            } else {
                redGain = Float((meanGreen - Double(blackLevel)) / max(meanRed - Double(blackLevel), 1))
                blueGain = Float((meanGreen - Double(blackLevel)) / max(meanBlue - Double(blackLevel), 1))
                redGain = min(max(redGain, 0.5), 2.5)
                blueGain = min(max(blueGain, 0.5), 2.5)
            }
        }

        let rangeD = Double(usefullRange)
        let scaleD = Double(exposureScale)
        let blackInt = Int(blackLevel)
        func linearRGB(_ red: Int, _ green: Int, _ blue: Int) -> (Double, Double, Double) {
            let lr = Double(max(red, 0) - blackInt) / rangeD
            let lg = Double(max(green, 0) - blackInt) / rangeD
            let lb = Double(max(blue, 0) - blackInt) / rangeD
            if let cc = ccm {
                return ((cc[0] * lr + cc[1] * lg + cc[2] * lb) * scaleD,
                        (cc[3] * lr + cc[4] * lg + cc[5] * lb) * scaleD,
                        (cc[6] * lr + cc[7] * lg + cc[8] * lb) * scaleD)
            }
            return (lr * Double(redGain) * scaleD, lg * scaleD, lb * Double(blueGain) * scaleD)
        }
        // A 16x16-sensor-pixel thumbnail keeps local adaptation small in memory.
        // Average linear luminance before taking logarithms in BurstToneMap.
        let toneBlock = 16
        let toneWidth = (width + toneBlock - 1) / toneBlock
        let toneHeight = (height + toneBlock - 1) / toneBlock
        var thumbnail = [Double](repeating: 0, count: toneWidth * toneHeight)
        for ty in 0..<toneHeight {
            for tx in 0..<toneWidth {
                var sum = 0.0, count = 0
                for y in stride(from: ty * toneBlock, to: min((ty + 1) * toneBlock, height - 1), by: 2) {
                    for x in stride(from: tx * toneBlock, to: min((tx + 1) * toneBlock, width - 1), by: 2) {
                        let r = Int(merged[y * width + x])
                        let g = (Int(merged[y * width + x + 1]) + Int(merged[(y + 1) * width + x])) / 2
                        let b = Int(merged[(y + 1) * width + x + 1])
                        let rgb = linearRGB(r, g, b)
                        sum += max(0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2, 1e-5)
                        count += 1
                    }
                }
                thumbnail[ty * toneWidth + tx] = count > 0 ? sum / Double(count) : 0
            }
        }
        let tone = try BurstToneMap(luminances: thumbnail, width: toneWidth, height: toneHeight)
        func gammaIndex(_ value: Double) -> Int {
            let clamped = min(max(value, 0), 1)
            return min(Int(clamped * 4096.0), 4096)
        }
        let gammaTable = (0...4096).map { srgbByte(Double($0) / 4096.0) }

        let rgbBytes = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount * 3)
        rgbBytes.initialize(repeating: 0, count: pixelCount * 3)
        defer {
            rgbBytes.deinitialize(count: pixelCount * 3)
            rgbBytes.deallocate()
        }

        for y in 0..<height {
            let y0 = y * width
            // Mirror borders instead of clamping: Bayer phase must stay intact.
            let yUp = (y > 0 ? y - 1 : 1) * width
            let yDown = (y + 1 < height ? y + 1 : height - 2) * width
            let yUp2 = (y > 1 ? y - 2 : 2 - y) * width
            let yDown2 = (y + 2 < height ? y + 2 : 2 * height - 4 - y) * width
            let evenRow = (y & 1) == 0
            for x in 0..<width {
                let xm2 = x > 1 ? x - 2 : 2 - x
                let xm1 = x > 0 ? x - 1 : 1
                let xp1 = x + 1 < width ? x + 1 : width - 2
                let xp2 = x + 2 < width ? x + 2 : 2 * width - 4 - x
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
                let linear = linearRGB(red, green, blue)
                let gain = tone.gain(x: (Double(x) + 0.5) / Double(toneBlock) - 0.5,
                                     y: (Double(y) + 0.5) / Double(toneBlock) - 0.5)
                let rendered = BurstToneMap.render(red: linear.0, green: linear.1, blue: linear.2, gain: gain)
                rgbBytes[offset] = gammaTable[gammaIndex(rendered.0)]
                rgbBytes[offset + 1] = gammaTable[gammaIndex(rendered.1)]
                rgbBytes[offset + 2] = gammaTable[gammaIndex(rendered.2)]
            }
        }

        denoiseInPlace(pixels: rgbBytes, width: width, height: height)

        let byteCount = pixelCount * 3
        let rgbData = Data(bytes: rgbBytes, count: byteCount)
        var outputData = rgbData
        var outputWidth = width
        var outputHeight = height
        if rotationAngle % 360 != 0 {
            let rotated = BurstGeometry.rotateRGB(
                pixels: [UInt8](rgbData),
                width: width,
                height: height,
                angleDegrees: rotationAngle
            )
            outputData = Data(rotated.pixels)
            outputWidth = rotated.width
            outputHeight = rotated.height
        }
        guard let provider = CGDataProvider(data: outputData as CFData),
              let cgImage = CGImage(
                  width: outputWidth,
                  height: outputHeight,
                  bitsPerComponent: 8,
                  bitsPerPixel: 24,
                  bytesPerRow: outputWidth * 3,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
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
            width: outputWidth,
            height: outputHeight,
            frameCount: frames.count,
            shifts: shifts.map { ($0.dx, $0.dy) },
            whiteGain: ccm != nil ? 1.0 : redGain,
            blueGain: ccm != nil ? 1.0 : blueGain,
            exposureScale: exposureScale,
            usedCCM: ccm != nil,
            denoised: true,
            elapsedSeconds: CFAbsoluteTimeGetCurrent() - started
        )
    }

    private static func denoiseInPlace(
        pixels: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        radius: Int = 3
    ) {
        let pixelCount = width * height
        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount * 3)
        source.initialize(from: pixels, count: pixelCount * 3)
        defer {
            source.deinitialize(count: pixelCount * 3)
            source.deallocate()
        }

        let luma = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        luma.initialize(repeating: 0, count: pixelCount)
        defer {
            luma.deinitialize(count: pixelCount)
            luma.deallocate()
        }
        for index in 0..<pixelCount {
            let offset = index * 3
            let value = 0.299 * Float(source[offset])
                + 0.587 * Float(source[offset + 1])
                + 0.114 * Float(source[offset + 2])
            luma[index] = clampByte(value)
        }

        for y in 0..<height {
            let yStart = max(0, y - radius)
            let yEnd = min(height - 1, y + radius)
            for x in 0..<width {
                let centerIndex = y * width + x
                let centerLuma = Float(luma[centerIndex])
                let shadow = 1.0 - min(centerLuma, 110.0) / 110.0
                let threshold = 14.0 + shadow * 20.0
                let xStart = max(0, x - radius)
                let xEnd = min(width - 1, x + radius)
                var chromaRed: Float = 0
                var chromaBlue: Float = 0
                var weightSum: Float = 0
                for neighborY in yStart...yEnd {
                    let row = neighborY * width
                    for neighborX in xStart...xEnd {
                        let neighborIndex = row + neighborX
                        let delta = abs(Float(luma[neighborIndex]) - centerLuma)
                        guard delta < threshold else { continue }
                        let weight = 1.0 - delta / threshold
                        let offset = neighborIndex * 3
                        let neighborLuma = Float(luma[neighborIndex])
                        chromaRed += (Float(source[offset]) - neighborLuma) * weight
                        chromaBlue += (Float(source[offset + 2]) - neighborLuma) * weight
                        weightSum += weight
                    }
                }
                guard weightSum > 0 else { continue }
                // Preserve the merged luminance texture. The spatial filter only
                // averages chroma; temporal merge remains responsible for luma noise.
                let outputLuma = centerLuma
                let outputRed = outputLuma + chromaRed / weightSum
                let outputBlue = outputLuma + chromaBlue / weightSum
                let outputGreen = (outputLuma - 0.299 * outputRed - 0.114 * outputBlue) / 0.587
                let offset = centerIndex * 3
                pixels[offset] = clampByte(outputRed)
                pixels[offset + 1] = clampByte(outputGreen)
                pixels[offset + 2] = clampByte(outputBlue)
            }
        }
    }

    private static func clampByte(_ value: Float) -> UInt8 {
        UInt8(min(max(value.rounded(), 0), 255))
    }

    private static func srgbByte(_ linear: Double) -> UInt8 {
        let clamped = min(max(linear, 0), 1)
        let encoded = clamped <= 0.0031308
            ? 12.92 * clamped
            : 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
        return UInt8((encoded * 255.0).rounded())
    }

    private static func estimateShift(reference: BurstFrame, frame: BurstFrame) -> Shift {
        guard let referenceProfiles = profiles(for: reference),
              let frameProfiles = profiles(for: frame) else {
            return Shift(dx: 0, dy: 0)
        }
        let dy = BurstAlignment.bestShift(referenceProfiles.rows, frameProfiles.rows, maxShift: 64)
        let dx = BurstAlignment.bestShift(referenceProfiles.columns, frameProfiles.columns, maxShift: 64)
        return Shift(dx: dx, dy: dy)
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
                x += 1
            }

            let rows = (0..<height).map { Float(rowSums[$0]) / Float(max(rowCounts[$0], 1)) }
            let columns = (0..<width).map { Float(columnSums[$0]) / Float(max(columnCounts[$0], 1)) }
            return (rows, columns)
        }
    }

}
