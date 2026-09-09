#if os(macOS)
import CSQLCipher
import Foundation

/// A keyed connection owned by a capture/OCR lifecycle or synchronous query batch, not a global cache.
/// Each operation is synchronous and serialized. Owners must close it at the
/// existing idle barrier before replacing the primary database. Ordinary store
/// callers retain their original open/use/close behavior unless they opt in.
public final class LibreReverseLibraryWriteSession: @unchecked Sendable {
    private let configuration: LibreReverseLibraryConfiguration
    private let lock = NSLock()
    private var database: OpaquePointer?
    private var openCount = 0
    private var appliedKey: Data?

    public init(configuration: LibreReverseLibraryConfiguration) {
        self.configuration = configuration
    }

    deinit { if let database { sqlite3_close(database) } }

    var connectionOpenCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return openCount
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let database { sqlite3_close(database) }
        database = nil
        appliedKey = nil
    }

    func withDatabase<T>(
        configuration: LibreReverseLibraryConfiguration,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard configuration.databaseURL == self.configuration.databaseURL,
              configuration.keyFileURL == self.configuration.keyFileURL,
              configuration.mediaRoot == self.configuration.mediaRoot else {
            throw LibreReverseLibraryStoreError.sqlite("Database session configuration mismatch")
        }
        let currentKey: Data
        do {
            // Preserve the store's key revocation/permission checks on every
            // operation without repeating SQLCipher's expensive derivation.
            try LibreReverseLibraryKey.validate(configuration.keyFileURL)
            currentKey = try Data(contentsOf: configuration.keyFileURL)
        } catch {
            if let database { sqlite3_close(database) }
            database = nil
            appliedKey = nil
            throw error
        }
        if appliedKey != currentKey {
            if let database { sqlite3_close(database) }
            database = nil
            appliedKey = nil
        }
        let connection: OpaquePointer
        if let database { connection = database }
        else {
            connection = try LibreReverseLibraryStore.openWriteDatabase(configuration, create: false)
            database = connection
            appliedKey = currentKey
            openCount += 1
        }
        do {
            let result = try operation(connection)
            guard sqlite3_get_autocommit(connection) != 0 else {
                throw LibreReverseLibraryStoreError.sqlite("Database operation left an open transaction")
            }
            return result
        } catch {
            // Discard even an uncertain connection state. Closing rolls back
            // an uncommitted transaction, and the next operation reopens cleanly.
            sqlite3_close(connection)
            database = nil
            appliedKey = nil
            throw error
        }
    }
}
#endif
