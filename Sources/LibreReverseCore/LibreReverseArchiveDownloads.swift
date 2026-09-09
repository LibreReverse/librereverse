#if os(macOS)
import CSQLCipher
import Foundation

public enum LibreReverseDownloadPhase: String, Codable, Sendable {
    case queued, history, recording, retrying, disconnected, unavailable, complete
}

public struct LibreReverseDownloadRequest: Codable, Sendable, Equatable {
    public let id: String
    public var date: Date
    public let start: Date
    public let end: Date
    public let createdAt: Date
    public var phase: LibreReverseDownloadPhase = .queued
    public var attempt = 0
    public var retryAt: Date?
    public var completedAt: Date?
    public var lastError: String?
    public var shardOrdinal: Int64?
    public var selectedVideoID: Int64?

    public init(date: Date, shardOrdinal: Int64? = nil, selectedVideoID: Int64? = nil, now: Date = Date()) {
        let hour = LibreReverseArchiveRehydrationPolicy.localHour(containing: date)
        id = String(Int64(hour.start.timeIntervalSince1970))
        self.date = date
        start = hour.start
        end = hour.end
        createdAt = now
        self.shardOrdinal = shardOrdinal
        self.selectedVideoID = selectedVideoID
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }
}

public struct LibreReverseDownloadStatus: Sendable {
    public let request: LibreReverseDownloadRequest
    public var phase: LibreReverseDownloadPhase
    public var transferID: String = ""
    public var completedBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var metadataAvailable = false
}

/// Requests live inside the encrypted library, not the lifetime of a window.
public struct LibreReverseDownloadRequestStore: Sendable {
    private let library: LibreReverseLibraryConfiguration
    public init(library: LibreReverseLibraryConfiguration) { self.library = library }

    public func load(session: LibreReverseLibraryWriteSession? = nil) throws -> [LibreReverseDownloadRequest] {
        try withDatabase(session: session) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT payload FROM archive_download_request ORDER BY createdAt", -1, &statement, nil) == SQLITE_OK else {
                throw failure(db)
            }
            defer { sqlite3_finalize(statement) }
            var result: [LibreReverseDownloadRequest] = []
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                guard let text = sqlite3_column_text(statement, 0) else { throw failure(db) }
                result.append(try JSONDecoder().decode(LibreReverseDownloadRequest.self, from: Data(String(cString: text).utf8)))
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE else { throw failure(db) }
            return result
        }
    }

    public func save(_ request: LibreReverseDownloadRequest) throws {
        let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        try withDatabase { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO archive_download_request(id,createdAt,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", -1, &statement, nil) == SQLITE_OK else { throw failure(db) }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, request.id, -1, transient)
            sqlite3_bind_double(statement, 2, request.createdAt.timeIntervalSince1970)
            sqlite3_bind_text(statement, 3, payload, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(db) }
        }
    }

    public func protects(shardOrdinal: Int64, now: Date = Date()) throws -> Bool {
        try load().contains {
            $0.shardOrdinal == shardOrdinal && ($0.completedAt == nil || now.timeIntervalSince($0.completedAt!) < 86_400)
        }
    }

    private func withDatabase<T>(
        session: LibreReverseLibraryWriteSession? = nil,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        if let session {
            return try session.withDatabase(configuration: library) { db in
                guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS archive_download_request(id TEXT PRIMARY KEY,createdAt REAL NOT NULL,payload TEXT NOT NULL)", nil, nil, nil) == SQLITE_OK else { throw failure(db) }
                return try body(db)
            }
        }
        try LibreReverseLibraryKey.validate(library.keyFileURL)
        let key = try Data(contentsOf: library.keyFileURL)
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(library.databaseURL.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let db = connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open library"
            if let connection { sqlite3_close(connection) }
            throw LibreReverseArchiveStoreError.unableToOpenDatabase(message)
        }
        defer { sqlite3_close(db) }
        let keyStatus = key.withUnsafeBytes { sqlite3_key(db, $0.baseAddress, Int32($0.count)) }
        guard keyStatus == SQLITE_OK else { throw LibreReverseArchiveStoreError.unableToApplyKey(keyStatus) }
        sqlite3_busy_timeout(db, 10_000)
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS archive_download_request(id TEXT PRIMARY KEY,createdAt REAL NOT NULL,payload TEXT NOT NULL)", nil, nil, nil) == SQLITE_OK else { throw failure(db) }
        return try body(db)
    }

    private func failure(_ db: OpaquePointer) -> Error {
        LibreReverseArchiveStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
    }
}

public protocol LibreReverseArchiveDownloading: Sendable {
    func download(_ request: LibreReverseDownloadRequest,
                  progress: @escaping @Sendable (LibreReverseDownloadStatus) async -> Void) async throws
}

public enum LibreReverseDownloadFailure {
    public static func unavailableInDestination(_ error: Error) -> Bool {
        if let error = error as? LibreReverseLocalMediaResolverError {
            if case .remoteMediaUnavailable = error { return true }
        }
        if let error = error as? LibreReverseShardArchiveError {
            if case .shardUnavailable = error { return true }
        }
        if case ArchiveBackendError.requestFailed(let status, _) = error { return status == 404 }
        return false
    }

