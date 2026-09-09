#if os(macOS)
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import XCTest
@testable import LibreReverseCore

final class NativePNGEncoderTests: XCTestCase {
    private struct Fixture {
        let frame: CapturedScreenFrame
        let expected: Data
        let stride: Int
    }

    private func fixture(width: Int = 137, height: Int = 91, seed: Int = 0,
                         space: CFString = CGColorSpace.sRGB,
                         transparent: Bool = false) throws -> Fixture {
        var output: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferBytesPerRowAlignmentKey as String: 256,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &output), kCVReturnSuccess)
        let buffer = try XCTUnwrap(output)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey,
            try XCTUnwrap(CGColorSpace(name: space)), .shouldPropagate)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        memset(base, 0xCD, stride * height)
        var expected = Data()
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let pixel = x * 4
                row[pixel] = UInt8((x * 3 + y * 7 + seed * 11) % 256)
                row[pixel + 1] = UInt8((x * 13 + y * 5 + seed * 17) % 256)
                row[pixel + 2] = UInt8((x * 19 + y * 23 + seed * 29) % 256)
                row[pixel + 3] = 255
                if transparent && x < width / 3 && y < height / 2 {
                    row[pixel] = 0; row[pixel + 1] = 0
                    row[pixel + 2] = 0; row[pixel + 3] = 0
                }
            }
            expected.append(row, count: width * 4)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return Fixture(frame: try CapturedScreenFrame(pixelBuffer: buffer, displayID: 1,
            backingScaleFactor: 1), expected: expected, stride: stride)
    }

    private func decodedImage(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func pixels(_ image: CGImage, space: CGColorSpace) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    private func chunks(_ url: URL) throws -> [String] {
        let data = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        var offset = 8
        var names: [String] = []
        while offset + 12 <= data.count {
            let size = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard size <= data.count - offset - 12 else {
                XCTFail("Invalid PNG chunk length"); return names
            }
            let name = String(bytes: data[offset + 4..<offset + 8], encoding: .ascii) ?? ""
            names.append(name)
            offset += 12 + size
            if name == "IEND" { break }
        }
        XCTAssertEqual(names.first, "IHDR")
        XCTAssertEqual(names.last, "IEND")
        XCTAssertEqual(offset, data.count)
        return names
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-png-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testOpaqueNativeBufferPreservesOddDimensionsPaddingAndAllChannels() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = CapturePNGEncoder()
        let input = try fixture()
        XCTAssertGreaterThan(input.stride, input.frame.image.width * 4)
        let destination = root.appendingPathComponent("opaque.png")
        try encoder.write(input.frame, to: destination)
        XCTAssertTrue(try chunks(destination).contains("fdEC"), "Opaque native capture must use FPNG")
        let decoded = try decodedImage(destination)
        XCTAssertEqual(decoded.width, input.frame.image.width)
        XCTAssertEqual(decoded.height, input.frame.image.height)
        XCTAssertEqual(try pixels(decoded, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))), input.expected)
    }

    func testTransparencyAndDisplayP3MatchImageIOFallback() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = CapturePNGEncoder()
        for (index, settings) in [(CGColorSpace.sRGB, true), (CGColorSpace.displayP3, false)].enumerated() {
            let input = try fixture(seed: index + 1, space: settings.0, transparent: settings.1)
            let actualURL = root.appendingPathComponent("actual-\(index).png")
            let referenceURL = root.appendingPathComponent("reference-\(index).png")
            // Supply the native buffer too: fallback must depend on image
            // semantics, not merely the absence of a pixel buffer.
            try encoder.write(image: input.frame.image, pixelBuffer: input.frame.pixelBuffer, to: actualURL)
            let referenceDestination = try XCTUnwrap(CGImageDestinationCreateWithURL(
                referenceURL as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(referenceDestination, input.frame.image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(referenceDestination))
            XCTAssertFalse(try chunks(actualURL).contains("fdEC"), "Transparency and wide gamut must use ImageIO")
            let actual = try decodedImage(actualURL), reference = try decodedImage(referenceURL)
            let space = try XCTUnwrap(CGColorSpace(name: settings.0))
            XCTAssertEqual(try pixels(actual, space: space), try pixels(reference, space: space))
            XCTAssertEqual(actual.colorSpace?.name, reference.colorSpace?.name)
            if settings.1 { XCTAssertEqual(try pixels(actual, space: space), input.expected) }
        }
    }

    func testEncoderReuseLeavesEarlierFilesStableAcrossDimensionsAndFallback() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = CapturePNGEncoder()
        var retained: [(URL, Data, Fixture)] = []
        for index in 0..<6 {
            let input = try fixture(width: index % 2 == 0 ? 137 : 93,
                                    height: index % 2 == 0 ? 91 : 57,
                                    seed: index, transparent: index == 3)
            let url = root.appendingPathComponent("frame-\(index).png")
            try encoder.write(input.frame, to: url)
            retained.append((url, try Data(contentsOf: url), input))
        }
        for (url, bytes, input) in retained {
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(try pixels(decodedImage(url), space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))), input.expected)
        }
    }

    func testUnusedAlphaBytesAreIgnoredForNoneSkipFirstImages() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let width = 137, height = 91
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var candidate: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferBytesPerRowAlignmentKey as String: 256] as CFDictionary,
            &candidate), kCVReturnSuccess)
        let buffer = try XCTUnwrap(candidate)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue))
        let base = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        memset(base, 0, context.bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = y * context.bytesPerRow + x * 4
                base[pixel] = UInt8(x % 256)
                base[pixel + 1] = UInt8(y % 256)
                base[pixel + 2] = 191
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(image.alphaInfo, .noneSkipFirst)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let url = root.appendingPathComponent("unused-alpha.png")
        try CapturePNGEncoder().write(image: image, pixelBuffer: buffer, to: url)
        XCTAssertTrue(try chunks(url).contains("fdEC"))
        XCTAssertEqual(try pixels(decodedImage(url), space: space), try pixels(image, space: space))
    }

    func testImageOnlyCropUsesImageIOAndPreservesVisiblePixels() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try fixture(seed: 9)
        let cropped = try XCTUnwrap(input.frame.image.cropping(to:
            CGRect(x: 3, y: 5, width: 97, height: 47)))
        let url = root.appendingPathComponent("crop.png")
        try CapturePNGEncoder().write(image: cropped, pixelBuffer: nil, to: url)
        XCTAssertFalse(try chunks(url).contains("fdEC"))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        XCTAssertEqual(try pixels(decodedImage(url), space: space), try pixels(cropped, space: space))
    }

    func testFailedPublishPreservesExistingDestinationAndRemovesStaging() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("protected.png", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sentinel = destination.appendingPathComponent("sentinel")
        let original = Data("must survive failed publish".utf8)
        try original.write(to: sentinel)
        let input = try fixture(seed: 8)
        XCTAssertThrowsError(try CapturePNGEncoder().write(input.frame, to: destination))
        XCTAssertEqual(try Data(contentsOf: sentinel), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["protected.png"])
    }

    func testFailedWritePropagatesAndDoesNotPoisonReusableEncoder() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = CapturePNGEncoder()
        let input = try fixture(seed: 7)
        let unavailable = root.appendingPathComponent("missing-parent/frame.png")
        XCTAssertThrowsError(try encoder.write(input.frame, to: unavailable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unavailable.path))
        let destination = root.appendingPathComponent("after-failure.png")
        try encoder.write(input.frame, to: destination)
        XCTAssertEqual(try pixels(decodedImage(destination), space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))), input.expected)
    }
}
#endif
