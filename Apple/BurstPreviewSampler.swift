import AVFoundation
import CoreImage

struct BurstPreviewSample {
    let reference: BurstPreviewReference
    let rgba: Data
    let timestamp: CFAbsoluteTime
}

/// Uses a preview-sized video output. Retains only one <=96px-wide SDR sample;
/// no video buffers survive the delegate callback and sampling stops in a burst.
final class BurstPreviewSampler {
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func sample(_ buffer: CVPixelBuffer) -> BurstPreviewSample? {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width >= 4, height >= 4, width >= height else { return nil }
        let w = 96, h = max(4, Int(96 * Double(height) / Double(width)))
        let image = CIImage(cvPixelBuffer: buffer).applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: Double(w) / Double(width), kCIInputAspectRatioKey: 1.0])
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: w * 4,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: colorSpace)
        }
        let decode = (0...255).map { i -> Double in
            let x = Double(i) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let luminances = (0..<(w * h)).map { i in
            0.2126 * decode[Int(rgba[4 * i])] + 0.7152 * decode[Int(rgba[4 * i + 1])] + 0.0722 * decode[Int(rgba[4 * i + 2])]
        }
        return BurstPreviewSample(reference: BurstPreviewReference(luminances: luminances, width: w, height: h),
                                  rgba: Data(rgba), timestamp: CFAbsoluteTimeGetCurrent())
    }
}
