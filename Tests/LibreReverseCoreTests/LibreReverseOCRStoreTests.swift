#if os(macOS)
import CSQLCipher
import Foundation
import XCTest
@testable import LibreReverseCore

final class LibreReverseOCRStoreTests: XCTestCase {
    func testAdmissionQueuesOCRAndCommitAtomicallyPersistsSearchMappingAndNodes() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = try LibreReverseLibraryStore.admitFrame(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            imageFileName: "frame.png",
            context: .init(bundleID: "com.example.Editor", windowName: "Draft"),
            configuration: configuration
        )
        XCTAssertEqual(
            try LibreReverseLibraryStore.pendingOCRFrameIDs(configuration: configuration),
            [frame.id]
        )

        let document = OCRDocument(
            text: "front words",
            otherText: "other words",
            nodes: [
                .init(
                    nodeOrder: 0, textOffset: 0, textLength: 5,
                    leftX: 0.1, topY: 0.2, width: 0.3, height: 0.04, windowIndex: 0
                ),
                .init(
                    nodeOrder: 1, textOffset: 11, textLength: 5,
                    leftX: 0.5, topY: 0.6, width: 0.2, height: 0.03, windowIndex: 1
                ),
            ]
        )
        try LibreReverseLibraryStore.commitOCRDocument(
            frameID: frame.id,
            document: document,
            configuration: configuration
        )

        XCTAssertTrue(try LibreReverseLibraryStore.pendingOCRFrameIDs(
            configuration: configuration
        ).isEmpty)
        try withDatabase(configuration) { database in
            XCTAssertEqual(try textRows(database, """
                SELECT sr.text||'|'||sr.otherText||'|'||sr.title
                  FROM searchRanking sr
                  JOIN doc_segment ds ON ds.docid=sr.rowid
                 WHERE ds.frameId=\(frame.id)
            """), ["front words|other words|Draft"])
            XCTAssertEqual(try textRows(database, """
                SELECT offsets(searchOffsets) FROM searchOffsets
                 WHERE searchOffsets MATCH '("words")'
            """), ["0 0 6 5 1 0 6 5"])
            XCTAssertEqual(try scalar(database, "SELECT count(*) FROM search"), 1)
            XCTAssertEqual(try textRows(database, """
                SELECT nodeOrder||'|'||textOffset||'|'||textLength||'|'||windowIndex
                  FROM node WHERE frameId=\(frame.id) ORDER BY nodeOrder
            """), ["0|0|5|0", "1|11|5|1"])
        }
    }

    func testRepeatedCommitReplacesRatherThanDuplicatesDocumentAndNodes() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = try LibreReverseLibraryStore.admitFrame(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            imageFileName: "frame.png",
            context: .init(bundleID: "com.example.Editor", windowName: "Draft"),
            configuration: configuration
        )
        let first = OCRDocument(
            text: "old", otherText: "", nodes: [
                .init(
                    nodeOrder: 0, textOffset: 0, textLength: 3,
                    leftX: 0, topY: 0, width: 1, height: 1, windowIndex: 0
                ),
            ]
        )
        try LibreReverseLibraryStore.commitOCRDocument(
            frameID: frame.id, document: first, configuration: configuration
        )
        let replacement = OCRDocument(text: "new", otherText: "background", nodes: [])
        try LibreReverseLibraryStore.commitOCRDocument(
            frameID: frame.id, document: replacement, configuration: configuration
        )

        try withDatabase(configuration) { database in
            XCTAssertEqual(try scalar(database, "SELECT count(*) FROM searchRanking"), 1)
            XCTAssertEqual(try scalar(database, "SELECT count(*) FROM search"), 1)
            XCTAssertEqual(try scalar(database, "SELECT count(*) FROM searchOffsets"), 1)
            XCTAssertEqual(try scalar(database, "SELECT count(*) FROM doc_segment"), 1)
            XCTAssertEqual(try scalar(database, "SELECT count(*) FROM node"), 0)
            XCTAssertEqual(try textRows(database, "SELECT text||'|'||otherText FROM searchRanking"), [
                "new|background",
            ])
            XCTAssertEqual(try textRows(database, "SELECT text||'|'||otherText FROM searchOffsets"), [
                "new|background",
            ])
        }
    }

    func testMissingCanonicalSegmentRollsBackAndLeavesWorkPending() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try LibreReverseLibraryStore.admitFrame(
            createdAt: date,
            imageFileName: "newer.png",
            context: nil,
            configuration: configuration
        )
        let outOfOrder = try LibreReverseLibraryStore.admitFrame(
            createdAt: date.addingTimeInterval(-10),
            imageFileName: "older.png",
            context: nil,
            configuration: configuration
        )
        XCTAssertNil(outOfOrder.segmentID)

        XCTAssertThrowsError(try LibreReverseLibraryStore.commitOCRDocument(
            frameID: outOfOrder.id,
            document: .init(text: "not committed", otherText: "", nodes: []),
            configuration: configuration
        ))
        XCTAssertTrue(try LibreReverseLibraryStore.pendingOCRFrameIDs(
            configuration: configuration
        ).contains(outOfOrder.id))
        try withDatabase(configuration) { database in
            XCTAssertEqual(try scalar(database, "SELECT count(*) FROM searchRanking"), 0)
            XCTAssertEqual(try scalar(database, "SELECT count(*) FROM doc_segment"), 0)
        }
    }

    private func makeLibrary() throws -> (URL, LibreReverseLibraryConfiguration) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-ocr-store-\(UUID().uuidString)", isDirectory: true)
        let configuration = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media", isDirectory: true)
        )
        try LibreReverseLibraryStore.initialize(configuration)
        return (root, configuration)
    }

    private func withDatabase(
        _ configuration: LibreReverseLibraryConfiguration,
        operation: (OpaquePointer) throws -> Void
    ) throws {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(configuration.databaseURL.path, &raw), SQLITE_OK)
        let database = try XCTUnwrap(raw)
        defer { sqlite3_close(database) }
        let key = try Data(contentsOf: configuration.keyFileURL)
        XCTAssertEqual(key.withUnsafeBytes {
            sqlite3_key(database, $0.baseAddress, Int32($0.count))
        }, SQLITE_OK)
        try operation(database)
    }

    private func scalar(_ database: OpaquePointer, _ sql: String) throws -> Int64 {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &raw, nil), SQLITE_OK)
        let statement = try XCTUnwrap(raw)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return sqlite3_column_int64(statement, 0)
    }

    private func textRows(_ database: OpaquePointer, _ sql: String) throws -> [String] {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &raw, nil), SQLITE_OK)
        let statement = try XCTUnwrap(raw)
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return rows
    }
}
#endif
