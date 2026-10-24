import Foundation
import CryptoKit

/// Reuses a saved Photo burst for a same-input, on-device rendering comparison.
/// Original RAWs/reports and the photo library are not modified.
enum BurstStoredPhotoReplay {
    enum Failure: LocalizedError {
        case invalidInput
        var errorDescription: String? { "Ensaio Foto incompleto ou invalido. Guarde os RAWs de uma foto primeiro." }
    }
    static func run(directory: URL) throws -> Data {
        let source = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: source) as? [String: Any],
              manifest["capture_mode"] as? String == CaptureMode.photo.rawValue,
              let entries = manifest["frames"] as? [[String: Any]], (1...20).contains(entries.count),
              let exposures = manifest["actual_exposures"] as? [[String: Double]], exposures.count == entries.count,
              let rotation = manifest["rotation_degrees_clockwise"] as? Int, [0, 90, 180, 270].contains(rotation)
        else { throw Failure.invalidInput }
        var frames: [BurstFrame] = [], bytes = 0
        var freshness = BurstFrameFreshness()
        for (i, entry) in entries.enumerated() {
            let name = String(format: "frame-%02d.raw16", i)
            guard entry["file"] as? String == name,
                  let width = entry["width"] as? Int, let height = entry["height"] as? Int,
                  let stride = entry["bytes_per_row"] as? Int, let count = entry["byte_count"] as? Int,
                  width == 4032, height == 3024,
                  BurstRawLayout.isValid(width: width, height: height, bytesPerRow: stride, byteCount: count),
                  count <= Int(BurstDiagnosticStorage.limitBytes) - bytes,
                  let expected = entry["pixel_sha256"] as? String,
                  let timestamp = exposures[i]["photo_timestamp_seconds"] else { throw Failure.invalidInput }
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            guard data.count == count else { throw Failure.invalidInput }
            bytes += count
            let frame = BurstFrame(width: width, height: height, bytesPerRow: stride, data: data)
            guard try freshness.accept(frame, timestamp: timestamp), freshness.hashes.last == expected else { throw Failure.invalidInput }
            frames.append(frame)
        }
        let reportData = try Data(contentsOf: directory.appendingPathComponent("processing.json"))
        let original = try JSONSerialization.jsonObject(with: reportData) as? [String: Any]
        let noise = original?["noise_profile"] as? [Double]
        var preview: BurstPreviewReference?
        if let p = manifest["preview_reference"] as? [String: Any], let width = p["width"] as? Int,
           let height = p["height"] as? Int, let values = p["luminances"] as? [Double] {
            preview = BurstPreviewReference(luminances: values, width: width, height: height)
        }
        let result = try BurstProcessor.process(frames: frames, underExposureEV: -0.5, rotationAngle: rotation,
            asShotNeutral: manifest["as_shot_neutral"] as? [Double],
            colorTransform: manifest["camera_to_linear_srgb"] as? [Double], noiseProfile: noise,
            previewReference: preview, refinesPhotoDetail: true)
        let output = directory.appendingPathComponent("replay-current", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try result.jpegData.write(to: output.appendingPathComponent("photo.jpg"), options: .atomic)
        try BurstDiagnostics.saveProcessing(result, directory: output, noiseProfile: noise)
        let report: [String: Any] = [
            "source_app_version": manifest["app_version"] as? String ?? "unknown",
            "replayed_with_app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "source_manifest_sha256": SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined(),
            "frame_pixel_hashes_verified": freshness.hashes,
            "output_jpeg_sha256": SHA256.hash(data: result.jpegData).map { String(format: "%02x", $0) }.joined(),
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "limitations": "Same saved Photo RAWs and preview, new processing. No new exposures; not saved to photo library."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("replay.json"), options: .atomic)
        return result.jpegData
    }
}
