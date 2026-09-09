#if os(macOS)
import Foundation

public actor LibreReverseMediaResidencyManager {
    private let destinationID: Int64
    private let library: LibreReverseLibraryConfiguration
    private let fileManager: FileManager
    private let backend: any ArchiveBackend
    private let stagingRoot: URL
    private let handoffGraceSeconds: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        destinationID: Int64,
        library: LibreReverseLibraryConfiguration,
        backend: any ArchiveBackend,
        fileManager: FileManager = .default,
        handoffGraceSeconds: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.destinationID = destinationID
        self.library = library
        self.backend = backend
        self.fileManager = fileManager
        self.handoffGraceSeconds = max(0, handoffGraceSeconds)
        self.now = now
        self.stagingRoot = library.mediaRoot
            .deletingLastPathComponent()
            .appendingPathComponent("EvictionStaging", isDirectory: true)
    }

    /// Recovers the two-phase rename/delete protocol without weakening the
    /// verified-remote invariant established before staging.
    public func recoverInterruptedEvictions() throws {
        let databaseSession = LibreReverseLibraryWriteSession(configuration: library)
        defer { databaseSession.close() }
        for record in try LibreReverseArchiveStore.stagedEvictions(configuration: library, databaseSession: databaseSession) {
            let canonical = library.mediaRoot.appendingPathComponent(record.relativePath)
            let staged = stagingRoot.appendingPathComponent(record.stagingPath)
            let canonicalExists = fileManager.fileExists(atPath: canonical.path)
            let stagedExists = fileManager.fileExists(atPath: staged.path)
            if canonicalExists {
                if stagedExists { try fileManager.removeItem(at: staged) }
                try LibreReverseArchiveStore.finishEviction(
                    videoID: record.videoID,
                    localState: .present,
                    configuration: library, databaseSession: databaseSession
                )
            } else {
                if stagedExists { try fileManager.removeItem(at: staged) }
                try LibreReverseArchiveStore.finishEviction(
                    videoID: record.videoID,
                    localState: .absent,
                    configuration: library, databaseSession: databaseSession
                )
            }
        }
    }

    @discardableResult
    public func evictEligible(limit: Int = 100) async throws -> Int {
        let databaseSession = LibreReverseLibraryWriteSession(configuration: library)
        defer { databaseSession.close() }
        let signposter = CaptureDiffInstrumentation.signposter
        let interval = signposter.beginInterval("MediaEviction", id: signposter.makeSignpostID())
        defer { signposter.endInterval("MediaEviction", interval) }
        try LibreReverseArchiveStore.reconcileDesiredResidency(
            destinationID: destinationID,
            configuration: library, session: databaseSession
        )
        var bytesRemaining = try LibreReverseArchiveStore.evictionBytesRequired(
            destinationID: destinationID,
            now: now(),
            configuration: library, session: databaseSession
        )
        guard bytesRemaining > 0 else { return 0 }
        let candidates = try LibreReverseArchiveStore.evictionCandidates(
            destinationID: destinationID,
            limit: limit,
            accessedBefore: now().addingTimeInterval(-handoffGraceSeconds),
            now: now(),
            configuration: library, databaseSession: databaseSession
        )
        if !candidates.isEmpty {
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        }
        var count = 0
        for candidate in candidates {
            guard bytesRemaining > 0 else { break }
            let canonical = library.mediaRoot.appendingPathComponent(candidate.relativePath)
            guard fileManager.fileExists(atPath: canonical.path) else { continue }
            let integrity = try await Task.detached(priority: .utility) {
                try ArchiveIntegrityEngine.hash(file: canonical)
            }.value
            guard integrity.byteCount == candidate.byteCount,
                  integrity.sha256 == candidate.sha256 else {
                try LibreReverseArchiveStore.recordResidencyError(
                    videoID: candidate.videoID,
                    message: "Local video changed after its remote copy was verified; it was not removed.",
                    configuration: library, databaseSession: databaseSession
                )
                continue
            }
            do {
                let verification = try await backend.verify(
                    candidate.remoteMetadata,
                    expected: integrity
                )
                guard verification.matches else {
                    throw ArchiveBackendError.verificationMismatch
                }
            } catch {
                try? LibreReverseArchiveStore.recordObjectFailure(
                    objectID: candidate.archiveObjectID,
                    error: error,
                    retryable: Self.isRetryable(error),
                    configuration: library, databaseSession: databaseSession
                )
                continue
            }
            let stagingName = "\(candidate.videoID).\(UUID().uuidString).mp4"
            guard try LibreReverseArchiveStore.stageEviction(
                candidate: candidate,
                stagingPath: stagingName,
                destinationID: destinationID,
                configuration: library, databaseSession: databaseSession
            ) else { continue }
            let staged = stagingRoot.appendingPathComponent(stagingName)
            do {
                try fileManager.moveItem(at: canonical, to: staged)
                try fileManager.removeItem(at: staged)
                try LibreReverseArchiveStore.finishEviction(
                    videoID: candidate.videoID,
                    localState: .absent,
                    configuration: library, databaseSession: databaseSession
                )
                bytesRemaining = max(0, bytesRemaining - candidate.byteCount)
                count += 1
            } catch {
                // Durable eviction_staged state lets startup recovery choose
                // the surviving canonical or staged copy deterministically.
                throw error
            }
        }
        return count
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let error = error as? GoogleDriveConnectionError {
            switch error {
            case let .tokenRequestFailed(status, _), let .driveRequestFailed(status, _):
                return status == 408 || status == 429 || (500...599).contains(status)
            case .authorizationTimedOut:
                return true
            default:
                return false
            }
        }
        guard let error = error as? ArchiveBackendError else {
            return (error as NSError).domain == NSURLErrorDomain
        }
        switch error {
        case let .requestFailed(status, _):
            return status == 408 || status == 429 || (500...599).contains(status)
        case .rateLimited, .expiredUploadSession, .invalidResponse:
            return true
        case .duplicateObject, .invalidAcknowledgedRange, .localFileChanged,
             .verificationMismatch, .unsupportedOperation:
            return false
        }
    }
}

public final class LibreReverseMediaLease: @unchecked Sendable {
    private let videoID: Int64
    private let library: LibreReverseLibraryConfiguration
    private let databaseSession: LibreReverseLibraryWriteSession?
    private let lock = NSLock()
    private var released = true

    public init(
        videoID: Int64,
        library: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        self.videoID = videoID
        self.library = library
        self.databaseSession = databaseSession
        try LibreReverseArchiveStore.adjustLease(videoID: videoID, delta: 1,
            configuration: library, databaseSession: databaseSession)
        released = false
    }

    public func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        lock.unlock()
        try? LibreReverseArchiveStore.adjustLease(videoID: videoID, delta: -1,
            configuration: library, databaseSession: databaseSession)
    }

    deinit { release() }
}
#endif
