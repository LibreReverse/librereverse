#if os(macOS)
import AVFoundation
import Foundation
import XCTest
@testable import LibreReverseCore

final class MeetingVideoCompressionTests: XCTestCase {
    func testBitrateBudgetScalesWithNativeResolutionAndKeeps30FPSCapturePolicy() {
        XCTAssertEqual(MeetingVideoCompression.frameRate, 30)
        XCTAssertEqual(MeetingVideoCompression.targetBitRate(width: 1280, height: 720), 1_500_000)
        XCTAssertEqual(MeetingVideoCompression.targetBitRate(width: 3024, height: 1964), 4_038_612)
        XCTAssertEqual(MeetingVideoCompression.targetBitRate(width: 7680, height: 4320), 8_000_000)
    }

    func testInvalidMovieRemainsUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("synthetic.mp4")
        let data = Data("synthetic unreadable media".utf8)
        try data.write(to: movie)
        let result = try await MeetingVideoCompression.optimizeFinalizedStagingMovie(at: movie)
        XCTAssertEqual(result, .keptOriginal)
        XCTAssertEqual(try Data(contentsOf: movie), data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["synthetic.mp4"])
    }

    func testCancelledAdmissionDoesNotMutateOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("synthetic.mp4")
        let data = Data("synthetic retained source".utf8)
        try data.write(to: movie)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MeetingVideoCompression.optimizeFinalizedStagingMovie(at: movie)
        }
        do { _ = try await task.value; XCTFail("Cancelled admission succeeded") }
        catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: movie), data)
    }

    func testAdmittedNativeCancellationDrainsAndRetainsOriginal() async throws {
        guard ProcessInfo.processInfo.environment["LIBREREVERSE_SYNTHETIC_COMPRESSION_TEST"] == "1",
              let path = ProcessInfo.processInfo.environment["LIBREREVERSE_SYNTHETIC_COMPRESSION_MOVIE"] else {
            throw XCTSkip("Set explicit synthetic compression fixture opt-in")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("synthetic.mp4")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: movie)
        let original = try Data(contentsOf: movie)
        let started = expectation(description: "native reader and writer admitted")
        let proceed = DispatchSemaphore(value: 0)
        let task = Task {
            try await MeetingVideoCompression.optimizeFinalizedStagingMovie(at: movie, nativeWorkStarted: {
                started.fulfill()
                _ = proceed.wait(timeout: .now() + 5)
            })
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        proceed.signal()
        do { _ = try await task.value; XCTFail("Cancelled native work must not replace the original") }
        catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: movie), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["synthetic.mp4"])
    }

    /// Opt-in only: the caller supplies a generated, nonprivate fixture. Copy it
    /// into an isolated workspace; the input fixture is never rewritten.
    func testNativeCompressionOfExplicitSyntheticFixture() async throws {
        guard ProcessInfo.processInfo.environment["LIBREREVERSE_SYNTHETIC_COMPRESSION_TEST"] == "1",
              let path = ProcessInfo.processInfo.environment["LIBREREVERSE_SYNTHETIC_COMPRESSION_MOVIE"] else {
            throw XCTSkip("Set explicit synthetic compression fixture opt-in")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("synthetic.mp4")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: movie)
        let before = AVURLAsset(url: movie)
        let sourceVideos = try await before.loadTracks(withMediaType: .video)
        let sourceVideo = try XCTUnwrap(sourceVideos.first)
        let size = try await sourceVideo.load(.naturalSize)
        let rate = try await sourceVideo.load(.nominalFrameRate)
        let duration = try await before.load(.duration).seconds
        let audioCount = try await before.loadTracks(withMediaType: .audio).count
        let result = try await MeetingVideoCompression.optimizeFinalizedStagingMovie(at: movie)
        guard case let .replaced(originalBytes, compressedBytes) = result else {
            XCTFail("Synthetic high-rate fixture must exercise native replacement"); return
        }
        XCTAssertLessThan(compressedBytes, originalBytes * 9 / 10)
        let after = AVURLAsset(url: movie)
        let resultVideos = try await after.loadTracks(withMediaType: .video)
        let resultVideo = try XCTUnwrap(resultVideos.first)
        let resultSize = try await resultVideo.load(.naturalSize)
        let resultRate = try await resultVideo.load(.nominalFrameRate)
        let resultDuration = try await after.load(.duration).seconds
        let resultAudioCount = try await after.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(resultSize, size)
        XCTAssertEqual(resultRate, rate, accuracy: 0.1)
        XCTAssertEqual(resultDuration, duration, accuracy: 0.15)
        XCTAssertEqual(resultAudioCount, audioCount)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["synthetic.mp4"])
        let compressedData = try Data(contentsOf: movie)
        let repeated = try await MeetingVideoCompression.optimizeFinalizedStagingMovie(at: movie)
        XCTAssertEqual(repeated, .keptOriginal, "Already efficient media must not get another lossy generation")
        XCTAssertEqual(try Data(contentsOf: movie), compressedData)
        if let output = ProcessInfo.processInfo.environment["LIBREREVERSE_SYNTHETIC_COMPRESSION_RESULT"] {
            try FileManager.default.copyItem(at: movie, to: URL(fileURLWithPath: output))
        }
    }
}
#endif
