#if os(macOS)
import AVFoundation
import CoreGraphics
import CoreVideo
import Metal
import XCTest
@testable import LibreReverseCore

@MainActor
final class NativeCaptureBufferTests: XCTestCase {
    private func frame(seed: Int, width: Int = 128, height: Int = 96) throws -> CapturedScreenFrame {
        var candidate: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
                as CFDictionary, &candidate), kCVReturnSuccess)
        let buffer = try XCTUnwrap(candidate)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey,
            CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height { for x in 0..<width {
            let i = y * stride + x * 4
            bytes[i] = UInt8((x + seed * 9) % 256)
            bytes[i + 1] = UInt8((y + seed * 11) % 256)
            bytes[i + 2] = UInt8(y <= 26 ? seed * 17 % 256 : 100)
            bytes[i + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return try CapturedScreenFrame(pixelBuffer: buffer, displayID: 1, backingScaleFactor: 1)
    }

    func testNativeAndImageTexturesMatchCPUAcrossSurfaceTransitions() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let gpu = ScreenDifferenceWorker(backend: .metal)
        var cpu = ScreenDiffer()
        for seed in [0, 0, 1, 1, 2, 3, 0, 4, 0] {
            let native = try frame(seed: seed)
            let input = seed == 3 ? CapturedScreenFrame(image: native.image,
                displayID: 1, backingScaleFactor: 1) : native
            let expected = try cpu.process(input)
            let actual = try await gpu.process(input)
            XCTAssertEqual(actual, expected, "seed \(seed)")
        }
        let resized = try frame(seed: 1, width: 137, height: 93)
        let expected = try cpu.process(resized)
        let actual = try await gpu.process(resized)
        XCTAssertEqual(actual, expected)
    }

    func testNativeVideoBuffersPreserveFramesColorsAndOrientation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Compare both encoders on identical images to catch swaps/flips without
        // asserting lossless HEVC output. Keep buffers queued to test ownership.
        let inputs = try [frame(seed: 0), frame(seed: 8), frame(seed: 16)]
        var outputs: [[Data]] = []
        for native in [false, true] {
            let url = root.appendingPathComponent(native ? "native.mp4" : "image.mp4")
            var ready = false
            let writer = try FrameVideoWriter(outputURL: url, width: 128, height: 96,
                drainTimeout: .seconds(5), readiness: { ready })
            for (number, input) in inputs.enumerated() {
                if native { try writer.write(frameNumber: Int64(number), frame: input) }
                else { try writer.write(frameNumber: Int64(number), image: input.image) }
            }
            XCTAssertEqual(writer.pendingFrameCount, inputs.count)
            ready = true
            try await writer.finish()
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first),
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var decoded: [Data] = []
            while let sample = output.copyNextSampleBuffer() {
                let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                let bytes = CVPixelBufferGetBaseAddress(buffer)!
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                var data = Data()
                for row in 0..<96 { data.append(bytes.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: 128 * 4) }
                decoded.append(data)
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertEqual(decoded.count, inputs.count)
            outputs.append(decoded)
        }
        for (image, native) in zip(outputs[0], outputs[1]) {
            let errors = zip(image, native).map { abs(Int($0) - Int($1)) }
            XCTAssertLessThan(Double(errors.reduce(0, +)) / Double(errors.count), 3)
            XCTAssertLessThan(errors.max() ?? 0, 20)
        }
    }
}
#endif
