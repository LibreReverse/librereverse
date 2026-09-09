#if os(macOS)
import XCTest
import CoreGraphics
import ImageIO
@testable import LibreReverseCore

final class CanonicalRecorderMetadataTests: XCTestCase {
    func testCompletedChunksReleaseMetadataWithoutChangingRemainingRecoveryIDs() {
        var metadata = CanonicalRecorderMetadata()
        let failedID: Int64 = -1
        metadata[failedID] = .init(canonicalFrameID: failedID, createdAt: .distantPast,
                                   imageFileName: "failed.png")
        for chunk in 0..<2_000 {
            let ids = (0..<150).map { Int64(chunk * 150 + $0) }
            for id in ids {
                metadata[id] = .init(canonicalFrameID: id,
                    createdAt: Date(timeIntervalSince1970: Double(id)), imageFileName: "\(id).png")
            }
            let replayIDs = metadata.orderedFrameIDs
            let firstHalf = Array(ids.prefix(75))
            metadata.removeCommitted(firstHalf)
            // A recovery traversal captured before the previous commit is still valid.
            for id in replayIDs where id == failedID || !firstHalf.contains(id) {
                XCTAssertNotNil(metadata[id])
            }
            metadata.removeCommitted(Array(ids.suffix(75)))
            XCTAssertEqual(metadata.count, 1)
            XCTAssertEqual(metadata[failedID]?.imageFileName, "failed.png")
        }
    }

    @MainActor
    func testSessionDropsCommittedMetadataAndRetainsFailedCommitForRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await requireEncoder(at: root)
        let configuration = configuration(at: root)
        try LibreReverseLibraryStore.initialize(configuration)
        let session = try ScreenRecordingSession(outputDirectory: configuration.mediaRoot,
                                                libraryConfiguration: configuration)
        let start = Date(timeIntervalSince1970: 1_700_100_000)
        for chunk in 0..<4 {
            let image = try image(width: 64, white: chunk % 2 == 0 ? 0 : 1)
            let result = try await session.ingestWithAdmission(
                .init(image: image, displayID: 1, backingScaleFactor: 1),
                at: start.addingTimeInterval(Double(chunk * 2)))
            XCTAssertNotNil(result.admittedFrame)
            XCTAssertEqual(session.retainedFrameCount, 1)
            try await session.finish()
            XCTAssertEqual(session.retainedFrameCount, 0)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: configuration.mediaRoot.appendingPathComponent("index.json").path))
        XCTAssertEqual(try chunks(configuration).count, 4)

        _ = try await session.ingest(.init(image: try image(width: 64, white: 0),
            displayID: 1, backingScaleFactor: 1), at: start.addingTimeInterval(10))
        let key = try Data(contentsOf: configuration.keyFileURL)
        try Data(repeating: 0xA5, count: key.count).write(to: configuration.keyFileURL, options: .atomic)
        do {
            try await session.finish()
            XCTFail("A commit using an incorrect database key must fail")
        } catch {}
        try key.write(to: configuration.keyFileURL, options: .atomic)
        XCTAssertEqual(session.retainedFrameCount, 1)
        XCTAssertTrue(session.requiresRecovery)
        do {
            _ = try await session.ingest(.init(image: try image(width: 64, white: 1),
                displayID: 1, backingScaleFactor: 1), at: start.addingTimeInterval(12))
            XCTFail("A terminal recorder must reject new frames before writing their PNGs or database rows")
        } catch ScreenRecordingSessionError.recoveryRequired {}
        XCTAssertEqual(session.retainedFrameCount, 1)
        XCTAssertEqual(try LibreReverseLibraryStore.loadRecoverableFrames(configuration: configuration).count, 1)
        let recovery = try ScreenRecordingSession(outputDirectory: configuration.mediaRoot,
                                                 libraryConfiguration: configuration)
        let recovered = try await recovery.recoverDeferredFrames()
        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(recovery.retainedFrameCount, 0)
        XCTAssertEqual(try chunks(configuration).count, 5)
    }

    @MainActor
    func testRecoveryAcrossDimensionBoundariesUsesStableFrameIDs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await requireEncoder(at: root)
        let configuration = configuration(at: root)
        try LibreReverseLibraryStore.initialize(configuration)
        let images = configuration.mediaRoot.appendingPathComponent("temp/images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        for index in 0..<4 {
            let filename = "\(index).png"
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
                images.appendingPathComponent(filename) as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try image(width: index % 2 == 0 ? 64 : 128,
                                                            white: 0.5), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            _ = try LibreReverseLibraryStore.admitFrame(
                createdAt: Date(timeIntervalSince1970: 1_700_200_000 + Double(index)),
                imageFileName: filename, context: nil, configuration: configuration)
        }
        let session = try ScreenRecordingSession(outputDirectory: configuration.mediaRoot,
                                                libraryConfiguration: configuration)
        let recovered = try await session.recoverDeferredFrames()
        XCTAssertEqual(recovered, 4)
        XCTAssertEqual(session.retainedFrameCount, 0)
        XCTAssertEqual(try chunks(configuration).map(\.sampleCount), [1, 1, 1, 1])
        XCTAssertTrue(try LibreReverseLibraryStore.loadRecoverableFrames(configuration: configuration).isEmpty)
    }

    private func configuration(at root: URL) -> LibreReverseLibraryConfiguration {
        .init(databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
              keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
              mediaRoot: root.appendingPathComponent("Library/Media"))
    }

    private func chunks(_ configuration: LibreReverseLibraryConfiguration) throws -> [TimelineChunk] {
        try LibraryDatabase.loadChunks(configuration: .init(
            databaseURL: configuration.databaseURL, keyFileURL: configuration.keyFileURL,
            mediaRoot: configuration.mediaRoot))
    }

    private func image(width: Int, white: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 64,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.setFillColor(red: white, green: white, blue: white, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: 64))
        return try XCTUnwrap(context.makeImage())
    }

    @MainActor
    private func requireEncoder(at root: URL) async throws {
        do {
            let writer = try FrameVideoWriter(outputURL: root.appendingPathComponent("probe.mp4"),
                                                       width: 64, height: 64)
            _ = try writer.write(frameNumber: 0, image: image(width: 64, white: 0))
            try await writer.finish()
        } catch {
            throw XCTSkip("Recording encoder unavailable: \(error)")
        }
    }
}
#endif
