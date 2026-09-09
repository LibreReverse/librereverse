#if os(macOS)
import Foundation

struct LibreReverseAdaptiveConcurrencyWindow: Equatable, Sendable {
    let maximum: Int
    private(set) var limit: Int
    private(set) var generation = 0
    private var cleanCompletions = 0
    private var hasObservedPressure = false

    init(initial: Int = 16, maximum: Int = 64) {
        self.maximum = max(1, min(64, maximum))
        self.limit = max(1, min(self.maximum, initial))
    }

    mutating func record(
        completed: Bool,
        throttled: Bool,
        admittedGeneration: Int
    ) {
        // A single overloaded flight can return many 403/429 responses. Only
        // the first is a new capacity signal; later outcomes from that same
        // flight must not repeatedly halve the replacement window.
        guard admittedGeneration == generation else { return }
        if throttled {
            limit = max(1, limit / 2)
            cleanCompletions = 0
            hasObservedPressure = true
            generation += 1
            return
        }
        guard completed, limit < maximum else {
            if !completed { cleanCompletions = 0 }
            return
        }
        // Probe quickly until Drive or the network supplies the first real
        // pressure signal. After that, use conservative additive increase.
        if !hasObservedPressure {
            limit += 1
            return
        }
        cleanCompletions += 1
        if cleanCompletions >= limit {
            limit += 1
            cleanCompletions = 0
        }
    }
}

