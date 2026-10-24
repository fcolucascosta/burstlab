import Foundation
#if canImport(Accelerate)
import Accelerate

public struct BurstRawFrame {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let data: Data

    public init(width: Int, height: Int, bytesPerRow: Int, data: Data) {
        self.width = width; self.height = height
        self.bytesPerRow = bytesPerRow; self.data = data
    }
}

public struct BurstOffset {
    public let dx: Int
    public let dy: Int
    public init(dx: Int, dy: Int) { self.dx = dx; self.dy = dy }
}

/// Independent implementation of the pairwise frequency shrinkage described by
/// Hasinoff et al. (2016), with half-overlapped tiles in each Bayer phase.
/// This is not the proprietary GCam implementation. See docs/pipeline-audit.md.
public enum BurstFusion {
    public enum Failure: Error { case invalidFrames, fftSetup }
    public static let patchSize = 16
    public static let temporalFactor: Float = 75

    final class Workspace {
        let setup: FFTSetup
        var real = [Float](repeating: 0, count: 256)
        var imag = [Float](repeating: 0, count: 256)
        var alternateReal = [Float](repeating: 0, count: 256)
        var alternateImag = [Float](repeating: 0, count: 256)
        var sumReal = [Float](repeating: 0, count: 256)
        var sumImag = [Float](repeating: 0, count: 256)
        var referenceWeights = [Float](repeating: 1, count: 256)
        var alternateSquares = [Float](repeating: 0, count: 256)

        init() throws {
            guard let setup = vDSP_create_fftsetup(4, FFTRadix(kFFTRadix2)) else {
                throw Failure.fftSetup
            }
            self.setup = setup
        }
        deinit { vDSP_destroy_fftsetup(setup) }

