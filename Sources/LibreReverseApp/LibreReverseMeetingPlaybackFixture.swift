#if os(macOS)
import Foundation
import LibreReverseCore

/// UI-validation-only resolver used by the early-launch signed playback fixture.
/// It copies a caller-owned A/V fixture into an isolated temporary library and
/// deliberately has no access to the user's library, credentials, or Drive.
actor LibreReverseMeetingPlaybackFixtureResolver: LocalMediaResolving {
    private let sourceURL: URL
    private let destinationURL: URL

    init(sourceURL: URL, destinationURL: URL) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
    }

    func resolve(videoID: Int64) async throws -> URL {
        try install()
    }

    func restoreMoment(
        videoID: Int64,
        progress: @escaping @Sendable (LibreReverseDayRestoreProgress) async -> Void
    ) async throws -> URL {
        try await restoreDay(containing: Date(), selectedVideoID: videoID, progress: progress)
    }

    func prefetchAround(videoID: Int64) async {}

    func restoreDay(
        containing date: Date,
        selectedVideoID: Int64,
        progress: @escaping @Sendable (LibreReverseDayRestoreProgress) async -> Void
    ) async throws -> URL {
        let byteCount = Int64(
            (try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        await progress(
            .init(
                completedBytes: 0,
                totalBytes: byteCount,
                currentRelativePath: destinationURL.lastPathComponent
            )
        )
        let installed = try install()
        await progress(
            .init(
                completedBytes: byteCount,
                totalBytes: byteCount,
                currentRelativePath: destinationURL.lastPathComponent
            )
        )
        return installed
    }

    private func install() throws -> URL {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }
}
#endif
