#if os(macOS)
import CSQLCipher
import Foundation
import XCTest
@testable import LibreReverseCore

final class LibreReverseChatStoreTests: XCTestCase {
    private func library() throws -> (URL, LibreReverseLibraryConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-store-\(UUID().uuidString)")
        let configuration = LibreReverseLibraryConfiguration(databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"), mediaRoot: root.appendingPathComponent("Library/Media"))
        try LibreReverseLibraryStore.initialize(configuration)
        return (root, configuration)
    }
    private func execute(_ sql: String, _ config: LibreReverseLibraryConfiguration) throws {
        let session = LibreReverseLibraryWriteSession(configuration: config); defer { session.close() }
        try session.withDatabase(configuration: config) { db in
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw LibreReverseLibraryStoreError.sqlite("Synthetic SQL failed") }
        }
    }
    func testRoundTripPaginationUpdatesDeletionAndEncryptedBytes() throws {
        let (root, config) = try library(); defer { try? FileManager.default.removeItem(at: root) }
        let firstID = UUID().uuidString, secondID = UUID().uuidString
        let payload = Data(#"{"turns":[{"question":"PRIVATE_CHAT_MARKER_13415","answer":"Saved answer"}]}"#.utf8)
        let first = try LibreReverseChatStore.save(id: firstID.lowercased(), title: "PRIVATE_TITLE_MARKER_7491", payload: payload,
            updatedAt: Date(timeIntervalSince1970: 100), configuration: config)
        _ = try LibreReverseChatStore.save(id: secondID, title: "Other", payload: Data("{}".utf8), updatedAt: Date(timeIntervalSince1970: 150), configuration: config)
        XCTAssertEqual(first.id, firstID)
        XCTAssertEqual(try LibreReverseChatStore.load(id: firstID, configuration: config)?.payload, payload)
        XCTAssertEqual(try LibreReverseChatStore.list(limit: 1, configuration: config).map(\.id), [secondID])
        XCTAssertEqual(try LibreReverseChatStore.list(limit: 1, offset: 1, configuration: config).map(\.id), [firstID])
        let updated = try LibreReverseChatStore.save(id: firstID, title: String(repeating: "👩🏽‍💻", count: 80), payload: payload,
            updatedAt: Date(timeIntervalSince1970: 200), configuration: config)
        XCTAssertEqual(updated.createdAt, first.createdAt)
        XCTAssertEqual(try LibreReverseChatStore.list(configuration: config).first?.id, firstID)
        for suffix in ["", "-wal"] {
            let url = URL(fileURLWithPath: config.databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                let bytes = try Data(contentsOf: url)
                XCTAssertNil(bytes.range(of: Data("PRIVATE_CHAT_MARKER_13415".utf8)))
                XCTAssertNil(bytes.range(of: Data("PRIVATE_TITLE_MARKER_7491".utf8)))
            }
        }
        try LibreReverseChatStore.delete(id: firstID, configuration: config)
        try LibreReverseChatStore.delete(id: firstID, configuration: config)
        XCTAssertNil(try LibreReverseChatStore.load(id: firstID, configuration: config))
        XCTAssertEqual(try LibreReverseChatStore.list(configuration: config).count, 1)
    }
    func testInvalidInputsDoNotReplaceSavedChat() throws {
        let (root, config) = try library(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString, original = Data("{\"saved\":true}".utf8)
        try LibreReverseChatStore.save(id: id, title: "Valid", payload: original, configuration: config)
        for invalid in [Data(), Data("not JSON".utf8), Data(repeating: 32, count: LibreReverseChatStore.maximumPayloadBytes + 1)] {
            XCTAssertThrowsError(try LibreReverseChatStore.save(id: id, title: "Invalid", payload: invalid, configuration: config))
        }
        XCTAssertThrowsError(try LibreReverseChatStore.save(id: "invalid", title: "Valid", payload: original, configuration: config))
        XCTAssertThrowsError(try LibreReverseChatStore.save(id: id, title: String(repeating: "x", count: 241), payload: original, configuration: config))
        XCTAssertThrowsError(try LibreReverseChatStore.save(id: id, title: "Valid", payload: original, updatedAt: Date(timeIntervalSince1970: .infinity), configuration: config))
        XCTAssertThrowsError(try LibreReverseChatStore.list(limit: 0, configuration: config))
        XCTAssertEqual(try LibreReverseChatStore.load(id: id, configuration: config)?.payload, original)
    }
    func testExistingDatabaseMigrationIsIdempotent() throws {
        let (root, config) = try library(); defer { try? FileManager.default.removeItem(at: root) }
        try execute("DROP TABLE ask_chat", config)
        try LibreReverseLibraryStore.initialize(config)
        let id = UUID().uuidString
        try LibreReverseChatStore.save(id: id, title: "Preserved", payload: Data("{}".utf8), configuration: config)
        try LibreReverseLibraryStore.initialize(config)
        XCTAssertEqual(try LibreReverseChatStore.list(configuration: config).map(\.id), [id])
    }
    func testPrimaryRolloverPreservesChatsButRecordingShardDoesNotExportThem() throws {
        let (root, config) = try library(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString, payload = Data("{\"chat\":\"local-only\"}".utf8)
        try LibreReverseChatStore.save(id: id, title: "Retained chat", payload: payload, configuration: config)
        let interval = LibreReverseShardInterval(ordinal: 0, epochStart: Date(timeIntervalSince1970: 0))
        let rebuilt = root.appendingPathComponent("rebuilt.sqlite3")
        _ = try LibreReverseShardBuilder.buildReplacementPrimary(source: config, destinationURL: rebuilt, activeInterval: interval, sealedShards: [])
        let rebuiltConfig = LibreReverseLibraryConfiguration(databaseURL: rebuilt, keyFileURL: config.keyFileURL, mediaRoot: config.mediaRoot)
        XCTAssertEqual(try LibreReverseChatStore.load(id: id, configuration: rebuiltConfig)?.payload, payload)
        let shard = root.appendingPathComponent("sealed.sqlite3")
        _ = try LibreReverseShardBuilder.buildToCompletion(source: config, destinationURL: shard, interval: interval)
        let shardConfig = LibreReverseLibraryConfiguration(databaseURL: shard, keyFileURL: config.keyFileURL, mediaRoot: config.mediaRoot)
        let session = LibreReverseLibraryWriteSession(configuration: shardConfig); defer { session.close() }
        let exported = try session.withDatabase(configuration: shardConfig) { db -> Int32 in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='ask_chat'", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw LibreReverseLibraryStoreError.sqlite("Synthetic schema check failed") }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw LibreReverseLibraryStoreError.sqlite("Synthetic row missing") }
            return sqlite3_column_int(statement, 0)
        }
        XCTAssertEqual(exported, 0)
    }
}
#endif
