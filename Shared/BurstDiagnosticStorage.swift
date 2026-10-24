import Foundation

/// Bounded, disposable developer captures. Never traverses or deletes user photos.
/// Call only on the processing queue, including exports and manual cleanup.
public struct BurstDiagnosticStorage {
    public static let limitBytes: Int64 = 512 * 1024 * 1024
    public static let lifetime: TimeInterval = 24 * 60 * 60
    public let root: URL
    private let manager = FileManager.default

    public enum Failure: LocalizedError {
        case unsafeDirectory, tooLarge, insufficientSpace
        public var errorDescription: String? {
            switch self {
            case .unsafeDirectory: return "Pasta de diagnostico invalida."
            case .tooLarge: return "Ensaio excede o limite de 512 MB de diagnostico."
            case .insufficientSpace: return "Espaco insuficiente para guardar o diagnostico. A foto sera processada normalmente."
            }
        }
    }

    public init(documents: URL) { root = documents.appendingPathComponent("Ensaios", isDirectory: true).standardizedFileURL }

    private func directories() throws -> [URL] {
        guard manager.fileExists(atPath: root.path) else { return [] }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.unsafeDirectory }
        return try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).filter { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return UUID(uuidString: url.lastPathComponent) != nil && values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    private func bytes(in directory: URL) throws -> Int64 {
        guard let items = manager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in items {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { items.skipDescendants(); continue }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    public func usageBytes() throws -> Int64 { try directories().reduce(0) { try $0 + bytes(in: $1) } }

    public func removeAll() throws {
        for directory in try directories() { try manager.removeItem(at: directory) }
    }

    /// Keep only the newest complete, unexpired export within the budget.
    /// Old versions' accumulated and interrupted exports are migrated here too.
    public func prune(now: Date = Date()) throws {
        var candidates: [(URL, Date, Int64)] = []
        for directory in try directories() {
            let manifest = directory.appendingPathComponent("manifest.json")
            let date: Date?
            if let data = try? Data(contentsOf: manifest),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let created = json["created_at"] as? String {
                date = ISO8601DateFormatter().date(from: created)
            } else { date = nil }
            let size = try bytes(in: directory)
            if let date, now.timeIntervalSince(date) >= 0, now.timeIntervalSince(date) < Self.lifetime,
               size <= Self.limitBytes { candidates.append((directory, date, size)) }
            else { try manager.removeItem(at: directory) }
        }
        let newest = candidates.max { $0.1 < $1.1 }?.0
        for candidate in candidates where candidate.0 != newest { try manager.removeItem(at: candidate.0) }
    }

    public func beginExport(expectedBytes: Int64) throws -> URL {
        guard expectedBytes > 0, expectedBytes <= Self.limitBytes else { throw Failure.tooLarge }
        // Validate the existing root before either deleting or creating files.
        _ = try directories()
        try removeAll()
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let attributes = try manager.attributesOfFileSystem(forPath: root.path)
        let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free >= expectedBytes + 64 * 1024 * 1024 else { throw Failure.insufficientSpace }
        var excludedRoot = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excludedRoot.setResourceValues(values)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    public func finishExport(_ directory: URL) throws {
        guard directory.deletingLastPathComponent().standardizedFileURL == root,
              UUID(uuidString: directory.lastPathComponent) != nil else { throw Failure.unsafeDirectory }
        guard try bytes(in: directory) <= Self.limitBytes else { throw Failure.tooLarge }
    }
}
