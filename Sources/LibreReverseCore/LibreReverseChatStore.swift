#if os(macOS)
import CSQLCipher
import Foundation

public struct LibreReverseChatSummary: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date
}

public struct LibreReverseStoredChat: Equatable, Sendable {
    public let summary: LibreReverseChatSummary
    public let payload: Data
}

public enum LibreReverseChatStoreError: Error, LocalizedError {
    case invalidIdentifier, invalidTitle, invalidPayload, invalidDate, invalidPagination
    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "The saved chat identifier is invalid."
        case .invalidTitle: "A saved chat needs a title of at most 240 characters."
        case .invalidPayload: "The saved chat is invalid or exceeds the 2 MiB limit."
        case .invalidDate: "The saved chat timestamp is invalid."
        case .invalidPagination: "The saved chat page request is invalid."
        }
    }
}

/// Local-only catalog data, encrypted by the library's existing SQLCipher key.
/// Callers serialize completed turns and safe references, never full transcript
/// evidence or credentials. No cloud object or retention job is created here.
public enum LibreReverseChatStore {
    public static let maximumPayloadBytes = 2 * 1_024 * 1_024

    public static func list(limit: Int = 100, offset: Int = 0,
        configuration: LibreReverseLibraryConfiguration) throws -> [LibreReverseChatSummary] {
        guard (1...500).contains(limit), (0...1_000_000).contains(offset) else { throw LibreReverseChatStoreError.invalidPagination }
        return try withDatabase(configuration) { db in
            let statement = try prepare(db, "SELECT id,title,createdAt,updatedAt FROM ask_chat ORDER BY updatedAt DESC,id ASC LIMIT ? OFFSET ?")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(limit)); sqlite3_bind_int64(statement, 2, Int64(offset))
            var values: [LibreReverseChatSummary] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return values }
                guard status == SQLITE_ROW else { throw databaseError(db) }
                values.append(try summary(statement))
            }
        }
    }

    public static func load(id: String, configuration: LibreReverseLibraryConfiguration) throws -> LibreReverseStoredChat? {
        let id = try identifier(id)
        return try withDatabase(configuration) { db in
            let statement = try prepare(db, "SELECT id,title,createdAt,updatedAt,payload FROM ask_chat WHERE id=?")
            defer { sqlite3_finalize(statement) }
            try bind(id, statement, 1, db)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw databaseError(db) }
            let count = Int(sqlite3_column_bytes(statement, 4))
            guard count > 0, count <= maximumPayloadBytes, let bytes = sqlite3_column_blob(statement, 4) else { throw LibreReverseChatStoreError.invalidPayload }
            let payload = Data(bytes: bytes, count: count)
            try validatePayload(payload)
            return .init(summary: try summary(statement), payload: payload)
        }
    }

    @discardableResult
    public static func save(id: String, title: String, payload: Data, updatedAt: Date = Date(),
        configuration: LibreReverseLibraryConfiguration) throws -> LibreReverseChatSummary {
        let id = try identifier(id)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 4_096, title.count <= 240, !title.contains("\0") else { throw LibreReverseChatStoreError.invalidTitle }
        try validatePayload(payload)
        guard updatedAt.timeIntervalSince1970.isFinite else { throw LibreReverseChatStoreError.invalidDate }
        return try withDatabase(configuration) { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                let statement = try prepare(db, """
                    INSERT INTO ask_chat(id,title,payload,createdAt,updatedAt) VALUES(?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET title=excluded.title,payload=excluded.payload,
                      updatedAt=MAX(ask_chat.updatedAt,excluded.updatedAt)
                    """)
                defer { sqlite3_finalize(statement) }
                try bind(id, statement, 1, db); try bind(title, statement, 2, db)
                let bound = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                guard bound == SQLITE_OK else { throw databaseError(db) }
                sqlite3_bind_double(statement, 4, updatedAt.timeIntervalSince1970)
                sqlite3_bind_double(statement, 5, updatedAt.timeIntervalSince1970)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
                let read = try prepare(db, "SELECT id,title,createdAt,updatedAt FROM ask_chat WHERE id=?")
                defer { sqlite3_finalize(read) }
                try bind(id, read, 1, db)
                guard sqlite3_step(read) == SQLITE_ROW else { throw databaseError(db) }
                let result = try summary(read)
                try execute(db, "COMMIT")
                return result
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    public static func delete(id: String, configuration: LibreReverseLibraryConfiguration) throws {
        let id = try identifier(id)
        try withDatabase(configuration) { db in
            let statement = try prepare(db, "DELETE FROM ask_chat WHERE id=?")
            defer { sqlite3_finalize(statement) }
            try bind(id, statement, 1, db)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
        }
    }

    private static func identifier(_ value: String) throws -> String {
        guard value.count == 36, let id = UUID(uuidString: value), id.uuidString.caseInsensitiveCompare(value) == .orderedSame else { throw LibreReverseChatStoreError.invalidIdentifier }
        return id.uuidString
    }
    private static func validatePayload(_ payload: Data) throws {
        guard !payload.isEmpty, payload.count <= maximumPayloadBytes,
            (try? JSONSerialization.jsonObject(with: payload, options: .fragmentsAllowed)) != nil else { throw LibreReverseChatStoreError.invalidPayload }
    }
    private static func summary(_ statement: OpaquePointer) throws -> LibreReverseChatSummary {
        guard let rawID = sqlite3_column_text(statement, 0), let title = sqlite3_column_text(statement, 1) else { throw LibreReverseChatStoreError.invalidPayload }
        let created = sqlite3_column_double(statement, 2), updated = sqlite3_column_double(statement, 3)
        guard created.isFinite, updated.isFinite else { throw LibreReverseChatStoreError.invalidDate }
        return .init(id: try identifier(String(cString: rawID)), title: String(cString: title),
            createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: updated))
    }
    private static func withDatabase<T>(_ configuration: LibreReverseLibraryConfiguration, _ body: (OpaquePointer) throws -> T) throws -> T {
        let session = LibreReverseLibraryWriteSession(configuration: configuration)
        defer { session.close() }
        return try session.withDatabase(configuration: configuration, operation: body)
    }
    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError(db) }
        return statement
    }
    private static func bind(_ text: String, _ statement: OpaquePointer, _ index: Int32, _ db: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw databaseError(db) }
    }
    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError(db) }
    }
    private static func databaseError(_ db: OpaquePointer) -> LibreReverseLibraryStoreError {
        .sqlite(String(cString: sqlite3_errmsg(db)))
    }
}
#endif
