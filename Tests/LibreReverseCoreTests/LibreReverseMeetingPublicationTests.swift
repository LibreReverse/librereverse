#if os(macOS)
import AVFoundation
import CSQLCipher
import CoreVideo
import Foundation
import XCTest
@testable import LibreReverseCore

final class LibreReverseMeetingPublicationTests: XCTestCase {
    private struct StubTranscriber: MeetingTranscriber {
        let result: MeetingTranscriptionResult

        func transcribe(mediaURL: URL) async throws -> MeetingTranscriptionResult { result }
    }

    private struct FailingTranscriber: MeetingTranscriber {
        struct Failure: Error {}
        func transcribe(mediaURL: URL) async throws -> MeetingTranscriptionResult {
            throw Failure()
        }
    }

    private actor CheckpointingStubTranscriber: CheckpointingMeetingTranscriber {
        let result: MeetingTranscriptionResult
        private var received: MeetingTranscriptionCheckpointContext?

        init(result: MeetingTranscriptionResult) { self.result = result }

        func transcribe(mediaURL: URL) async throws -> MeetingTranscriptionResult { result }

        func transcribe(mediaURL: URL, checkpoint: MeetingTranscriptionCheckpointContext)
            async throws -> MeetingTranscriptionResult
        {
            received = checkpoint
            try Data("durable partial progress".utf8).write(to: checkpoint.url, options: .atomic)
            return result
        }

        func receivedCheckpoint() -> MeetingTranscriptionCheckpointContext? { received }
    }

    private actor BlockingTranscriber: MeetingTranscriber {
        private let result: MeetingTranscriptionResult
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        init(result: MeetingTranscriptionResult) { self.result = result }

        func transcribe(mediaURL: URL) async throws -> MeetingTranscriptionResult {
            started = true
            for waiter in startWaiters { waiter.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { releaseContinuation = $0 }
            return result
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private actor CancellationTranslatingTranscriber: MeetingTranscriber {
        struct Failure: Error {}
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func transcribe(mediaURL: URL) async throws -> MeetingTranscriptionResult {
            started = true
            for waiter in startWaiters { waiter.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { releaseContinuation = $0 }
            throw Failure()
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private actor MeetingArchiveBackend: ArchiveBackend {
        nonisolated let kind: ArchiveBackendKind = .googleDrive
        private var requests: [ArchiveObjectKey: ArchiveUploadRequest] = [:]
        private var objects: [ArchiveObjectKey: Data] = [:]
        private var shouldFailRemoval = false

        func failRemoval(_ shouldFail: Bool) { shouldFailRemoval = shouldFail }

        func locate(_ key: ArchiveObjectKey) async throws -> RemoteObjectMetadata? {
            guard let request = requests[key], objects[key] != nil else { return nil }
            return metadata(for: request)
        }

        func beginUpload(_ request: ArchiveUploadRequest) async throws -> ArchiveUploadSession {
            requests[request.key] = request
            return .init(
                identifier: "meeting://\(request.key.value)", key: request.key,
                totalBytes: request.integrity.byteCount)
        }

        func resumeUpload(
            _ session: ArchiveUploadSession, from file: URL,
            checkpoint: @Sendable (ArchiveUploadSession) async throws -> Void
        ) async throws -> ArchiveUploadResult {
            let data = try Data(contentsOf: file)
            objects[session.key] = data
            try await checkpoint(
                .init(
                    identifier: session.identifier, key: session.key,
                    acknowledgedBytes: Int64(data.count), totalBytes: session.totalBytes))
            return .init(metadata: metadata(for: try XCTUnwrap(requests[session.key])))
        }

        func verify(_ remote: RemoteObjectMetadata, expected: ArchiveIntegrity) async throws
            -> RemoteVerification
        {
            let request = try XCTUnwrap(requests[remote.key])
            return .init(
                metadata: metadata(for: request),
                matches: objects[remote.key] != nil && request.integrity == expected)
        }

        func download(
            _ remote: RemoteObjectMetadata, to temporaryURL: URL,
            progress: @escaping @Sendable (Int64) async -> Void
        ) async throws {
            let data = try XCTUnwrap(objects[remote.key])
            try data.write(to: temporaryURL)
            await progress(Int64(data.count))
        }

        func remove(_ remote: RemoteObjectMetadata) async throws {
            if shouldFailRemoval {
                throw ArchiveBackendError.requestFailed(
                    status: 503, message: "injected removal failure")
            }
            objects[remote.key] = nil
        }

        private func metadata(for request: ArchiveUploadRequest) -> RemoteObjectMetadata {
            .init(
                identifier: "remote-\(request.subjectID)", version: "1", key: request.key,
                byteCount: request.integrity.byteCount, sha256: request.integrity.sha256)
        }
    }

    private actor MeetingShardRestorer: LibreReverseMeetingShardRestoring {
        let ordinal: Int64
        let shardID: Int64
        let parkedURL: URL
        let canonicalURL: URL
        let library: LibreReverseLibraryConfiguration

        init(
            ordinal: Int64, shardID: Int64, parkedURL: URL, canonicalURL: URL,
            library: LibreReverseLibraryConfiguration
        ) {
            self.ordinal = ordinal
            self.shardID = shardID
            self.parkedURL = parkedURL
            self.canonicalURL = canonicalURL
            self.library = library
        }

        func restoreForMeetingDeletion(ordinal requested: Int64) async throws -> URL {
            XCTAssertEqual(requested, ordinal)
            try FileManager.default.moveItem(at: parkedURL, to: canonicalURL)
            try LibreReverseShardArchiveStore.setShardState(
                shardID: shardID, from: .remoteOnly, to: .sealedLocal, configuration: library)
            return canonicalURL
        }
    }

    func testCompletedStagedCapturePublishesThroughCanonicalMeetingGraph() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive", remoteRoot: "rewind", configuration: library)
        let staging = root.appendingPathComponent("staging/meeting.mp4")
        try FileManager.default.createDirectory(
            at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([4, 3, 2, 1]).write(to: staging)
        let start = Date(timeIntervalSince1970: 1_700_100_000)
        let candidate = LibreReverseMeetingCandidate(
            provider: .googleMeet, source: .windowDetection, windowID: 77, processIdentifier: 88,
            bundleIdentifier: "com.google.Chrome", title: "Weekly sync",
            url: URL(string: "https://meet.google.com/abc-defg-hij"), calendarEventID: "event-77",
            calendarID: "calendar-work", calendarSeriesID: "series-weekly", calendarTitle: "Work",
            calendarParticipants: ["Ada", "Grace"])
        let published = try LibreReverseMeetingCaptureFinalizer.publish(
            .init(
                stagingMediaURL: staging,
                manifest: completedManifest(staging: staging, start: start), candidate: candidate,
                transcript: .init(
                    text: "hello", language: "en",
                    words: [
                        .init(
                            text: "hello", startSeconds: 1.8, endSeconds: 2.2,
                            fullTextUTF16Offset: 0)
                    ])), configuration: library)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM segment WHERE id=\(published.segmentID) AND type=1"),
            1)
        XCTAssertEqual(
            try scalar(
                library,
                "SELECT COUNT(*) FROM transcript_word WHERE segmentId=\(published.segmentID) AND timeOffset=1"
            ), 1)
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM archive_object WHERE videoId=\(published.videoID)"),
            1)
        XCTAssertEqual(
            try scalar(
                library,
                """
                SELECT COUNT(*) FROM event
                 WHERE segmentID=\(published.segmentID)
                   AND title='Weekly sync'
                   AND calendarID='calendar-work'
                   AND calendarEventID='event-77'
                   AND calendarSeriesID='series-weekly'
                   AND participants='["Ada","Grace"]'
                   AND detailsJSON LIKE '%"calendarTitle":"Work"%'
                   AND detailsJSON LIKE '%"provider":"googleMeet"%'
                """), 1)
    }

    func testPublicationRetainsJournalBoundaryUntilTranscriptionQueueIsDurable() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let stagingDirectory = root.appendingPathComponent("staging-retry", isDirectory: true)
        let staging = stagingDirectory.appendingPathComponent("meeting.mp4")
        try FileManager.default.createDirectory(
            at: stagingDirectory, withIntermediateDirectories: true)
        try Data([4, 3, 2, 1]).write(to: staging)
        let start = Date(timeIntervalSince1970: 1_700_100_500)
        let xid = XID.generate(at: start)
        let journal = LibreReverseMeetingCaptureJournal(
            publicationXID: xid,
            candidate: .init(
                provider: .zoom, source: .windowDetection, windowID: 501,
                title: "Retry-safe transcript"))
        try journal.write(to: stagingDirectory)
        let queueRoot = root.appendingPathComponent("blocked-transcription-queue")
        try Data("not a directory".utf8).write(to: queueRoot)
        let queue = LibreReverseMeetingTranscriptionQueue(root: queueRoot)
        let capture = LibreReverseFinalizedMeetingCapture(
            stagingMediaURL: staging, manifest: completedManifest(staging: staging, start: start),
            candidate: journal.candidate, publicationXID: xid)

        XCTAssertThrowsError(
            try LibreReverseMeetingPublicationPipeline.publishAndEnqueue(
                capture, configuration: library, transcriptionQueue: queue))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: stagingDirectory.appendingPathComponent(
                    LibreReverseMeetingCaptureJournal.fileName
                ).path))
        let committed = try XCTUnwrap(
            LibreReverseLibraryStore.publishedMeeting(xid: xid, configuration: library))

        try FileManager.default.removeItem(at: queueRoot)
        let retried = try LibreReverseMeetingPublicationPipeline.publishAndEnqueue(
            capture, configuration: library, transcriptionQueue: queue)
        XCTAssertEqual(retried, committed)
        let job = try XCTUnwrap(queue.job(segmentID: retried.segmentID))
        XCTAssertEqual(job.publicationXID, xid)
        XCTAssertEqual(job.videoID, retried.videoID)
        XCTAssertEqual(job.title, "Retry-safe transcript")
        XCTAssertEqual(
            job.relativeMediaPath, VideoStorage.relativePath(xid: xid, date: start))

        struct RetryFailure: LocalizedError { var errorDescription: String? { "retry me" } }
        try queue.recordFailure(job, error: RetryFailure(), now: start)
        _ = try LibreReverseMeetingPublicationPipeline.publishAndEnqueue(
            capture, configuration: library, transcriptionQueue: queue)
        XCTAssertEqual(try queue.job(segmentID: retried.segmentID)?.attempt, 1)

        _ = try LibreReverseLibraryStore.replaceMeetingTranscript(
            segmentID: retried.segmentID, title: "Retry-safe transcript", transcriptText: "",
            words: [], configuration: library)
        try queue.complete(try XCTUnwrap(queue.job(segmentID: retried.segmentID)))
        _ = try LibreReverseMeetingPublicationPipeline.publishAndEnqueue(
            capture, configuration: library, transcriptionQueue: queue)
        XCTAssertTrue(try queue.pending().isEmpty)
    }

    func testPublicationReclaimsUnownedCanonicalMediaAfterIndeterminateCommit() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let stagingDirectory = root.appendingPathComponent(
            "staging-indeterminate", isDirectory: true)
        let staging = stagingDirectory.appendingPathComponent("meeting.mp4")
        try FileManager.default.createDirectory(
            at: stagingDirectory, withIntermediateDirectories: true)
        let payload = Data([9, 8, 7, 6])
        try payload.write(to: staging)
        let integrity = try ArchiveIntegrityEngine.hash(file: staging)
        let start = Date(timeIntervalSince1970: 1_700_101_000)
        let xid = XID.generate(at: start)
        let destination = library.mediaRoot.appendingPathComponent(
            VideoStorage.relativePath(xid: xid, date: start))
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Simulate the only durable filesystem state left when COMMIT and its
        // rollback both failed to report an outcome.
        try FileManager.default.moveItem(at: staging, to: destination)
        let queue = LibreReverseMeetingTranscriptionQueue(
            root: root.appendingPathComponent("MeetingTranscriptionQueue"))
        let capture = LibreReverseFinalizedMeetingCapture(
            stagingMediaURL: staging,
            manifest: completedManifest(
                staging: staging, start: start, integrity: integrity, publicationXID: xid),
            candidate: .init(
                provider: .zoom, source: .windowDetection, windowID: 700,
                title: "Indeterminate recovery"), publicationXID: xid)

        let published = try LibreReverseMeetingPublicationPipeline.publishAndEnqueue(
            capture, configuration: library, transcriptionQueue: queue)
        XCTAssertEqual(
            published.relativeMediaPath, VideoStorage.relativePath(xid: xid, date: start))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(try queue.pending().map(\.publicationXID), [xid])
    }

    func testPublicationRejectsSubstitutedDestinationOnlyMedia() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging-substituted/meeting.mp4")
        try FileManager.default.createDirectory(
            at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        let expectedPayload = Data([1, 2, 3, 4])
        try expectedPayload.write(to: staging)
        let expectedIntegrity = try ArchiveIntegrityEngine.hash(file: staging)
        let start = Date(timeIntervalSince1970: 1_700_101_100)
        let xid = XID.generate(at: start)
        let destination = library.mediaRoot.appendingPathComponent(
            VideoStorage.relativePath(xid: xid, date: start))
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: staging)
        let substitutedPayload = Data([4, 3, 2, 1])
        try substitutedPayload.write(to: destination)
        let actualIntegrity = try ArchiveIntegrityEngine.hash(file: destination)
        let capture = LibreReverseFinalizedMeetingCapture(
            stagingMediaURL: staging,
            manifest: completedManifest(
                staging: staging, start: start, integrity: expectedIntegrity, publicationXID: xid),
            candidate: .init(provider: .zoom, source: .windowDetection), publicationXID: xid)

