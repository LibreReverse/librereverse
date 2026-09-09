#if os(macOS)
import AVFoundation
import AppKit
import XCTest
@testable import LibreReverseApp
import LibreReverseCore

final class ArchivedMediaPlaybackTests: XCTestCase {
    func testRestoredMediaUsesOrdinaryPreparationAndDecodesDifferentFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.mp4")
        let canonical = root.appendingPathComponent("extensionless-chunk")
        try await makeVideo(at: remote)
        let loader = LibreReversePersistedMediaLoader(
            resolver: FixtureResolver(remote: remote, canonical: canonical)
        )
        func moment(_ index: Int) -> HistoricalTimelineMoment {
            HistoricalTimelineMoment(
                frameID: Int64(index + 1),
                // Deliberately sparse wall time: it cannot determine media time.
                wallDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 600)),
                databaseVideoID: 1, chunkURL: canonical,
                frameImageURL: root.appendingPathComponent("missing.png"),
                mediaTime: Double(index), videoFrameIndex: index, videoFrameRate: 1,
                videoWidth: 32, videoHeight: 32, segmentID: 1, bundleID: nil,
                segmentStartDate: nil, segmentEndDate: nil, windowName: nil,
                browserURL: nil, segmentType: 0, isStarred: false, isPendingImage: false
            )
        }
        let before = await loader.prepare(moment: moment(0))
        XCTAssertNil(before.playbackURL)
        let restored = try await loader.restoreArchivedSelection(for: moment(0))
        XCTAssertEqual(restored, canonical)
        let after = await loader.prepare(moment: moment(0))
        XCTAssertEqual(after.playbackURL, canonical)
        XCTAssertNil(after.playbackPreparationError)
        let firstImage = await loader.searchFrame(moment: moment(0))
        let secondImage = await loader.searchFrame(moment: moment(1))
        let first = try XCTUnwrap(firstImage)
        let second = try XCTUnwrap(secondImage)
        let firstBitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(first.tiffRepresentation)))
        let secondBitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(second.tiffRepresentation)))
        let firstColor = try XCTUnwrap(firstBitmap.colorAt(x: 16, y: 16)?.usingColorSpace(.deviceRGB))
        let secondColor = try XCTUnwrap(secondBitmap.colorAt(x: 16, y: 16)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(firstColor.redComponent, 0.2)
        XCTAssertGreaterThan(secondColor.redComponent, 0.8)
        // A fresh loader after reopening the app needs no archive resolver.
        let reopened = await LibreReversePersistedMediaLoader().prepare(moment: moment(1))
        XCTAssertEqual(reopened.playbackURL, canonical)
    }

    private func makeVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 32, AVVideoHeightKey: 32,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32,
            ]
        )
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        for index in 0..<3 {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels))
            memset(base, index == 0 ? 0 : 255,
                   CVPixelBufferGetBytesPerRow(pixels) * 32)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: 1)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    private struct FixtureResolver: LocalMediaResolving {
        let remote: URL
        let canonical: URL
        func resolve(videoID: Int64) async throws -> URL {
            try FileManager.default.copyItem(at: remote, to: canonical)
            return canonical
        }
        func restoreMoment(videoID: Int64, progress: @escaping @Sendable (LibreReverseDayRestoreProgress) async -> Void) async throws -> URL {
            try await resolve(videoID: videoID)
        }
        func prefetchAround(videoID: Int64) async {}
        func restoreDay(containing date: Date, selectedVideoID: Int64, progress: @escaping @Sendable (LibreReverseDayRestoreProgress) async -> Void) async throws -> URL {
            try await resolve(videoID: selectedVideoID)
        }
    }
}
#endif
