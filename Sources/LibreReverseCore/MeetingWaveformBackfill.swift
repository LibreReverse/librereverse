#if os(macOS)
import CSQLCipher
import Foundation

/// Explicit maintenance for old immutable recordings. Playback never calls this.
public enum MeetingWaveformBackfill {
    public struct Candidate: Equatable, Sendable {
        public let videoID: Int64
        public let url: URL
    }

    public struct Progress: Codable, Sendable {
        public var completed: [String: Date] = [:]
        public var failures: [String: String] = [:]
        public init() {}
    }

    /// The primary catalog retains every video through shard rotation, including
    /// the captureType discriminator. No shard hydration or media download occurs.
    public static func candidates(configuration: LibreReverseLibraryConfiguration) throws -> [Candidate] {
        let key = try Data(contentsOf: configuration.keyFileURL)
        var raw: OpaquePointer?
        guard sqlite3_open_v2(configuration.databaseURL.path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database = raw else {
            if let raw { sqlite3_close(raw) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        guard key.withUnsafeBytes({ sqlite3_key(database, $0.baseAddress, Int32($0.count)) }) == SQLITE_OK else {
            throw CocoaError(.fileReadNoPermission)
        }
        sqlite3_busy_timeout(database, 5_000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "SELECT id,path FROM video WHERE captureType='meeting' ORDER BY id", -1, &statement, nil) == SQLITE_OK,
            let statement else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        let root = configuration.mediaRoot.resolvingSymlinksInPath().standardizedFileURL
        var result: [Candidate] = []
        while true {
            let state = sqlite3_step(statement)
            if state == SQLITE_DONE { return result }
            guard state == SQLITE_ROW, let path = sqlite3_column_text(statement, 1) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let relative = String(cString: path)
            guard !relative.hasPrefix("/") else { continue }
            let url = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            result.append(Candidate(videoID: sqlite3_column_int64(statement, 0), url: url))
        }
    }

    /// One serial pass. The index is the idempotent checkpoint; this small report
    /// distinguishes successful items from retryable failures without suppressing
    /// re-preparation when a recording's content changes or an index is removed.
    @discardableResult
    public static func run(
        configuration: LibreReverseLibraryConfiguration,
        shouldPause: @escaping @Sendable () async -> Bool = { false },
        prepare: @escaping @Sendable (URL) async throws -> Void = { url in
            _ = try await MeetingWaveformMetadata.prepareLegacyIndex(forLocalMediaURL: url)
        }
    ) async throws -> Progress {
        let reportURL = configuration.databaseURL.deletingLastPathComponent()
            .appendingPathComponent("meeting-waveform-backfill-v1.json")
        var progress = (try? JSONDecoder().decode(Progress.self, from: Data(contentsOf: reportURL))) ?? Progress()
        for candidate in try candidates(configuration: configuration) {
            try Task.checkCancellation()
            while await shouldPause() {
                try await Task.sleep(for: .seconds(5))
            }
            let id = String(candidate.videoID)
            do {
                // The lease prevents archive eviction during the explicit decode.
                let lease = try LibreReverseMediaLease(videoID: candidate.videoID, library: configuration)
                defer { lease.release() }
                try await prepare(candidate.url)
                progress.completed[id] = Date()
                progress.failures.removeValue(forKey: id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                progress.completed.removeValue(forKey: id)
                progress.failures[id] = error.localizedDescription
            }
            try JSONEncoder().encode(progress).write(to: reportURL, options: .atomic)
            try await Task.sleep(for: .seconds(1))
        }
        return progress
    }
}
#endif