        XCTAssertThrowsError(
            try LibreReverseMeetingCaptureFinalizer.publish(capture, configuration: library)
        ) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingCapturePublicationError,
                .outputIntegrityMismatch(
                    path: destination.path, expectedByteCount: expectedIntegrity.byteCount,
                    actualByteCount: actualIntegrity.byteCount,
                    expectedSHA256: expectedIntegrity.sha256, actualSHA256: actualIntegrity.sha256))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try Data(contentsOf: destination), substitutedPayload)
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM segment WHERE type=1"), 0)
    }

    func testPublicationRejectsManifestFromAnotherJournalBeforeMovingMedia() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging-wrong-xid/meeting.mp4")
        try FileManager.default.createDirectory(
            at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Data([5, 6, 7, 8])
        try payload.write(to: staging)
        let integrity = try ArchiveIntegrityEngine.hash(file: staging)
        let start = Date(timeIntervalSince1970: 1_700_101_150)
        let journalXID = XID.generate(at: start)
        let otherXID = XID.generate(at: start.addingTimeInterval(1))
        let capture = LibreReverseFinalizedMeetingCapture(
            stagingMediaURL: staging,
            manifest: completedManifest(
                staging: staging, start: start, integrity: integrity, publicationXID: otherXID),
            candidate: .init(provider: .zoom, source: .windowDetection), publicationXID: journalXID)

        XCTAssertThrowsError(
            try LibreReverseMeetingCaptureFinalizer.publish(capture, configuration: library)
        ) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingCapturePublicationError,
                .publicationXIDMismatch(expected: journalXID, actual: otherXID))
        }
        XCTAssertEqual(try Data(contentsOf: staging), payload)
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM segment WHERE type=1"), 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: library.mediaRoot, includingPropertiesForKeys: nil
            ).count, 0)
    }

    func testPublicationRejectsNonCanonicalSchemaFiveXIDBeforeMovingMedia() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging-invalid-xid/meeting.mp4")
        try FileManager.default.createDirectory(
            at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Data([8, 6, 7, 5])
        try payload.write(to: staging)
        let integrity = try ArchiveIntegrityEngine.hash(file: staging)
        let invalidXID = "not-a-valid-xid"
        let capture = LibreReverseFinalizedMeetingCapture(
            stagingMediaURL: staging,
            manifest: completedManifest(
                staging: staging, start: Date(timeIntervalSince1970: 1_700_101_175),
                integrity: integrity, publicationXID: invalidXID),
            candidate: .init(provider: .zoom, source: .windowDetection), publicationXID: invalidXID)

        XCTAssertThrowsError(
            try LibreReverseMeetingCaptureFinalizer.publish(capture, configuration: library)
        ) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingCapturePublicationError,
                .invalidPublicationXID(invalidXID))
        }
        XCTAssertEqual(try Data(contentsOf: staging), payload)
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM segment WHERE type=1"), 0)
    }

    func testPublicationRejectsSemanticallyInvalidManifestBeforeMovingMedia() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging-invalid-manifest/meeting.mp4")
        try FileManager.default.createDirectory(
            at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Data([4, 2, 4, 2])
        try payload.write(to: staging)
        let start = Date(timeIntervalSince1970: 1_700_101_190)
        let xid = XID.generate(at: start)
        let invalid: [(HighFidelityMeetingCaptureManifest, String)] = [
            (
                completedManifest(
                    staging: staging, start: Date(timeIntervalSinceReferenceDate: .infinity)),
                "date interval"
            ),
            (
                completedManifest(staging: staging, start: start, hostClockStartSeconds: .infinity),
                "host clock"
            ),
            (
                completedManifest(staging: staging, start: start, hostClockStartSeconds: -1),
                "host clock"
            ), (completedManifest(staging: staging, start: start, displayID: 0), "display ID"),
            (completedManifest(staging: staging, start: start, width: 0), "width"),
            (
                completedManifest(staging: staging, start: start, width: Int(Int32.max / 2) + 1),
                "width"
            ), (completedManifest(staging: staging, start: start, height: 0), "height"),
            (
                completedManifest(staging: staging, start: start, height: Int(Int32.max / 2) + 1),
                "height"
            ),
            (
                completedManifest(staging: staging, start: start, requestedFrameRate: 0),
                "requested frame rate"
            ),
            (
                completedManifest(
                    staging: staging, start: start,
                    requestedFrameRate: HighFidelityMeetingCaptureSession.maximumSupportedFrameRate
                        + 1), "requested frame rate"
            ),
            (
                completedManifest(staging: staging, start: start, expectedSourceFrameRate: 0),
                "expected source frame rate"
            ),
            (
                completedManifest(
                    staging: staging, start: start,
                    expectedSourceFrameRate: HighFidelityMeetingCaptureSession
                        .maximumSupportedFrameRate + 1), "expected source frame rate"
            ),
            (
                completedManifest(staging: staging, start: start, requestedDurationSeconds: .nan),
                "requested duration"
            ),
            (
                completedManifest(staging: staging, start: start, requestedDurationSeconds: 0),
                "requested duration"
            ),
            (
                completedManifest(
                    staging: staging, start: start,
                    requestedDurationSeconds: HighFidelityMeetingCaptureSession
                        .maximumSupportedRequestedDurationSeconds + 1), "requested duration"
            ),
        ]

        for (manifest, field) in invalid {
            XCTAssertThrowsError(
                try LibreReverseMeetingCaptureFinalizer.publish(
                    .init(
                        stagingMediaURL: staging, manifest: manifest,
                        candidate: .init(provider: .zoom, source: .windowDetection),
                        publicationXID: xid), configuration: library)
            ) { error in
                XCTAssertEqual(
                    error as? LibreReverseMeetingCapturePublicationError, .invalidManifestField(field)
                )
            }
            XCTAssertEqual(try Data(contentsOf: staging), payload)
            XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM segment WHERE type=1"), 0)
        }
    }

    func testPublicationRejectsSymlinkedStagedMediaBeforeHashOrMove() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging-symlink/meeting.mp4")
        let target = root.appendingPathComponent("unrelated.mp4")
        try FileManager.default.createDirectory(
            at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Data([9, 8, 7, 6])
        try payload.write(to: target)
        try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: target)
        let start = Date(timeIntervalSince1970: 1_700_101_195)

        XCTAssertThrowsError(
            try LibreReverseMeetingCaptureFinalizer.publish(
                .init(
                    stagingMediaURL: staging,
                    manifest: completedManifest(staging: staging, start: start),
                    candidate: .init(provider: .manual, source: .manual),
                    publicationXID: XID.generate(at: start)), configuration: library)
        ) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingCapturePublicationError,
                .unsupportedMediaFileType(staging.path))
        }
        XCTAssertEqual(try Data(contentsOf: target), payload)
        XCTAssertEqual(
            try staging.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM segment WHERE type=1"), 0)
    }

    func testPublicationRejectsLegacyDestinationOnlyMediaWithoutIntegrityEvidence() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging-legacy/meeting.mp4")
        let start = Date(timeIntervalSince1970: 1_700_101_200)
        let xid = XID.generate(at: start)
        let destination = library.mediaRoot.appendingPathComponent(
            VideoStorage.relativePath(xid: xid, date: start))
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([7, 7, 7]).write(to: destination)
        let capture = LibreReverseFinalizedMeetingCapture(
            stagingMediaURL: staging, manifest: completedManifest(staging: staging, start: start),
            candidate: .init(provider: .zoom, source: .windowDetection), publicationXID: xid)

        XCTAssertThrowsError(
            try LibreReverseMeetingCaptureFinalizer.publish(capture, configuration: library)
        ) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingCapturePublicationError,
                .missingOutputIntegrity(destination.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM segment WHERE type=1"), 0)
    }

    func testRecoveryRetriesTransientFailuresButRejectsDeterministicArtifacts() {
        XCTAssertEqual(
            LibreReverseMeetingRecoveryFailureClassifier.disposition(
                for: CocoaError(.fileWriteNoPermission)), .retry)
        XCTAssertEqual(
            LibreReverseMeetingRecoveryFailureClassifier.disposition(
                for: LibreReverseMeetingCapturePublicationError.invalidDuration(0)), .reject)
        XCTAssertEqual(
            LibreReverseMeetingRecoveryFailureClassifier.disposition(
                for: LibreReverseMeetingTranscriptionQueueError.publicationMismatch("xid")), .reject)
    }

    func testPublicationStoresRecoveredLegacyProviderSpelling() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive", remoteRoot: "rewind", configuration: library)
        let staging = root.appendingPathComponent("staging/slack-meeting.mp4")
        try FileManager.default.createDirectory(
            at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: staging)
        let start = Date(timeIntervalSince1970: 1_700_101_000)
        let published = try LibreReverseMeetingCaptureFinalizer.publish(
            .init(
                stagingMediaURL: staging,
                manifest: completedManifest(staging: staging, start: start),
                candidate: .init(
                    provider: .slackHuddle, source: .windowDetection, windowID: 78,
                    processIdentifier: 89, bundleIdentifier: "com.tinyspeck.slackmacgap",
                    title: "Huddle")), configuration: library)

        XCTAssertEqual(
            try scalar(
                library,
                """
                SELECT COUNT(*) FROM event
                 WHERE segmentID=\(published.segmentID)
                   AND detailsJSON LIKE '%"provider":"slack"%'
                   AND detailsJSON NOT LIKE '%slackHuddle%'
                """), 1)
    }

    func testPrimaryMeetingDeletionJournalsThenRemovesEntireLegacyGraphAndMedia() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive", remoteRoot: "rewind", configuration: library)
        let start = Date(timeIntervalSince1970: 1_700_150_000)
        let xid = "librereverse:meeting:delete"
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(30), windowName: "Delete me",
                relativeMediaPath: path, xid: xid, width: 1280, height: 720, frameRate: 30,
                audioStartTime: start, duration: 30, transcriptText: "remove every word",
                transcriptWords: [
                    .init(
                        speechSource: "others", word: "remove", timeOffset: 0, fullTextOffset: 0,
                        duration: 1)
                ], event: .init(title: "Delete me")), configuration: library)
        let mediaURL = library.mediaRoot.appendingPathComponent(path)

        let plan = try LibreReverseMeetingDeletion.prepare(
            segmentID: meeting.segmentID, configuration: library)
        XCTAssertEqual(plan.ownership, .primary)
        XCTAssertEqual(plan.videoID, meeting.videoID)
        XCTAssertEqual(try LibreReverseMeetingDeletion.pendingPlans(configuration: library), [plan])
        XCTAssertEqual(
            try scalar(
                library,
                "SELECT COUNT(*) FROM archive_object WHERE videoId=\(meeting.videoID) AND remoteState='deleting'"
            ), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path))

        XCTAssertThrowsError(
            try LibreReverseMeetingDeletion.finishPreparedDeletion(plan, configuration: library))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path))

        try LibreReverseMeetingDeletion.commitPreparedPrimaryDeletion(plan, configuration: library)
        for query in [
            "SELECT COUNT(*) FROM segment WHERE id=\(meeting.segmentID)",
            "SELECT COUNT(*) FROM video WHERE id=\(meeting.videoID)",
            "SELECT COUNT(*) FROM frame WHERE segmentId=\(meeting.segmentID)",
            "SELECT COUNT(*) FROM audio WHERE segmentId=\(meeting.segmentID)",
            "SELECT COUNT(*) FROM transcript_word WHERE segmentId=\(meeting.segmentID)",
            "SELECT COUNT(*) FROM doc_segment WHERE segmentId=\(meeting.segmentID)",
            "SELECT COUNT(*) FROM event WHERE segmentID=\(meeting.segmentID)",
            "SELECT COUNT(*) FROM archive_object WHERE videoId=\(meeting.videoID)",
            "SELECT COUNT(*) FROM media_residency WHERE videoId=\(meeting.videoID)",
        ] { XCTAssertEqual(try scalar(library, query), 0, query) }
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'remove'"), 0
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: mediaURL.path),
            "media remains recoverable until the database transaction commits")

        try LibreReverseMeetingDeletion.finishPreparedDeletion(plan, configuration: library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
        XCTAssertTrue(try LibreReverseMeetingDeletion.pendingPlans(configuration: library).isEmpty)
    }

    func testAbortedMeetingDeletionRestoresArchiveStateAndLeavesGraphIntact() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive", remoteRoot: "rewind", configuration: library)
        let start = Date(timeIntervalSince1970: 1_700_160_000)
        let xid = "librereverse:meeting:abort-delete"
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(10), relativeMediaPath: path,
                xid: xid, width: 640, height: 480, frameRate: 30, audioStartTime: start,
                duration: 10), configuration: library)
        let before = try scalar(
            library, "SELECT COUNT(*) FROM segment WHERE id=\(meeting.segmentID)")
        let plan = try LibreReverseMeetingDeletion.prepare(
            segmentID: meeting.segmentID, configuration: library)
        try LibreReverseMeetingDeletion.abortPreparedDeletion(
            plan, requeueRemote: false, configuration: library)
        XCTAssertEqual(
            try scalar(library, "SELECT COUNT(*) FROM segment WHERE id=\(meeting.segmentID)"),
            before)
        XCTAssertEqual(
            try scalar(
                library,
                "SELECT COUNT(*) FROM archive_object WHERE videoId=\(meeting.videoID) AND remoteState='queued'"
            ), 1)
        XCTAssertTrue(try LibreReverseMeetingDeletion.pendingPlans(configuration: library).isEmpty)
    }

    func testSealedShardDeletionRewritesCopyOnWriteAndRetiresPriorRemoteAfterReplacement() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        try execute(
            library,
            """
            UPDATE shard_metadata
               SET epochStart='\(databaseString(epoch))' WHERE id=1
            """)
        let xid = "librereverse:meeting:sealed-delete"
        let path = try makeMedia(xid: xid, date: epoch, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: epoch, endDate: epoch.addingTimeInterval(20), relativeMediaPath: path,
                xid: xid, width: 640, height: 480, frameRate: 30, audioStartTime: epoch,
                duration: 20, transcriptText: "sealed words",
                transcriptWords: [
                    .init(
                        speechSource: "others", word: "sealed", timeOffset: 0, fullTextOffset: 0,
                        duration: 1)
                ]), configuration: library)
        let neighborXID = "librereverse:meeting:sealed-neighbor"
        let neighborPath = try makeMedia(
            xid: neighborXID, date: epoch.addingTimeInterval(60), library: library)
        let neighbor = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: epoch.addingTimeInterval(60), endDate: epoch.addingTimeInterval(80),
                windowName: "Keep me", relativeMediaPath: neighborPath, xid: neighborXID,
                width: 640, height: 480, frameRate: 30,
                audioStartTime: epoch.addingTimeInterval(60), duration: 20,
                transcriptText: "neighbor survives",
                transcriptWords: [
                    .init(
                        speechSource: "others", word: "neighbor", timeOffset: 0, fullTextOffset: 0,
                        duration: 1)
                ]), configuration: library)
        let sealed = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        let active = LibreReverseShardInterval(ordinal: 1, epochStart: epoch)
        let shardURL = root.appendingPathComponent("Library/Shards/\(sealed.fileName)")
        let replacementURL = root.appendingPathComponent("Library/replacement.sqlite3")
        let manifest = try LibreReverseShardBuilder.buildToCompletion(
            source: library, destinationURL: shardURL, interval: sealed, batchSize: 1)
        _ = try LibreReverseShardBuilder.buildReplacementPrimary(
            source: library, destinationURL: replacementURL, activeInterval: active,
            sealedShards: [.init(manifest: manifest, relativePath: "Shards/\(sealed.fileName)")])
        let replacement = LibreReverseLibraryConfiguration(
            databaseURL: replacementURL, keyFileURL: library.keyFileURL,
            mediaRoot: library.mediaRoot)
        let before = try ArchiveIntegrityEngine.hash(file: shardURL)
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive", remoteRoot: "rewind", configuration: replacement)
        _ = try LibreReverseShardArchiveStore.reconcile(
            destinationID: destinationID, configuration: replacement)
        let shardID = try XCTUnwrap(
            LibreReverseShardStore.records(configuration: replacement).first?.id)
        try execute(
            replacement,
            """
            INSERT INTO meeting_deletion(
              segmentId,shardId,planJSON,state,createdAt,updatedAt,lastError
            ) VALUES(999,\(shardID),x'7B7D','prepared','2026-08-01','2026-08-01',NULL)
            """)
        XCTAssertThrowsError(
            try LibreReverseMeetingTitleUpdate.prepare(
                segmentID: meeting.segmentID, title: "Blocked title", configuration: replacement)
        ) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingTitleUpdateError, .shardMutationBusy(meeting.segmentID))
        }
        try execute(replacement, "DELETE FROM meeting_deletion WHERE segmentId=999")
        try execute(
            replacement,
            """
            UPDATE shard_archive_object
               SET remoteState='verified',remoteIdentifier='old-shard-remote',
                   remoteVersion='1',remoteSHA256='\(before.sha256)',
                   verifiedAt='2026-08-01T00:00:00.000';
            UPDATE library_shard
               SET remoteIdentifier='old-shard-remote',remoteVersion='1',
                   remoteSHA256='\(before.sha256)',verifiedAt='2026-08-01T00:00:00.000'
             WHERE id=\(shardID);
            """)

        let plan = try LibreReverseMeetingDeletion.prepare(
            segmentID: meeting.segmentID, configuration: replacement)
        XCTAssertEqual(plan.ownership, .sealedShard)
        XCTAssertNil(
            try LibreReverseShardArchiveStore.nextPending(
                destinationID: destinationID, configuration: replacement),
            "a prepared deletion freezes the shard archive object")
        XCTAssertEqual(try ArchiveIntegrityEngine.hash(file: shardURL), before)
        XCTAssertEqual(
            try scalar(replacement, "SELECT COUNT(*) FROM segment WHERE id=\(meeting.segmentID)"), 1
        )

        try LibreReverseMeetingDeletion.commitPreparedSealedShardDeletion(
            plan, configuration: replacement)

        let after = try ArchiveIntegrityEngine.hash(file: shardURL)
        XCTAssertNotEqual(after.sha256, before.sha256)
        for query in [
            "SELECT COUNT(*) FROM segment WHERE id=\(meeting.segmentID)",
            "SELECT COUNT(*) FROM video WHERE id=\(meeting.videoID)",
            "SELECT COUNT(*) FROM frame WHERE segmentId=\(meeting.segmentID)",
            "SELECT COUNT(*) FROM audio WHERE segmentId=\(meeting.segmentID)",
            "SELECT COUNT(*) FROM transcript_word WHERE segmentId=\(meeting.segmentID)",
            "SELECT COUNT(*) FROM doc_segment WHERE segmentId=\(meeting.segmentID)",
        ] {
            let database =
                query.contains("frame ") || query.contains("audio ")
                    || query.contains("transcript_word ") || query.contains("doc_segment ")
                ? shardURL : replacement.databaseURL
            XCTAssertEqual(try scalar(database, replacement.keyFileURL, query), 0, query)
        }
        XCTAssertEqual(
            try scalar(
                shardURL, replacement.keyFileURL,
                "SELECT COUNT(*) FROM frame WHERE segmentId=\(neighbor.segmentID)"), 1)
        XCTAssertEqual(
            try scalar(
                shardURL, replacement.keyFileURL,
                "SELECT COUNT(*) FROM transcript_word WHERE segmentId=\(neighbor.segmentID) AND word='neighbor'"
            ), 1)
        XCTAssertEqual(
            try scalar(replacement, "SELECT COUNT(*) FROM segment WHERE id=\(neighbor.segmentID)"),
            1)
        XCTAssertEqual(
            try scalar(
                replacement,
                "SELECT COUNT(*) FROM library_shard WHERE id=\(shardID) AND sha256='\(after.sha256)'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                replacement,
                "SELECT COUNT(*) FROM shard_archive_retired_object WHERE remoteIdentifier='old-shard-remote'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                replacement,
                "SELECT COUNT(*) FROM shard_archive_object WHERE shardId=\(shardID) AND remoteState='queued' AND objectKey LIKE '%/\(after.sha256).sqlite3'"
            ), 1)
        XCTAssertNil(
            try LibreReverseShardArchiveStore.nextRetiredObjectReadyForRemoval(
                destinationID: destinationID, configuration: replacement))
        try execute(
            replacement,
            """
            UPDATE shard_archive_object SET remoteState='verified',
              remoteIdentifier='replacement-shard-remote',remoteSHA256='\(after.sha256)',
              verifiedAt='2026-08-02T00:00:00.000' WHERE shardId=\(shardID)
            """)
        XCTAssertEqual(
            try LibreReverseShardArchiveStore.nextRetiredObjectReadyForRemoval(
                destinationID: destinationID, configuration: replacement)?.metadata.identifier,
            "old-shard-remote")
        let pending = try XCTUnwrap(
            LibreReverseMeetingDeletion.pendingPlans(configuration: replacement).first)
        try LibreReverseMeetingDeletion.finishPreparedDeletion(pending, configuration: replacement)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: replacement.mediaRoot.appendingPathComponent(path).path))
        XCTAssertTrue(
            try LibreReverseMeetingDeletion.pendingPlans(configuration: replacement).isEmpty)
    }

    func testDeletionCoordinatorRestoresRemoteOnlyShardBeforeCopyOnWrite() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        try execute(
            library,
            "UPDATE shard_metadata SET epochStart='\(databaseString(epoch))' WHERE id=1")
        let xid = "librereverse:meeting:remote-shard-delete"
        let path = try makeMedia(xid: xid, date: epoch, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: epoch, endDate: epoch.addingTimeInterval(15), relativeMediaPath: path,
                xid: xid, width: 640, height: 480, frameRate: 30, audioStartTime: epoch,
                duration: 15, transcriptText: "restore then delete"), configuration: library)
        let sealed = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        let shardURL = root.appendingPathComponent("Library/Shards/\(sealed.fileName)")
        let manifest = try LibreReverseShardBuilder.buildToCompletion(
            source: library, destinationURL: shardURL, interval: sealed, batchSize: 1)
        let replacementURL = root.appendingPathComponent("Library/replacement.sqlite3")
        _ = try LibreReverseShardBuilder.buildReplacementPrimary(
            source: library, destinationURL: replacementURL,
            activeInterval: .init(ordinal: 1, epochStart: epoch),
            sealedShards: [.init(manifest: manifest, relativePath: "Shards/\(sealed.fileName)")])
        let replacement = LibreReverseLibraryConfiguration(
            databaseURL: replacementURL, keyFileURL: library.keyFileURL,
            mediaRoot: library.mediaRoot)
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive", remoteRoot: "rewind", configuration: replacement)
        let shardID = try XCTUnwrap(
            LibreReverseShardStore.records(configuration: replacement).first?.id)
        let parkedURL = root.appendingPathComponent("parked-shard.sqlite3")
        try FileManager.default.moveItem(at: shardURL, to: parkedURL)
        try LibreReverseShardArchiveStore.setShardState(
            shardID: shardID, from: .sealedLocal, to: .remoteOnly, configuration: replacement)
        let restorer = MeetingShardRestorer(
            ordinal: sealed.ordinal, shardID: shardID, parkedURL: parkedURL, canonicalURL: shardURL,
            library: replacement)

        try await LibreReverseMeetingDeletionCoordinator(
            destinationID: destinationID, library: replacement, backend: MeetingArchiveBackend(),
            shardRestorer: restorer
        ).delete(segmentID: meeting.segmentID)

        XCTAssertTrue(FileManager.default.fileExists(atPath: shardURL.path))
        XCTAssertEqual(
            try scalar(
                shardURL, replacement.keyFileURL,
                "SELECT COUNT(*) FROM frame WHERE segmentId=\(meeting.segmentID)"), 0)
        XCTAssertEqual(
            try scalar(replacement, "SELECT COUNT(*) FROM segment WHERE id=\(meeting.segmentID)"), 0
        )
    }

    func testTitleUpdateCoordinatorRestoresRemoteOnlyShardBeforeCopyOnWrite() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        try execute(
            library,
            "UPDATE shard_metadata SET epochStart='\(databaseString(epoch))' WHERE id=1")
        let xid = "librereverse:meeting:remote-shard-rename"
        let path = try makeMedia(xid: xid, date: epoch, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: epoch, endDate: epoch.addingTimeInterval(15),
                windowName: "Remote original", relativeMediaPath: path, xid: xid, width: 640,
                height: 480, frameRate: 30, audioStartTime: epoch, duration: 15,
                transcriptText: "restore then rename"), configuration: library)
        let sealed = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        let shardURL = root.appendingPathComponent("Library/Shards/\(sealed.fileName)")
        let manifest = try LibreReverseShardBuilder.buildToCompletion(
            source: library, destinationURL: shardURL, interval: sealed, batchSize: 1)
        let replacementURL = root.appendingPathComponent("Library/rename-remote.sqlite3")
        _ = try LibreReverseShardBuilder.buildReplacementPrimary(
            source: library, destinationURL: replacementURL,
            activeInterval: .init(ordinal: 1, epochStart: epoch),
            sealedShards: [.init(manifest: manifest, relativePath: "Shards/\(sealed.fileName)")])
        let replacement = LibreReverseLibraryConfiguration(
            databaseURL: replacementURL, keyFileURL: library.keyFileURL,
            mediaRoot: library.mediaRoot)
        let shardID = try XCTUnwrap(
            LibreReverseShardStore.records(configuration: replacement).first?.id)
        let parkedURL = root.appendingPathComponent("parked-rename-shard.sqlite3")
        try FileManager.default.moveItem(at: shardURL, to: parkedURL)
        try LibreReverseShardArchiveStore.setShardState(
            shardID: shardID, from: .sealedLocal, to: .remoteOnly, configuration: replacement)
        let restorer = MeetingShardRestorer(
            ordinal: sealed.ordinal, shardID: shardID, parkedURL: parkedURL, canonicalURL: shardURL,
            library: replacement)

        let updated = try await LibreReverseMeetingTitleUpdateCoordinator(
            library: replacement, shardRestorer: restorer
        ).update(segmentID: meeting.segmentID, title: "Remote edited")

        XCTAssertEqual(updated, "Remote edited")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shardURL.path))
        XCTAssertEqual(
            try scalar(
                shardURL, replacement.keyFileURL,
                "SELECT COUNT(*) FROM segment WHERE id=\(meeting.segmentID) AND windowName='Remote edited'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                shardURL, replacement.keyFileURL,
                "SELECT COUNT(*) FROM searchRanking r JOIN doc_segment d ON d.docid=r.rowid WHERE d.segmentId=\(meeting.segmentID) AND r.title='Remote edited' AND r.text='restore then rename'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                replacement,
                "SELECT COUNT(*) FROM segment WHERE id=\(meeting.segmentID) AND windowName='Remote edited'"
            ), 1)
        XCTAssertTrue(
            try LibreReverseMeetingTitleUpdate.pendingPlans(configuration: replacement).isEmpty)
    }

    func testPreparedSealedShardTitleUpdateResumesCopyOnWriteAndRequeuesDriveShard() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        try execute(
            library,
            "UPDATE shard_metadata SET epochStart='\(databaseString(epoch))' WHERE id=1")
        let xid = "librereverse:meeting:sealed-rename"
        let path = try makeMedia(xid: xid, date: epoch, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: epoch, endDate: epoch.addingTimeInterval(20),
                windowName: "Original sealed title",
                browserURL: "https://meet.google.com/abc-defg-hij", relativeMediaPath: path,
                xid: xid, width: 640, height: 480, frameRate: 30, audioStartTime: epoch,
                duration: 20, transcriptText: "sealed rename words",
                transcriptWords: [
                    .init(
                        speechSource: "others", word: "sealed", timeOffset: 0, fullTextOffset: 0,
                        duration: 1)
                ],
                event: .init(
                    title: "Original sealed title", participants: "[\"Ada\"]",
                    detailsJSON:
                        "{\"provider\":\"googleMeet\",\"calendarTitle\":\"Old calendar\",\"futureField\":\"keep\"}",
                    calendarID: "work", calendarEventID: "event-sealed",
                    calendarSeriesID: "series-sealed")), configuration: library)
        let neighborXID = "librereverse:meeting:sealed-rename-neighbor"
        let neighborPath = try makeMedia(
            xid: neighborXID, date: epoch.addingTimeInterval(60), library: library)
        let neighbor = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: epoch.addingTimeInterval(60), endDate: epoch.addingTimeInterval(80),
                windowName: "Neighbor title", relativeMediaPath: neighborPath, xid: neighborXID,
                width: 640, height: 480, frameRate: 30,
                audioStartTime: epoch.addingTimeInterval(60), duration: 20,
                transcriptText: "neighbor words",
                transcriptWords: [
                    .init(
                        speechSource: "others", word: "neighbor", timeOffset: 0, fullTextOffset: 0,
                        duration: 1)
                ]), configuration: library)
        let sealed = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        let active = LibreReverseShardInterval(ordinal: 1, epochStart: epoch)
        let shardURL = root.appendingPathComponent("Library/Shards/\(sealed.fileName)")
        let replacementURL = root.appendingPathComponent("Library/rename-primary.sqlite3")
        let manifest = try LibreReverseShardBuilder.buildToCompletion(
            source: library, destinationURL: shardURL, interval: sealed, batchSize: 1)
        _ = try LibreReverseShardBuilder.buildReplacementPrimary(
            source: library, destinationURL: replacementURL, activeInterval: active,
            sealedShards: [.init(manifest: manifest, relativePath: "Shards/\(sealed.fileName)")])
        let replacement = LibreReverseLibraryConfiguration(
            databaseURL: replacementURL, keyFileURL: library.keyFileURL,
            mediaRoot: library.mediaRoot)
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive", remoteRoot: "rewind", configuration: replacement)
        _ = try LibreReverseShardArchiveStore.reconcile(
            destinationID: destinationID, configuration: replacement)
        let before = try ArchiveIntegrityEngine.hash(file: shardURL)
        let shardID = try XCTUnwrap(
            LibreReverseShardStore.records(configuration: replacement).first?.id)
        try execute(
            replacement,
            """
            UPDATE shard_archive_object
               SET remoteState='verified',remoteIdentifier='old-title-shard',
                   remoteVersion='1',remoteSHA256='\(before.sha256)',
                   verifiedAt='2026-08-01T00:00:00.000';
            UPDATE library_shard
               SET remoteIdentifier='old-title-shard',remoteVersion='1',
                   remoteSHA256='\(before.sha256)',verifiedAt='2026-08-01T00:00:00.000'
             WHERE id=\(shardID);
            """)

        let plan = try XCTUnwrap(
            LibreReverseMeetingTitleUpdate.prepare(
                segmentID: meeting.segmentID, title: "Edited sealed title",
                configuration: replacement))
        XCTAssertEqual(plan.shardID, shardID)
        XCTAssertThrowsError(
            try LibreReverseMeetingDeletion.prepare(
                segmentID: neighbor.segmentID, configuration: replacement)
        ) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingDeletionError, .shardMutationBusy(neighbor.segmentID))
        }
        XCTAssertNil(
            try LibreReverseShardArchiveStore.nextPending(
                destinationID: destinationID, configuration: replacement),
            "a prepared title update must freeze the shard archive object")
        XCTAssertEqual(
            try LibreReverseMeetingTitleUpdateCoordinator(library: replacement)
                .resumePendingUpdates(), 1)

        let after = try ArchiveIntegrityEngine.hash(file: shardURL)
        XCTAssertNotEqual(after.sha256, before.sha256)
        XCTAssertEqual(
            try scalar(
                shardURL, replacement.keyFileURL,
                "SELECT COUNT(*) FROM segment WHERE id=\(meeting.segmentID) AND windowName='Edited sealed title' AND browserUrl='https://meet.google.com/abc-defg-hij'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                shardURL, replacement.keyFileURL,
                "SELECT COUNT(*) FROM searchRanking r JOIN doc_segment d ON d.docid=r.rowid WHERE d.segmentId=\(meeting.segmentID) AND r.title='Edited sealed title' AND r.text='sealed rename words'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                shardURL, replacement.keyFileURL,
                "SELECT COUNT(*) FROM transcript_word WHERE segmentId=\(meeting.segmentID) AND word='sealed'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                shardURL, replacement.keyFileURL,
                "SELECT COUNT(*) FROM segment WHERE id=\(neighbor.segmentID) AND windowName='Neighbor title'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                replacement,
                "SELECT COUNT(*) FROM segment WHERE id=\(meeting.segmentID) AND windowName='Edited sealed title'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                replacement,
                "SELECT COUNT(*) FROM event WHERE segmentID=\(meeting.segmentID) AND title='Edited sealed title' AND calendarEventID='event-sealed'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                replacement,
                "SELECT COUNT(*) FROM library_shard WHERE id=\(shardID) AND sha256='\(after.sha256)'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                replacement,
                "SELECT COUNT(*) FROM shard_archive_retired_object WHERE remoteIdentifier='old-title-shard'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                replacement,
                "SELECT COUNT(*) FROM shard_archive_object WHERE shardId=\(shardID) AND remoteState='queued' AND objectKey LIKE '%/\(after.sha256).sqlite3'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                replacement,
                "SELECT COUNT(*) FROM meeting_title_update WHERE segmentId=\(meeting.segmentID)"), 0
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: replacement.mediaRoot.appendingPathComponent(path).path),
            "renaming must not mutate meeting media residency")
        XCTAssertEqual(
            try scalar(
                replacement,
                "SELECT COUNT(*) FROM video WHERE id=\(meeting.videoID) AND xid='\(xid)'"), 1)

        let beforeContext = try ArchiveIntegrityEngine.hash(file: shardURL)
        let context = try await LibreReverseMeetingTitleUpdateCoordinator(library: replacement)
            .updateContext(
                segmentID: meeting.segmentID, participants: ["Grace", " Lin ", "Grace"],
                calendarTitle: "Product calendar")
        XCTAssertEqual(context.participants, ["Grace", "Lin"])
        XCTAssertEqual(try ArchiveIntegrityEngine.hash(file: shardURL).sha256, beforeContext.sha256)
        XCTAssertEqual(
            try scalar(
                replacement,
                """
                SELECT COUNT(*) FROM event
                 WHERE segmentID=\(meeting.segmentID)
                   AND title='Edited sealed title'
                   AND participants='["Grace","Lin"]'
                   AND calendarID='work'
                   AND calendarEventID='event-sealed'
                   AND calendarSeriesID='series-sealed'
                   AND detailsJSON LIKE '%"calendarTitle":"Product calendar"%'
                   AND detailsJSON LIKE '%"futureField":"keep"%'
                   AND detailsJSON LIKE '%"provider":"googleMeet"%'
                """), 1)
        XCTAssertEqual(
            try scalar(
                replacement,
                "SELECT COUNT(*) FROM meeting_title_update WHERE segmentId=\(meeting.segmentID)"),
            0, "event metadata remains primary-catalog owned and needs no shard rewrite journal")
    }

    func testFailedOrUnpublishableCaptureNeverEscapesStaging() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging/meeting.mp4")
        try FileManager.default.createDirectory(
            at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([9, 8, 7]).write(to: staging)
        let start = Date(timeIntervalSince1970: 1_700_200_000)
        let failed = HighFidelityMeetingCaptureManifest(
            state: .failed, finalizationReason: "streamError", outputPath: staging.path,
            displayID: 1, width: 1920, height: 1080, requestedFrameRate: 60,
            expectedSourceFrameRate: 60, capturesSystemAudio: true, capturesMicrophone: true,
            microphoneDeviceID: nil, startedAt: start, finishedAt: start.addingTimeInterval(10),
            hostClockStartSeconds: 1, writerStatus: "completed", writerError: nil,
            streamError: "interrupted", timestamps: .init(frameRate: 60))
        let candidate = LibreReverseMeetingCandidate(provider: .manual, source: .manual)
        XCTAssertThrowsError(
            try LibreReverseMeetingCaptureFinalizer.publish(
                .init(stagingMediaURL: staging, manifest: failed, candidate: candidate),
                configuration: library))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM segment WHERE type=1"), 0)

        let unavailable = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("missing/library.sqlite3"),
            keyFileURL: library.keyFileURL, mediaRoot: library.mediaRoot)
        XCTAssertThrowsError(
            try LibreReverseMeetingCaptureFinalizer.publish(
                .init(
                    stagingMediaURL: staging,
                    manifest: completedManifest(staging: staging, start: start),
                    candidate: candidate), configuration: unavailable))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: staging.path),
            "a failed DB transaction must reverse the canonical media move")
    }

    func testPublicationJournalRoundTripsCandidateAndCommittedRetryIsIdempotent() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("MeetingStaging/retry")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent("meeting.mp4")
        try Data([1, 3, 3, 7]).write(to: staging)
        let candidate = LibreReverseMeetingCandidate(
            provider: .zoom, source: .windowDetection, windowID: 42,
            bundleIdentifier: "us.zoom.xos", title: "Recovery sync")
        let xid = XID.generate(at: Date(timeIntervalSince1970: 1_700_250_000))
        let journal = LibreReverseMeetingCaptureJournal(
            publicationXID: xid, candidate: candidate,
            createdAt: Date(timeIntervalSince1970: 1_700_250_000))
        try journal.write(to: directory)
        XCTAssertEqual(try LibreReverseMeetingCaptureJournal.read(from: directory), journal)

        let checkpoint: LibreReverseMeetingCaptureRecoveryCheckpoint = .init(
            startedAt: Date(timeIntervalSince1970: 1_700_250_001), hostClockStartSeconds: 12,
            displayID: 1, width: 64, height: 48, requestedFrameRate: 60,
            expectedSourceFrameRate: 30, capturesSystemAudio: true, capturesMicrophone: false,
            microphoneDeviceID: nil)
        let renamedJournal = journal.checkpointed(checkpoint).updatingCandidate(
            candidate.updatingTitle("Edited recovery sync"))
        try renamedJournal.write(to: directory)
        let restoredRename = try LibreReverseMeetingCaptureJournal.read(from: directory)
        XCTAssertEqual(restoredRename.candidate.title, "Edited recovery sync")
        XCTAssertEqual(restoredRename.candidate.identity, candidate.identity)
        XCTAssertEqual(restoredRename.recoveryCheckpoint, checkpoint)
        XCTAssertEqual(restoredRename.publicationXID, xid)
        XCTAssertEqual(restoredRename.createdAt, journal.createdAt)

        let capture = LibreReverseFinalizedMeetingCapture(
            stagingMediaURL: staging,
            manifest: completedManifest(
                staging: staging, start: Date(timeIntervalSince1970: 1_700_250_000)),
            candidate: restoredRename.candidate, publicationXID: xid)
        let first = try LibreReverseMeetingCaptureFinalizer.publish(capture, configuration: library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))

        let retry = try LibreReverseMeetingCaptureFinalizer.publish(capture, configuration: library)
        XCTAssertEqual(retry, first)
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM segment WHERE type=1"), 1)
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM video WHERE xid='\(xid)'"), 1)
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM segment WHERE windowName='Edited recovery sync'"), 1)
        XCTAssertEqual(
            try scalar(library, "SELECT COUNT(*) FROM event WHERE title='Edited recovery sync'"), 1)
    }

    func testCaptureJournalRejectsUnknownVersionAndCheckpointShapeMismatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let xid = XID.generate(at: Date(timeIntervalSince1970: 1_700_255_000))
        let journal = LibreReverseMeetingCaptureJournal(
            publicationXID: xid, candidate: .init(provider: .zoom, source: .windowDetection))
        try journal.write(to: root)
        let url = root.appendingPathComponent(LibreReverseMeetingCaptureJournal.fileName)
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])

        payload["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: payload).write(to: url, options: .atomic)
        XCTAssertThrowsError(try LibreReverseMeetingCaptureJournal.read(from: root)) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingCaptureJournalError, .unsupportedSchemaVersion(99))
        }

        payload["schemaVersion"] = 2
        try JSONSerialization.data(withJSONObject: payload).write(to: url, options: .atomic)
        XCTAssertThrowsError(try LibreReverseMeetingCaptureJournal.read(from: root)) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingCaptureJournalError,
                .checkpointSchemaMismatch(schemaVersion: 2, hasCheckpoint: false))
        }
        XCTAssertEqual(
            LibreReverseMeetingRecoveryFailureClassifier.disposition(
                for: LibreReverseMeetingCaptureJournalError.unsupportedSchemaVersion(99)), .reject)
    }

    func testCaptureJournalRejectsInvalidOwnershipOnWriteReadAndRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "librereverse-invalid-journal-owner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_700_255_050)
        let checkpoint = LibreReverseMeetingCaptureRecoveryCheckpoint(
            startedAt: start, hostClockStartSeconds: 10, displayID: 1, width: 1920, height: 1080,
            requestedFrameRate: 30, expectedSourceFrameRate: 30, capturesSystemAudio: false,
            capturesMicrophone: false, microphoneDeviceID: nil)
        let invalidXID = LibreReverseMeetingCaptureJournal(
            publicationXID: "not-a-valid-xid",
            candidate: .init(provider: .manual, source: .manual), createdAt: start,
            recoveryCheckpoint: checkpoint)
        XCTAssertThrowsError(try invalidXID.write(to: root)) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingCaptureJournalError,
                .invalidPublicationXID("not-a-valid-xid"))
        }

        let invalidDate = LibreReverseMeetingCaptureJournal(
            publicationXID: XID.generate(at: start),
            candidate: .init(provider: .manual, source: .manual),
            createdAt: Date(timeIntervalSinceReferenceDate: .infinity),
            recoveryCheckpoint: checkpoint)
        XCTAssertThrowsError(try invalidDate.write(to: root)) { error in
            XCTAssertEqual(error as? LibreReverseMeetingCaptureJournalError, .invalidCreationDate)
        }

        let invalidCandidates: [(LibreReverseMeetingCandidate, String)] = [
            (.init(provider: .zoom, source: .manual), "manual source/provider"),
            (.init(provider: .manual, source: .windowDetection), "window source/provider"),
            (.init(provider: .zoom, source: .calendar), "calendar source/provider"),
            (.init(provider: .zoom, source: .windowDetection, windowID: 0), "window ID"),
            (
                .init(provider: .zoom, source: .windowDetection, windowID: 1, processIdentifier: 0),
                "process identifier"
            ),
            (
                .init(provider: .zoom, source: .windowDetection, processIdentifier: 42),
                "process without window"
            ),
            (
                .init(provider: .zoom, source: .windowDetection, bundleIdentifier: "  "),
                "bundle identifier"
            ),
            (
                .init(provider: .zoom, source: .windowDetection, calendarEventID: "event"),
                "calendar identity"
            ),
            (
                .init(provider: .zoom, source: .windowDetection, calendarSeriesID: "series"),
                "calendar series without event"
            ),
        ]
        for (candidate, field) in invalidCandidates {
            let journal = LibreReverseMeetingCaptureJournal(
                publicationXID: XID.generate(at: start), candidate: candidate,
                createdAt: start, recoveryCheckpoint: checkpoint)
            XCTAssertThrowsError(try journal.write(to: root)) { error in
                XCTAssertEqual(
                    error as? LibreReverseMeetingCaptureJournalError, .invalidCandidateField(field))
            }
        }

        let valid = LibreReverseMeetingCaptureJournal(
            publicationXID: XID.generate(at: start),
            candidate: .init(provider: .manual, source: .manual), createdAt: start,
            recoveryCheckpoint: checkpoint)
        try valid.write(to: root)
        let url = root.appendingPathComponent(LibreReverseMeetingCaptureJournal.fileName)
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        payload["publicationXID"] = "tampered-owner"
        try JSONSerialization.data(withJSONObject: payload).write(to: url, options: .atomic)
        XCTAssertThrowsError(try LibreReverseMeetingCaptureJournal.read(from: root)) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingCaptureJournalError,
                .invalidPublicationXID("tampered-owner"))
        }

        try valid.write(to: root)
        payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var candidate = try XCTUnwrap(payload["candidate"] as? [String: Any])
        candidate["source"] = LibreReverseMeetingCandidateSource.windowDetection.rawValue
        payload["candidate"] = candidate
        try JSONSerialization.data(withJSONObject: payload).write(to: url, options: .atomic)
        XCTAssertThrowsError(try LibreReverseMeetingCaptureJournal.read(from: root)) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingCaptureJournalError,
                .invalidCandidateField("window source/provider"))
        }

        do {
            _ = try await LibreReverseMeetingCrashRecovery.recoverManifest(
                journal: invalidXID, directory: URL(fileURLWithPath: "/does-not-exist"))
            XCTFail("invalid owner must fail before staged media lookup")
        } catch {
            XCTAssertEqual(
                error as? LibreReverseMeetingCaptureJournalError,
                .invalidPublicationXID("not-a-valid-xid"))
        }
        let invalidCandidate = LibreReverseMeetingCaptureJournal(
            publicationXID: XID.generate(at: start),
            candidate: .init(provider: .zoom, source: .windowDetection, processIdentifier: 42),
            createdAt: start, recoveryCheckpoint: checkpoint)
        do {
            _ = try await LibreReverseMeetingCrashRecovery.recoverManifest(
                journal: invalidCandidate, directory: URL(fileURLWithPath: "/does-not-exist"))
            XCTFail("invalid candidate must fail before staged media lookup")
        } catch {
            XCTAssertEqual(
                error as? LibreReverseMeetingCaptureJournalError,
                .invalidCandidateField("process without window"))
        }
    }

    func testCaptureJournalRejectsSemanticallyInvalidRecoveryCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "librereverse-invalid-checkpoint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_700_255_100)
        let journal = LibreReverseMeetingCaptureJournal(
            publicationXID: XID.generate(at: start),
            candidate: .init(provider: .zoom, source: .windowDetection),
            recoveryCheckpoint: .init(
                startedAt: start, hostClockStartSeconds: 10, displayID: 1, width: 1920,
                height: 1080, requestedFrameRate: 30, expectedSourceFrameRate: 30,
                capturesSystemAudio: true, capturesMicrophone: false, microphoneDeviceID: nil))
        try journal.write(to: root)
        let url = root.appendingPathComponent(LibreReverseMeetingCaptureJournal.fileName)
        let original = try Data(contentsOf: url)
        let invalidFields: [(key: String, value: Any, label: String)] = [
            ("hostClockStartSeconds", -1.0, "host clock"), ("displayID", 0, "display ID"),
            ("width", 0, "width"), ("width", Int(Int32.max / 2) + 1, "width"),
            ("height", 0, "height"), ("requestedFrameRate", 0, "requested frame rate"),
            (
                "requestedFrameRate",
                HighFidelityMeetingCaptureSession.maximumSupportedFrameRate + 1,
                "requested frame rate"
            ), ("expectedSourceFrameRate", 0, "expected source frame rate"),
            (
                "expectedSourceFrameRate",
                HighFidelityMeetingCaptureSession.maximumSupportedFrameRate + 1,
                "expected source frame rate"
            ),
        ]

        for invalid in invalidFields {
            var payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: original) as? [String: Any])
            var checkpoint = try XCTUnwrap(payload["recoveryCheckpoint"] as? [String: Any])
            checkpoint[invalid.key] = invalid.value
            payload["recoveryCheckpoint"] = checkpoint
            try JSONSerialization.data(withJSONObject: payload).write(to: url, options: .atomic)
            XCTAssertThrowsError(try LibreReverseMeetingCaptureJournal.read(from: root)) { error in
                XCTAssertEqual(
                    error as? LibreReverseMeetingCaptureJournalError,
                    .invalidCheckpointField(invalid.label))
            }
        }

        XCTAssertNoThrow(try journal.recoveryCheckpoint?.validate())
        let nonfinite = LibreReverseMeetingCaptureRecoveryCheckpoint(
            startedAt: start, hostClockStartSeconds: .infinity, displayID: 1, width: 1920,
            height: 1080, requestedFrameRate: 30, expectedSourceFrameRate: 30,
            capturesSystemAudio: false, capturesMicrophone: false, microphoneDeviceID: nil)
        XCTAssertThrowsError(try nonfinite.validate()) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingCaptureJournalError,
                .invalidCheckpointField("host clock"))
        }
        let nonfiniteDate = LibreReverseMeetingCaptureRecoveryCheckpoint(
            startedAt: Date(timeIntervalSinceReferenceDate: .infinity), hostClockStartSeconds: 10,
            displayID: 1, width: 1920, height: 1080, requestedFrameRate: 30,
            expectedSourceFrameRate: 30, capturesSystemAudio: false, capturesMicrophone: false,
            microphoneDeviceID: nil)
        XCTAssertThrowsError(try nonfiniteDate.validate()) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingCaptureJournalError,
                .invalidCheckpointField("start date"))
        }
    }

    func testCrashRecoveryValidatesCheckpointBeforeOpeningMedia() async {
        let start = Date(timeIntervalSince1970: 1_700_255_200)
        let journal = LibreReverseMeetingCaptureJournal(
            publicationXID: XID.generate(at: start),
            candidate: .init(provider: .manual, source: .manual),
            recoveryCheckpoint: .init(
                startedAt: start, hostClockStartSeconds: 10, displayID: 0, width: 1920,
                height: 1080, requestedFrameRate: 30, expectedSourceFrameRate: 30,
                capturesSystemAudio: false, capturesMicrophone: false, microphoneDeviceID: nil))
        do {
            _ = try await LibreReverseMeetingCrashRecovery.recoverManifest(
                journal: journal, directory: URL(fileURLWithPath: "/does-not-exist"))
            XCTFail("invalid checkpoint must fail before staged media lookup")
        } catch {
            XCTAssertEqual(
                error as? LibreReverseMeetingCaptureJournalError,
                .invalidCheckpointField("display ID"))
        }
    }

    func testPublicationRejectsUnknownManifestSchemaBeforeMovingMedia() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging-unknown-schema/meeting.mp4")
        try FileManager.default.createDirectory(
            at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Data([2, 7, 1, 8])
        try payload.write(to: staging)
        let start = Date(timeIntervalSince1970: 1_700_255_100)
        let xid = XID.generate(at: start)
        let capture = LibreReverseFinalizedMeetingCapture(
            stagingMediaURL: staging,
            manifest: completedManifest(staging: staging, start: start, schemaVersion: 99),
            candidate: .init(provider: .zoom, source: .windowDetection), publicationXID: xid)

        XCTAssertThrowsError(
            try LibreReverseMeetingCaptureFinalizer.publish(capture, configuration: library)
        ) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingCapturePublicationError,
                .unsupportedManifestSchemaVersion(99))
        }
        XCTAssertEqual(try Data(contentsOf: staging), payload)
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM segment WHERE type=1"), 0)
    }

    func testCrashCheckpointRecoversReadableVideoAndPublishesIdempotently() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library/MeetingStaging/crashed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let media = directory.appendingPathComponent("meeting.mp4")
        try await makeCrashRecoveryVideo(at: media, width: 64, height: 48)
        let start = Date(timeIntervalSince1970: 1_700_260_000)
        let xid = XID.generate(at: start)
        let candidate = LibreReverseMeetingCandidate(
            provider: .manual, source: .manual, title: "Recovered meeting")
        let journal = LibreReverseMeetingCaptureJournal(
            publicationXID: xid, candidate: candidate, createdAt: start,
            recoveryCheckpoint: .init(
                startedAt: start, hostClockStartSeconds: 10, displayID: 1, width: 64, height: 48,
                requestedFrameRate: 30, expectedSourceFrameRate: 30, capturesSystemAudio: false,
                capturesMicrophone: false, microphoneDeviceID: nil))
        try journal.write(to: directory)

        let manifest = try await LibreReverseMeetingCrashRecovery.recoverManifest(
            journal: journal, directory: directory)
        XCTAssertEqual(manifest.schemaVersion, 6)
        XCTAssertEqual(manifest.mediaEvidence?.videoTrackCount, 1)
        XCTAssertTrue(manifest.mediaEvidence?.videoHasReadableSample == true)
        XCTAssertEqual(manifest.publicationXID, xid)
        let recoveredIntegrity = try ArchiveIntegrityEngine.hash(file: media)
        XCTAssertEqual(manifest.outputByteCount, recoveredIntegrity.byteCount)
        XCTAssertEqual(manifest.outputSHA256, recoveredIntegrity.sha256)
        XCTAssertEqual(
            manifest.finalizationReason, LibreReverseMeetingCrashRecovery.finalizationReason)
        XCTAssertEqual(manifest.state, .completed)
        XCTAssertEqual(manifest.writerStatus, "completed")
        XCTAssertGreaterThan(manifest.finishedAt.timeIntervalSince(start), 0)

        let capture = LibreReverseFinalizedMeetingCapture(
            stagingMediaURL: media, manifest: manifest, candidate: candidate, publicationXID: xid)
        let first = try LibreReverseMeetingCaptureFinalizer.publish(capture, configuration: library)
        let retry = try LibreReverseMeetingCaptureFinalizer.publish(capture, configuration: library)
        XCTAssertEqual(retry, first)
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM segment WHERE type=1"), 1)
    }

    func testCompletionTimeoutRecoveryPreservesTelemetryAndPublishesIdempotently() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library/MeetingStaging/crashed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let media = directory.appendingPathComponent("meeting.mp4")
        try await makeCrashRecoveryVideo(at: media, width: 64, height: 48)
        let start = Date(timeIntervalSince1970: 1_700_260_000)
        let xid = XID.generate(at: start)
        let candidate = LibreReverseMeetingCandidate(
            provider: .manual, source: .manual, title: "Recovered meeting")
        let journal = LibreReverseMeetingCaptureJournal(
            publicationXID: xid, candidate: candidate, createdAt: start,
            recoveryCheckpoint: .init(
                startedAt: start, hostClockStartSeconds: 10, displayID: 1, width: 64, height: 48,
                requestedFrameRate: 30, expectedSourceFrameRate: 30, capturesSystemAudio: false,
                capturesMicrophone: false, microphoneDeviceID: nil))
        try journal.write(to: directory)

        var timestamps = MeetingCaptureTimestampLedger(frameRate: 30)
        XCTAssertTrue(timestamps.recordVideo(presentationTimeSeconds: 10))
        XCTAssertTrue(timestamps.recordVideo(presentationTimeSeconds: 10 + 1.0 / 30))
        let manifest = try await LibreReverseMeetingCrashRecovery.recoverManifest(
            journal: journal, directory: directory,
            finalizationReason: "recordingCompletionRecovered", capturedDuration: 1.0 / 30,
            timestamps: timestamps)
        XCTAssertEqual(manifest.timestamps.video.sampleBufferCount, 2)
        XCTAssertEqual(manifest.schemaVersion, 6)
        XCTAssertEqual(manifest.mediaEvidence?.videoTrackCount, 1)
        XCTAssertTrue(manifest.mediaEvidence?.videoHasReadableSample == true)
        XCTAssertEqual(manifest.publicationXID, xid)
        let recoveredIntegrity = try ArchiveIntegrityEngine.hash(file: media)
        XCTAssertEqual(manifest.outputByteCount, recoveredIntegrity.byteCount)
        XCTAssertEqual(manifest.outputSHA256, recoveredIntegrity.sha256)
        XCTAssertEqual(
            manifest.finalizationReason, "recordingCompletionRecovered")
        XCTAssertEqual(manifest.state, .completed)
        XCTAssertEqual(manifest.writerStatus, "completed")
        XCTAssertGreaterThan(manifest.finishedAt.timeIntervalSince(start), 0)

        let capture = LibreReverseFinalizedMeetingCapture(
            stagingMediaURL: media, manifest: manifest, candidate: candidate, publicationXID: xid)
        let first = try LibreReverseMeetingCaptureFinalizer.publish(capture, configuration: library)
        let retry = try LibreReverseMeetingCaptureFinalizer.publish(capture, configuration: library)
        XCTAssertEqual(retry, first)
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM segment WHERE type=1"), 1)
    }

    func testCrashRecoveryRejectsPreStartJournalAndCorruptMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "librereverse-crash-rejection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("meeting.mp4"))
        let candidate = LibreReverseMeetingCandidate(provider: .manual, source: .manual)
        let preStart = LibreReverseMeetingCaptureJournal(
            publicationXID: "pre-start", candidate: candidate)
        do {
            _ = try await LibreReverseMeetingCrashRecovery.recoverManifest(
                journal: preStart, directory: root)
            XCTFail("pre-start journals must not be guessed into recordings")
        } catch {
            XCTAssertEqual(error as? LibreReverseMeetingCrashRecoveryError, .missingCheckpoint)
        }

        let checkpointed = LibreReverseMeetingCaptureJournal(
            publicationXID: XID.generate(at: Date(timeIntervalSince1970: 1_700_260_000)),
            candidate: candidate,
            recoveryCheckpoint: .init(
                startedAt: Date(timeIntervalSince1970: 1_700_260_000), hostClockStartSeconds: 10,
                displayID: 1, width: 64, height: 48, requestedFrameRate: 30,
                expectedSourceFrameRate: 30, capturesSystemAudio: false, capturesMicrophone: false,
                microphoneDeviceID: nil))
        do {
            _ = try await LibreReverseMeetingCrashRecovery.recoverManifest(
                journal: checkpointed, directory: root)
            XCTFail("corrupt media must remain quarantined")
        } catch { XCTAssertNotNil(error as? LibreReverseMeetingCrashRecoveryError) }
    }

    func testCrashRecoveryRejectsSymlinkedMediaBeforeAVFoundationParsing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "librereverse-crash-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("external.mp4")
        let media = root.appendingPathComponent("meeting.mp4")
        try Data([0, 1, 2, 3]).write(to: target)
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: target)
        let start = Date(timeIntervalSince1970: 1_700_260_100)
        let journal = LibreReverseMeetingCaptureJournal(
            publicationXID: XID.generate(at: start),
            candidate: .init(provider: .manual, source: .manual),
            recoveryCheckpoint: .init(
                startedAt: start, hostClockStartSeconds: 10, displayID: 1, width: 64, height: 48,
                requestedFrameRate: 30, expectedSourceFrameRate: 30, capturesSystemAudio: false,
                capturesMicrophone: false, microphoneDeviceID: nil))

        do {
            _ = try await LibreReverseMeetingCrashRecovery.recoverManifest(
                journal: journal, directory: root)
            XCTFail("symlinked crash media must remain quarantined")
        } catch {
            XCTAssertEqual(
                error as? LibreReverseMeetingCrashRecoveryError, .unsupportedMediaFileType(media.path)
            )
        }
    }

    func testPublicationAtomicallyCreatesLegacyGraphAndArchiveObject() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive", remoteRoot: "rewind", configuration: library)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let xid = "librereverse:meeting:test"
        let path = try makeMedia(xid: xid, date: start, library: library)

        let published = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(90), windowName: "Weekly sync",
                relativeMediaPath: path, xid: xid, width: 1920, height: 1080, frameRate: 60,
                audioStartTime: start.addingTimeInterval(0.01), duration: 89.9,
                transcriptText: "hello team",
                transcriptWords: [
                    .init(
                        speechSource: "me", word: "hello", timeOffset: 0, fullTextOffset: 0,
                        duration: 50),
                    .init(
                        speechSource: "others", word: "team", timeOffset: 50, fullTextOffset: 6,
                        duration: 40),
                ],
                event: .init(
                    title: "Weekly sync", participants: "[\"A\",\"B\"]",
                    calendarEventID: "calendar-event")), configuration: library)

        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM segment WHERE type=1"), 1)
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM segment WHERE bundleID='ai.rewind.audiorecorder'"), 1
        )
        XCTAssertEqual(
            try scalar(library, "SELECT COUNT(*) FROM video WHERE captureType='meeting'"), 1)
        XCTAssertEqual(
            try scalar(library, "SELECT COUNT(*) FROM frame WHERE encodingStatus='success'"), 1)
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM audio"), 1)
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM transcript_word"), 2)
        XCTAssertEqual(
            try scalar(library, "SELECT COUNT(*) FROM event WHERE status='completed'"), 1)
        XCTAssertEqual(
            try scalar(library, "SELECT COUNT(*) FROM doc_segment WHERE frameId IS NULL"), 1)
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'hello'"), 1)
        XCTAssertEqual(
            try scalar(
                library,
                """
                SELECT COUNT(*) FROM audio a JOIN video v ON v.path=a.path
                 WHERE a.segmentId=\(published.segmentID) AND v.id=\(published.videoID)
                """), 1)
        XCTAssertEqual(
            try scalar(
                library,
                """
                SELECT COUNT(*) FROM frame
                 WHERE id=\(published.frameID) AND segmentId=\(published.segmentID)
                   AND videoId=\(published.videoID) AND videoFrameIndex=0
                """), 1)
        XCTAssertEqual(
            try scalar(
                library,
                """
                SELECT COUNT(*) FROM archive_object
                 WHERE destinationId=\(destinationID) AND videoId=\(published.videoID)
                   AND relativePath='\(path)' AND remoteState='queued'
                """), 1)
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM media_residency WHERE videoId=\(published.videoID)"),
            1)
        XCTAssertFalse(
            try LibreReverseLibraryStore.canRemoveSourceImage(
                frameID: published.frameID, configuration: library))
        XCTAssertTrue(
            try LibreReverseLibraryStore.removableSourceImages(configuration: library).isEmpty)
    }

    func testPrimaryMeetingTitleUpdatePreservesTranscriptCalendarAndMediaIdentity() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive", remoteRoot: "rewind", configuration: library)
        let start = Date(timeIntervalSince1970: 1_700_005_000)
        let xid = "librereverse:meeting:rename"
        let path = try makeMedia(xid: xid, date: start, library: library)
        let published = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(60),
                windowName: "Original title", browserURL: "https://meet.google.com/abc-defg-hij",
                relativeMediaPath: path, xid: xid, width: 1920, height: 1080, frameRate: 60,
                audioStartTime: start, duration: 60, transcriptText: "durable words",
                transcriptWords: [
                    .init(
                        speechSource: "others", word: "durable", timeOffset: 0, fullTextOffset: 0,
                        duration: 1),
                    .init(
                        speechSource: "others", word: "words", timeOffset: 1, fullTextOffset: 8,
                        duration: 1),
                ],
                event: .init(
                    title: "Original title", participants: "[\"Ada\"]", calendarID: "work",
                    calendarEventID: "event-1", calendarSeriesID: "series-1")),
            configuration: library)
        let documentID = try XCTUnwrap(published.transcriptDocumentID)

        XCTAssertEqual(
            try LibreReverseLibraryStore.updateMeetingTitle(
                segmentID: published.segmentID, title: "  Edited planning sync  ",
                configuration: library), "Edited planning sync")
        XCTAssertEqual(
            try scalar(
                library,
                "SELECT COUNT(*) FROM segment WHERE id=\(published.segmentID) AND windowName='Edited planning sync' AND browserUrl='https://meet.google.com/abc-defg-hij'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                library,
                "SELECT COUNT(*) FROM event WHERE segmentID=\(published.segmentID) AND title='Edited planning sync' AND participants='[\"Ada\"]' AND calendarID='work' AND calendarEventID='event-1' AND calendarSeriesID='series-1'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                library,
                "SELECT COUNT(*) FROM searchRanking WHERE rowid=\(documentID) AND title='Edited planning sync' AND text='durable words'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                library,
                "SELECT COUNT(*) FROM doc_segment WHERE docid=\(documentID) AND segmentId=\(published.segmentID) AND frameId IS NULL"
            ), 1)
        XCTAssertEqual(
            try scalar(
                library,
                "SELECT COUNT(*) FROM transcript_word WHERE segmentId=\(published.segmentID)"), 2)
        XCTAssertEqual(
            try scalar(
                library,
                "SELECT COUNT(*) FROM video WHERE id=\(published.videoID) AND xid='\(xid)' AND path='\(path)'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM archive_object WHERE videoId=\(published.videoID)"),
            1)
    }

    func testPrimaryMeetingContextUpdatePreservesUnknownDetailsAndIdentity() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_006_000)
        let xid = "librereverse:meeting:context"
        let path = try makeMedia(xid: xid, date: start, library: library)
        let published = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(60),
                windowName: "Context meeting", relativeMediaPath: path, xid: xid, width: 1280,
                height: 720, frameRate: 30, audioStartTime: start, duration: 60,
                transcriptText: "context words",
                transcriptWords: [
                    .init(
                        speechSource: "others", word: "context", timeOffset: 0, fullTextOffset: 0,
                        duration: 1)
                ],
                event: .init(
                    title: "Context meeting", participants: "[\"Ada\"]",
                    detailsJSON:
                        "{\"provider\":\"googleMeet\",\"source\":\"windowDetection\",\"calendarTitle\":\"Old calendar\",\"futureField\":\"keep\"}",
                    calendarID: "work", calendarEventID: "event-context",
                    calendarSeriesID: "series-context")), configuration: library)

        let stored = try await LibreReverseMeetingTitleUpdateCoordinator(library: library)
            .updateContext(
                segmentID: published.segmentID, participants: [" Ada ", "Grace", "Ada", ""],
                calendarTitle: "  Product calendar  ")

        XCTAssertEqual(stored.participants, ["Ada", "Grace"])
        XCTAssertEqual(stored.calendarTitle, "Product calendar")
        XCTAssertEqual(
            try scalar(
                library,
                """
                SELECT COUNT(*) FROM event
                 WHERE segmentID=\(published.segmentID)
                   AND title='Context meeting'
                   AND participants='["Ada","Grace"]'
                   AND calendarID='work'
                   AND calendarEventID='event-context'
                   AND calendarSeriesID='series-context'
                   AND detailsJSON LIKE '%"calendarTitle":"Product calendar"%'
                   AND detailsJSON LIKE '%"futureField":"keep"%'
                   AND detailsJSON LIKE '%"provider":"googleMeet"%'
                """), 1)
        XCTAssertEqual(
            try scalar(
                library,
                "SELECT COUNT(*) FROM segment WHERE id=\(published.segmentID) AND windowName='Context meeting'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                library,
                "SELECT COUNT(*) FROM transcript_word WHERE segmentId=\(published.segmentID) AND word='context'"
            ), 1)
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM video WHERE id=\(published.videoID) AND xid='\(xid)'"
            ), 1)

        let cleared = try await LibreReverseMeetingTitleUpdateCoordinator(library: library)
            .updateContext(segmentID: published.segmentID, participants: [], calendarTitle: nil)
        XCTAssertEqual(cleared, .init(participants: [], calendarTitle: nil))
        XCTAssertEqual(
            try scalar(
                library,
                """
                SELECT COUNT(*) FROM event
                 WHERE segmentID=\(published.segmentID)
                   AND participants IS NULL
                   AND detailsJSON NOT LIKE '%calendarTitle%'
                   AND detailsJSON LIKE '%"futureField":"keep"%'
                   AND calendarID='work'
                   AND calendarEventID='event-context'
                """), 1)
    }

    func testMeetingContextUpdateRemainsCatalogOnlyForSealedAndRemotePayloads() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let epoch = Date(timeIntervalSince1970: 1_700_007_000)
        try execute(
            library,
            "UPDATE shard_metadata SET epochStart='\(databaseString(epoch))' WHERE id=1")
        let xid = "librereverse:meeting:archived-context"
        let path = try makeMedia(xid: xid, date: epoch, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: epoch, endDate: epoch.addingTimeInterval(30),
                windowName: "Archived context", relativeMediaPath: path, xid: xid, width: 1280,
                height: 720, frameRate: 30, audioStartTime: epoch, duration: 30,
                transcriptText: "archived context words",
                transcriptWords: [
                    .init(
                        speechSource: "others", word: "archived", timeOffset: 0, fullTextOffset: 0,
                        duration: 1),
                    .init(
                        speechSource: "others", word: "context", timeOffset: 1, fullTextOffset: 9,
                        duration: 1),
                    .init(
                        speechSource: "others", word: "words", timeOffset: 2, fullTextOffset: 17,
                        duration: 1),
                ],
                event: .init(
                    title: "Archived context", participants: "[\"Ada\"]",
                    detailsJSON:
                        "{\"provider\":\"googleMeet\",\"calendarTitle\":\"Old calendar\",\"futureField\":\"keep\"}",
                    calendarID: "work", calendarEventID: "event-archived-context",
                    calendarSeriesID: "series-archived-context")), configuration: library)
        let sealed = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        let shardURL = root.appendingPathComponent("Library/Shards/\(sealed.fileName)")
        let manifest = try LibreReverseShardBuilder.buildToCompletion(
            source: library, destinationURL: shardURL, interval: sealed, batchSize: 1)
        let replacementURL = root.appendingPathComponent("Library/context-primary.sqlite3")
        _ = try LibreReverseShardBuilder.buildReplacementPrimary(
            source: library, destinationURL: replacementURL,
            activeInterval: .init(ordinal: 1, epochStart: epoch),
            sealedShards: [.init(manifest: manifest, relativePath: "Shards/\(sealed.fileName)")])
        let replacement = LibreReverseLibraryConfiguration(
            databaseURL: replacementURL, keyFileURL: library.keyFileURL,
            mediaRoot: library.mediaRoot)
        let shardID = try XCTUnwrap(
            LibreReverseShardStore.records(configuration: replacement).first?.id)
        let originalShard = try ArchiveIntegrityEngine.hash(file: shardURL)
        let coordinator = LibreReverseMeetingTitleUpdateCoordinator(library: replacement)

        let sealedContext = try await coordinator.updateContext(
            segmentID: meeting.segmentID, participants: [" Ada ", "Grace", "Ada"],
            calendarTitle: "  Product  ")

        XCTAssertEqual(
            sealedContext, .init(participants: ["Ada", "Grace"], calendarTitle: "Product"))
        XCTAssertEqual(try ArchiveIntegrityEngine.hash(file: shardURL), originalShard)
        XCTAssertEqual(
            try scalar(
                replacement,
                """
                SELECT COUNT(*) FROM event
                 WHERE segmentID=\(meeting.segmentID)
                   AND participants='["Ada","Grace"]'
                   AND calendarID='work'
                   AND calendarEventID='event-archived-context'
                   AND calendarSeriesID='series-archived-context'
                   AND detailsJSON LIKE '%"calendarTitle":"Product"%'
                   AND detailsJSON LIKE '%"futureField":"keep"%'
                """), 1)
        let session = LibraryDatabaseSession(
            configuration: .init(
                databaseURL: replacement.databaseURL, keyFileURL: replacement.keyFileURL,
                mediaRoot: replacement.mediaRoot)
        )
        let sealedTranscript = try await session.meetingTranscript(
            segmentID: meeting.segmentID, at: epoch)
        XCTAssertEqual(sealedTranscript?.metadata.participants, ["Ada", "Grace"])
        XCTAssertEqual(sealedTranscript?.metadata.calendarTitle, "Product")
        XCTAssertEqual(sealedTranscript?.text, "archived context words")
        await session.closeConnection()

        let parkedURL = root.appendingPathComponent("parked-context-shard.sqlite3")
        try FileManager.default.moveItem(at: shardURL, to: parkedURL)
        try LibreReverseShardArchiveStore.setShardState(
            shardID: shardID, from: .sealedLocal, to: .remoteOnly, configuration: replacement)

        let remoteContext = try await coordinator.updateContext(
            segmentID: meeting.segmentID, participants: ["Lin"], calendarTitle: nil)

        XCTAssertEqual(remoteContext, .init(participants: ["Lin"], calendarTitle: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shardURL.path))
        XCTAssertEqual(try ArchiveIntegrityEngine.hash(file: parkedURL), originalShard)
        XCTAssertEqual(
            try scalar(
                replacement,
                """
                SELECT COUNT(*) FROM event
                 WHERE segmentID=\(meeting.segmentID)
                   AND participants='["Lin"]'
                   AND calendarID='work'
                   AND calendarEventID='event-archived-context'
                   AND calendarSeriesID='series-archived-context'
                   AND detailsJSON NOT LIKE '%calendarTitle%'
                   AND detailsJSON LIKE '%"futureField":"keep"%'
                """), 1)
        XCTAssertTrue(
            try LibreReverseMeetingTitleUpdate.pendingPlans(configuration: replacement).isEmpty)
    }

    func testTranscriptReplacementIsRetrySafeAndUpdatesEverySearchIndex() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_100_000)
        let xid = "librereverse:meeting:replace"
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(20), relativeMediaPath: path,
                xid: xid, width: 1280, height: 720, frameRate: 30, audioStartTime: start,
                duration: 20, transcriptText: "temporary words",
                transcriptWords: [
                    .init(
                        speechSource: "others", word: "temporary", timeOffset: 0, fullTextOffset: 0,
                        duration: 10)
                ]), configuration: library)
        let finalWords: [LibreReverseTranscriptWordInput] = [
            .init(
                speechSource: "others", word: "final", timeOffset: 0, fullTextOffset: 0,
                duration: 10),
            .init(
                speechSource: "me", word: "answer", timeOffset: 10, fullTextOffset: 6, duration: 10),
        ]

        let firstDocument = try LibreReverseLibraryStore.replaceMeetingTranscript(
            segmentID: meeting.segmentID, title: "Meeting", transcriptText: "final answer",
            words: finalWords, configuration: library)
        let retryDocument = try LibreReverseLibraryStore.replaceMeetingTranscript(
            segmentID: meeting.segmentID, title: "Meeting", transcriptText: "final answer",
            words: finalWords, configuration: library)

        XCTAssertEqual(firstDocument, retryDocument)
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM transcript_word"), 2)
        XCTAssertEqual(
            try scalar(library, "SELECT COUNT(*) FROM doc_segment WHERE frameId IS NULL"), 1)
        for table in ["searchRanking", "search", "searchOffsets"] {
            XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM \(table)"), 1)
        }
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'temporary'"),
            0)
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'final'"), 1)
    }

    func testInvalidReplacementRollsBackWithoutDisturbingFinalizedTranscript() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_200_000)
        let xid = "librereverse:meeting:rollback"
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(10), relativeMediaPath: path,
                xid: xid, width: 640, height: 480, frameRate: 30, audioStartTime: start,
                duration: 10, transcriptText: "kept",
                transcriptWords: [
                    .init(
                        speechSource: "me", word: "kept", timeOffset: 1, fullTextOffset: 0,
                        duration: 1)
                ]), configuration: library)

        XCTAssertThrowsError(
            try LibreReverseLibraryStore.replaceMeetingTranscript(
                segmentID: meeting.segmentID, title: "Meeting", transcriptText: "bad order",
                words: [
                    .init(
                        speechSource: "me", word: "bad", timeOffset: 9, fullTextOffset: 0,
                        duration: 1),
                    .init(
                        speechSource: "me", word: "order", timeOffset: 2, fullTextOffset: 4,
                        duration: 1),
                ], configuration: library))
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM transcript_word"), 1)
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'kept'"), 1)
    }

    func testPublishedMeetingMovesIntoOwningShardAsOneLegacyGraph() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_300_000)
        let xid = "librereverse:meeting:shard"
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(60), relativeMediaPath: path,
                xid: xid, width: 1920, height: 1080, frameRate: 60, audioStartTime: start,
                duration: 60, transcriptText: "sharded transcript",
                transcriptWords: [
                    .init(
                        speechSource: "others", word: "sharded", timeOffset: 0, fullTextOffset: 0,
                        duration: 10),
                    .init(
                        speechSource: "others", word: "transcript", timeOffset: 10,
                        fullTextOffset: 8, duration: 10),
                ]), configuration: library)
        let epoch = Calendar(identifier: .gregorian).startOfDay(for: start)
        try execute(
            library,
            "UPDATE shard_metadata SET epochStart='\(databaseString(epoch))' WHERE id=1")
        let interval = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        let shardURL = root.appendingPathComponent("Library/Shards/\(interval.fileName)")
        try LibreReverseShardBuilder.prepare(
            source: library, destinationURL: shardURL, interval: interval)
        let manifest = try LibreReverseShardBuilder.buildToCompletion(
            source: library, destinationURL: shardURL, interval: interval, batchSize: 1)

        XCTAssertEqual(manifest.frameCount, 1)
        XCTAssertEqual(manifest.audioCount, 1)
        XCTAssertEqual(manifest.transcriptWordCount, 2)
        XCTAssertEqual(manifest.documentCount, 1)
        XCTAssertEqual(
            try scalar(
                shardURL, library.keyFileURL,
                """
                SELECT COUNT(*) FROM segment s
                JOIN frame f ON f.segmentId=s.id
                JOIN video v ON v.id=f.videoId
                JOIN audio a ON a.segmentId=s.id AND a.path=v.path
                JOIN transcript_word w ON w.segmentId=s.id
                JOIN doc_segment d ON d.segmentId=s.id AND d.frameId IS NULL
                WHERE s.type=1 AND v.captureType='meeting'
                """), 2)

        let replacementURL = root.appendingPathComponent("Library/export-primary.sqlite3")
        _ = try LibreReverseShardBuilder.buildReplacementPrimary(
            source: library, destinationURL: replacementURL,
            activeInterval: .init(ordinal: 1, epochStart: epoch),
            sealedShards: [.init(manifest: manifest, relativePath: "Shards/\(interval.fileName)")])
        let shardedSession = LibraryDatabaseSession(
            configuration: .init(
                databaseURL: replacementURL, keyFileURL: library.keyFileURL,
                mediaRoot: library.mediaRoot))
        let loadedTranscript = try await shardedSession.meetingTranscript(
            segmentID: meeting.segmentID, at: start)
        let transcript = try XCTUnwrap(loadedTranscript)
        let exported = try LibreReverseMeetingTranscriptExport.data(transcript, format: .losslessJSON)
        XCTAssertEqual(
            try LibreReverseMeetingTranscriptExport.transcript(fromLosslessJSON: exported), transcript
        )
        await shardedSession.closeConnection()
    }

    func testTranscriptCaptureServicePersistsLocalWordsAndSearchDocument() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_400_000)
        let xid = "librereverse:meeting:transcribe"
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(15), relativeMediaPath: path,
                xid: xid, width: 1280, height: 720, frameRate: 30, audioStartTime: start,
                duration: 15), configuration: library)
        let expected = MeetingTranscriptionResult(
            text: "captured locally", language: "en",
            words: [
                .init(
                    text: "captured", startSeconds: 0.25, endSeconds: 0.75, fullTextUTF16Offset: 0),
                .init(
                    text: "locally", startSeconds: 0.75, endSeconds: 1.25, fullTextUTF16Offset: 9),
            ])
        let service = MeetingTranscriptCaptureService(
            transcriber: StubTranscriber(result: expected),
            clock: try LegacyTranscriptClock(unitsPerSecond: 100), speechSource: "others")

        let outcome = try await service.transcribeAndPersist(
            mediaURL: library.mediaRoot.appendingPathComponent(path), segmentID: meeting.segmentID,
            title: "Captured meeting", configuration: library)

        XCTAssertEqual(outcome.transcription, expected)
        XCTAssertNotNil(outcome.documentID)
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM transcript_word"), 2)
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM transcript_word WHERE timeOffset=25 AND duration=50"),
            1)
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'captured'"),
            1)
    }

    func testDurableTranscriptionQueuePersistsThenClearsOnlyAfterAtomicTranscriptCommit()
        async throws
    {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_425_000)
        let xid = XID.generate(at: start)
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(20),
                windowName: "Published title", relativeMediaPath: path, xid: xid, width: 1280,
                height: 720, frameRate: 30, audioStartTime: start, duration: 20),
            configuration: library)
        let queue = LibreReverseMeetingTranscriptionQueue(
            root: root.appendingPathComponent("MeetingTranscriptionQueue"))
        let job = LibreReverseMeetingTranscriptionJob(
            publicationXID: xid, segmentID: meeting.segmentID, videoID: meeting.videoID,
            title: "Queued sync", relativeMediaPath: path, createdAt: start)
        try queue.enqueue(job)
        XCTAssertEqual(try queue.ready(at: start), [job])
        XCTAssertEqual(try queue.job(segmentID: meeting.segmentID), job)
        XCTAssertEqual(job.processingState, .queued)
        XCTAssertThrowsError(try queue.retryNow(segmentID: meeting.segmentID)) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingTranscriptionQueueError,
                .retryNotNeeded(meeting.segmentID))
        }
        _ = try LibreReverseLibraryStore.updateMeetingTitle(
            segmentID: meeting.segmentID, title: "Renamed while queued", configuration: library)
        let expected = MeetingTranscriptionResult(
            text: "durable words", language: "en",
            words: [
                .init(text: "durable", startSeconds: 1.8, endSeconds: 2.2, fullTextUTF16Offset: 0),
                .init(text: "words", startSeconds: 2.2, endSeconds: 2.9, fullTextUTF16Offset: 8),
            ])
        let transcriber = CheckpointingStubTranscriber(result: expected)
        let checkpoint = queue.checkpointContext(for: job, encryptionKeyURL: library.keyFileURL)
        let runner = LibreReverseMeetingTranscriptionRunner(
            queue: queue, library: library, transcriber: transcriber)

        let run = await runner.runReady(at: start)
        XCTAssertEqual(run, .init(completed: 1, failed: 0))
        XCTAssertTrue(try queue.pending().isEmpty)
        let summaryJob = try XCTUnwrap(LibreReverseLibraryStore.pendingMeetingSummaries(configuration: library).first)
        XCTAssertEqual(summaryJob.segmentID, meeting.segmentID)
        XCTAssertEqual(summaryJob.transcript, "durable words")
        try LibreReverseLibraryStore.finishMeetingSummary(eventID: summaryJob.eventID, text: nil, configuration: library, now: start)
        XCTAssertTrue(try LibreReverseLibraryStore.pendingMeetingSummaries(configuration: library, now: start).isEmpty)
        XCTAssertEqual(try LibreReverseLibraryStore.pendingMeetingSummaries(configuration: library, now: start.addingTimeInterval(60)).count, 1)
        try LibreReverseLibraryStore.finishMeetingSummary(eventID: summaryJob.eventID, text: "Local summary", configuration: library)
        try LibreReverseLibraryStore.enqueueMeetingSummary(segmentID: meeting.segmentID, configuration: library)
        XCTAssertTrue(try LibreReverseLibraryStore.pendingMeetingSummaries(configuration: library).isEmpty)
        let receivedCheckpoint = await transcriber.receivedCheckpoint()
        XCTAssertEqual(receivedCheckpoint, checkpoint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.url.path))
        XCTAssertNil(try queue.job(segmentID: meeting.segmentID))
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM transcript_word WHERE segmentId=\(meeting.segmentID)"
            ), 2)
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'durable'"),
            1)
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM searchRanking WHERE title='Renamed while queued'"), 1
        )
        XCTAssertEqual(
            try scalar(
                library, "SELECT activeLeases FROM media_residency WHERE videoId=\(meeting.videoID)"
            ), 0)
    }

    func testCorruptTranscriptionJobRepairsFromCanonicalPublicationAndRetainsCheckpoint()
        async throws
    {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_427_000)
        let xid = XID.generate(at: start)
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(20),
                windowName: "Authoritative repair title", relativeMediaPath: path, xid: xid,
                width: 1280, height: 720, frameRate: 30, audioStartTime: start, duration: 20),
            configuration: library)
        let queueRoot = root.appendingPathComponent("MeetingTranscriptionQueue")
        let queue = LibreReverseMeetingTranscriptionQueue(root: queueRoot)
        try FileManager.default.createDirectory(at: queueRoot, withIntermediateDirectories: true)
        try Data("{ definitely not a job".utf8).write(
            to: queueRoot.appendingPathComponent("\(xid).json"))
        try Data("unresolvable".utf8).write(to: queueRoot.appendingPathComponent("bad xid.json"))
        let identity = LibreReverseMeetingTranscriptionJob(
            publicationXID: xid, segmentID: meeting.segmentID, videoID: meeting.videoID,
            title: "ignored", relativeMediaPath: path)
        let checkpoint = queue.checkpointContext(
            for: identity, encryptionKeyURL: library.keyFileURL)
        let checkpointBytes = Data("authenticated checkpoint bytes".utf8)
        try checkpointBytes.write(to: checkpoint.url)

        let repair = try queue.repairCorruptJobs(configuration: library)

        XCTAssertEqual(repair.recoveredPublicationXIDs, [xid])
        XCTAssertTrue(repair.retiredPublicationXIDs.isEmpty)
        XCTAssertEqual(repair.unresolvedFileNames, ["bad xid.json"])
        let recovered = try XCTUnwrap(queue.job(segmentID: meeting.segmentID))
        XCTAssertEqual(recovered.publicationXID, xid)
        XCTAssertEqual(recovered.segmentID, meeting.segmentID)
        XCTAssertEqual(recovered.videoID, meeting.videoID)
        XCTAssertEqual(recovered.title, "Authoritative repair title")
        XCTAssertEqual(recovered.relativeMediaPath, path)
        XCTAssertEqual(recovered.createdAt, start)
        XCTAssertEqual(recovered.attempt, 0)
        XCTAssertNil(recovered.retryAfter)
        XCTAssertNil(recovered.lastError)
        XCTAssertEqual(try Data(contentsOf: checkpoint.url), checkpointBytes)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: queueRoot.appendingPathComponent("bad xid.json").path))

        let runner = LibreReverseMeetingTranscriptionRunner(
            queue: queue, library: library,
            transcriber: StubTranscriber(
                result: .init(
                    text: "repaired transcript", language: "en",
                    words: [
                        .init(
                            text: "repaired", startSeconds: 0, endSeconds: 1, fullTextUTF16Offset: 0
                        )
                    ])))
        let run = await runner.runReady(at: start)
        XCTAssertEqual(run, .init(completed: 1, failed: 0))
        XCTAssertNil(try queue.job(segmentID: meeting.segmentID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.url.path))
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM transcript_word WHERE segmentId=\(meeting.segmentID)"
            ), 1)
    }

    func testSemanticTranscriptionJobCorruptionRebuildsBeforeRunnerDrain() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_427_500)
        let xid = XID.generate(at: start)
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(20),
                windowName: "Semantic repair", relativeMediaPath: path, xid: xid, width: 1280,
                height: 720, frameRate: 30, audioStartTime: start, duration: 20),
            configuration: library)
        let queueRoot = root.appendingPathComponent("MeetingTranscriptionQueue")
        let queue = LibreReverseMeetingTranscriptionQueue(root: queueRoot)
        let original = LibreReverseMeetingTranscriptionJob(
            publicationXID: xid, segmentID: meeting.segmentID, videoID: meeting.videoID,
            title: "Semantic repair", relativeMediaPath: path, createdAt: start)
        try queue.enqueue(original)
        let jobURL = queueRoot.appendingPathComponent("\(xid).json")
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: jobURL)) as? [String: Any])
        payload["schemaVersion"] = 99
        payload["publicationXID"] = "wrong-xid"
        payload["videoID"] = meeting.videoID + 999
        payload["attempt"] = -4
        try JSONSerialization.data(withJSONObject: payload).write(to: jobURL, options: .atomic)
        let checkpoint = queue.checkpointContext(
            for: original, encryptionKeyURL: library.keyFileURL)
        let checkpointBytes = Data("bound encrypted progress".utf8)
        try checkpointBytes.write(to: checkpoint.url)

        let transcriber = BlockingTranscriber(
            result: .init(
                text: "semantic repair drained", language: "en",
                words: [
                    .init(text: "semantic", startSeconds: 0, endSeconds: 1, fullTextUTF16Offset: 0)
                ]))
        let runner = LibreReverseMeetingTranscriptionRunner(
            queue: queue, library: library, transcriber: transcriber)
        let runTask = Task { await runner.runReady(at: start) }
        await transcriber.waitUntilStarted()

        let recovered = try XCTUnwrap(queue.job(segmentID: meeting.segmentID))
        XCTAssertEqual(recovered.schemaVersion, 1)
        XCTAssertEqual(recovered.publicationXID, xid)
        XCTAssertEqual(recovered.segmentID, meeting.segmentID)
        XCTAssertEqual(recovered.videoID, meeting.videoID)
        XCTAssertEqual(recovered.relativeMediaPath, path)
        XCTAssertEqual(recovered.attempt, 0)
        XCTAssertNil(recovered.retryAfter)
        XCTAssertNil(recovered.lastError)
        XCTAssertEqual(try Data(contentsOf: checkpoint.url), checkpointBytes)

        await transcriber.release()
        let run = await runTask.value
        XCTAssertEqual(run, .init(completed: 1, failed: 0))
        XCTAssertTrue(try queue.pending().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.url.path))
    }

    func testCorruptTranscriptionJobRetiresOnlyAfterCanonicalCompletion() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_428_000)
        let xid = XID.generate(at: start)
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(20), relativeMediaPath: path,
                xid: xid, width: 1280, height: 720, frameRate: 30, audioStartTime: start,
                duration: 20), configuration: library)
        _ = try LibreReverseLibraryStore.replaceMeetingTranscript(
            segmentID: meeting.segmentID, title: "Silent completion", transcriptText: "", words: [],
            configuration: library)
        let queueRoot = root.appendingPathComponent("MeetingTranscriptionQueue")
        let queue = LibreReverseMeetingTranscriptionQueue(root: queueRoot)
        try FileManager.default.createDirectory(at: queueRoot, withIntermediateDirectories: true)
        let jobURL = queueRoot.appendingPathComponent("\(xid).json")
        let checkpointURL = queueRoot.appendingPathComponent("\(xid).checkpoint")
        try Data("corrupt".utf8).write(to: jobURL)
        try Data("obsolete checkpoint".utf8).write(to: checkpointURL)

        let repair = try queue.repairCorruptJobs(configuration: library)

        XCTAssertTrue(repair.recoveredPublicationXIDs.isEmpty)
        XCTAssertEqual(repair.retiredPublicationXIDs, [xid])
        XCTAssertTrue(repair.unresolvedFileNames.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jobURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointURL.path))
    }

    func testRepairRetiresValidJobAfterTranscriptCommitBeforeQueueCompletion() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_428_500)
        let xid = XID.generate(at: start)
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(20), relativeMediaPath: path,
                xid: xid, width: 1280, height: 720, frameRate: 30, audioStartTime: start,
                duration: 20), configuration: library)
        let queue = LibreReverseMeetingTranscriptionQueue(
            root: root.appendingPathComponent("MeetingTranscriptionQueue"))
        let job = LibreReverseMeetingTranscriptionJob(
            publicationXID: xid, segmentID: meeting.segmentID, videoID: meeting.videoID,
            title: "Committed before cleanup", relativeMediaPath: path, createdAt: start)
        try queue.enqueue(job)
        let checkpoint = queue.checkpointContext(for: job, encryptionKeyURL: library.keyFileURL)
        try Data("obsolete committed progress".utf8).write(to: checkpoint.url)
        _ = try LibreReverseLibraryStore.replaceMeetingTranscript(
            segmentID: meeting.segmentID, title: job.title, transcriptText: "already committed",
            words: [
                .init(
                    speechSource: "unknown", word: "already", timeOffset: 0, fullTextOffset: 0,
                    duration: 1)
            ], configuration: library)

        let repair = try queue.repairCorruptJobs(configuration: library)

        XCTAssertTrue(repair.recoveredPublicationXIDs.isEmpty)
        XCTAssertEqual(repair.retiredPublicationXIDs, [xid])
        XCTAssertTrue(repair.unresolvedFileNames.isEmpty)
        XCTAssertTrue(try queue.pending().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.url.path))
    }

    func testDuplicatePublicationXIDFailsClosedAcrossReplayAndQueueRepair() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_429_000)
        let xid = XID.generate(at: start)
        let path = try makeMedia(xid: xid, date: start, library: library)
        let first = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(20), relativeMediaPath: path,
                xid: xid, width: 1280, height: 720, frameRate: 30, audioStartTime: start,
                duration: 20), configuration: library)
        // Multiple frames may legitimately map one video to one meeting. They
        // must not be mistaken for multiple publication owners.
        try execute(
            library,
            """
            INSERT INTO frame(
              createdAt,imageFileName,segmentId,videoId,videoFrameIndex,isStarred,encodingStatus
            ) VALUES(
              '\(databaseString(start.addingTimeInterval(1)))','',\(first.segmentID),
              \(first.videoID),1,0,'success'
            )
            """)
        XCTAssertEqual(
            try LibreReverseLibraryStore.publishedMeeting(xid: xid, configuration: library), first)

        _ = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start.addingTimeInterval(30), endDate: start.addingTimeInterval(50),
                relativeMediaPath: path, xid: xid, width: 1280, height: 720, frameRate: 30,
                audioStartTime: start.addingTimeInterval(30), duration: 20), configuration: library)
        let ambiguity = LibreReverseLibraryStoreError.invalidMeeting(
            "Meeting publication XID is ambiguous: \(xid)")
        XCTAssertThrowsError(
            try LibreReverseLibraryStore.publishedMeeting(xid: xid, configuration: library)
        ) { error in XCTAssertEqual(error as? LibreReverseLibraryStoreError, ambiguity) }
        XCTAssertEqual(
            LibreReverseMeetingRecoveryFailureClassifier.disposition(for: ambiguity), .reject)

        let missingStaging = root.appendingPathComponent("staging/ambiguous.mp4")
        let capture = LibreReverseFinalizedMeetingCapture(
            stagingMediaURL: missingStaging,
            manifest: completedManifest(staging: missingStaging, start: start),
            candidate: .init(
                provider: .zoom, source: .windowDetection, windowID: 9, title: "Ambiguous replay"),
            publicationXID: xid)
        XCTAssertThrowsError(
            try LibreReverseMeetingCaptureFinalizer.publish(capture, configuration: library)
        ) { error in XCTAssertEqual(error as? LibreReverseLibraryStoreError, ambiguity) }

        let validStart = start.addingTimeInterval(90)
        let validXID = XID.generate(at: validStart)
        let validPath = try makeMedia(xid: validXID, date: validStart, library: library)
        let validMeeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: validStart, endDate: validStart.addingTimeInterval(20),
                windowName: "Repair while neighbor is ambiguous", relativeMediaPath: validPath,
                xid: validXID, width: 1280, height: 720, frameRate: 30, audioStartTime: validStart,
                duration: 20), configuration: library)
        let queueRoot = root.appendingPathComponent("MeetingTranscriptionQueue")
        try FileManager.default.createDirectory(at: queueRoot, withIntermediateDirectories: true)
        let jobURL = queueRoot.appendingPathComponent("\(xid).json")
        let damagedBytes = Data("ambiguous damaged job".utf8)
        try damagedBytes.write(to: jobURL)
        let validJobURL = queueRoot.appendingPathComponent("\(validXID).json")
        try Data("another damaged job".utf8).write(to: validJobURL)
        let queue = LibreReverseMeetingTranscriptionQueue(root: queueRoot)
        let repair = try queue.repairCorruptJobs(configuration: library)
        XCTAssertEqual(repair.recoveredPublicationXIDs, [validXID])
        XCTAssertTrue(repair.retiredPublicationXIDs.isEmpty)
        XCTAssertEqual(repair.unresolvedFileNames, [jobURL.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: jobURL), damagedBytes)
        XCTAssertEqual(try queue.job(segmentID: validMeeting.segmentID)?.publicationXID, validXID)
    }

    func testFailedTranscriptionRetainsJobWithBackoffAndReleasesArchiveLease() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_430_000)
        let xid = XID.generate(at: start)
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(20), relativeMediaPath: path,
                xid: xid, width: 1280, height: 720, frameRate: 30, audioStartTime: start,
                duration: 20), configuration: library)
        let queue = LibreReverseMeetingTranscriptionQueue(
            root: root.appendingPathComponent("MeetingTranscriptionQueue"))
        try queue.enqueue(
            .init(
                publicationXID: xid, segmentID: meeting.segmentID, videoID: meeting.videoID,
                title: "Retry sync", relativeMediaPath: path, createdAt: start))
        let runner = LibreReverseMeetingTranscriptionRunner(
            queue: queue, library: library, transcriber: FailingTranscriber())

        let run = await runner.runReady(at: start)
        XCTAssertEqual(run, .init(completed: 0, failed: 1))
        let retained = try XCTUnwrap(queue.pending().first)
        XCTAssertEqual(retained.attempt, 1)
        XCTAssertEqual(retained.retryAfter, start.addingTimeInterval(30))
        XCTAssertNotNil(retained.lastError)
        XCTAssertEqual(
            retained.processingState,
            .retrying(attempt: 1, retryAfter: start.addingTimeInterval(30)))
        XCTAssertEqual(
            retained.processingState(at: start.addingTimeInterval(29)),
            .retrying(attempt: 1, retryAfter: start.addingTimeInterval(30)))
        XCTAssertEqual(retained.processingState(at: start.addingTimeInterval(30)), .queued)
        let checkpoint = queue.checkpointContext(
            for: retained, encryptionKeyURL: library.keyFileURL)
        let checkpointBytes = Data("encrypted-window-checkpoint".utf8)
        try checkpointBytes.write(to: checkpoint.url, options: .atomic)

        let retried = try queue.retryNow(segmentID: meeting.segmentID)
        XCTAssertEqual(retried.attempt, retained.attempt)
        XCTAssertEqual(retried.lastError, retained.lastError)
        XCTAssertNil(retried.retryAfter)
        XCTAssertEqual(retried.processingState, .queued)
        XCTAssertEqual(try queue.ready(at: start), [retried])
        XCTAssertEqual(try Data(contentsOf: checkpoint.url), checkpointBytes)
        XCTAssertThrowsError(
            try queue.recordFailure(retained, error: FailingTranscriber.Failure(), now: start)
        ) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingTranscriptionQueueError,
                .staleJob(retained.publicationXID))
        }
        XCTAssertEqual(try queue.job(segmentID: meeting.segmentID), retried)
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM transcript_word"), 0)
        XCTAssertEqual(
            try scalar(
                library, "SELECT activeLeases FROM media_residency WHERE videoId=\(meeting.videoID)"
            ), 0)
        XCTAssertThrowsError(try queue.retryNow(segmentID: meeting.segmentID + 1)) { error in
            XCTAssertEqual(
                error as? LibreReverseMeetingTranscriptionQueueError,
                .missingJob(meeting.segmentID + 1))
        }
        // A transcript commit wins over deadline-only retry presentation state
        // for the same immutable publication, even if it began before Retry.
        try queue.complete(retained)
        XCTAssertNil(try queue.job(segmentID: meeting.segmentID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.url.path))
        try queue.complete(retained)
    }

    func testCancelledNonCooperativeTranscriptionDoesNotCommitOrConsumeJob() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_435_000)
        let xid = XID.generate(at: start)
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(20), relativeMediaPath: path,
                xid: xid, width: 1280, height: 720, frameRate: 30, audioStartTime: start,
                duration: 20), configuration: library)
        let queue = LibreReverseMeetingTranscriptionQueue(
            root: root.appendingPathComponent("MeetingTranscriptionQueue"))
        try queue.enqueue(
            .init(
                publicationXID: xid, segmentID: meeting.segmentID, videoID: meeting.videoID,
                title: "Cancelled sync", relativeMediaPath: path, createdAt: start))
        let transcriber = BlockingTranscriber(
            result: .init(
                text: "must not commit", language: "en",
                words: [.init(text: "must", startSeconds: 0, endSeconds: 1, fullTextUTF16Offset: 0)]
            ))
        let runner = LibreReverseMeetingTranscriptionRunner(
            queue: queue, library: library, transcriber: transcriber)

        let runTask = Task { await runner.runReady(at: start) }
        await transcriber.waitUntilStarted()
        runTask.cancel()
        await transcriber.release()

        let run = await runTask.value
        XCTAssertEqual(run, .init(completed: 0, failed: 0))
        XCTAssertEqual(try queue.pending().count, 1)
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM transcript_word"), 0)
        XCTAssertEqual(try scalar(library, "SELECT COUNT(*) FROM searchRanking"), 0)
        XCTAssertEqual(
            try scalar(
                library, "SELECT activeLeases FROM media_residency WHERE videoId=\(meeting.videoID)"
            ), 0)
    }

    func testCancelledRunnerDoesNotPersistTranslatedBackendFailure() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_437_000)
        let xid = XID.generate(at: start)
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(20), relativeMediaPath: path,
                xid: xid, width: 1280, height: 720, frameRate: 30, audioStartTime: start,
                duration: 20), configuration: library)
        let queue = LibreReverseMeetingTranscriptionQueue(
            root: root.appendingPathComponent("MeetingTranscriptionQueue"))
        let job = LibreReverseMeetingTranscriptionJob(
            publicationXID: xid, segmentID: meeting.segmentID, videoID: meeting.videoID,
            title: "Translated cancellation", relativeMediaPath: path, createdAt: start)
        try queue.enqueue(job)
        let transcriber = CancellationTranslatingTranscriber()
        let runner = LibreReverseMeetingTranscriptionRunner(
            queue: queue, library: library, transcriber: transcriber)

        let runTask = Task { await runner.runReady(at: start) }
        await transcriber.waitUntilStarted()
        runTask.cancel()
        await transcriber.release()

        let run = await runTask.value
        XCTAssertEqual(run, .init(completed: 0, failed: 0))
        XCTAssertEqual(try queue.job(segmentID: meeting.segmentID), job)
    }

    func testActiveTranscriptionLeasePreventsVerifiedMeetingEviction() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive", remoteRoot: "rewind", configuration: library)
        let start = Date(timeIntervalSince1970: 1_700_440_000)
        let xid = XID.generate(at: start)
        let path = try makeMedia(xid: xid, date: start, library: library)
        let canonical = library.mediaRoot.appendingPathComponent(path)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(20), relativeMediaPath: path,
                xid: xid, width: 1280, height: 720, frameRate: 30, audioStartTime: start,
                duration: 20), configuration: library)
        let backend = MeetingArchiveBackend()
        let archive = LibreReverseArchiveCoordinator(
            destinationID: destinationID, library: library, backend: backend)
        let uploaded = try await archive.runUntilIdle()
        XCTAssertEqual(uploaded, 1)
        try LibreReverseArchiveStore.updatePolicy(
            .init(requiredLocalSeconds: 0, rehydratedCacheBytes: 0), destinationID: destinationID,
            configuration: library)
        let queue = LibreReverseMeetingTranscriptionQueue(
            root: root.appendingPathComponent("MeetingTranscriptionQueue"))
        try queue.enqueue(
            .init(
                publicationXID: xid, segmentID: meeting.segmentID, videoID: meeting.videoID,
                title: "Leased sync", relativeMediaPath: path, createdAt: start))
        let transcriber = BlockingTranscriber(
            result: .init(
                text: "lease held", language: "en",
                words: [
                    .init(text: "lease", startSeconds: 0, endSeconds: 1, fullTextUTF16Offset: 0),
                    .init(text: "held", startSeconds: 1, endSeconds: 2, fullTextUTF16Offset: 6),
                ]))
        let runner = LibreReverseMeetingTranscriptionRunner(
            queue: queue, library: library, transcriber: transcriber)
        let runTask = Task { await runner.runReady(at: start) }
        await transcriber.waitUntilStarted()
        XCTAssertEqual(
            try scalar(
                library, "SELECT activeLeases FROM media_residency WHERE videoId=\(meeting.videoID)"
            ), 1)
        let residency = LibreReverseMediaResidencyManager(
            destinationID: destinationID, library: library, backend: backend, handoffGraceSeconds: 0
        )
        let evictionWhileLeased = try await residency.evictEligible()
        XCTAssertEqual(evictionWhileLeased, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonical.path))

        await transcriber.release()
        let run = await runTask.value
        XCTAssertEqual(run, .init(completed: 1, failed: 0))
        let evictionAfterTranscription = try await residency.evictEligible()
        XCTAssertEqual(evictionAfterTranscription, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))
    }

    func testMeetingBrowserIncludesUntranscribedMeetingsAndPaginates() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_450_000)
        var ids: [Int64] = []
        for index in 0..<3 {
            let date = start.addingTimeInterval(Double(index) * 120)
            let xid = "librereverse:meeting:browse\(index)"
            let path = try makeMedia(xid: xid, date: date, library: library)
            let meeting = try LibreReverseLibraryStore.publishMeeting(.init(
                startDate: date, endDate: date.addingTimeInterval(60),
                windowName: "Meeting \(index)", relativeMediaPath: path, xid: xid,
                width: 1280, height: 720, frameRate: 30, audioStartTime: date,
                duration: 60), configuration: library)
            ids.append(meeting.segmentID)
        }
        let session = LibraryDatabaseSession(configuration: .init(
            databaseURL: library.databaseURL, keyFileURL: library.keyFileURL,
            mediaRoot: library.mediaRoot))
        let first = try await session.recencyTranscriptSearchPage(query: "", pageSize: 2)
        XCTAssertEqual(first.results.map { $0.result.candidate.segmentID }, Array(ids.reversed().prefix(2)))
        XCTAssertTrue(first.hasMore)
        let second = try await session.recencyTranscriptSearchPage(query: "", before: first.nextCursor,
            pageSize: 2, previousResults: first.results)
        XCTAssertEqual(second.results.map { $0.result.candidate.segmentID }, [ids[0]])
        XCTAssertFalse(second.hasMore)
        await session.closeConnection()
    }

    func testStarredTranscriptFacetPagesTiedMeetingsBeforeAndAfterSharding() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let epoch = Date(timeIntervalSince1970: 1_700_450_000)
        var starredIDs: [Int64] = []
        for index in 0..<5 {
            // Equal dates force the cursor to use its document-ID tie break.
            let start = epoch.addingTimeInterval(100)
            let xid = "librereverse:meeting:star-page-\(index)"
            let path = try makeMedia(xid: xid, date: start, library: library)
            let meeting = try LibreReverseLibraryStore.publishMeeting(.init(
                startDate: start, endDate: start.addingTimeInterval(60),
                windowName: "Starred page \(index)", relativeMediaPath: path, xid: xid,
                width: 1280, height: 720, frameRate: 30, audioStartTime: start,
                duration: 60, transcriptText: "unique meeting transcript \(index)"), configuration: library)
            if index != 2 {
                try execute(library, "UPDATE frame SET isStarred=1 WHERE segmentId=\(meeting.segmentID)")
                starredIDs.append(meeting.segmentID)
            }
        }
        func checkPages(_ configuration: LibreReverseLibraryConfiguration) async throws {
            let session = LibraryDatabaseSession(configuration: .init(
                databaseURL: configuration.databaseURL, keyFileURL: configuration.keyFileURL,
                mediaRoot: configuration.mediaRoot))
            let facets = SearchFacets(isStarred: true, isTranscript: true)
            let first = try await session.recencyTranscriptSearchPage(query: "", facets: facets, pageSize: 2)
            XCTAssertEqual(first.results.count, 2)
            XCTAssertTrue(first.hasMore)
            let second = try await session.recencyTranscriptSearchPage(query: "", facets: facets,
                before: first.nextCursor, pageSize: 2, previousResults: first.results)
            XCTAssertEqual(second.results.count, 2)
            XCTAssertFalse(second.hasMore)
            let ids = (first.results + second.results).map { $0.result.candidate.segmentID }
            XCTAssertEqual(ids, Array(starredIDs.reversed()))
            await session.closeConnection()
        }
        try await checkPages(library)
        let interval = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        let manifest = try LibreReverseShardBuilder.buildToCompletion(source: library,
            destinationURL: root.appendingPathComponent("Library/Shards/\(interval.fileName)"),
            interval: interval, batchSize: 2)
        let replacementURL = root.appendingPathComponent("Library/star-primary.sqlite3")
        _ = try LibreReverseShardBuilder.buildReplacementPrimary(source: library,
            destinationURL: replacementURL, activeInterval: .init(ordinal: 1, epochStart: epoch),
            sealedShards: [.init(manifest: manifest, relativePath: "Shards/\(interval.fileName)")])
        try await checkPages(.init(databaseURL: replacementURL,
            keyFileURL: library.keyFileURL, mediaRoot: library.mediaRoot))
    }

    func testTranscriptSearchResolvesMatchedLegacyWordToMeetingSeekInstant() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_450_000)
        let xid = "librereverse:meeting:search"
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(60),
                windowName: "Searchable sync", relativeMediaPath: path, xid: xid, width: 1280,
                height: 720, frameRate: 30, audioStartTime: start, duration: 60,
                transcriptText: "intro words needle appears",
                transcriptWords: [
                    .init(
                        speechSource: "others", word: "intro", timeOffset: 0, fullTextOffset: 0,
                        duration: 1),
                    .init(
                        speechSource: "others", word: "words", timeOffset: 2, fullTextOffset: 6,
                        duration: 1),
                    .init(
                        speechSource: "others", word: "needle", timeOffset: 7, fullTextOffset: 12,
                        duration: 1),
                    .init(
                        speechSource: "others", word: "appears", timeOffset: 8, fullTextOffset: 19,
                        duration: 1),
                ],
                event: .init(
                    title: "Searchable sync", participants: "[\" Ada \",\"Grace\",\"\"]",
                    detailsJSON:
                        "{\"provider\":\"teams\",\"source\":\"windowDetection\",\"calendarTitle\":\"Work\"}",
                    calendarID: "calendar-work", calendarEventID: "event-42",
                    calendarSeriesID: "series-42")), configuration: library)
        let session = LibraryDatabaseSession(
            configuration: .init(
                databaseURL: library.databaseURL, keyFileURL: library.keyFileURL,
                mediaRoot: library.mediaRoot))

        let allMeetings = try await session.recencyTranscriptSearchPage(query: "")
        XCTAssertEqual(allMeetings.results.map { $0.result.candidate.segmentID }, [meeting.segmentID])
        XCTAssertEqual(allMeetings.results.first?.result.representativeInstant, start)
        let noMatches = try await session.recencyTranscriptSearchPage(query: "absentphrase")
        XCTAssertTrue(noMatches.results.isEmpty)

        let page = try await session.recencyTranscriptSearchPage(query: "needle")

        XCTAssertEqual(page.results.count, 1)
        let result = try XCTUnwrap(page.results.first?.result)
        XCTAssertEqual(result.segmentType, .audio)
        XCTAssertEqual(result.resolvedTitle, "Searchable sync")
        XCTAssertEqual(result.transcriptDetails?.transcript, "intro words needle appears")
        XCTAssertEqual(result.transcriptDetails?.matchInstant, start.addingTimeInterval(7))
        XCTAssertNil(result.matchRectangle)
        let moment = try await session.meetingMoment(
            segmentID: meeting.segmentID, at: start.addingTimeInterval(7))
        XCTAssertEqual(moment?.segmentID, meeting.segmentID)
        XCTAssertEqual(moment?.segmentType, SegmentType.audio.rawValue)
        XCTAssertEqual(moment?.videoFrameIndex, 0)
        let transcript = try await session.meetingTranscript(
            segmentID: meeting.segmentID, at: start.addingTimeInterval(7))
        XCTAssertEqual(transcript?.text, "intro words needle appears")
        XCTAssertEqual(transcript?.processingState, .complete)
        XCTAssertEqual(transcript?.words.map(\.text), ["intro", "words", "needle", "appears"])
        XCTAssertEqual(transcript?.metadata.provider, .microsoftTeams)
        XCTAssertEqual(transcript?.metadata.source, .windowDetection)
        XCTAssertEqual(transcript?.metadata.calendarTitle, "Work")
        XCTAssertEqual(transcript?.metadata.participants, ["Ada", "Grace"])
        XCTAssertEqual(transcript?.metadata.calendarID, "calendar-work")
        XCTAssertEqual(transcript?.metadata.calendarEventID, "event-42")
        XCTAssertEqual(transcript?.metadata.calendarSeriesID, "series-42")
        XCTAssertEqual(
            transcript?.metadata.compactLabels, ["Microsoft Teams", "Work", "2 participants"])
        XCTAssertEqual(transcript?.updatingTitle("Renamed").metadata, transcript?.metadata)
        let editedContext = transcript?.updatingContext(
            .init(participants: ["Lin"], calendarTitle: "Product"))
        XCTAssertEqual(editedContext?.metadata.participants, ["Lin"])
        XCTAssertEqual(editedContext?.metadata.calendarTitle, "Product")
        XCTAssertEqual(editedContext?.metadata.provider, transcript?.metadata.provider)
        XCTAssertEqual(editedContext?.metadata.calendarID, "calendar-work")
        XCTAssertEqual(editedContext?.metadata.calendarEventID, "event-42")
        XCTAssertEqual(editedContext?.metadata.calendarSeriesID, "series-42")
        XCTAssertEqual(editedContext?.words, transcript?.words)
        XCTAssertEqual(transcript?.activeWordIndex(at: start.addingTimeInterval(7.5)), 2)
        let loadedTranscript = try XCTUnwrap(transcript)
        let matchedWordIndex = try XCTUnwrap(
            loadedTranscript.words.firstIndex(where: { $0.text == "needle" }))
        let wordSeekDate = try XCTUnwrap(loadedTranscript.wallDate(forWordAt: matchedWordIndex))
        XCTAssertEqual(wordSeekDate, result.transcriptDetails?.matchInstant)
        XCTAssertNil(loadedTranscript.wallDate(forWordAt: -1))
        XCTAssertNil(loadedTranscript.wallDate(forWordAt: loadedTranscript.words.count))
        let resolvedMoment = try XCTUnwrap(moment)
        XCTAssertEqual(
            LibreReverseMeetingPlaybackTiming.mediaTime(
                requestedDate: wordSeekDate, segmentStartDate: resolvedMoment.segmentStartDate,
                segmentType: resolvedMoment.segmentType.flatMap(
                    SegmentType.init(rawValue:)),
                anchorFrameIndex: try XCTUnwrap(resolvedMoment.videoFrameIndex),
                frameRate: try XCTUnwrap(resolvedMoment.videoFrameRate)),
            loadedTranscript.words[matchedWordIndex].startSeconds)
    }

    func testSilentMeetingRemainsReadableForDetailsRenameAndDeletionUI() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_455_000)
        let xid = "librereverse:meeting:silent"
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(45), windowName: "Quiet sync",
                relativeMediaPath: path, xid: xid, width: 1280, height: 720, frameRate: 30,
                audioStartTime: start, duration: 45, transcriptText: "", transcriptWords: [],
                event: .init(
                    title: "Quiet sync", participants: "[\"Ada\"]",
                    detailsJSON: "{\"provider\":\"zoom\",\"source\":\"windowDetection\"}")),
            configuration: library)
        let session = LibraryDatabaseSession(
            configuration: .init(
                databaseURL: library.databaseURL, keyFileURL: library.keyFileURL,
                mediaRoot: library.mediaRoot))

        let transcript = try await session.meetingTranscript(
            segmentID: meeting.segmentID, at: start)

        XCTAssertNotNil(transcript)
        XCTAssertFalse(try XCTUnwrap(transcript).hasTranscriptText)
        XCTAssertTrue(transcript?.words.isEmpty == true)
        XCTAssertEqual(transcript?.metadata.provider, .zoom)
        XCTAssertEqual(transcript?.metadata.participants, ["Ada"])
        XCTAssertEqual(transcript?.metadata.compactLabels, ["Zoom", "1 participant"])
        XCTAssertEqual(transcript?.processingState, .unavailable)
        XCTAssertEqual(transcript?.processingState.emptyStateDescription, "No transcript available")
    }

    func testCompletedSilentTranscriptionPersistsLegacyCompatibleCompletionMarker() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_456_000)
        let xid = "librereverse:meeting:completed-silence"
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(30),
                windowName: "Silent review", relativeMediaPath: path, xid: xid, width: 1280,
                height: 720, frameRate: 30, audioStartTime: start, duration: 30),
            configuration: library)

        XCTAssertEqual(
            try scalar(library, "SELECT COUNT(*) FROM doc_segment WHERE frameId IS NULL"), 0)
        let documentID = try LibreReverseLibraryStore.replaceMeetingTranscript(
            segmentID: meeting.segmentID, title: "Silent review", transcriptText: "", words: [],
            configuration: library)
        XCTAssertNotNil(documentID)
        XCTAssertEqual(
            try scalar(library, "SELECT COUNT(*) FROM doc_segment WHERE frameId IS NULL"), 1)
        let session = LibraryDatabaseSession(
            configuration: .init(
                databaseURL: library.databaseURL, keyFileURL: library.keyFileURL,
                mediaRoot: library.mediaRoot))
        let loaded = try await session.meetingTranscript(segmentID: meeting.segmentID, at: start)
        let transcript = try XCTUnwrap(loaded)
        XCTAssertFalse(transcript.hasTranscriptText)
        XCTAssertEqual(transcript.processingState, .complete)
        XCTAssertEqual(transcript.processingState.emptyStateDescription, "No speech detected")
    }

    func testOfflineMeetingPipelineComposesCaptureTranscriptTimelineAndArchiveRestore() async throws
    {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive", remoteRoot: "rewind", configuration: library)
        let start = Date(timeIntervalSince1970: 1_700_490_000)
        let xid = XID.generate(at: start)
        let stagingDirectory = root.appendingPathComponent(
            "MeetingStaging/offline-e2e", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory, withIntermediateDirectories: true)
        let staging = stagingDirectory.appendingPathComponent("meeting.mp4")
        let original = Data([3, 1, 4, 1, 5, 9])
        try original.write(to: staging)
        let integrity = try ArchiveIntegrityEngine.hash(file: staging)
        let candidate = LibreReverseMeetingCandidate(
            provider: .googleMeet, source: .windowDetection, windowID: 700, processIdentifier: 701,
            bundleIdentifier: "com.google.Chrome", title: "Offline end-to-end sync",
            url: URL(string: "https://meet.google.com/abc-defg-hij"), calendarEventID: "event-e2e",
            calendarID: "calendar-work", calendarSeriesID: "series-e2e", calendarTitle: "Work",
            calendarParticipants: ["Ada", "Grace"])
        let journal = LibreReverseMeetingCaptureJournal(
            publicationXID: xid, candidate: candidate, createdAt: start)
        try journal.write(to: stagingDirectory)
        let queue = LibreReverseMeetingTranscriptionQueue(
            root: root.appendingPathComponent("MeetingTranscriptionQueue"))
        let published = try LibreReverseMeetingPublicationPipeline.publishAndEnqueue(
            .init(
                stagingMediaURL: staging,
                manifest: completedManifest(
                    staging: staging, start: start, integrity: integrity, publicationXID: xid),
                candidate: candidate, publicationXID: xid), configuration: library,
            transcriptionQueue: queue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try queue.pending().map(\.publicationXID), [xid])

        let transcription = MeetingTranscriptionResult(
            text: "composed workflow searchable", language: "en",
            words: [
                .init(text: "composed", startSeconds: 1, endSeconds: 2, fullTextUTF16Offset: 0),
                .init(text: "workflow", startSeconds: 2, endSeconds: 3, fullTextUTF16Offset: 9),
                .init(text: "searchable", startSeconds: 3, endSeconds: 4, fullTextUTF16Offset: 18),
            ])
        let runner = LibreReverseMeetingTranscriptionRunner(
            queue: queue, library: library, transcriber: StubTranscriber(result: transcription))
        let transcriptionRun = await runner.runReady(at: start)
        XCTAssertEqual(transcriptionRun, .init(completed: 1, failed: 0))
        XCTAssertTrue(try queue.pending().isEmpty)

        let session = LibraryDatabaseSession(
            configuration: .init(
                databaseURL: library.databaseURL, keyFileURL: library.keyFileURL,
                mediaRoot: library.mediaRoot))
        let seekDate = start.addingTimeInterval(3)
        let loadedTranscript = try await session.meetingTranscript(
            segmentID: published.segmentID, at: seekDate)
        let transcript = try XCTUnwrap(loadedTranscript)
        XCTAssertEqual(transcript.text, transcription.text)
        XCTAssertEqual(transcript.words.map(\.text), ["composed", "workflow", "searchable"])
        XCTAssertEqual(transcript.metadata.calendarEventID, "event-e2e")
        XCTAssertEqual(transcript.metadata.participants, ["Ada", "Grace"])
        let search = try await session.recencyTranscriptSearchPage(query: "searchable")
        XCTAssertEqual(search.results.map(\.result.candidate.segmentID), [published.segmentID])
        XCTAssertEqual(search.results.first?.result.transcriptDetails?.matchInstant, seekDate)
        let window = try await session.timelineWindow(around: seekDate, duration: 60)
        let snapshot = LibreReverseTimelineSnapshot(
            rawSegments: window.segments, validSeekInterval: window.validSeekInterval)
        XCTAssertEqual(
            snapshot.meetingSelection(at: seekDate, anchoredBy: published.segmentID),
            .init(segmentID: published.segmentID, seekDate: seekDate))

        let backend = MeetingArchiveBackend()
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID, library: library, backend: backend)
        let uploaded = try await coordinator.runUntilIdle()
        XCTAssertEqual(uploaded, 1)
        try LibreReverseArchiveStore.updatePolicy(
            .init(requiredLocalSeconds: 0, rehydratedCacheBytes: 0), destinationID: destinationID,
            configuration: library)
        let residency = LibreReverseMediaResidencyManager(
            destinationID: destinationID, library: library, backend: backend, handoffGraceSeconds: 0
        )
        let evicted = try await residency.evictEligible()
        XCTAssertEqual(evicted, 1)
        let canonicalURL = library.mediaRoot.appendingPathComponent(published.relativeMediaPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))
        let loadedRemoteTranscript = try await session.meetingTranscript(
            segmentID: published.segmentID, at: seekDate)
        let remoteTranscript = try XCTUnwrap(loadedRemoteTranscript)
        XCTAssertEqual(remoteTranscript, transcript)
        let remoteSearch = try await session.recencyTranscriptSearchPage(query: "searchable")
        XCTAssertEqual(
            remoteSearch.results.map(\.result.candidate.segmentID), [published.segmentID])

        let resolver = LibreReverseLocalMediaResolver(
            destinationID: destinationID, library: library, backend: backend)
        let restoredURL = try await resolver.resolve(videoID: published.videoID)
        XCTAssertEqual(restoredURL, canonicalURL)
        XCTAssertEqual(try Data(contentsOf: canonicalURL), original)
        let loadedRestoredMoment = try await session.meetingMoment(
            segmentID: published.segmentID, at: seekDate)
        let restoredMoment = try XCTUnwrap(loadedRestoredMoment)
        XCTAssertEqual(restoredMoment.segmentID, published.segmentID)
        XCTAssertEqual(restoredMoment.chunkURL, canonicalURL)
        XCTAssertEqual(
            LibreReverseMeetingPlaybackTiming.mediaTime(
                requestedDate: seekDate, segmentStartDate: restoredMoment.segmentStartDate,
                segmentType: restoredMoment.segmentType.flatMap(
                    SegmentType.init(rawValue:)),
                anchorFrameIndex: try XCTUnwrap(restoredMoment.videoFrameIndex),
                frameRate: try XCTUnwrap(restoredMoment.videoFrameRate)), 3)
    }

    func testMeetingMediaArchivesEvictsAndRestoresWithoutLosingTranscriptGraph() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive", remoteRoot: "rewind", configuration: library)
        let start = Date(timeIntervalSince1970: 1_700_500_000)
        let xid = "librereverse:meeting:archive"
        let path = try makeMedia(xid: xid, date: start, library: library)
        let canonicalURL = library.mediaRoot.appendingPathComponent(path)
        let original = try Data(contentsOf: canonicalURL)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(30), relativeMediaPath: path,
                xid: xid, width: 1280, height: 720, frameRate: 30, audioStartTime: start,
                duration: 30, transcriptText: "drive survives",
                transcriptWords: [
                    .init(
                        speechSource: "others", word: "drive", timeOffset: 0, fullTextOffset: 0,
                        duration: 50),
                    .init(
                        speechSource: "others", word: "survives", timeOffset: 50, fullTextOffset: 6,
                        duration: 50),
                ]), configuration: library)
        let backend = MeetingArchiveBackend()
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID, library: library, backend: backend)

        let uploaded = try await coordinator.runUntilIdle()
        XCTAssertEqual(uploaded, 1)
        try LibreReverseArchiveStore.updatePolicy(
            .init(requiredLocalSeconds: 0, rehydratedCacheBytes: 0), destinationID: destinationID,
            configuration: library)
        let residency = LibreReverseMediaResidencyManager(
            destinationID: destinationID, library: library, backend: backend, handoffGraceSeconds: 0
        )
        let evicted = try await residency.evictEligible()
        XCTAssertEqual(evicted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))

        let session = LibraryDatabaseSession(
            configuration: .init(
                databaseURL: library.databaseURL, keyFileURL: library.keyFileURL,
                mediaRoot: library.mediaRoot))
        let seekDate = start.addingTimeInterval(8)
        let window = try await session.timelineWindow(around: seekDate, duration: 120)
        let snapshot = LibreReverseTimelineSnapshot(
            rawSegments: window.segments, validSeekInterval: window.validSeekInterval)
        XCTAssertEqual(snapshot.processedAudioSegments.map(\.rawID), [meeting.segmentID])
        XCTAssertEqual(
            snapshot.meetingSelection(at: seekDate, anchoredBy: meeting.segmentID),
            .init(segmentID: meeting.segmentID, seekDate: seekDate))
        let loadedRemoteMoment = try await session.meetingMoment(
            segmentID: meeting.segmentID, at: seekDate)
        let remoteMoment = try XCTUnwrap(loadedRemoteMoment)
        XCTAssertEqual(remoteMoment.chunkURL, canonicalURL)
        let remoteChunkURL = try XCTUnwrap(remoteMoment.chunkURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteChunkURL.path))
        let loadedRemoteTranscript = try await session.meetingTranscript(
            segmentID: meeting.segmentID, at: seekDate)
        let remoteTranscript = try XCTUnwrap(loadedRemoteTranscript)
        XCTAssertEqual(remoteTranscript.text, "drive survives")
        XCTAssertEqual(remoteTranscript.words.map(\.text), ["drive", "survives"])
        let remoteExport = try LibreReverseMeetingTranscriptExport.data(
            remoteTranscript, format: .losslessJSON)
        XCTAssertEqual(
            try LibreReverseMeetingTranscriptExport.transcript(fromLosslessJSON: remoteExport),
            remoteTranscript,
            "transcript export remains complete while meeting media is remote-only")
        let remoteSearch = try await session.recencyTranscriptSearchPage(query: "survives")
        XCTAssertEqual(remoteSearch.results.map(\.result.candidate.segmentID), [meeting.segmentID])
        XCTAssertFalse(
            LibreReverseMeetingPlaybackControlPolicy.isEnabled(
                hasAction: true, isActive: false,
                mediaAvailable: FileManager.default.fileExists(atPath: canonicalURL.path)))

        let resolver = LibreReverseLocalMediaResolver(
            destinationID: destinationID, library: library, backend: backend)
        let restored = try await resolver.resolve(videoID: meeting.videoID)
        XCTAssertEqual(restored, canonicalURL)
        XCTAssertEqual(try Data(contentsOf: restored), original)
        let loadedRestoredMoment = try await session.meetingMoment(
            segmentID: meeting.segmentID, at: seekDate)
        let restoredMoment = try XCTUnwrap(loadedRestoredMoment)
        XCTAssertEqual(restoredMoment, remoteMoment)
        let restoredChunkURL = try XCTUnwrap(restoredMoment.chunkURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredChunkURL.path))
        XCTAssertEqual(
            LibreReverseMeetingPlaybackTiming.mediaTime(
                requestedDate: seekDate, segmentStartDate: restoredMoment.segmentStartDate,
                segmentType: restoredMoment.segmentType.flatMap(
                    SegmentType.init(rawValue:)),
                anchorFrameIndex: try XCTUnwrap(restoredMoment.videoFrameIndex),
                frameRate: try XCTUnwrap(restoredMoment.videoFrameRate)), 8)
        XCTAssertTrue(
            LibreReverseMeetingPlaybackControlPolicy.isEnabled(
                hasAction: true, isActive: false,
                mediaAvailable: FileManager.default.fileExists(atPath: canonicalURL.path)))
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM transcript_word WHERE segmentId=\(meeting.segmentID)"
            ), 2)
        XCTAssertEqual(
            try scalar(
                library, "SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'survives'"),
            1)
        XCTAssertEqual(
            try scalar(
                library,
                "SELECT COUNT(*) FROM audio WHERE segmentId=\(meeting.segmentID) AND path='\(path)'"
            ), 1)
        await session.closeConnection()
    }

    func testDeletionCoordinatorRemovesDriveObjectGraphAndLocalMedia() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive", remoteRoot: "rewind", configuration: library)
        let start = Date(timeIntervalSince1970: 1_700_700_000)
        let xid = "meeting-coordinated-delete"
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(30), relativeMediaPath: path,
                xid: xid, width: 1280, height: 720, frameRate: 30, audioStartTime: start,
                duration: 30, transcriptText: "delete from drive"), configuration: library)
        let backend = MeetingArchiveBackend()
        _ = try await LibreReverseArchiveCoordinator(
            destinationID: destinationID, library: library, backend: backend
        ).runUntilIdle()
        let object = try XCTUnwrap(
            LibreReverseArchiveStore.objects(destinationID: destinationID, configuration: library)
                .first(where: { $0.videoID == meeting.videoID }))
        let remoteBeforeDeletion = try await backend.locate(.init(object.objectKey))
        XCTAssertNotNil(remoteBeforeDeletion)
        let queue = LibreReverseMeetingTranscriptionQueue(
            root: root.appendingPathComponent("TranscriptionQueue"))
        try queue.enqueue(
            .init(
                publicationXID: xid, segmentID: meeting.segmentID, videoID: meeting.videoID,
                title: "Delete me", relativeMediaPath: path))

        try await LibreReverseMeetingDeletionCoordinator(
            destinationID: destinationID, library: library, backend: backend,
            transcriptionQueue: queue
        ).delete(segmentID: meeting.segmentID)

        let remoteAfterDeletion = try await backend.locate(.init(object.objectKey))
        XCTAssertNil(remoteAfterDeletion)
        XCTAssertEqual(
            try scalar(library, "SELECT COUNT(*) FROM segment WHERE id=\(meeting.segmentID)"), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: library.mediaRoot.appendingPathComponent(path).path))
        XCTAssertTrue(try LibreReverseMeetingDeletion.pendingPlans(configuration: library).isEmpty)
        XCTAssertTrue(try queue.pending().isEmpty)
    }

    func testDeletionCoordinatorRequeuesIntactMeetingAfterDriveRemovalFailure() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive", remoteRoot: "rewind", configuration: library)
        let start = Date(timeIntervalSince1970: 1_700_710_000)
        let xid = "librereverse:meeting:failed-delete"
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(20), relativeMediaPath: path,
                xid: xid, width: 640, height: 480, frameRate: 30, audioStartTime: start,
                duration: 20), configuration: library)
        let backend = MeetingArchiveBackend()
        _ = try await LibreReverseArchiveCoordinator(
            destinationID: destinationID, library: library, backend: backend
        ).runUntilIdle()
        await backend.failRemoval(true)
        let coordinator = LibreReverseMeetingDeletionCoordinator(
            destinationID: destinationID, library: library, backend: backend)

        do {
            try await coordinator.delete(segmentID: meeting.segmentID)
            XCTFail("expected remote removal failure")
        } catch {
            XCTAssertEqual(
                error as? ArchiveBackendError,
                .requestFailed(status: 503, message: "injected removal failure"))
        }

        XCTAssertEqual(
            try scalar(library, "SELECT COUNT(*) FROM segment WHERE id=\(meeting.segmentID)"), 1)
        XCTAssertEqual(
            try scalar(
                library,
                "SELECT COUNT(*) FROM archive_object WHERE videoId=\(meeting.videoID) AND remoteState='queued' AND remoteIdentifier IS NULL"
            ), 1)
        XCTAssertTrue(try LibreReverseMeetingDeletion.pendingPlans(configuration: library).isEmpty)

        await backend.failRemoval(false)
        try await coordinator.delete(segmentID: meeting.segmentID)
        XCTAssertEqual(
            try scalar(library, "SELECT COUNT(*) FROM segment WHERE id=\(meeting.segmentID)"), 0)
    }

    func testDeletionCoordinatorResumesPostCommitCleanupAfterRestart() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive", remoteRoot: "rewind", configuration: library)
        let start = Date(timeIntervalSince1970: 1_700_720_000)
        let xid = XID.generate(at: start)
        let path = try makeMedia(xid: xid, date: start, library: library)
        let mediaURL = library.mediaRoot.appendingPathComponent(path)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(10), relativeMediaPath: path,
                xid: xid, width: 640, height: 480, frameRate: 30, audioStartTime: start,
                duration: 10), configuration: library)
        let queueRoot = root.appendingPathComponent("TranscriptionQueue")
        let queue = LibreReverseMeetingTranscriptionQueue(root: queueRoot)
        try FileManager.default.createDirectory(at: queueRoot, withIntermediateDirectories: true)
        let corruptJobURL = queueRoot.appendingPathComponent("\(xid).json")
        let checkpointURL = queueRoot.appendingPathComponent("\(xid).checkpoint")
        try Data("malformed after launch".utf8).write(to: corruptJobURL)
        try Data("encrypted partial transcript".utf8).write(to: checkpointURL)
        let plan = try LibreReverseMeetingDeletion.prepare(
            segmentID: meeting.segmentID, configuration: library)
        try LibreReverseMeetingDeletion.commitPreparedPrimaryDeletion(plan, configuration: library)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path))

        let completed = try await LibreReverseMeetingDeletionCoordinator(
            destinationID: destinationID, library: library, backend: MeetingArchiveBackend(),
            transcriptionQueue: queue
        ).resumePendingDeletions()

        XCTAssertEqual(completed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptJobURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointURL.path))
        XCTAssertTrue(try LibreReverseMeetingDeletion.pendingPlans(configuration: library).isEmpty)
    }

    func testDeletionCoordinatorDeletesNeverArchivedLocalMeetingWithoutProvider() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_730_000)
        let xid = "librereverse:meeting:local-only-delete"
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(10), relativeMediaPath: path,
                xid: xid, width: 640, height: 480, frameRate: 30, audioStartTime: start,
                duration: 10), configuration: library)

        let queue = LibreReverseMeetingTranscriptionQueue(
            root: root.appendingPathComponent("TranscriptionQueue"))
        try await LibreReverseMeetingDeletionCoordinator(library: library, transcriptionQueue: queue)
            .delete(segmentID: meeting.segmentID)

        XCTAssertEqual(
            try scalar(library, "SELECT COUNT(*) FROM segment WHERE id=\(meeting.segmentID)"), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: library.mediaRoot.appendingPathComponent(path).path))
    }

    func testDeletionCoordinatorRequiresProviderWhenMeetingHasArchiveObject() async throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive", remoteRoot: "rewind", configuration: library)
        let start = Date(timeIntervalSince1970: 1_700_740_000)
        let xid = "meeting-provider-required-delete"
        let path = try makeMedia(xid: xid, date: start, library: library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
            .init(
                startDate: start, endDate: start.addingTimeInterval(10), relativeMediaPath: path,
                xid: xid, width: 640, height: 480, frameRate: 30, audioStartTime: start,
                duration: 10), configuration: library)

        do {
            try await LibreReverseMeetingDeletionCoordinator(library: library).delete(
                segmentID: meeting.segmentID)
            XCTFail("expected archive provider requirement")
        } catch {
            XCTAssertEqual(error as? LibreReverseMeetingDeletionError, .archiveProviderRequired)
        }
        XCTAssertEqual(
            try scalar(library, "SELECT COUNT(*) FROM segment WHERE id=\(meeting.segmentID)"), 1)
        XCTAssertTrue(try LibreReverseMeetingDeletion.pendingPlans(configuration: library).isEmpty)
    }

    private func makeLibrary() throws -> (URL, LibreReverseLibraryConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "librereverse-meeting-publication-\(UUID().uuidString)")
        let library = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media"))
        try LibreReverseLibraryStore.initialize(library)
        return (root, library)
    }

    private func makeCrashRecoveryVideo(at url: URL, width: Int, height: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw NSError(domain: "CrashRecoveryFixture", code: 1) }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "CrashRecoveryFixture", code: 2)
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw NSError(domain: "CrashRecoveryFixture", code: 3)
        }
        for frame in 0..<3 {
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                let pixelBuffer
            else { throw NSError(domain: "CrashRecoveryFixture", code: 4) }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, Int32(frame * 40), CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard
                adaptor.append(
                    pixelBuffer,
                    withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
            else { throw writer.error ?? NSError(domain: "CrashRecoveryFixture", code: 5) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "CrashRecoveryFixture", code: 6)
        }
    }

    private func completedManifest(
        staging: URL, start: Date, integrity: ArchiveIntegrity? = nil,
        publicationXID: String? = nil, schemaVersion: Int? = nil, finishedAt: Date? = nil,
        hostClockStartSeconds: Double = 1, displayID: UInt32 = 1, width: Int = 1920,
        height: Int = 1080, requestedFrameRate: Int = 60, expectedSourceFrameRate: Int = 60,
        requestedDurationSeconds: Double? = nil,
        mediaEvidence: HighFidelityMeetingCaptureMediaEvidence? = nil,
        timestamps: MeetingCaptureTimestampLedger? = nil
    ) -> HighFidelityMeetingCaptureManifest {
        HighFidelityMeetingCaptureManifest(
            schemaVersion: schemaVersion
                ?? (publicationXID == nil ? (integrity == nil ? 2 : 4) : 5), state: .completed,
            finalizationReason: "meetingEnded", outputPath: staging.path, displayID: displayID,
            width: width, height: height, requestedFrameRate: requestedFrameRate,
            expectedSourceFrameRate: expectedSourceFrameRate, capturesSystemAudio: true,
            capturesMicrophone: true, microphoneDeviceID: nil, startedAt: start,
            finishedAt: finishedAt ?? start.addingTimeInterval(10),
            hostClockStartSeconds: hostClockStartSeconds, writerStatus: "completed",
            writerError: nil, streamError: nil, timestamps: timestamps ?? .init(frameRate: 60),
            requestedDurationSeconds: requestedDurationSeconds,
            outputByteCount: integrity?.byteCount, outputSHA256: integrity?.sha256,
            publicationXID: publicationXID, mediaEvidence: mediaEvidence)
    }

    private func makeMedia(xid: String, date: Date, library: LibreReverseLibraryConfiguration) throws
        -> String
    {
        let path = VideoStorage.relativePath(xid: xid, date: date)
        let url = library.mediaRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: url)
        return path
    }

    private func scalar(_ library: LibreReverseLibraryConfiguration, _ sql: String) throws -> Int64 {
        try scalar(library.databaseURL, library.keyFileURL, sql)
    }

    private func scalar(_ databaseURL: URL, _ keyURL: URL, _ sql: String) throws -> Int64 {
        let key = try Data(contentsOf: keyURL)
        var raw: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let database = raw
        else { throw NSError(domain: "MeetingPublicationTests", code: 1) }
        defer { sqlite3_close(database) }
        guard
            key.withUnsafeBytes({ sqlite3_key(database, $0.baseAddress, Int32($0.count)) })
                == SQLITE_OK
        else { throw NSError(domain: "MeetingPublicationTests", code: 2) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else { throw NSError(domain: "MeetingPublicationTests", code: 3) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "MeetingPublicationTests", code: 4)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func execute(_ library: LibreReverseLibraryConfiguration, _ sql: String) throws {
        let key = try Data(contentsOf: library.keyFileURL)
        var raw: OpaquePointer?
        guard
            sqlite3_open_v2(library.databaseURL.path, &raw, SQLITE_OPEN_READWRITE, nil)
                == SQLITE_OK, let database = raw
        else { throw NSError(domain: "MeetingPublicationTests", code: 5) }
        defer { sqlite3_close(database) }
        guard
            key.withUnsafeBytes({ sqlite3_key(database, $0.baseAddress, Int32($0.count)) })
                == SQLITE_OK
        else { throw NSError(domain: "MeetingPublicationTests", code: 6) }
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(message)
            throw NSError(
                domain: "MeetingPublicationTests", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: text])
        }
    }

    private func databaseString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

