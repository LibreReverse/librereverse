#if os(macOS)
import Foundation
import XCTest
@testable import LibreReverseCore

final class VideoStorageTests: XCTestCase {
    func testCalendarPathIsExtensionlessAndUsesFormatters() {
        let date = Date(timeIntervalSince1970: 1_764_791_355)
        XCTAssertEqual(
            VideoStorage.relativePath(
                xid: "d4o98eor8kk07r7hn090",
                date: date
            ),
            "202512/03/d4o98eor8kk07r7hn090"
        )
    }

    func testCanonicalPathValidationRejectsBespokeFlatMP4Names() {
        let xid = "d4o98eor8kk07r7hn090"
        XCTAssertTrue(VideoStorage.isCanonicalRelativePath(
            "202512/03/\(xid)", xid: xid
        ))
        XCTAssertFalse(VideoStorage.isCanonicalRelativePath(
            "2025-12-03T19-30-51Z-uuid.mp4", xid: xid
        ))
        XCTAssertFalse(VideoStorage.isCanonicalRelativePath(
            "202513/03/\(xid)", xid: xid
        ))
        XCTAssertFalse(VideoStorage.isCanonicalRelativePath(
            "202512/03/wrong-xid", xid: xid
        ))
    }

    func testStoreMovesThenRemovesReplacementParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let temporaryItems = root.appendingPathComponent("A")
        let replacement = temporaryItems.appendingPathComponent("B")
        let source = replacement.appendingPathComponent("video.mp4")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: source)

        let destination = try VideoStorage.storeTemporaryVideo(
            at: source,
            relativePath: "202512/03/d4o98eor8kk07r7hn090",
            chunksDirectory: root
        )

        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryItems.path))
        XCTAssertFalse(destination.pathExtension.count > 0)
    }
}
#endif
