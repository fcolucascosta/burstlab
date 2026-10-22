import Foundation

/// Opt-in capture evidence. No uploads; files stay in the app's Documents folder.
enum BurstDiagnostics {
    static func save(frames: [BurstFrame], referenceDNG: Data?, rotation: Int,
                     neutral: [Double]?, transform: [Double]?) throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory,
                                                   in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = documents.appendingPathComponent("Ensaios", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var entries: [[String: Any]] = []
        for (index, frame) in frames.enumerated() {
            let name = String(format: "frame-%02d.raw16", index)
            try frame.data.write(to: directory.appendingPathComponent(name), options: .atomic)
            entries.append(["file": name, "width": frame.width, "height": frame.height,
                            "bytes_per_row": frame.bytesPerRow, "byte_count": frame.data.count])
        }
        if let referenceDNG {
            try referenceDNG.write(to: directory.appendingPathComponent("reference.dng"), options: .atomic)
        }
        var manifest: [String: Any] = [
            "schema_version": 1,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "pixel_format": "rgg4", "storage": "little-endian UInt16, row stride included",
            "black_level_assumed": 2112, "white_level_assumed": 16383,
            "rotation_degrees_clockwise": rotation,
            "reference_dng_available": referenceDNG != nil,
            "frames": entries,
            "limitations": "Fixed sensor levels are historical assumptions; no measured quality claim."
        ]
        if let neutral { manifest["as_shot_neutral"] = neutral }
        if let transform { manifest["camera_to_linear_srgb"] = transform }
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        // A manifest is written last, so interrupted exports are identifiable.
        try json.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        return directory
    }
}
