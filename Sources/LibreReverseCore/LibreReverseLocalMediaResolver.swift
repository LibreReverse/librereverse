#if os(macOS)
import Foundation

public protocol LocalMediaResolving: Sendable {
    func resolve(videoID: Int64) async throws -> URL
    func restoreMoment(
        videoID: Int64,
        progress: @escaping @Sendable (LibreReverseDayRestoreProgress) async -> Void
    ) async throws -> URL
    func prefetchAround(videoID: Int64) async
    func restoreDay(
        containing date: Date,
        selectedVideoID: Int64,
        progress: @escaping @Sendable (LibreReverseDayRestoreProgress) async -> Void
    ) async throws -> URL
}

/// A local URL whose residency is protected until its lease is released.
/// Restoration takes place without a lease; acquisition then competes atomically
/// with eviction's present-to-staged transition. A losing acquisition retries
/// resolution rather than returning an unprotected URL.
public struct LibreReverseResolvedMedia: Sendable {
    public let url: URL
    public let lease: LibreReverseMediaLease

    public static func acquire(
        videoID: Int64,
        canonicalURL: URL,
        library: LibreReverseLibraryConfiguration,
        resolver: (@Sendable (Int64, URL) async throws -> URL)? = nil
    ) async throws -> Self {
        var candidate = canonicalURL
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let lease = try LibreReverseMediaLease(videoID: videoID, library: library)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return .init(url: candidate, lease: lease)
                }
                lease.release()
            } catch LibreReverseArchiveStoreError.mediaLeaseUnavailable {
                // Eviction or restoration currently owns residency.
            }
            guard attempt < 2, let resolver else {
                throw LibreReverseArchiveStoreError.mediaLeaseUnavailable(videoID)
            }
            candidate = try await resolver(videoID, canonicalURL)
        }
        throw LibreReverseArchiveStoreError.mediaLeaseUnavailable(videoID)
    }
}

public enum LibreReverseArchiveRehydrationPolicy {
    public static func localHour(containing date: Date) -> DateInterval {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        let end = calendar.date(byAdding: .hour, value: 1, to: start)
            ?? start.addingTimeInterval(3_600)
        return DateInterval(start: start, end: end)
    }

    public static func localDay(containing date: Date) -> DateInterval {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }
}

public struct LibreReverseDayRestoreProgress: Equatable, Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let currentRelativePath: String

    public init(completedBytes: Int64, totalBytes: Int64, currentRelativePath: String) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.currentRelativePath = currentRelativePath
    }
}

public enum LibreReverseLocalMediaResolverError: Error, LocalizedError {
    case remoteMediaUnavailable(Int64)
    case integrityMismatch(Int64)

    public var errorDescription: String? {
        switch self {
        case let .remoteMediaUnavailable(videoID): "Archived video \(videoID) is not available remotely."
        case let .integrityMismatch(videoID): "Downloaded video \(videoID) failed integrity verification."
        }
    }
}

private actor LibreReverseDownloadPermitPool {
    private var available: Int
    private var foregroundWaiters: [CheckedContinuation<Void, Never>] = []
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = max(1, limit) }

    func acquire(foreground: Bool) async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation {
            if foreground {
                foregroundWaiters.append($0)
            } else {
                backgroundWaiters.append($0)
            }
        }
    }

    func release() {
        if !foregroundWaiters.isEmpty {
            foregroundWaiters.removeFirst().resume()
        } else if !backgroundWaiters.isEmpty {
            backgroundWaiters.removeFirst().resume()
        } else { available += 1 }
    }
}

