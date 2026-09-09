#if os(macOS)
import AVFoundation
import CoreGraphics
import XCTest
@testable import LibreReverseCore

@MainActor
final class FrameVideoWriterBackpressureTests: XCTestCase {
    func testFinishDrainsEveryQueuedFrameBeforePublishingSuccess() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await requireEncoder(at: root)
        var permitsAppend = false
        let output = root.appendingPathComponent("recording.mp4")
        let writer = try FrameVideoWriter(outputURL: output, width: 64, height: 64,
            drainTimeout: .seconds(5), readiness: { permitsAppend })
        let image = try image()
        for number in 0..<24 { try writer.write(frameNumber: Int64(number), image: image) }
        XCTAssertEqual(writer.pendingFrameCount, 24)
        let finishing = Task { try await writer.finish() }
        await Task.yield()
        // The writer must yield the main actor while waiting for encoder input.
        permitsAppend = true
        try await finishing.value
        XCTAssertEqual(writer.pendingFrameCount, 0)
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(decoded)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        while let sample = decoded.copyNextSampleBuffer() {
            XCTAssertNotNil(CMSampleBufferGetImageBuffer(sample))
            frames += CMSampleBufferGetNumSamples(sample)
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(frames, 24, "Every frame accepted before finalization must be playable")
        XCTAssertThrowsError(try writer.write(frameNumber: 24, image: image))
    }

    func testStalledEncoderFailureStaysTerminalOnRepeatedFinish() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await requireEncoder(at: root)
        let writer = try FrameVideoWriter(outputURL: root.appendingPathComponent("stalled.mp4"),
            width: 64, height: 64, drainTimeout: .milliseconds(20), readiness: { false })
        try writer.write(frameNumber: 0, image: image())
        for _ in 0..<2 {
            do {
                try await writer.finish()
                XCTFail("Timed-out media must never become a successful finalization on retry")
            } catch FrameVideoWriterError.backpressureTimedOut {
            }
        }
        XCTAssertThrowsError(try writer.checkCanWrite())
    }

    func testCancelledFlushCannotBeCommittedOnLaterRetry() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await requireEncoder(at: root)
        let writer = try FrameVideoWriter(outputURL: root.appendingPathComponent("cancelled.mp4"),
            width: 64, height: 64, drainTimeout: .seconds(30), readiness: { false })
        try writer.write(frameNumber: 0, image: image())
        let task = Task { try await writer.finish() }
        await Task.yield()
        task.cancel()
        do { try await task.value; XCTFail("Cancellation must prevent success") }
        catch is CancellationError {}
        do { try await writer.finish(); XCTFail("A cancelled writer remains terminal") }
        catch is CancellationError {}
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return try XCTUnwrap(context.makeImage())
    }

    private func requireEncoder(at root: URL) async throws {
        do {
            let probe = try FrameVideoWriter(outputURL: root.appendingPathComponent("probe.mp4"),
                width: 64, height: 64)
            try probe.write(frameNumber: 0, image: image())
            try await probe.finish()
        } catch { throw XCTSkip("HEVC encoder unavailable: \(error)") }
    }
}
#endif