    public static func needsConnection(_ error: Error) -> Bool {
        if let error = error as? GoogleDriveConnectionError {
            switch error {
            case .notAuthorized, .missingRefreshToken, .missingClientConfiguration, .invalidClientConfiguration,
                 .authorizationDenied: return true
            case .tokenRequestFailed(let status, _): return status == 400 || status == 401 || status == 403
            case .driveRequestFailed(let status, _): return status == 401 || status == 403
            default: return false
            }
        }
        if case ArchiveBackendError.requestFailed(let status, _) = error {
            return status == 401 || status == 403
        }
        return false
    }
}

/// App-owned worker. Views only enqueue requests and observe snapshots.
public actor LibreReverseArchiveDownloadCoordinator {
    private let store: LibreReverseDownloadRequestStore
    private let onChange: @Sendable (LibreReverseDownloadStatus) async -> Void
    private let retrySeconds: TimeInterval
    private var requests: [String: LibreReverseDownloadRequest]?
    private var snapshots: [String: LibreReverseDownloadStatus] = [:]
    private var executor: (any LibreReverseArchiveDownloading)?
    private var worker: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var disconnected = false
    private var activeAttempt: UUID?

    public init(library: LibreReverseLibraryConfiguration, retrySeconds: TimeInterval = 5,
                onChange: @escaping @Sendable (LibreReverseDownloadStatus) async -> Void = { _ in }) {
        store = .init(library: library)
        self.retrySeconds = retrySeconds
        self.onChange = onChange
    }

    public func enqueue(date: Date, shardOrdinal: Int64? = nil, selectedVideoID: Int64? = nil) async throws {
        try load()
        let proposed = LibreReverseDownloadRequest(date: date, shardOrdinal: shardOrdinal, selectedVideoID: selectedVideoID)
        if let existing = requests?[proposed.id], existing.completedAt == nil {
            start()
            await publish(snapshot(existing))
            return
        }
        try store.save(proposed) // Commit the user's intent before starting any network work.
        requests?[proposed.id] = proposed
        snapshots[proposed.id] = nil
        await publish(snapshot(proposed))
        start()
    }

    public func connect(_ executor: any LibreReverseArchiveDownloading) async throws {
        try load()
        generation &+= 1
        worker?.cancel()
        worker = nil
        self.executor = executor
        disconnected = false
        for var request in requests!.values where request.completedAt == nil {
            request.phase = .queued
            request.retryAt = nil
            try store.save(request)
            requests?[request.id] = request
            snapshots[request.id] = nil
        }
        start()
    }

    public func pause(needsConnection: Bool) async {
        generation &+= 1
        let token = generation
        let previous = worker
        previous?.cancel()
        worker = nil
        executor = nil
        disconnected = needsConnection
        await previous?.value
        guard generation == token else { return }
        try? load()
        for request in requests?.values ?? [:].values where request.completedAt == nil {
            snapshots[request.id] = nil
            await publish(snapshot(request))
        }
    }

    /// A saved destination is not proof that this process has an authenticated executor.
    public var connectionAvailable: Bool { executor != nil }

    public func status(at date: Date) throws -> LibreReverseDownloadStatus? {
        try load()
        guard let request = requests?.values.first(where: { $0.contains(date) }) else { return nil }
        return snapshot(request)
    }

    private func load() throws {
        if requests == nil { requests = Dictionary(uniqueKeysWithValues: try store.load().map { ($0.id, $0) }) }
    }

    private func snapshot(_ request: LibreReverseDownloadRequest) -> LibreReverseDownloadStatus {
        if request.completedAt != nil { return .init(request: request, phase: .complete, metadataAvailable: true) }
        if executor == nil { return .init(request: request, phase: disconnected ? .disconnected : .retrying) }
        return snapshots[request.id] ?? .init(request: request, phase: request.phase)
    }

    private func publish(_ status: LibreReverseDownloadStatus) async {
        snapshots[status.request.id] = status
        await onChange(status)
    }

    private func start() {
        guard worker == nil, executor != nil else { return }
        let token = generation
        worker = Task { await self.run(generation: token) }
    }

    private func run(generation token: UInt64) async {
        defer { if token == generation { worker = nil } }
        while token == generation, !Task.isCancelled, let executor {
            let pending = (requests?.values ?? [:].values)
                .filter { $0.completedAt == nil && $0.phase != .disconnected && $0.phase != .unavailable }
                .sorted { ($0.retryAt ?? .distantPast, $0.createdAt) < ($1.retryAt ?? .distantPast, $1.createdAt) }
            guard var request = pending.first else { return }
            if let retry = request.retryAt, retry > Date() {
                do { try await Task.sleep(nanoseconds: UInt64(max(0.001, min(1, retry.timeIntervalSinceNow)) * 1_000_000_000)) }
                catch { return }
                continue
            }
            do {
                request.phase = .queued
                try store.save(request)
                requests?[request.id] = request
                let attemptID = UUID()
                activeAttempt = attemptID
                try await executor.download(request) { status in
                    await self.receive(status, generation: token, attempt: attemptID)
                }
                guard token == generation, !Task.isCancelled else { return }
                activeAttempt = nil
                request.shardOrdinal = requests?[request.id]?.shardOrdinal ?? request.shardOrdinal
                request.phase = .complete
                request.completedAt = Date()
                request.lastError = nil
                request.retryAt = nil
                try store.save(request)
                requests?[request.id] = request
                await publish(.init(request: request, phase: .complete, metadataAvailable: true))
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                activeAttempt = nil
                request.attempt += 1
                request.lastError = error.localizedDescription
                if LibreReverseDownloadFailure.unavailableInDestination(error) {
                    request.phase = .unavailable
                    request.retryAt = nil
                } else {
                    request.phase = LibreReverseDownloadFailure.needsConnection(error) ? .disconnected : .retrying
                    request.retryAt = Date().addingTimeInterval(min(60, retrySeconds * pow(2, Double(min(request.attempt - 1, 4)))))
                }
                // An I/O failure must not erase the already committed request.
                try? store.save(request)
                requests?[request.id] = request
                await publish(.init(request: request, phase: request.phase))
            }
        }
    }

    private func receive(_ status: LibreReverseDownloadStatus, generation token: UInt64, attempt: UUID) async {
        guard token == generation, activeAttempt == attempt, !Task.isCancelled else { return }
        if let ordinal = status.request.shardOrdinal { requests?[status.request.id]?.shardOrdinal = ordinal }
        await publish(status)
    }
}

