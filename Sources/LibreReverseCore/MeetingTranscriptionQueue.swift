#if os(macOS)
import Darwin
import Foundation

// lockf locks belong to a process, so independent queue values also share a
// recursive in-process gate. Only the outermost entry opens/closes the lock
// file: closing another descriptor would release the process's advisory lock.
private final class MeetingQueueMutationGate: @unchecked Sendable {
    let lock = NSRecursiveLock()
    var depth = 0
}

private final class MeetingQueueMutationGates: @unchecked Sendable {
    static let shared = MeetingQueueMutationGates()
    private let lock = NSLock()
    private var gates: [String: MeetingQueueMutationGate] = [:]

    func gate(for path: String) -> MeetingQueueMutationGate {
        lock.lock()
        defer { lock.unlock() }
        if let gate = gates[path] { return gate }
        let gate = MeetingQueueMutationGate()
        gates[path] = gate
        return gate
    }
}

public struct LibreReverseMeetingTranscriptionJob: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let publicationXID: String
    public let segmentID: Int64
    public let videoID: Int64
    public let title: String
    public let relativeMediaPath: String
    public let createdAt: Date
    public var attempt: Int
    public var retryAfter: Date?
    public var lastError: String?

    public init(
        publicationXID: String,
        segmentID: Int64,
        videoID: Int64,
        title: String,
        relativeMediaPath: String,
        createdAt: Date = Date(),
        attempt: Int = 0,
        retryAfter: Date? = nil,
        lastError: String? = nil
    ) {
        schemaVersion = 1
        self.publicationXID = publicationXID
        self.segmentID = segmentID
        self.videoID = videoID
        self.title = title
        self.relativeMediaPath = relativeMediaPath
        self.createdAt = createdAt
        self.attempt = attempt
        self.retryAfter = retryAfter
        self.lastError = lastError
    }

    public var processingState: LibreReverseMeetingTranscriptProcessingState {
        attempt == 0 || retryAfter == nil
            ? .queued
            : .retrying(attempt: attempt, retryAfter: retryAfter)
    }

    /// Presentation state at a particular wall time. Once backoff expires the
    /// durable job is ready (and may already be running), so the follower must
    /// stop offering a redundant restart action and return to Transcribing.
    public func processingState(at date: Date) -> LibreReverseMeetingTranscriptProcessingState {
        guard let retryAfter, retryAfter > date else { return .queued }
        return .retrying(attempt: attempt, retryAfter: retryAfter)
    }
}

public enum LibreReverseMeetingTranscriptionQueueError: Error, Equatable {
    case invalidPublicationXID(String)
    case invalidMediaPath(String)
    case publicationMismatch(String)
    case missingLocalMedia(String)
    case missingJob(Int64)
    case retryNotNeeded(Int64)
    case staleJob(String)
    case mutationLockFailed(Int32)
}

public struct LibreReverseMeetingTranscriptionQueueRepair: Equatable, Sendable {
    public let recoveredPublicationXIDs: [String]
    public let retiredPublicationXIDs: [String]
    public let unresolvedFileNames: [String]

    public init(
        recoveredPublicationXIDs: [String],
        retiredPublicationXIDs: [String],
        unresolvedFileNames: [String]
    ) {
        self.recoveredPublicationXIDs = recoveredPublicationXIDs
        self.retiredPublicationXIDs = retiredPublicationXIDs
        self.unresolvedFileNames = unresolvedFileNames
    }
}

extension LibreReverseMeetingTranscriptionQueueError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPublicationXID(let xid): "Invalid transcription publication XID: \(xid)"
        case .invalidMediaPath(let path): "Invalid transcription media path: \(path)"
        case .publicationMismatch(let xid):
            "Transcription job does not match meeting publication \(xid)"
        case .missingLocalMedia(let path): "Meeting media is not local: \(path)"
        case .missingJob(let segmentID):
            "No pending transcription job exists for meeting \(segmentID)"
        case .retryNotNeeded(let segmentID):
            "Meeting \(segmentID) is already queued for transcription"
        case .staleJob(let xid):
            "Transcription job \(xid) changed before the operation completed"
        case .mutationLockFailed(let code):
            "Unable to lock the transcription queue (errno \(code))"
        }
    }
}