public actor LibreReverseLocalMediaResolver: LocalMediaResolving {
    private let destinationID: Int64
    private let library: LibreReverseLibraryConfiguration
    private let backend: any ArchiveBackend
    private let fileManager: FileManager
    private let downloadPermits: LibreReverseDownloadPermitPool
    private var inFlight: [Int64: Task<URL, Error>] = [:]
    private var retired = false
    private var neighborhoodPrefetch: Task<Void, Never>?

    public init(
        destinationID: Int64,
        library: LibreReverseLibraryConfiguration,
        backend: any ArchiveBackend,
        maximumConcurrentDownloads: Int = 2,
        fileManager: FileManager = .default
    ) {
        self.destinationID = destinationID
        self.library = library
        self.backend = backend
        self.fileManager = fileManager
        self.downloadPermits = LibreReverseDownloadPermitPool(limit: maximumConcurrentDownloads)
        let rehydrationRoot = library.mediaRoot
            .deletingLastPathComponent()
            .appendingPathComponent("Rehydration", isDirectory: true)
        if let entries = try? fileManager.contentsOfDirectory(
            at: rehydrationRoot,
            includingPropertiesForKeys: nil
        ) {
            for entry in entries where entry.pathExtension == "partial" {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    public func cancelAll() {
        neighborhoodPrefetch?.cancel()
        for task in inFlight.values { task.cancel() }
    }

    public func stopAcceptingWork() {
        retired = true
        cancelAll()
    }

    /// Drain old provider reads before another destination can mutate residency.
    public func cancelAllAndWait() async {
        stopAcceptingWork()
        let prefetch = neighborhoodPrefetch
        let tasks = Array(inFlight.values)
        cancelAll()
        await prefetch?.value
        for task in tasks { _ = try? await task.value }
    }

    public func restoreMoment(
        videoID: Int64,
        progress: @escaping @Sendable (LibreReverseDayRestoreProgress) async -> Void
    ) async throws -> URL {
        guard let remote = try LibreReverseArchiveStore.verifiedRemoteMedia(
            videoID: videoID,
            destinationID: destinationID,
            configuration: library
        ) else {
            throw LibreReverseLocalMediaResolverError.remoteMediaUnavailable(videoID)
        }
        await progress(.init(
            completedBytes: 0,
            totalBytes: remote.integrity.byteCount,
            currentRelativePath: remote.relativePath
        ))
        let result = try await resolve(videoID: videoID, foreground: true) { completedBytes in
            await progress(.init(
                completedBytes: completedBytes,
                totalBytes: remote.integrity.byteCount,
                currentRelativePath: remote.relativePath
            ))
        }
        await progress(.init(
            completedBytes: remote.integrity.byteCount,
            totalBytes: remote.integrity.byteCount,
            currentRelativePath: remote.relativePath
        ))
        await prefetchAround(videoID: videoID)
        return result
    }

    public func prefetchAround(videoID: Int64) async {
        guard !retired else { return }
        neighborhoodPrefetch?.cancel()
        guard let entries = try? LibreReverseArchiveStore.verifiedRemoteVideos(
            centeredOn: videoID,
            destinationID: destinationID,
            limit: 9,
            configuration: library
        ) else { return }
        let resolver = self
        neighborhoodPrefetch = Task(priority: .utility) {
            // One-at-a-time prefetch leaves a download permit free for a new
            // cursor target. Cancellation changes the neighborhood only after
            // the current file finishes, so scrolling never tears a file down.
            for entry in entries where entry.videoID != videoID {
                guard !Task.isCancelled else { return }
                _ = try? await resolver.resolve(
                    videoID: entry.videoID,
                    foreground: false
                ) { _ in }
            }
        }
    }

    public func restoreDay(
        containing date: Date,
        selectedVideoID: Int64,
        progress: @escaping @Sendable (LibreReverseDayRestoreProgress) async -> Void
    ) async throws -> URL {
        let interval = LibreReverseArchiveRehydrationPolicy.localHour(containing: date)
        let available = try LibreReverseArchiveStore.verifiedRemoteVideos(
            in: interval,
            destinationID: destinationID,
            configuration: library
        )
        guard let selected = available.first(where: { $0.videoID == selectedVideoID }) else {
            throw LibreReverseLocalMediaResolverError.remoteMediaUnavailable(selectedVideoID)
        }
        let ordered = [selected] + available
            .filter { $0.videoID != selectedVideoID }
            .sorted {
                let lhs = abs($0.videoID - selectedVideoID)
                let rhs = abs($1.videoID - selectedVideoID)
                return lhs == rhs ? $0.videoID < $1.videoID : lhs < rhs
            }
        let byteLimit = LibreReverseArchivePolicy.defaultRehydratedCacheBytes
        var entries: [LibreReverseRemoteDayVideo] = []
        var totalBytes: Int64 = 0
        for entry in ordered where entry.byteCount <= byteLimit - totalBytes {
            entries.append(entry)
            totalBytes += entry.byteCount
        }
        let hourTotalBytes = totalBytes
        var completedBytes: Int64 = 0
        var selectedURL: URL?
        for entry in entries {
            await progress(.init(
                completedBytes: completedBytes,
                totalBytes: hourTotalBytes,
                currentRelativePath: entry.relativePath
            ))
            let base = completedBytes
            do {
                let url = try await resolve(
                    videoID: entry.videoID,
                    foreground: false
                ) { fileBytes in
                    await progress(.init(
                        completedBytes: min(hourTotalBytes, base + fileBytes),
                        totalBytes: hourTotalBytes,
                        currentRelativePath: entry.relativePath
                    ))
                }
                if entry.videoID == selectedVideoID { selectedURL = url }
                completedBytes += entry.byteCount
            } catch {
                if error is CancellationError { throw error }
                // The selected recording is the foreground contract. Once it
                // is available, a later neighboring-file failure must not put
                // the cursor back behind a Download button. That independent
                // file remains eligible for a later retry or adjacent prefetch.
                if entry.videoID == selectedVideoID { throw error }
            }
        }
        guard let selectedURL else {
            throw LibreReverseLocalMediaResolverError.remoteMediaUnavailable(selectedVideoID)
        }
        return selectedURL
    }

    public func resolve(videoID: Int64) async throws -> URL {
        try await resolve(videoID: videoID, foreground: true) { _ in }
    }

    private func resolve(
        videoID: Int64,
        foreground: Bool,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> URL {
        guard !retired else { throw CancellationError() }
        if let task = inFlight[videoID] { return try await task.value }
        guard let remote = try LibreReverseArchiveStore.verifiedRemoteMedia(
            videoID: videoID,
            destinationID: destinationID,
            configuration: library
        ) else {
            throw LibreReverseLocalMediaResolverError.remoteMediaUnavailable(videoID)
        }
        let canonical = library.mediaRoot.appendingPathComponent(remote.relativePath)
        if fileManager.fileExists(atPath: canonical.path) {
            try LibreReverseArchiveStore.markRehydrated(videoID: videoID, configuration: library)
            await progress(remote.integrity.byteCount)
            return canonical
        }
        try LibreReverseArchiveStore.beginRehydration(videoID: videoID, configuration: library)
        let backend = self.backend
        let library = self.library
        let destinationID = self.destinationID
        let fileManager = self.fileManager
        let downloadPermits = self.downloadPermits
        let task = Task.detached(priority: .utility) { () throws -> URL in
            await downloadPermits.acquire(foreground: foreground)
            do {
                try Task.checkCancellation()
                let rehydrationRoot = library.mediaRoot
                    .deletingLastPathComponent()
                    .appendingPathComponent("Rehydration", isDirectory: true)
                try fileManager.createDirectory(at: rehydrationRoot, withIntermediateDirectories: true)
                let temporary = rehydrationRoot.appendingPathComponent("\(videoID).\(UUID().uuidString).partial")
                defer { try? fileManager.removeItem(at: temporary) }
                try await backend.download(remote.metadata, to: temporary, progress: progress)
                try Task.checkCancellation()
                let integrity = try await Task.detached(priority: .utility) {
                    try ArchiveIntegrityEngine.hash(file: temporary)
                }.value
                try Task.checkCancellation()
                guard integrity == remote.integrity else {
                    await backend.releaseDownloadedCopy(remote.metadata, temporaryURL: temporary)
                    throw LibreReverseLocalMediaResolverError.integrityMismatch(videoID)
                }
                try LibreReverseArchiveStore.markRehydrationInstalling(
                    videoID: videoID,
                    configuration: library
                )
                try Task.checkCancellation()
                try fileManager.createDirectory(
                    at: canonical.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: canonical.path) {
                    try fileManager.removeItem(at: temporary)
                } else {
                    try fileManager.moveItem(at: temporary, to: canonical)
                }
                try LibreReverseArchiveStore.markRehydrated(videoID: videoID, configuration: library)
                await backend.releaseDownloadedCopy(remote.metadata, temporaryURL: temporary)
                await downloadPermits.release()
                return canonical
            } catch {
                try? LibreReverseArchiveStore.recordRehydrationFailure(
                    videoID: videoID,
                    error: error,
                    configuration: library
                )
                if case let ArchiveBackendError.requestFailed(status, _) = error,
                   status == 404 || status == 410 {
                    try? LibreReverseArchiveStore.recordVerifiedRemoteUnavailable(
                        videoID: videoID,
                        destinationID: destinationID,
                        error: error,
                        configuration: library
                    )
                }
                await downloadPermits.release()
                throw error
            }
        }
        inFlight[videoID] = task
        defer { inFlight[videoID] = nil }
        return try await task.value
    }
}
#endif
