import CoreImage
import Foundation
import ImageIO

/// On-demand research reference from a single original DNG, not the burst.
/// Selects only a decoder explicitly reported by the OS for this file.
enum BurstAppleRAWReference {
    enum Failure: LocalizedError {
        case missingDNG, unsupportedDNG, renderFailed
        var errorDescription: String? {
            switch self {
            case .missingDNG: return "Nenhum ensaio com DNG guardado. Ative Guardar RAWs e fotografe primeiro."
            case .unsupportedDNG: return "O sistema nao conseguiu abrir este DNG."
            case .renderFailed: return "A revelacao Apple nao produziu uma imagem."
            }
        }
    }
    struct Result { let jpeg: Data; let report: [String: Any] }

    static func latestDirectory(in documents: URL) throws -> URL {
        let root = documents.appendingPathComponent("Ensaios", isDirectory: true)
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let candidates: [(String, URL)] = folders.compactMap { url in
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("reference.dng").path),
                  let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let created = manifest["created_at"] as? String else { return nil }
            return (created, url)
        }
        guard let latest = candidates.max(by: { $0.0 < $1.0 }) else { throw Failure.missingDNG }
        return latest.1
    }

    static func render(directory: URL) throws -> Result {
        try autoreleasepool {
            let started = CFAbsoluteTimeGetCurrent()
            let url = directory.appendingPathComponent("reference.dng")
            guard let raw = CIRAWFilter(imageURL: url) else { throw Failure.unsupportedDNG }
            let initial = raw.decoderVersion.rawValue
            let versions = raw.supportedDecoderVersions
            // Apple documents this list in reverse chronological order. Using
            // a returned value also works with a newer OS than the build SDK.
            if let newest = versions.first { raw.decoderVersion = newest }
            raw.scaleFactor = 0.5
            raw.extendedDynamicRangeAmount = 0
            guard let output = raw.outputImage else { throw Failure.renderFailed }
            let context = CIContext(options: [.cacheIntermediates: false])
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let options: [CIImageRepresentationOption: Any] = [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95]
            guard let jpeg = context.jpegRepresentation(of: output, colorSpace: space, options: options) else {
                throw Failure.renderFailed
            }
            let report: [String: Any] = [
                "schema_version": 1, "source": "reference.dng", "source_frame_count": 1,
                "decoder_initial": initial, "supported_decoders": versions.map { $0.rawValue },
                "decoder_effective": raw.decoderVersion.rawValue,
                "scale_factor": raw.scaleFactor, "output_width": Int(output.extent.width),
                "output_height": Int(output.extent.height), "output": "apple-raw-reference.jpg",
                "exposure": raw.exposure, "baseline_exposure": raw.baselineExposure,
                "luminance_noise_reduction": raw.luminanceNoiseReductionAmount,
                "sharpness": raw.sharpnessAmount, "boost": raw.boostAmount,
                "elapsed_seconds": CFAbsoluteTimeGetCurrent() - started,
                "limitations": "Single original RAW at half dimensions; no burst merge. Public CIRAWFilter, not Camera app Smart HDR/Deep Fusion. Decoder availability does not prove Neural Engine use or image-quality improvement."
            ]
            try jpeg.write(to: directory.appendingPathComponent("apple-raw-reference.jpg"), options: .atomic)
            let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: directory.appendingPathComponent("apple-raw-reference.json"), options: .atomic)
            return Result(jpeg: jpeg, report: report)
        }
    }
}