extension LibreReverseMeetingPublicationTests {
    func testFinalMediaInspectorReadsBackVideoAndRejectsMissingRequestedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "librereverse-terminal-media-evidence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("meeting.mp4")
        try await makeCrashRecoveryVideo(at: media, width: 64, height: 48)

        let evidence = try await HighFidelityMeetingCaptureMediaInspector.inspect(
            url: media, expectedWidth: 64, expectedHeight: 48, requiresAudio: false)
        XCTAssertGreaterThan(evidence.durationSeconds, 0)
        XCTAssertEqual(evidence.videoTrackCount, 1)
        XCTAssertEqual(evidence.audioTrackCount, 0)
        XCTAssertEqual(evidence.width, 64)
        XCTAssertEqual(evidence.height, 48)
        XCTAssertTrue(evidence.videoHasReadableSample)
        XCTAssertFalse(evidence.audioHasReadableSample)
        let finalized = try await HighFidelityMeetingCaptureMediaInspector.inspect(
            url: media, expectedWidth: 64, expectedHeight: 48, requiresAudio: false,
            capturedDuration: evidence.durationSeconds)
        XCTAssertEqual(finalized.durationSeconds, evidence.durationSeconds)
        do {
            _ = try await HighFidelityMeetingCaptureMediaInspector.inspect(
                url: media, expectedWidth: 64, expectedHeight: 48, requiresAudio: false,
                capturedDuration: evidence.durationSeconds + 10)
            XCTFail("A playable but prematurely ended movie must not recover a callback timeout")
        } catch {
            XCTAssertTrue(String(describing: error).contains("movie ends before capture telemetry"))
        }

