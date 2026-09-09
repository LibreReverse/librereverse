#if os(macOS)
import CoreGraphics
import ImageIO
import XCTest
@testable import LibreReverseCore

final class CapturePNGTests: XCTestCase {
    func testRecoveryPNGPreservesPixelsIncludingTransparencyAndOddWidth() throws {
        let width = 137, height = 91
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        let source = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: bitmap)!
        source.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: width, height: height))
        source.clear(CGRect(x: 3, y: 7, width: 13, height: 19))
        source.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        source.fill(CGRect(x: 70, y: 40, width: 4, height: 5))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ScreenRecordingSession.writePNG(source.makeImage()!, to: url)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
        let decoded = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: bitmap)!
        decoded.setBlendMode(.copy)
        decoded.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        XCTAssertEqual(memcmp(source.data!, decoded.data!, width * height * 4), 0)
    }
}
#endif