public actor LibreReverseArchiveDownloadExecutor: LibreReverseArchiveDownloading {
    private let library: LibreReverseLibraryConfiguration
    private let destinationID: Int64
    private let shards: LibreReverseShardResolver
    private let media: any LocalMediaResolving
    private let session: LibraryDatabaseSession

    public init(library: LibreReverseLibraryConfiguration, destinationID: Int64,
                shards: LibreReverseShardResolver, media: any LocalMediaResolving) {
        self.library = library
        self.destinationID = destinationID
        self.shards = shards
        self.media = media
        session = .init(configuration: .init(databaseURL: library.databaseURL, keyFileURL: library.keyFileURL,
                         mediaRoot: library.mediaRoot, frameImagesRoot: library.frameImagesRoot))
    }

    public func download(_ original: LibreReverseDownloadRequest,
                         progress: @escaping @Sendable (LibreReverseDownloadStatus) async -> Void) async throws {
        await session.reloadShardCatalog()
        let records = try LibreReverseShardStore.records(configuration: library)
        let request: LibreReverseDownloadRequest = {
            var result = original
            result.shardOrdinal = records.first(where: { $0.interval.contains(original.date) })?.interval.ordinal
            return result
        }()
        try LibreReverseDownloadRequestStore(library: library).save(request)
        if let shard = try await session.unavailableShards().first(where: { $0.interval.contains(request.date) }) {
            await progress(.init(request: request, phase: .history, transferID: "history:\(shard.ordinal)"))
            _ = try await shards.restore(ordinal: shard.ordinal) { value in
                await progress(.init(request: request, phase: .history, transferID: "history:\(shard.ordinal)",
                                     completedBytes: value.completedBytes, totalBytes: value.totalBytes))
            }
            await session.reloadShardCatalog()
        }
        try Task.checkCancellation()
        await progress(.init(request: request, phase: .recording, metadataAvailable: true))
        let moment = try await session.nearestMoment(to: request.date)
        guard let selectedID = request.selectedVideoID ?? moment?.databaseVideoID else {
            throw LibreReverseShardArchiveError.shardUnavailable(request.shardOrdinal ?? -1)
        }
        let entries = try LibreReverseArchiveStore.verifiedRemoteVideos(
            in: DateInterval(start: request.start, end: request.end), destinationID: destinationID, configuration: library)
        let ordered = [selectedID] + entries.map(\.videoID).filter { $0 != selectedID }
        for videoID in ordered {
            try Task.checkCancellation()
            let remote = try LibreReverseArchiveStore.verifiedRemoteMedia(videoID: videoID,
                destinationID: destinationID, configuration: library)
            let path = remote.map { library.mediaRoot.appendingPathComponent($0.relativePath) }
                ?? (videoID == moment?.databaseVideoID ? moment?.chunkURL : nil)
            if let path, FileManager.default.fileExists(atPath: path.path) { continue }
            let transfer = "video:\(videoID)"
            await progress(.init(request: request, phase: .recording, transferID: transfer, metadataAvailable: true))
            _ = try await media.restoreMoment(videoID: videoID) { value in
                await progress(.init(request: request, phase: .recording, transferID: transfer,
                                     completedBytes: value.completedBytes, totalBytes: value.totalBytes, metadataAvailable: true))
            }
            await progress(.init(request: request, phase: .recording, transferID: transfer, metadataAvailable: true))
        }
    }
}
#endif