        do {
            _ = try await HighFidelityMeetingCaptureMediaInspector.inspect(
                url: media, expectedWidth: 64, expectedHeight: 48, requiresAudio: true)
            XCTFail("requested audio must be independently readable from final media")
        } catch {
            XCTAssertTrue(String(describing: error).contains("requested audio track is missing"))
        }
    }

    func testSchemaSixPublicationRequiresSemanticTerminalMediaEvidence() throws {
        let (root, library) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("Staging/meeting.mp4")
        try FileManager.default.createDirectory(
            at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("schema-six-media".utf8).write(to: staging)
        let integrity = try ArchiveIntegrityEngine.hash(file: staging)
        let start = Date(timeIntervalSince1970: 1_700_300_000)
        let xid = XID.generate(at: start)
        var completeTelemetry = MeetingCaptureTimestampLedger(frameRate: 60)
        XCTAssertTrue(completeTelemetry.recordVideo(presentationTimeSeconds: 0))
        XCTAssertTrue(
            completeTelemetry.recordAudio(
                presentationTimeSeconds: 0, durationSeconds: 0.02, mediaSampleCount: 960))
        XCTAssertTrue(
            completeTelemetry.recordMicrophone(
                presentationTimeSeconds: 0, durationSeconds: 0.02, mediaSampleCount: 960))

        func capture(
            evidence: HighFidelityMeetingCaptureMediaEvidence?,
            timestamps: MeetingCaptureTimestampLedger? = nil
        ) -> LibreReverseFinalizedMeetingCapture {
            .init(
                stagingMediaURL: staging,
                manifest: completedManifest(
                    staging: staging, start: start, integrity: integrity, publicationXID: xid,
                    schemaVersion: 6, mediaEvidence: evidence, timestamps: timestamps),
                candidate: .init(provider: .manual, source: .manual), publicationXID: xid)
        }

        for evidence in [
            nil,
            HighFidelityMeetingCaptureMediaEvidence(
                durationSeconds: 10, videoTrackCount: 1, audioTrackCount: 1, width: 1920,
                height: 1080, videoHasReadableSample: true, audioHasReadableSample: false),
            HighFidelityMeetingCaptureMediaEvidence(
                durationSeconds: 4, videoTrackCount: 1, audioTrackCount: 1, width: 1920,
                height: 1080, videoHasReadableSample: true, audioHasReadableSample: true),
        ] {
            XCTAssertThrowsError(
                try LibreReverseMeetingCaptureFinalizer.publish(
                    capture(evidence: evidence), configuration: library))
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        }

        var missingMicrophoneTelemetry = MeetingCaptureTimestampLedger(frameRate: 60)
        XCTAssertTrue(missingMicrophoneTelemetry.recordVideo(presentationTimeSeconds: 0))
        XCTAssertTrue(
            missingMicrophoneTelemetry.recordAudio(
                presentationTimeSeconds: 0, durationSeconds: 0.02, mediaSampleCount: 960))
        let validEvidence = HighFidelityMeetingCaptureMediaEvidence(
            durationSeconds: 10, videoTrackCount: 1, audioTrackCount: 1, width: 1920, height: 1080,
            videoHasReadableSample: true, audioHasReadableSample: true)
        XCTAssertThrowsError(
            try LibreReverseMeetingCaptureFinalizer.publish(
                capture(evidence: validEvidence, timestamps: missingMicrophoneTelemetry),
                configuration: library))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))

        let published = try LibreReverseMeetingCaptureFinalizer.publish(
            capture(evidence: validEvidence, timestamps: completeTelemetry), configuration: library)
        XCTAssertEqual(
            published.relativeMediaPath, VideoStorage.relativePath(xid: xid, date: start))
    }

    func testCrashRecoveryRequiresMatchingDimensionsAndRequestedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "librereverse-crash-contract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await makeCrashRecoveryVideo(
            at: root.appendingPathComponent("meeting.mp4"), width: 64, height: 48)
        let candidate = LibreReverseMeetingCandidate(provider: .manual, source: .manual)
        let start = Date(timeIntervalSince1970: 1_700_260_000)

        let wrongSize = LibreReverseMeetingCaptureJournal(
            publicationXID: XID.generate(at: start), candidate: candidate,
            recoveryCheckpoint: .init(
                startedAt: start, hostClockStartSeconds: 10, displayID: 1, width: 65, height: 48,
                requestedFrameRate: 30, expectedSourceFrameRate: 30, capturesSystemAudio: false,
                capturesMicrophone: false, microphoneDeviceID: nil))
        do {
            _ = try await LibreReverseMeetingCrashRecovery.recoverManifest(
                journal: wrongSize, directory: root)
            XCTFail("mismatched capture geometry must not be published")
        } catch {
            XCTAssertEqual(
                error as? LibreReverseMeetingCrashRecoveryError,
                .videoDimensionsMismatch(
                    expectedWidth: 65, expectedHeight: 48, actualWidth: 64, actualHeight: 48))
        }

        let missingAudio = LibreReverseMeetingCaptureJournal(
            publicationXID: XID.generate(at: start.addingTimeInterval(1)),
            candidate: candidate,
            recoveryCheckpoint: .init(
                startedAt: start, hostClockStartSeconds: 10, displayID: 1, width: 64, height: 48,
                requestedFrameRate: 30, expectedSourceFrameRate: 30, capturesSystemAudio: true,
                capturesMicrophone: false, microphoneDeviceID: nil))
        do {
            _ = try await LibreReverseMeetingCrashRecovery.recoverManifest(
                journal: missingAudio, directory: root)
            XCTFail("a requested audio class must be present")
        } catch {
            XCTAssertEqual(error as? LibreReverseMeetingCrashRecoveryError, .missingAudioTrack)
        }
    }
}
#endif
