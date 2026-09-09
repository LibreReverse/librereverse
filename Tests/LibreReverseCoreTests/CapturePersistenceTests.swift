#if canImport(AVFoundation) && canImport(Metal)
import AVFoundation
import CoreGraphics
import ImageIO
import Metal
import XCTest
@testable import LibreReverseCore

final class CapturePersistenceTests: XCTestCase {
    func testTimelineSampleAtOrBeforeDoesNotSelectAFutureFrame() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let chunk = TimelineChunk(
            url: URL(fileURLWithPath: "/fixture.mp4"),
            startDate: start,
            wallEndDate: start.addingTimeInterval(2),
            duration: 2,
            width: 10,
            height: 10,
            source: .clone,
            samples: [
                TimelineSample(wallDate: start, mediaTime: 0),
                TimelineSample(wallDate: start.addingTimeInterval(1), mediaTime: 1.0 / 30.0),
            ]
        )

        XCTAssertNil(chunk.sample(atOrBefore: start.addingTimeInterval(-0.001)))
        XCTAssertEqual(chunk.sample(atOrBefore: start)?.mediaTime, 0)
        XCTAssertEqual(
            chunk.sample(atOrBefore: start.addingTimeInterval(0.999))?.mediaTime,
            0
        )
    }


    @MainActor
    func testRuntimeAssistantSettingsPreserveEncoderContract() throws {
        let settings = try FrameVideoWriter.outputSettings(
            width: 3024, height: 1964, frameRate: 30)
        XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, .hevc)
        XCTAssertEqual(settings[AVVideoWidthKey] as? Int, 3024)
        XCTAssertEqual(settings[AVVideoHeightKey] as? Int, 1964)
        let compression = try XCTUnwrap(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
        XCTAssertEqual((compression[AVVideoAverageBitRateKey] as? NSNumber)?.uintValue, 11_358_597)
        XCTAssertEqual((compression[AVVideoExpectedSourceFrameRateKey] as? NSNumber)?.intValue, 30)
        XCTAssertEqual((compression[AVVideoMaxKeyFrameIntervalKey] as? NSNumber)?.intValue, 30)
        XCTAssertEqual((compression[AVVideoAllowFrameReorderingKey] as? NSNumber)?.boolValue, true)
        XCTAssertEqual(compression[AVVideoProfileLevelKey] as? String, "HEVC_Main_AutoLevel")
    }


    @MainActor
    func testReplacementWriterProducesSparseThirtyTimescaleTimeline() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("rewind-writer-parity-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let writer = try FrameVideoWriter(outputURL: output, width: 320, height: 240)
        let image = try solidImage(width: 320, height: 240)
        XCTAssertTrue(try writer.write(frameNumber: 0, image: image))
        XCTAssertTrue(try writer.write(frameNumber: 2, image: image))
        XCTAssertTrue(try writer.write(frameNumber: 4, image: image))
        try await writer.finish()

        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let timeRange = try await tracks[0].load(.timeRange)
        XCTAssertEqual(timeRange.duration.timescale, 600)
        XCTAssertEqual(timeRange.duration.seconds, 0.2, accuracy: 0.001)
    }


    func testScreenDifferUsesRecoveredByteThresholdMenubarAndAdmissionBoundary() throws {
        var differ = ScreenDiffer()
        let displayID: CGDirectDisplayID = 77
        let black = try solidImage(width: 50, height: 60, red: 0, green: 0, blue: 0)
        let nine = try solidImage(width: 50, height: 60, red: 9.0 / 255.0, green: 0, blue: 0)
        let ten = try solidImage(width: 50, height: 60, red: 10.0 / 255.0, green: 0, blue: 0)
        let first = try differ.process(
            CapturedScreenFrame(image: black, displayID: displayID, backingScaleFactor: 1))
        XCTAssertTrue(first.isFirstFrame)
        XCTAssertTrue(first.admitted)
        let below = try differ.process(
            CapturedScreenFrame(image: nine, displayID: displayID, backingScaleFactor: 1))
        XCTAssertEqual(below.changedPixels, 0)
        // The incoming image always becomes the next comparison baseline, even on skip.
        _ = try differ.process(
            CapturedScreenFrame(image: black, displayID: displayID, backingScaleFactor: 1))
        let accepted = try differ.process(
            CapturedScreenFrame(image: ten, displayID: displayID, backingScaleFactor: 1))
        // Rows 27...59 satisfy the kernel's strict y > 26 condition.
        XCTAssertEqual(accepted.changedPixels, 50 * 33)
        XCTAssertTrue(accepted.admitted)
    }

    func testRetinaCaptureReportsLogicalDisplaySize() throws {
        let image = try solidImage(width: 3024, height: 1964)
        let retina = CapturedScreenFrame(
            image: image,
            displayID: 1,
            backingScaleFactor: 2
        )
        XCTAssertEqual(retina.logicalDisplaySize, CGSize(width: 1512, height: 982))

        let unknownScale = CapturedScreenFrame(
            image: image,
            displayID: 1,
            backingScaleFactor: 0
        )
        XCTAssertEqual(unknownScale.logicalDisplaySize, CGSize(width: 3024, height: 1964))
    }

    func testScreenDifferSeedsAgainWhenComputedMenubarHeightChanges() throws {
        var differ = ScreenDiffer()
        let displayID: CGDirectDisplayID = 78
        let black = try solidImage(width: 50, height: 80, red: 0, green: 0, blue: 0)
        let white = try solidImage(width: 50, height: 80, red: 1, green: 1, blue: 1)

        _ = try differ.process(
            CapturedScreenFrame(image: black, displayID: displayID, backingScaleFactor: 1)
        )
        let scaleTransition = try differ.process(
            CapturedScreenFrame(image: white, displayID: displayID, backingScaleFactor: 2)
        )

        // The controller resets its per-display reference when
        // Float(backingScaleFactor) * 26 changes, so this is a fresh seed even
        // if the pixel dimensions happen to be unchanged.
        XCTAssertEqual(
            scaleTransition,
            ScreenDifferenceDecision(changedPixels: 0, isFirstFrame: true, admitted: true)
        )
    }



    @MainActor
    func testFailedRecoveryImageWriteDoesNotAdmitCanonicalFrame() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-failed-png-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(configuration)
        let session = try ScreenRecordingSession(outputDirectory: configuration.mediaRoot,
                                                 libraryConfiguration: configuration)
        let images = configuration.mediaRoot.appendingPathComponent("temp/images")
        try FileManager.default.removeItem(at: images)
        let sentinel = Data("a file blocks the recovery-image directory".utf8)
        try sentinel.write(to: images)
        let frame = CapturedScreenFrame(image: try solidImage(width: 64, height: 64),
                                        displayID: 1, backingScaleFactor: 1)
        do {
            _ = try await session.ingest(frame, at: Date(timeIntervalSince1970: 1_700_100_000))
            XCTFail("Frame admission must wait for successful recovery-image publication")
        } catch { }
        XCTAssertEqual(session.retainedFrameCount, 0)
        XCTAssertTrue(try LibreReverseLibraryStore.loadRecoverableFrames(configuration: configuration).isEmpty)
        XCTAssertEqual(try Data(contentsOf: images), sentinel)
        try await session.finish(at: Date(timeIntervalSince1970: 1_700_100_002))
    }

    @MainActor
    func testRecordingSessionCommitsCompletedChunkToCanonicalLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-canonical-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(configuration)
        let session = try ScreenRecordingSession(
            outputDirectory: configuration.mediaRoot,
            libraryConfiguration: configuration
        )
        let first = try solidImage(width: 64, height: 64, red: 0, green: 0, blue: 0)
        let second = try solidImage(width: 64, height: 64, red: 1, green: 1, blue: 1)
        let start = Date(timeIntervalSince1970: 1_700_100_000)
        _ = try await session.ingest(
            CapturedScreenFrame(image: first, displayID: 1, backingScaleFactor: 1),
            at: start
        )
        _ = try await session.ingest(
            CapturedScreenFrame(image: second, displayID: 1, backingScaleFactor: 1),
            at: start.addingTimeInterval(2)
        )
        try await session.finish(at: start.addingTimeInterval(2))

        let chunks = try LibraryDatabase.loadChunks(
            configuration: .init(
                databaseURL: configuration.databaseURL,
                keyFileURL: configuration.keyFileURL,
                mediaRoot: configuration.mediaRoot
            ))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].sampleCount, 2)
        XCTAssertEqual(chunks[0].startDate, start)
        XCTAssertEqual(chunks[0].wallEndDate, start.addingTimeInterval(2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunks[0].url.path))
    }

    @MainActor
    func testTerminalFinalizationFailureRetainsCanonicalFramesForFreshSessionRecovery() async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-finalization-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(configuration)
        let session = try ScreenRecordingSession(
            outputDirectory: configuration.mediaRoot,
            libraryConfiguration: configuration
        )
        let first = try solidImage(width: 64, height: 64, red: 0, green: 0, blue: 0)
        let second = try solidImage(width: 64, height: 64, red: 1, green: 1, blue: 1)
        let start = Date(timeIntervalSince1970: 1_700_150_000)
        _ = try await session.ingest(
            CapturedScreenFrame(image: first, displayID: 1, backingScaleFactor: 1),
            at: start
        )
        _ = try await session.ingest(
            CapturedScreenFrame(image: second, displayID: 1, backingScaleFactor: 1),
            at: start.addingTimeInterval(2)
        )

        // Force the post-writer canonical commit to fail. The writer is now
        // terminal, but the database and source PNGs must remain sufficient for
        // a different session to replay the exact deferred Frame identities.
        let key = try Data(contentsOf: configuration.keyFileURL)
        try Data(repeating: 0xA5, count: key.count).write(
            to: configuration.keyFileURL,
            options: .atomic
        )
        do {
            try await session.finish(at: start.addingTimeInterval(2))
            XCTFail("finalization should fail while the library key is wrong")
        } catch {}
        try key.write(to: configuration.keyFileURL, options: .atomic)

        XCTAssertTrue(
            try canonicalMediaFiles(configuration: configuration).isEmpty,
            "a rolled-back canonical commit must remove its unowned MP4"
        )
        XCTAssertEqual(
            try LibreReverseLibraryStore.loadRecoverableFrames(configuration: configuration).count,
            2
        )
        let recovery = try ScreenRecordingSession(
            outputDirectory: configuration.mediaRoot,
            libraryConfiguration: configuration
        )
        let recoveredCount = try await recovery.recoverDeferredFrames()
        XCTAssertEqual(recoveredCount, 2)
        XCTAssertTrue(
            try LibreReverseLibraryStore.loadRecoverableFrames(configuration: configuration).isEmpty
        )
        let chunks = try LibraryDatabase.loadChunks(
            configuration: .init(
                databaseURL: configuration.databaseURL,
                keyFileURL: configuration.keyFileURL,
                mediaRoot: configuration.mediaRoot
            ))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].sampleCount, 2)
        XCTAssertEqual(try canonicalMediaFiles(configuration: configuration), [chunks[0].url])
    }


    @MainActor
    func testDeferredCanonicalFramesRecoverIntoOneDenseVideoChunk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-deferred-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(configuration)
        let start = Date(timeIntervalSince1970: 1_700_200_000)
        let image = try solidImage(width: 64, height: 64)
        try seedDeferredCanonicalFrame(
            image: image,
            imageFileName: "first.png",
            at: start,
            context: .init(
                bundleID: "com.example.Editor",
                windowName: "Draft"
            ),
            configuration: configuration
        )
        let secondImage = try solidImage(
            width: 64,
            height: 64,
            red: 0.9,
            green: 0.1,
            blue: 0.1
        )
        try seedDeferredCanonicalFrame(
            image: secondImage,
            imageFileName: "second.png",
            at: start.addingTimeInterval(2),
            context: .init(
                bundleID: "com.example.Browser",
                windowName: "Project notes"
            ),
            configuration: configuration
        )
        XCTAssertEqual(
            try LibraryDatabase.loadChunks(
                configuration: .init(
                    databaseURL: configuration.databaseURL,
                    keyFileURL: configuration.keyFileURL,
                    mediaRoot: configuration.mediaRoot
                )
            ).count,
            0
        )
        XCTAssertEqual(
            try LibreReverseLibraryStore.loadDeferredFrames(configuration: configuration).count,
            2
        )

        let recoverySession = try ScreenRecordingSession(
            outputDirectory: configuration.mediaRoot,
            libraryConfiguration: configuration
        )
        let recoveredCount = try await recoverySession.recoverDeferredFrames()
        XCTAssertEqual(recoveredCount, 2)
        XCTAssertTrue(
            try LibreReverseLibraryStore.loadDeferredFrames(
                configuration: configuration
            ).isEmpty)
        let chunks = try LibraryDatabase.loadChunks(
            configuration: .init(
                databaseURL: configuration.databaseURL,
                keyFileURL: configuration.keyFileURL,
                mediaRoot: configuration.mediaRoot
            ))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.startDate, start)
        let segments = try LibraryDatabase.loadRecentTimelineWindow(
            configuration: .init(
                databaseURL: configuration.databaseURL,
                keyFileURL: configuration.keyFileURL,
                mediaRoot: configuration.mediaRoot
            )
        ).segments
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.first?.bundleID, "com.example.Editor")
        XCTAssertEqual(segments.first?.windowName, "Draft")
        XCTAssertEqual(segments.last?.bundleID, "com.example.Browser")
        let moment = try LibraryDatabase.nearestMoment(
            to: start.addingTimeInterval(1),
            configuration: .init(
                databaseURL: configuration.databaseURL,
                keyFileURL: configuration.keyFileURL,
                mediaRoot: configuration.mediaRoot
            )
        )
        // The seek is exactly between the two recovered frames. The canonical
        // nearest-frame contract resolves an equal-distance tie to the later row.
        XCTAssertEqual(moment?.segmentID, segments.last?.rawID)
    }


    private func seedDeferredCanonicalFrame(
        image: CGImage,
        imageFileName: String,
        at date: Date,
        context: LibreReverseCaptureContext?,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        let temp = configuration.mediaRoot
            .appendingPathComponent("temp", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        guard
            let destination = CGImageDestinationCreateWithURL(
                temp.appendingPathComponent(imageFileName) as CFURL,
                "public.png" as CFString,
                1,
                nil
            )
        else { throw XCTSkip("PNG destination unavailable") }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        _ = try LibreReverseLibraryStore.admitFrame(
            createdAt: date,
            imageFileName: imageFileName,
            context: context,
            configuration: configuration
        )
    }






    private func solidImage(
        width: Int,
        height: Int,
        red: CGFloat = 0.2,
        green: CGFloat = 0.4,
        blue: CGFloat = 0.8
    ) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        else { throw XCTSkip("CGContext allocation failed") }
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw XCTSkip("CGImage creation failed") }
        return image
    }

    private func canonicalMediaFiles(
        configuration: LibreReverseLibraryConfiguration
    ) throws -> [URL] {
        try FileManager.default.subpathsOfDirectory(
            atPath: configuration.mediaRoot.path
        ).compactMap { relativePath in
            guard !relativePath.hasPrefix("temp/") else { return nil }
            let url = configuration.mediaRoot.appendingPathComponent(relativePath)
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
                ? url : nil
        }.sorted { $0.path < $1.path }
    }
}
#endif
