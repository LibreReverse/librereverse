#if os(macOS)
import CoreGraphics
import Foundation
import Metal
import XCTest
@testable import LibreReverseCore

final class MetalScreenDifferTests: XCTestCase {
    private func frame(width: Int = 51, height: Int = 81, display: UInt32 = 1,
                       scale: CGFloat = 1, changed: Int = 0, value: UInt8 = 0,
                       channel: Int = 2, alpha: UInt8 = 255) throws -> CapturedScreenFrame {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            bytes[pixel * 4 + 3] = alpha
            if pixel >= width * 27 && pixel < width * 27 + changed {
                bytes[pixel * 4 + channel] = value
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue:
                CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return CapturedScreenFrame(image: image, displayID: display, backingScaleFactor: scale)
    }

    func testGPUCountsMatchCPUAcrossBoundariesAndReferenceResets() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let gpu = ScreenDifferenceWorker(backend: .metal)
        var cpu = ScreenDiffer()
        let frames = try [
            frame(), frame(changed: 1000, value: 9), frame(),
            frame(changed: 999, value: 10), frame(), frame(changed: 1000, value: 10),
            frame(changed: 1000, value: 19), // skipped input must still become the baseline
            frame(changed: 1000, value: 28),
            frame(display: 2), frame(display: 2, changed: 1000, value: 10, channel: 0),
            frame(changed: 1000, value: 28),
            frame(scale: 2, changed: 2754, value: 200), frame(scale: 2),
            frame(width: 19, height: 21), frame(width: 19, height: 21, alpha: 128),
            frame(), frame(changed: 2754, value: 255, channel: 1), frame(),
            frame(alpha: 128), frame(scale: 1.25), frame(scale: 1.25, changed: 2754, value: 255)
        ]
        for (index, frame) in frames.enumerated() {
            let expected = try cpu.process(frame)
            let actual = try await gpu.process(frame)
            XCTAssertEqual(actual, expected, "frame \(index)")
        }
    }

    func testReusedSurfacesMatchCPUForAlphaAndColorConversions() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let gpu = ScreenDifferenceWorker(backend: .metal)
        var cpu = ScreenDiffer()
        let width = 117, height = 93
        for spaceName in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            let space = try XCTUnwrap(CGColorSpace(name: spaceName))
            for seed in 0..<12 {
                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                for pixel in 0..<(width * height) {
                    let alpha: UInt8 = seed % 3 == 0 ? 0 : (seed % 3 == 1 ? 128 : 255)
                    for channel in 0..<3 {
                        bytes[pixel * 4 + channel] = alpha == 0 ? 0
                            : UInt8((pixel * (channel + 1) + seed * 9) % 129)
                    }
                    bytes[pixel * 4 + 3] = alpha
                }
                // RGBA input forces channel/layout conversion to canonical BGRA.
                let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
                let image = try XCTUnwrap(CGImage(width: width, height: height,
                    bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                let input = CapturedScreenFrame(image: image, displayID: 1, backingScaleFactor: 1)
                let expected = try cpu.process(input)
                let actual = try await gpu.process(input)
                XCTAssertEqual(actual, expected, "space \(spaceName), seed \(seed)")
            }
        }
    }

}
#endif