        func transform(_ re: inout [Float], _ im: inout [Float], inverse: Bool) {
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_fft2d_zip(setup, &split, 1, 16, 4, 4,
                                   FFTDirection(inverse ? FFT_INVERSE : FFT_FORWARD))
                }
            }
        }

        func begin() {
            for i in 0..<256 { imag[i] = 0; referenceWeights[i] = 1; alternateSquares[i] = 0 }
            transform(&real, &imag, inverse: false)
            for i in 0..<256 { sumReal[i] = real[i]; sumImag[i] = imag[i] }
        }

        func add(variance: Float, debiasNoise: Bool = true) {
            for i in 0..<256 { alternateImag[i] = 0 }
            transform(&alternateReal, &alternateImag, inverse: false)
            // N^2 / 4^2 * 2 * temporalFactor, for an unnormalized forward DFT.
            let noisePower = max(variance, 0.000001) * 32 * temporalFactor
            for i in 0..<256 {
                let dr = real[i] - alternateReal[i]
                let di = imag[i] - alternateImag[i]
                // An unnormalized 16x16 DFT gives N*variance noise power.
                // Two independent noisy frames differ by 2*N*variance even
                // when the scene agrees. Remove that expected noise floor
                // before interpreting disagreement as scene motion.
                let noiseDistance = debiasNoise ? max(variance, 0) * 512 : 0
                let distance = max(dr * dr + di * di - noiseDistance, 0)
                let referenceWeight = distance / (distance + noisePower)
                referenceWeights[i] += referenceWeight
                alternateSquares[i] += (1 - referenceWeight) * (1 - referenceWeight)
                sumReal[i] += alternateReal[i] + referenceWeight * dr
                sumImag[i] += alternateImag[i] + referenceWeight * di
            }
        }

        func finish(frameCount: Int, variance: Float = 0, spatialFactor: Float = 0) {
            if spatialFactor > 0 {
                let n = Float(frameCount)
                // The anchor is reused by every rejected alternate. Assuming
                // variance/N here would underestimate noise at motion/edges.
                for i in 1..<256 { // Preserve DC exactly, including black pedestal.
                    let r = sumReal[i] / n, im = sumImag[i] / n
                    let power = r * r + im * im
                    let residual = 256 * variance * (referenceWeights[i] * referenceWeights[i] + alternateSquares[i]) / (n * n)
                    let gain = power / max(power + spatialFactor * residual, 1e-12)
                    sumReal[i] *= gain; sumImag[i] *= gain
                }
            }
            transform(&sumReal, &sumImag, inverse: true)
            let scale = 1 / (Float(frameCount) * 256)
            for i in 0..<256 { sumReal[i] *= scale }
        }
    }

    /// Small deterministic entry point for testing the actual production operator.
    public static func mergePatch(reference: [Float], alternates: [[Float]], variance: Float,
                                  debiasNoise: Bool = true, spatialFactor: Float = 0) throws -> [Float] {
        guard reference.count == 256, reference.allSatisfy({ $0.isFinite }),
              variance.isFinite, variance >= 0, spatialFactor.isFinite, spatialFactor >= 0,
              alternates.allSatisfy({ $0.count == 256 && $0.allSatisfy({ $0.isFinite }) }) else {
            throw Failure.invalidFrames
        }
        let work = try Workspace()
        work.real = reference
        work.begin()
        for alternate in alternates { work.alternateReal = alternate; work.add(variance: variance, debiasNoise: debiasNoise) }
        work.finish(frameCount: alternates.count + 1, variance: variance, spatialFactor: spatialFactor)
        return work.sumReal
    }

    @inline(__always) private static func mirror(_ index: Int, count: Int) -> Int {
        let period = 2 * (count - 1)
        let wrapped = ((index % period) + period) % period
        return wrapped < count ? wrapped : period - wrapped
    }

    // Nested byte scopes keep every Data pointer valid for the entire merge.
    private static func withBuffers<T>(_ frames: [BurstRawFrame], index: Int = 0,
                                       buffers: [UnsafeRawBufferPointer] = [],
                                       body: ([UnsafeRawBufferPointer]) throws -> T) rethrows -> T {
        if index == frames.count { return try body(buffers) }
        return try frames[index].data.withUnsafeBytes { bytes in
            try withBuffers(frames, index: index + 1, buffers: buffers + [bytes], body: body)
        }
    }

    public static func fill(frames: [BurstRawFrame], offsets: [BurstOffset],
                            output: UnsafeMutableBufferPointer<UInt16>,
                            noiseProfile: [Double]? = nil,
                            localFields: [BurstLocalAlignment.Field]? = nil, spatialFactor: Float = 0) throws {
        let reference = try validate(frames: frames, offsets: offsets, outputCount: output.count)
        guard spatialFactor.isFinite, spatialFactor >= 0,
              localFields == nil || localFields?.count == frames.count else { throw Failure.invalidFrames }
        try fillValidated(frames: frames, offsets: offsets, reference: reference, output: output,
                          noiseProfile: noiseProfile, localFields: localFields, spatialFactor: spatialFactor)
    }

    private static func validate(frames: [BurstRawFrame], offsets: [BurstOffset], outputCount: Int) throws -> BurstRawFrame {
        guard let reference = frames.first, frames.count <= 32, offsets.count == frames.count,
              frames.allSatisfy({ $0.width == reference.width && $0.height == reference.height &&
                  BurstRawLayout.isValid(width: $0.width, height: $0.height,
                                         bytesPerRow: $0.bytesPerRow, byteCount: $0.data.count) }),
              outputCount == reference.width * reference.height,
              offsets.first?.dx == 0, offsets.first?.dy == 0,
              offsets.allSatisfy({ $0.dx % 2 == 0 && $0.dy % 2 == 0 && $0.dx >= -64 && $0.dx <= 64 && $0.dy >= -64 && $0.dy <= 64 })
        else { throw Failure.invalidFrames }
        return reference
    }

    /// Normalized accumulation for explicit long-exposure effects. All aligned
    /// frames contribute equally, including moving objects; black pedestal is
    /// retained once by averaging. UInt32 is safe for <=32 UInt16 samples.
    public static func fillAverage(frames: [BurstRawFrame], offsets: [BurstOffset],
                                   output: UnsafeMutableBufferPointer<UInt16>) throws {
        let reference = try validate(frames: frames, offsets: offsets, outputCount: output.count)
        let width = reference.width, height = reference.height
        var sums = [UInt32](repeating: 0, count: width * height)
        withBuffers(frames) { buffers in
            for f in frames.indices {
                let dx = offsets[f].dx, dy = offsets[f].dy
                for y in 0..<height {
                    let sy = y + dy
                    for x in 0..<width {
                        let sx = x + dx
                        let valid = sx >= 0 && sx < width && sy >= 0 && sy < height
                        let frame = valid ? f : 0
                        let yy = valid ? sy : y, xx = valid ? sx : x
                        let value = buffers[frame].loadUnaligned(fromByteOffset: yy * frames[frame].bytesPerRow + xx * 2, as: UInt16.self)
                        sums[y * width + x] += UInt32(value)
                    }
                }
            }
        }
        let count = UInt32(frames.count)
        for i in sums.indices { output[i] = UInt16((sums[i] + count / 2) / count) }
    }

    private static func fillValidated(frames: [BurstRawFrame], offsets: [BurstOffset], reference: BurstRawFrame,
                                      output: UnsafeMutableBufferPointer<UInt16>, noiseProfile: [Double]?,
                                      localFields: [BurstLocalAlignment.Field]?, spatialFactor: Float) throws {
        let width = reference.width, height = reference.height
        let pw = width / 2, ph = height / 2
        let work = try Workspace()
        let window = (0..<16).map { Float(0.5 - 0.5 * cos(2 * Double.pi * (Double($0) + 0.5) / 16)) }
        var sums = [Float](repeating: 0, count: pw * ph)
        var weights = [Float](repeating: 0, count: pw * ph)
        let profile = noiseProfile.flatMap { values -> [Double]? in
            guard values.count == 2, values.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  values[0] + values[1] > 0 else { return nil }
            return values
        }
        withBuffers(frames) { buffers in
            @inline(__always) func sample(_ frame: Int, x: Int, y: Int, local: BurstOffset? = nil) -> Float {
                let offset = local ?? offsets[frame]
                let sx = x + offset.dx, sy = y + offset.dy
                if sx < 0 || sy < 0 || sx >= width || sy >= height {
                    return Float(buffers[0].loadUnaligned(fromByteOffset: y * frames[0].bytesPerRow + x * 2, as: UInt16.self))
                }
                return Float(buffers[frame].loadUnaligned(fromByteOffset: sy * frames[frame].bytesPerRow + sx * 2, as: UInt16.self))
            }
            // Robust global fallback when the capture metadata has no NoiseProfile.
            // Motion/registration can inflate this estimate; that limitation is logged.
            var differences: [Float] = []
            if frames.count > 1 {
                for y in stride(from: 0, to: height, by: max(1, height / 64)) {
                    for x in stride(from: 0, to: width, by: max(1, width / 64)) {
                        differences.append(sample(1, x: x, y: y) - sample(0, x: x, y: y))
                    }
                }
            }
            differences.sort()
            let median = differences.isEmpty ? 0 : differences[differences.count / 2]
            var deviations = differences.map { abs($0 - median) }; deviations.sort()
            let mad = deviations.isEmpty ? 1 : deviations[deviations.count / 2]
            let sigma = max(1, mad / 0.67448975 / sqrt(2))
            let fallbackVariance = sigma * sigma
            for phase in 0..<4 {
                for i in sums.indices { sums[i] = 0; weights[i] = 0 }
                let px = phase & 1, py = phase >> 1
                for ty in stride(from: -8, to: ph, by: 8) {
                    for tx in stride(from: -8, to: pw, by: 8) {
                        var signal: Float = 0
                        for y in 0..<16 {
                            let sy = mirror(ty + y, count: ph) * 2 + py
                            for x in 0..<16 {
                                let sx = mirror(tx + x, count: pw) * 2 + px
                                let value = sample(0, x: sx, y: sy)
                                work.real[y * 16 + x] = value
                                signal += max(0, value - 2112)
                            }
                        }
                        let variance: Float
                        if let profile {
                            let normalized = Double(signal / 256) / 14271
                            variance = Float((profile[0] * normalized + profile[1]) * 14271 * 14271)
                        } else { variance = fallbackVariance }
                        work.begin()
                        for frame in 1..<frames.count {
                            let local = localFields?[frame].offset(x: tx * 2 + 16, y: ty * 2 + 16)
                            for y in 0..<16 {
                                let sy = mirror(ty + y, count: ph) * 2 + py
                                for x in 0..<16 {
                                    let sx = mirror(tx + x, count: pw) * 2 + px
                                    work.alternateReal[y * 16 + x] = sample(frame, x: sx, y: sy, local: local)
                                }
                            }
                            work.add(variance: variance)
                        }
                        work.finish(frameCount: frames.count, variance: variance, spatialFactor: spatialFactor)
                        for y in 0..<16 where ty + y >= 0 && ty + y < ph {
                            for x in 0..<16 where tx + x >= 0 && tx + x < pw {
                                let index = (ty + y) * pw + tx + x
                                let weight = window[y] * window[x]
                                sums[index] += work.sumReal[y * 16 + x] * weight
                                weights[index] += weight
                            }
                        }
                    }
                }
                for y in 0..<ph {
                    for x in 0..<pw {
                        let index = y * pw + x
                        let value = sums[index] / max(weights[index], 0.000001)
                        output[(y * 2 + py) * width + x * 2 + px] = UInt16(min(max(value.rounded(), 0), 65535))
                    }
                }
            }
        }
    }
}
#endif
