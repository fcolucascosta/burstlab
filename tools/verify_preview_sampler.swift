import AVFoundation
import CoreImage
import Foundation

/// Exercises the actual camera sampler without a camera or a display. In
/// particular, a Core Image row inversion would invalidate spatial matching.
@main struct VerifyPreviewSampler {
    static func main() throws {
        var optional: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true,
                          kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 192, 144,
            kCVPixelFormatType_32BGRA, attributes, &optional) == kCVReturnSuccess)
        let buffer = optional!
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey,
            CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<144 { for x in 0..<192 {
            let i = y * stride + x * 4
            bytes[i] = y < 72 ? 0 : 192
            bytes[i + 1] = x < 96 ? 0 : 128
            bytes[i + 2] = y < 72 ? 128 : 0
            bytes[i + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let sample = BurstPreviewSampler().sample(buffer)!
        precondition(sample.reference.width == 96 && sample.reference.height == 72)
        let rgba = [UInt8](sample.rgba)
        func check(_ x: Int, _ y: Int, _ expected: [Int]) {
            let i = (y * 96 + x) * 4
            for c in 0..<4 { precondition(abs(Int(rgba[i + c]) - expected[c]) <= 1, "Preview orientation or channel error") }
        }
        check(10, 10, [128, 0, 0, 255])
        check(80, 10, [128, 128, 0, 255])
        check(10, 60, [0, 0, 192, 255])
        check(80, 60, [0, 128, 192, 255])
        let redLinear = pow((128.0 / 255 + 0.055) / 1.055, 2.4)
        precondition(abs(sample.reference.luminances[10 * 96 + 10] - 0.2126 * redLinear) < 0.001)
        precondition(sample.rgba.count == 96 * 72 * 4)
        print("Production preview sampler: downsampling, row order, RGBA channels and linear sRGB luminance passed.")
    }
}
