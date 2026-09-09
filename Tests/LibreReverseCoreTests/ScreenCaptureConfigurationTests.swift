#if os(macOS)
import XCTest
import ScreenCaptureKit
import CoreGraphics
import CoreVideo
@testable import LibreReverseCore

final class ScreenCaptureConfigurationTests: XCTestCase {
    func testNativeResolutionPreservesFullDisplayAndDoesNotExpandWindowSelection() {
        let configuration = WindowCapture.screenshotConfiguration(pixelWidth: 3024, pixelHeight: 1964)
        XCTAssertEqual(configuration.width, 3024)
        XCTAssertEqual(configuration.height, 1964)
        XCTAssertEqual(configuration.captureResolution, .best)
        XCTAssertEqual(configuration.sourceRect, .zero)
        XCTAssertFalse(configuration.includeChildWindows)
        XCTAssertFalse(configuration.showsCursor)
        XCTAssertFalse(configuration.capturesAudio)
        XCTAssertFalse(configuration.captureMicrophone)
        XCTAssertEqual(configuration.captureDynamicRange, .SDR)
        XCTAssertEqual(configuration.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(configuration.colorSpaceName, CGColorSpace.sRGB)
        XCTAssertEqual(configuration.queueDepth, 1)
    }

    func testEmptyPrivacySelectionFailsBeforeRequestingCapturePermission() async {
        do {
            _ = try await WindowCapture.capture(displayID: 0, windowIDs: [])
            XCTFail("An empty approved window set must never capture the whole display")
        } catch WindowCaptureError.noWindows {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
#endif