public actor LibreReverseArchiveCoordinator {
    private struct ProcessOutcome: Sendable {
        let videoID: Int64
        let admittedGeneration: Int
        let completed: Bool
        let throttled: Bool
        let errorMessage: String?
    }

    public struct Snapshot: Equatable, Sendable {
        public let isRunning: Bool
        public let currentVideoID: Int64?
        public let status: LibreReverseArchiveStatus
        public let lastError: String?
    }

    private let destinationID: Int64
    private let library: LibreReverseLibraryConfiguration
    private let backend: any ArchiveBackend
    private var concurrency: LibreReverseAdaptiveConcurrencyWindow
    private var running = false
    private(set) var lastRunDatabaseOpenCount = 0
    private var currentVideoID: Int64?
    private var activeVideoIDs: Set<Int64> = []
    private var lastError: String?

    public init(
        destinationID: Int64,
        library: LibreReverseLibraryConfiguration,
        backend: any ArchiveBackend,
        maximumConcurrentObjects: Int = 64,
        initialConcurrentObjects: Int = 16
    ) {
        self.destinationID = destinationID
        self.library = library
        self.backend = backend
        self.concurrency = .init(
            initial: initialConcurrentObjects,
            maximum: maximumConcurrentObjects
        )
    }

    public func currentConcurrencyLimit() -> Int { concurrency.limit }

    public func snapshot() throws -> Snapshot {
        .init(
            isRunning: running,
            currentVideoID: currentVideoID,
            status: try LibreReverseArchiveStore.status(destinationID: destinationID, configuration: library),
            lastError: lastError
        )
    }

    /// Processes bounded durable work until caught up. Calling again after a
    /// crash resumes queued/retry objects and any saved resumable URI.
    @discardableResult
    public func runUntilIdle(maxObjects: Int = .max) async throws -> Int {
        let signposter = CaptureDiffInstrumentation.signposter
        let interval = signposter.beginInterval("ArchiveUploadBatch", id: signposter.makeSignpostID())
        defer { signposter.endInterval("ArchiveUploadBatch", interval) }
        guard !running else { return 0 }
        running = true
        // The caller awaits this run before primary replacement. No handle survives idle.
        let databaseSession = LibreReverseLibraryWriteSession(configuration: library)
        defer {
            lastRunDatabaseOpenCount = databaseSession.connectionOpenCount
            databaseSession.close()
        }
        defer {
            running = false
            activeVideoIDs.removeAll()
            currentVideoID = nil
        }
        let workerLimit = min(concurrency.limit, maxObjects)
        guard workerLimit > 0 else { return 0 }
        var attempted = 0
        var completed = 0
        var encounteredError = false
        var encounteredPressure = false
        return try await withThrowingTaskGroup(of: ProcessOutcome.self) { group in
            for _ in 0..<workerLimit {
                guard let object = try claimNextObject(databaseSession: databaseSession) else { break }
                attempted += 1
                markActive(object.videoID)
                let generation = concurrency.generation
                group.addTask {
                    try await self.processClaimed(
                        object,
                        admittedGeneration: generation,
                        databaseSession: databaseSession
                    )
                }
            }
            while let outcome = try await group.next() {
                markInactive(outcome.videoID)
                if outcome.completed {
                    completed += 1
                } else if let errorMessage = outcome.errorMessage {
                    encounteredError = true
                    lastError = errorMessage
                }
                encounteredPressure = encounteredPressure || outcome.throttled
                concurrency.record(
                    completed: outcome.completed,
                    throttled: outcome.throttled,
                    admittedGeneration: outcome.admittedGeneration
                )
                // Drain the current flight after provider pressure. The
                // durable retry date wakes a fresh, smaller flight instead of
                // feeding more queued objects into a known overload event.
                while !encounteredPressure,
                      attempted < maxObjects,
                      activeVideoIDs.count < concurrency.limit,
                      let object = try claimNextObject(databaseSession: databaseSession) {
                    attempted += 1
                    markActive(object.videoID)
                    let generation = concurrency.generation
                    group.addTask {
                        try await self.processClaimed(
                            object,
                            admittedGeneration: generation,
                            databaseSession: databaseSession
                        )
                    }
                }
            }
            if !encounteredError { lastError = nil }
            return completed
        }
    }

    private func claimNextObject(databaseSession: LibreReverseLibraryWriteSession) throws -> LibreReverseArchiveObject? {
        try Task.checkCancellation()
        return try LibreReverseArchiveStore.claimNextQueuedObject(
            destinationID: destinationID,
            configuration: library, databaseSession: databaseSession
        )
    }

    private func markActive(_ videoID: Int64) {
        activeVideoIDs.insert(videoID)
        currentVideoID = activeVideoIDs.min()
    }

    private func markInactive(_ videoID: Int64) {
        activeVideoIDs.remove(videoID)
        currentVideoID = activeVideoIDs.min()
    }

    private func processClaimed(
        _ object: LibreReverseArchiveObject,
        admittedGeneration: Int,
        databaseSession: LibreReverseLibraryWriteSession
    ) async throws -> ProcessOutcome {
        do {
            try await process(object, databaseSession: databaseSession)
            return .init(
                videoID: object.videoID,
                admittedGeneration: admittedGeneration,
                completed: true,
                throttled: false,
                errorMessage: nil
            )
        } catch {
            let throttled = Self.isThrottled(error)
            try? LibreReverseArchiveStore.recordObjectFailure(
                objectID: object.id,
                error: error,
                retryable: error is CancellationError || Self.isRetryable(error),
                configuration: library, databaseSession: databaseSession
            )
            if error is CancellationError { throw error }
            return .init(
                videoID: object.videoID,
                admittedGeneration: admittedGeneration,
                completed: false,
                throttled: throttled,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func process(_ object: LibreReverseArchiveObject, databaseSession: LibreReverseLibraryWriteSession) async throws {
        try Task.checkCancellation()
        let localURL = library.mediaRoot.appendingPathComponent(object.relativePath)
        let integrity = try await Task.detached(priority: .utility) {
            try ArchiveIntegrityEngine.hash(file: localURL)
        }.value
        try LibreReverseArchiveStore.recordHashedObject(
            objectID: object.id,
            integrity: integrity,
            configuration: library, databaseSession: databaseSession
        )
        let key = ArchiveObjectKey(object.objectKey)
        let remote: RemoteObjectMetadata
        if let existing = try await backend.locate(key) {
            remote = existing
        } else {
            var uploadSession = try LibreReverseArchiveStore.uploadCheckpoint(
                objectID: object.id,
                key: key,
                configuration: library, databaseSession: databaseSession
            )
            if uploadSession == nil {
                uploadSession = try await backend.beginUpload(.init(
                    key: key,
                    displayName: localURL.lastPathComponent,
                    videoID: object.videoID,
                    relativePath: object.relativePath,
                    integrity: integrity
                ))
                try LibreReverseArchiveStore.checkpointUpload(
                    objectID: object.id,
                    session: uploadSession!,
                    configuration: library, databaseSession: databaseSession
                )
            }
            do {
                remote = try await backend.resumeUpload(uploadSession!, from: localURL) { [library] checkpoint in
                    try LibreReverseArchiveStore.checkpointUpload(
                        objectID: object.id,
                        session: checkpoint,
                        configuration: library, databaseSession: databaseSession
                    )
                }.metadata
            } catch ArchiveBackendError.expiredUploadSession {
                try LibreReverseArchiveStore.discardUploadCheckpoint(
                    objectID: object.id,
                    configuration: library, databaseSession: databaseSession
                )
                let replacement = try await backend.beginUpload(.init(
                    key: key,
                    displayName: localURL.lastPathComponent,
                    videoID: object.videoID,
                    relativePath: object.relativePath,
                    integrity: integrity
                ))
                try LibreReverseArchiveStore.checkpointUpload(objectID: object.id, session: replacement, configuration: library, databaseSession: databaseSession)
                remote = try await backend.resumeUpload(replacement, from: localURL) { [library] checkpoint in
                    try LibreReverseArchiveStore.checkpointUpload(objectID: object.id, session: checkpoint, configuration: library, databaseSession: databaseSession)
                }.metadata
            }
        }
        try LibreReverseArchiveStore.recordUploadedObject(
            objectID: object.id,
            metadata: remote,
            configuration: library, databaseSession: databaseSession
        )
        let verification = try await backend.verify(remote, expected: integrity)
        try Task.checkCancellation()
        guard verification.matches else { throw ArchiveBackendError.verificationMismatch }
        try LibreReverseArchiveStore.recordVerifiedObject(
            objectID: object.id,
            verification: verification,
            configuration: library, databaseSession: databaseSession
        )
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
        case .rateLimited:
            return true
        case .expiredUploadSession, .invalidResponse:
            return true
        case .duplicateObject, .invalidAcknowledgedRange, .localFileChanged,
             .verificationMismatch, .unsupportedOperation:
            return false
        }
    }

    private static func isThrottled(_ error: Error) -> Bool {
        if let error = error as? GoogleDriveConnectionError {
            switch error {
            case let .tokenRequestFailed(status, _), let .driveRequestFailed(status, _):
                return status == 429 || (500...599).contains(status)
            default:
                return false
            }
        }
        if let error = error as? ArchiveBackendError {
            switch error {
            case .rateLimited:
                return true
            case let .requestFailed(status, _):
                return status == 429 || (500...599).contains(status)
            default:
                return false
            }
        }
        let networkError = error as NSError
        guard networkError.domain == NSURLErrorDomain else { return false }
        return networkError.code == NSURLErrorTimedOut
            || networkError.code == NSURLErrorNetworkConnectionLost
            || networkError.code == NSURLErrorCannotConnectToHost
    }
}
#endif
