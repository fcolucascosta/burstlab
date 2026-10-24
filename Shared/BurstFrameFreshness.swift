import Foundation
#if canImport(Accelerate) && canImport(CryptoKit)
import CryptoKit

/// A capture callback/EXIF exposure is not proof of a new sensor image.
/// Count only increasing photo timestamps and previously unseen RAW pixels.
public struct BurstFrameFreshness {
    public enum Failure: Error { case invalidFrame, invalidTimestamp }
    private var seen = Set<SHA256.Digest>()
    private var lastTimestamp: Double?
    public private(set) var hashes: [String] = []
    public private(set) var rejectedCount = 0
    public init() {}

    public mutating func accept(_ frame: BurstRawFrame, timestamp: Double) throws -> Bool {
        guard timestamp.isFinite, timestamp >= 0 else { throw Failure.invalidTimestamp }
        guard BurstRawLayout.isValid(width: frame.width, height: frame.height,
            bytesPerRow: frame.bytesPerRow, byteCount: frame.data.count) else { throw Failure.invalidFrame }
        var hasher = SHA256()
        if frame.bytesPerRow == frame.width * 2 {
            // Ignore any storage beyond the image as well as row padding.
            hasher.update(data: frame.data.prefix(frame.bytesPerRow * frame.height))
        } else {
            for y in 0..<frame.height {
                let start = frame.data.startIndex + y * frame.bytesPerRow
                hasher.update(data: frame.data[start..<(start + frame.width * 2)])
            }
        }
        let digest = hasher.finalize()
        guard !seen.contains(digest), lastTimestamp.map({ timestamp > $0 }) ?? true else {
            rejectedCount += 1
            return false
        }
        seen.insert(digest); lastTimestamp = timestamp
        hashes.append(digest.map { String(format: "%02x", $0) }.joined())
        return true
    }

    /// Pace tripod requests by sensor exposure time, not callback throughput.
    /// A second content/timestamp check still rejects cached frames at readback.
    public static func tripodWait(elapsed: Double, previousExposure: Double) -> Double {
        guard elapsed.isFinite, previousExposure.isFinite, previousExposure > 0 else { return 0 }
        return max(previousExposure + 0.05 - max(elapsed, 0), 0)
    }
}
#endif
