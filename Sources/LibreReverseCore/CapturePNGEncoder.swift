#if os(macOS)
import CFPNG
import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One encoder per recording session. The lock protects reusable native storage
/// and its borrowed output across detached capture tasks; no pixel data escapes.
final class CapturePNGEncoder: @unchecked Sendable {
    private let lock = NSLock()
    // Bounds packed input, not total memory. Larger images retain ImageIO support.
    private let native = cf_png_create(128 * 1024 * 1024)

    deinit { cf_png_destroy(native) }

    func write(_ frame: CapturedScreenFrame, to url: URL) throws {
        try write(image: frame.image, pixelBuffer: frame.pixelBuffer, to: url)
    }

    /// A supplied pixel buffer must be the immutable surface backing image.
    func write(image: CGImage, pixelBuffer: CVPixelBuffer?, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let signposter = CaptureDiffInstrumentation.signposter
        let interval = signposter.beginInterval("CapturePNGWrite", id: signposter.makeSignpostID())
        defer { signposter.endInterval("CapturePNGWrite", interval) }

        // Publish only a completed file. Failure removes our new staging file,
        // never an existing recovery image. Admission still awaits this method.
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".capture-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staging) }
        if let encoded = encode(image: image, pixelBuffer: pixelBuffer) {
            try Self.writeBytes(encoded, to: staging)
            signposter.emitEvent("CapturePNGNative", "bytes: \(encoded.count)")
        } else {
            try Self.writeImageIO(image, to: staging)
            signposter.emitEvent("CapturePNGImageIO")
        }
        guard rename(staging.path, url.path) == 0 else { throw Self.fileError() }
    }

    private struct EncodedBytes {
        let base: UnsafePointer<UInt8>
        let count: Int
    }

    private func encode(image: CGImage, pixelBuffer: CVPixelBuffer?) -> EncodedBytes? {
        guard native != nil,
            image.bitsPerComponent == 8, image.bitsPerPixel == 32,
            image.decode == nil, !image.isMask,
            !image.bitmapInfo.contains(.floatComponents),
            image.colorSpace?.name == CGColorSpace.sRGB,
            image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little,
            [.premultipliedFirst, .first, .noneSkipFirst].contains(image.alphaInfo),
            let width = UInt32(exactly: image.width),
            let height = UInt32(exactly: image.height)
        else { return nil }
        let ignoreAlpha: Int32 = image.alphaInfo == .noneSkipFirst ? 1 : 0
        if let buffer = pixelBuffer,
            !CVPixelBufferIsPlanar(buffer),
            CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
            CVPixelBufferGetWidth(buffer) == image.width,
            CVPixelBufferGetHeight(buffer) == image.height,
            CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
        {
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            return encode(base.assumingMemoryBound(to: UInt8.self),
                count: CVPixelBufferGetDataSize(buffer), width: width, height: height,
                stride: CVPixelBufferGetBytesPerRow(buffer), ignoreAlpha: ignoreAlpha)
        }
        // Image-only inputs may carry crop/mask/provider semantics beyond a
        // plain pixel array. Keep their complete ImageIO interpretation.
        return nil
    }

    private func encode(_ base: UnsafePointer<UInt8>, count: Int,
                        width: UInt32, height: UInt32, stride: Int,
                        ignoreAlpha: Int32) -> EncodedBytes? {
        var output: UnsafePointer<UInt8>?
        var outputCount = 0
        let result = cf_png_encode_bgra8(native, base, count, width, height, stride,
                                        ignoreAlpha, &output, &outputCount)
        guard result == CFPNG_SUCCESS, let output, outputCount > 0 else { return nil }
        return EncodedBytes(base: output, count: outputCount)
    }

    private static func writeBytes(_ bytes: EncodedBytes, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw fileError() }
        var needsClose = true
        defer { if needsClose { _ = close(descriptor) } }
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(descriptor, bytes.base.advanced(by: offset), bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw fileError()
            }
            guard written > 0 else { throw POSIXError(.EIO) }
            offset += written
        }
        // Normal close semantics match capture's existing persistence contract;
        // no per-frame fsync is added. Always check close before publishing.
        let result = close(descriptor)
        needsClose = false
        guard result == 0 else { throw fileError() }
    }

    private static func fileError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    static func writeImageIO(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ScreenRecordingSessionError.unableToWriteImage }
        let properties = [kCGImagePropertyPNGDictionary: [
            kCGImagePropertyPNGCompressionFilter: IMAGEIO_PNG_FILTER_UP
        ]] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenRecordingSessionError.unableToWriteImage
        }
    }
}
#endif