/// Small file-backed queue kept outside the archive-managed media tree. Jobs
/// are created immediately after canonical publication and removed only after
/// transcript words plus all search indexes commit successfully. The bundled
/// backend's encrypted window checkpoint is owned and retired with the job.
public struct LibreReverseMeetingTranscriptionQueue: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public func enqueue(_ job: LibreReverseMeetingTranscriptionJob) throws {
        try withMutationLock {
            try enqueueUnlocked(job)
        }
    }

    /// Serializes a compound library/queue transition with every queue
    /// mutation. Meeting publication and primary rollover use this boundary so
    /// a committed publication cannot appear between rollover's queue audit
    /// and its atomic database swap.
    public func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T {
        try withMutationLock(body)
    }

    func enqueueAssumingExclusiveAccess(_ job: LibreReverseMeetingTranscriptionJob) throws {
        try enqueueUnlocked(job)
    }

    private func enqueueUnlocked(_ job: LibreReverseMeetingTranscriptionJob) throws {
        try validate(job.publicationXID)
        guard
            VideoStorage.isCanonicalRelativePath(
                job.relativeMediaPath,
                xid: job.publicationXID
            )
        else {
            throw LibreReverseMeetingTranscriptionQueueError.invalidMediaPath(
                job.relativeMediaPath
            )
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let jobURL = url(for: job.publicationXID)
        if FileManager.default.fileExists(atPath: jobURL.path) {
            let existing = try decode(Data(contentsOf: jobURL))
            guard existing.publicationXID == job.publicationXID,
                existing.segmentID == job.segmentID,
                existing.videoID == job.videoID,
                existing.relativeMediaPath == job.relativeMediaPath
            else {
                throw LibreReverseMeetingTranscriptionQueueError.publicationMismatch(
                    job.publicationXID
                )
            }
            // Recovery replays an attempt-zero publication job. Preserve any
            // accumulated retry/backoff state instead of resetting it.
            if job.attempt == 0 { return }
        }
        try encode(job).write(to: jobURL, options: .atomic)
    }

    public func ready(at date: Date = Date()) throws -> [LibreReverseMeetingTranscriptionJob] {
        try pending().filter { ($0.retryAfter ?? .distantPast) <= date }
    }

    public func pending() throws -> [LibreReverseMeetingTranscriptionJob] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .compactMap { try? decode(Data(contentsOf: $0)) }
        .sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.publicationXID < $1.publicationXID
        }
    }

    /// Repairs malformed or semantically invalid job payloads only when the
    /// primary library can prove their immutable publication identity. An
    /// authenticated checkpoint is deliberately retained for unfinished work;
    /// the transcriber validates its own binding before use. Files with invalid
    /// names or no canonical publication remain byte-for-byte intact for
    /// diagnosis.
    public func repairCorruptJobs(
        configuration: LibreReverseLibraryConfiguration
    ) throws -> LibreReverseMeetingTranscriptionQueueRepair {
        try withMutationLock {
            try repairCorruptJobsAssumingExclusiveAccess(configuration: configuration)
        }
    }

    func repairCorruptJobsAssumingExclusiveAccess(
        configuration: LibreReverseLibraryConfiguration
    ) throws -> LibreReverseMeetingTranscriptionQueueRepair {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return .init(
                recoveredPublicationXIDs: [],
                retiredPublicationXIDs: [],
                unresolvedFileNames: []
            )
        }
        var recovered: [String] = []
        var retired: [String] = []
        var unresolved: [String] = []
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for jobURL in urls {
            let data = try Data(contentsOf: jobURL)
            let xid = jobURL.deletingPathExtension().lastPathComponent
            do {
                try validate(xid)
                guard
                    let publication = try LibreReverseLibraryStore.publishedMeeting(
                        xid: xid,
                        configuration: configuration
                    ),
                    VideoStorage.isCanonicalRelativePath(
                        publication.relativeMediaPath,
                        xid: xid
                    )
                else {
                    unresolved.append(jobURL.lastPathComponent)
                    continue
                }
                if publication.transcriptDocumentID != nil {
                    try FileManager.default.removeItem(at: jobURL)
                    let checkpointURL = checkpointURL(for: xid)
                    if FileManager.default.fileExists(atPath: checkpointURL.path) {
                        try FileManager.default.removeItem(at: checkpointURL)
                    }
                    retired.append(xid)
                    continue
                }
                if let decoded = try? decode(data),
                    isSemanticallyValid(
                        decoded,
                        fileXID: xid,
                        publication: publication
                    )
                {
                    continue
                }
                let title = try LibreReverseLibraryStore.meetingTitle(
                    segmentID: publication.segmentID,
                    configuration: configuration
                )
                let replacement = LibreReverseMeetingTranscriptionJob(
                    publicationXID: xid,
                    segmentID: publication.segmentID,
                    videoID: publication.videoID,
                    title: title,
                    relativeMediaPath: publication.relativeMediaPath,
                    createdAt: publication.startedAt
                )
                try encode(replacement).write(to: jobURL, options: .atomic)
                recovered.append(xid)
            } catch is LibreReverseMeetingTranscriptionQueueError {
                unresolved.append(jobURL.lastPathComponent)
            } catch let error as LibreReverseLibraryStoreError {
                guard case .invalidMeeting = error else { throw error }
                unresolved.append(jobURL.lastPathComponent)
            }
        }
        return .init(
            recoveredPublicationXIDs: recovered,
            retiredPublicationXIDs: retired,
            unresolvedFileNames: unresolved
        )
    }

    public func job(segmentID: Int64) throws -> LibreReverseMeetingTranscriptionJob? {
        try pending().first(where: { $0.segmentID == segmentID })
    }

    public func nextAttemptDate() throws -> Date? {
        try pending().map { $0.retryAfter ?? .distantPast }.min()
    }

    public func recordFailure(
        _ job: LibreReverseMeetingTranscriptionJob,
        error: Error,
        now: Date = Date()
    ) throws {
        try withMutationLock {
            guard let current = try self.job(segmentID: job.segmentID) else {
                throw LibreReverseMeetingTranscriptionQueueError.missingJob(job.segmentID)
            }
            guard current == job else {
                throw LibreReverseMeetingTranscriptionQueueError.staleJob(job.publicationXID)
            }
            var failed = job
            failed.attempt += 1
            failed.lastError = error.localizedDescription
            failed.retryAfter = now.addingTimeInterval(Self.retryDelay(attempt: failed.attempt))
            try enqueueUnlocked(failed)
        }
    }

    /// Makes one failed job immediately eligible without discarding its
    /// attempt history, diagnostic error, or encrypted window checkpoint.
    /// Segment lookup keeps a stale follower action from waking another
    /// meeting's job, while `enqueue` revalidates the publication identity.
    @discardableResult
    public func retryNow(segmentID: Int64) throws -> LibreReverseMeetingTranscriptionJob {
        try withMutationLock {
            guard var job = try self.job(segmentID: segmentID) else {
                throw LibreReverseMeetingTranscriptionQueueError.missingJob(segmentID)
            }
            guard job.attempt > 0 else {
                throw LibreReverseMeetingTranscriptionQueueError.retryNotNeeded(segmentID)
            }
            job.retryAfter = nil
            try enqueueUnlocked(job)
            return job
        }
    }

    public func complete(_ job: LibreReverseMeetingTranscriptionJob) throws {
        try withMutationLock {
            guard let current = try self.job(segmentID: job.segmentID) else {
                // Completion is idempotent after the job is gone. Clean an
                // orphaned checkpoint only when this exact XID has no newer
                // job file that could still own it.
                let jobURL = url(for: job.publicationXID)
                let checkpointURL = checkpointURL(for: job.publicationXID)
                if !FileManager.default.fileExists(atPath: jobURL.path),
                    FileManager.default.fileExists(atPath: checkpointURL.path)
                {
                    try FileManager.default.removeItem(at: checkpointURL)
                }
                return
            }
            guard current.publicationXID == job.publicationXID,
                current.segmentID == job.segmentID,
                current.videoID == job.videoID,
                current.relativeMediaPath == job.relativeMediaPath
            else {
                throw LibreReverseMeetingTranscriptionQueueError.staleJob(job.publicationXID)
            }
            let checkpointURL = checkpointURL(for: job.publicationXID)
            if FileManager.default.fileExists(atPath: checkpointURL.path) {
                try FileManager.default.removeItem(at: checkpointURL)
            }
            let jobURL = url(for: job.publicationXID)
            if FileManager.default.fileExists(atPath: jobURL.path) {
                try FileManager.default.removeItem(at: jobURL)
            }
        }
    }

    /// Removes queue state after a user-authorized meeting deletion commits.
    /// The deletion journal supplies the canonical XID/path pair, so cleanup
    /// does not need to decode a job that may itself be malformed. Restricting
    /// removal to that exact XID also makes interrupted cleanup idempotent.
    public func removeDeletedPublication(
        publicationXID: String,
        relativeMediaPath: String
    ) throws {
        try withMutationLock {
            // A publication with an XID outside the queue filename alphabet cannot
            // own a queue artifact, so its deletion cleanup is an idempotent no-op.
            do {
                try validate(publicationXID)
            } catch LibreReverseMeetingTranscriptionQueueError.invalidPublicationXID {
                return
            }
            guard
                VideoStorage.isCanonicalRelativePath(
                    relativeMediaPath,
                    xid: publicationXID
                )
            else {
                throw LibreReverseMeetingTranscriptionQueueError.invalidMediaPath(
                    relativeMediaPath
                )
            }
            for artifactURL in [
                url(for: publicationXID),
                checkpointURL(for: publicationXID),
            ] where FileManager.default.fileExists(atPath: artifactURL.path) {
                try FileManager.default.removeItem(at: artifactURL)
            }
        }
    }

    public func checkpointContext(
        for job: LibreReverseMeetingTranscriptionJob,
        encryptionKeyURL: URL
    ) -> MeetingTranscriptionCheckpointContext {
        .init(
            identifier: job.publicationXID,
            url: checkpointURL(for: job.publicationXID),
            encryptionKeyURL: encryptionKeyURL
        )
    }

    public static func retryDelay(attempt: Int) -> TimeInterval {
        min(6 * 60 * 60, 30 * pow(2, Double(max(0, min(attempt - 1, 10)))))
    }

    private func url(for xid: String) -> URL {
        root.appendingPathComponent(xid).appendingPathExtension("json")
    }

    private func checkpointURL(for xid: String) -> URL {
        root.appendingPathComponent(xid).appendingPathExtension("checkpoint")
    }

    private func validate(_ xid: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !xid.isEmpty, xid.unicodeScalars.allSatisfy(allowed.contains) else {
            throw LibreReverseMeetingTranscriptionQueueError.invalidPublicationXID(xid)
        }
    }

    private func isSemanticallyValid(
        _ job: LibreReverseMeetingTranscriptionJob,
        fileXID: String,
        publication: LibreReversePublishedMeeting
    ) -> Bool {
        guard job.schemaVersion == 1,
            job.publicationXID == fileXID,
            job.segmentID == publication.segmentID,
            job.videoID == publication.videoID,
            job.relativeMediaPath == publication.relativeMediaPath,
            job.segmentID > 0,
            job.videoID > 0,
            job.attempt >= 0,
            job.createdAt.timeIntervalSinceReferenceDate.isFinite,
            job.retryAfter?.timeIntervalSinceReferenceDate.isFinite != false
        else { return false }
        if job.attempt == 0 {
            return job.retryAfter == nil && job.lastError == nil
        }
        return job.lastError?.isEmpty == false
    }

    /// Serializes read/compare/write transitions across tasks and processes.
    /// Job payloads are still atomically replaced, while this advisory lock
    /// closes the gap between reading the current snapshot and installing its
    /// successor.
    private func withMutationLock<T>(_ body: () throws -> T) throws -> T {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let parent = canonicalRoot.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // Keep the lock beside the queue directory. This lets the lock still
        // guard recovery when the queue path itself is missing, corrupt, or
        // accidentally occupied by a regular file.
        let lockURL = parent.appendingPathComponent(".\(canonicalRoot.lastPathComponent).lock")
        let gate = MeetingQueueMutationGates.shared.gate(
            for: lockURL.resolvingSymlinksInPath().standardizedFileURL.path
        )
        gate.lock.lock()
        defer { gate.lock.unlock() }
        if gate.depth > 0 { return try body() }
        gate.depth += 1
        defer { gate.depth -= 1 }
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw LibreReverseMeetingTranscriptionQueueError.mutationLockFailed(errno)
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw LibreReverseMeetingTranscriptionQueueError.mutationLockFailed(errno)
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }

    private func encode(_ job: LibreReverseMeetingTranscriptionJob) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(job)
    }

    private func decode(_ data: Data) throws -> LibreReverseMeetingTranscriptionJob {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibreReverseMeetingTranscriptionJob.self, from: data)
    }
}

