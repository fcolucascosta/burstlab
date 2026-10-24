import XCTest
@testable import BurstCore

final class BurstDiagnosticStorageTests: XCTestCase {
    func testMigrationRetainsOnlyNewestCompleteAndUnexpiredExport() throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: documents) }
        let storage = BurstDiagnosticStorage(documents: documents), now = Date()
        func capture(age: TimeInterval, complete: Bool = true) throws -> URL {
            let url = storage.root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 100).write(to: url.appendingPathComponent("frame-00.raw16"))
            if complete {
                let data = try JSONSerialization.data(withJSONObject: ["created_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(-age))])
                try data.write(to: url.appendingPathComponent("manifest.json"))
            }
            return url
        }
        let old = try capture(age: 30), latest = try capture(age: 10)
        let expired = try capture(age: 90000), interrupted = try capture(age: 0, complete: false)
        let photos = documents.appendingPathComponent("MyPhoto.jpg")
        try Data([42]).write(to: photos)
        try storage.prune(now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: latest.path))
        for url in [old, expired, interrupted] { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        XCTAssertEqual(try Data(contentsOf: photos), Data([42]))
        try storage.prune(now: now.addingTimeInterval(90000))
        XCTAssertEqual(try storage.usageBytes(), 0)
    }

    func testCleanupLeavesUnmanagedFoldersAndSymlinkTargetsAlone() throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: documents) }
        let storage = BurstDiagnosticStorage(documents: documents)
        let unrelated = storage.root.appendingPathComponent("Minhas fotos")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let photo = unrelated.appendingPathComponent("photo.jpg")
        try Data([42]).write(to: photo)
        let link = storage.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
        try storage.prune(); try storage.removeAll()
        XCTAssertEqual(try Data(contentsOf: photo), Data([42]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testOversizedExportRejectedBeforeReplacingExistingEvidence() throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: documents) }
        let storage = BurstDiagnosticStorage(documents: documents)
        let directory = try storage.beginExport(expectedBytes: 100)
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("frame-00.raw16"))
        XCTAssertThrowsError(try storage.beginExport(expectedBytes: BurstDiagnosticStorage.limitBytes + 1))
        XCTAssertEqual(try storage.usageBytes(), 3)
        let replacement = try storage.beginExport(expectedBytes: 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
        try storage.finishExport(replacement)
    }

    func testSymlinkRootCannotRedirectCleanup() throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: documents) }
        let storage = BurstDiagnosticStorage(documents: documents)
        let target = documents.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: storage.root, withDestinationURL: target)
        XCTAssertThrowsError(try storage.removeAll())
        XCTAssertThrowsError(try storage.beginExport(expectedBytes: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }
}
