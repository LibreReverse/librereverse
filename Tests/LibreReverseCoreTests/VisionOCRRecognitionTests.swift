#if os(macOS)
import AppKit
import XCTest
@testable import LibreReverseCore

final class VisionOCRRecognitionTests: XCTestCase {
    @MainActor
    func testFastStandardRecognitionKeepsReadableDesktopTextAndGeometry() throws {
        let width = 1200, height = 500
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (row, phrase) in ["Budget 4837", "Release 9264", "Project 5172"].enumerated() {
            (phrase as NSString).draw(at: NSPoint(x: 40, y: 400 - row * 100), withAttributes: [
                .font: NSFont.systemFont(ofSize: CGFloat(20 + row * 4)),
                .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = try XCTUnwrap(context.makeImage())
        let document = try VisionOCRRecognizer(additionalLanguageSupport: false).recognize(
            image: image, normalizedFrontWindowBounds: nil)
        for token in ["4837", "9264", "5172"] { XCTAssertTrue(document.text.contains(token), token) }
        XCTAssertFalse(document.nodes.isEmpty)
        for node in document.nodes {
            XCTAssertGreaterThan(node.width, 0)
            XCTAssertGreaterThan(node.height, 0)
            XCTAssertGreaterThanOrEqual(node.leftX, 0)
            XCTAssertGreaterThanOrEqual(node.topY, 0)
            XCTAssertLessThanOrEqual(node.leftX + node.width, 1.001)
            XCTAssertLessThanOrEqual(node.topY + node.height, 1.001)
        }
    }
}
#endif