public struct LibreReverseMeetingTranscriptionRun: Equatable, Sendable {
    public let completed: Int
    public let failed: Int
}

/// Generation ownership for the app's long-lived queue runner. Restarting a
/// cancelled task is intentionally immediate, but the predecessor can finish
/// later; only the newest generation may clear the stored runner handle.
/// Library mutations temporarily close admission so an edit cannot orphan a
/// replacement runner while it waits for the predecessor to stop.
public struct LibreReverseMeetingTranscriptionSchedulerState: Equatable, Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var libraryMutationDepth = 0

    public init() {}

    public mutating func beginRunner() -> UInt64? {
        guard libraryMutationDepth == 0 else { return nil }
        generation &+= 1
        return generation
    }

    public mutating func beginLibraryMutation() {
        libraryMutationDepth += 1
        generation &+= 1
    }

    public mutating func endLibraryMutation() {
        precondition(libraryMutationDepth > 0, "unbalanced transcription library mutation")
        libraryMutationDepth -= 1
    }

    public func owns(_ runnerGeneration: UInt64) -> Bool {
        libraryMutationDepth == 0 && generation == runnerGeneration
    }
}

public actor LibreReverseMeetingTranscriptionRunner {
    public typealias MediaResolver = @Sendable (Int64, URL) async throws -> URL

    private let queue: LibreReverseMeetingTranscriptionQueue
    private let library: LibreReverseLibraryConfiguration
    private let transcriber: any MeetingTranscriber
    private let mediaResolver: MediaResolver?

    public init(
        queue: LibreReverseMeetingTranscriptionQueue,
        library: LibreReverseLibraryConfiguration,
        transcriber: any MeetingTranscriber,
        mediaResolver: MediaResolver? = nil
    ) {
        self.queue = queue
        self.library = library
        self.transcriber = transcriber
        self.mediaResolver = mediaResolver
    }

    public func runReady(at now: Date = Date()) async -> LibreReverseMeetingTranscriptionRun {
        guard (try? queue.repairCorruptJobs(configuration: library)) != nil else {
            return .init(completed: 0, failed: 0)
        }
        guard let jobs = try? queue.ready(at: now) else {
            return .init(completed: 0, failed: 0)
        }
        var completed = 0
        var failed = 0
        for job in jobs {
            if Task.isCancelled { break }
            do {
                guard
                    try LibreReverseLibraryStore.meetingPublicationMatches(
                        xid: job.publicationXID,
                        segmentID: job.segmentID,
                        videoID: job.videoID,
                        relativeMediaPath: job.relativeMediaPath,
                        configuration: library
                    )
                else {
                    throw LibreReverseMeetingTranscriptionQueueError.publicationMismatch(
                        job.publicationXID
                    )
                }
                let canonical = library.mediaRoot.appendingPathComponent(job.relativeMediaPath)
                let resolved = try await LibreReverseResolvedMedia.acquire(
                    videoID: job.videoID,
                    canonicalURL: canonical,
                    library: library,
                    resolver: mediaResolver
                )
                defer { resolved.lease.release() }
                let mediaURL = resolved.url
                let service = MeetingTranscriptCaptureService(
                    transcriber: transcriber,
                    clock: .rewind15607,
                    speechSource: "unknown"
                )
                // The queue title is publication-time diagnostic context. A
                // user may rename the meeting while this durable job waits, so
                // the canonical segment title must win at commit time.
                let currentTitle = try LibreReverseLibraryStore.meetingTitle(
                    segmentID: job.segmentID,
                    configuration: library
                )
                _ = try await service.transcribeAndPersist(
                    mediaURL: mediaURL,
                    segmentID: job.segmentID,
                    title: currentTitle,
                    configuration: library,
                    checkpoint: queue.checkpointContext(
                        for: job,
                        encryptionKeyURL: library.keyFileURL
                    )
                )
                try LibreReverseLibraryStore.enqueueMeetingSummary(segmentID: job.segmentID, configuration: library)
                try queue.complete(job)
                completed += 1
            } catch is CancellationError {
                break
            } catch {
                // Some subprocess and resolver adapters translate cancellation
                // into their own error type. A superseded runner must never
                // turn that translated error into a fresh backoff record.
                if Task.isCancelled { break }
                try? queue.recordFailure(job, error: error, now: now)
                failed += 1
            }
        }
        return .init(completed: completed, failed: failed)
    }
}
#endif
