import Foundation

/// Opt-in capture evidence. No uploads; files stay in the app's Documents folder.
enum BurstDiagnostics {
    static func saveProcessing(_ result: BurstProcessResult, directory: URL, noiseProfile: [Double]?) throws {
        var report: [String: Any] = [
            "schema_version": 1,
            "elapsed_processing_seconds": result.elapsedSeconds,
            "stage_seconds": result.stageSeconds,
            "exposure_meter": result.exposureMeter,
            "noise_metadata_available": noiseProfile?.count == 2,
            "shifts": result.shifts.map { ["dx": $0.dx, "dy": $0.dy] },
            "limitations": "Timing excludes RAW export and photo-library save. No peak-memory or image-quality measurement."
        ]
        if let noiseProfile { report["noise_profile"] = noiseProfile }
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: directory.appendingPathComponent("processing.json"), options: .atomic)
    }

    static func save(frames: [BurstFrame], referenceDNG: Data?, rotation: Int,
                     neutral: [Double]?, transform: [Double]?, config: BurstConfig,
                     plan: BurstCapturePlan?, exposureReadings: [[String: Double]], preview: BurstPreviewSample?,
                     frameHashes: [String], duplicateRejections: Int, frameBudget: [String: Double]) throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory,
                                                   in: .userDomainMask, appropriateFor: nil, create: true)
        let storage = BurstDiagnosticStorage(documents: documents)
        let expected = frames.reduce(Int64(0)) { $0 + Int64($1.data.count) }
            + Int64(referenceDNG?.count ?? 0) + Int64(preview?.rgba.count ?? 0) + 2 * 1024 * 1024
        let directory = try storage.beginExport(expectedBytes: expected)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        var entries: [[String: Any]] = []
        for (index, frame) in frames.enumerated() {
            let name = String(format: "frame-%02d.raw16", index)
            try frame.data.write(to: directory.appendingPathComponent(name), options: .atomic)
            var entry: [String: Any] = ["file": name, "width": frame.width, "height": frame.height,
                                       "bytes_per_row": frame.bytesPerRow, "byte_count": frame.data.count]
            if frameHashes.indices.contains(index) { entry["pixel_sha256"] = frameHashes[index] }
            entries.append(entry)
        }
        if let referenceDNG {
            try referenceDNG.write(to: directory.appendingPathComponent("reference.dng"), options: .atomic)
        }
        var manifest: [String: Any] = [
            "schema_version": 5,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "pixel_format": "rgg4", "storage": "little-endian UInt16, row stride included",
            "black_level_assumed": 2112, "white_level_assumed": 16383,
            "rotation_degrees_clockwise": rotation,
            "reference_dng_available": referenceDNG != nil,
            "frames": entries,
            "capture_mode": config.mode.rawValue,
            "merge": config.usesRobustMerge ? "reference_anchored_spectral" : "aligned_equal_weight_average",
            "requested_frame_count": config.frameCount,
            "actual_exposures": exposureReadings,
            "adaptive_frame_budget": frameBudget,
            "unique_pixel_frames": Set(frameHashes).count,
            "repeated_or_stale_raw_rejections": duplicateRejections,
            "limitations": "Fixed sensor levels are historical assumptions; no measured quality claim."
        ]
        if let neutral { manifest["as_shot_neutral"] = neutral }
        if let transform { manifest["camera_to_linear_srgb"] = transform }
        if let preview {
            // Same bytes and luminances used by rendering; opt-in, local only.
            try preview.rgba.write(to: directory.appendingPathComponent("preview.rgba8"), options: .atomic)
            manifest["preview_reference"] = ["width": preview.reference.width, "height": preview.reference.height,
                "luminances": preview.reference.luminances, "file": "preview.rgba8",
                "encoding": "SDR sRGB RGBA8, unrotated video proxy; not a screen screenshot"] as [String: Any]
        }
        if let plan {
            manifest["capture_plan"] = ["duration_seconds": plan.duration, "iso": plan.iso,
                                        "integration_seconds": plan.integrationSeconds,
                                        "timeout_seconds": plan.timeoutSeconds]
            manifest["highlight_frame_indices"] = plan.shortIndices
            manifest["planned_frame_durations"] = (0..<config.frameCount).map { plan.duration(for: $0) }
        }
        if exposureReadings.count == frames.count,
           exposureReadings.allSatisfy({ $0["duration_seconds"] != nil }) {
            manifest["unique_frame_exposure_sum_seconds"] = exposureReadings.reduce(0.0) { $0 + ($1["duration_seconds"] ?? 0) }
        }
        if let first = exposureReadings.first?["photo_timestamp_seconds"],
           let last = exposureReadings.last?["photo_timestamp_seconds"] {
            manifest["accepted_photo_timestamp_span_seconds"] = last - first
        }
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        // A manifest is written last, so interrupted exports are identifiable.
        try json.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        try storage.finishExport(directory)
        complete = true
        return directory
    }
}
