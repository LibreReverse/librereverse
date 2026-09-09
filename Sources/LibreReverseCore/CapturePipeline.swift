#if os(macOS)
import CoreGraphics
import CoreVideo
import VideoToolbox
import Foundation
import AppKit
@preconcurrency import ScreenCaptureKit

public enum CaptureContract {
    /// Interval between scheduled screen captures.
    public static let productionCaptureIntervalSeconds: TimeInterval = 2
    /// Capture timer scheduling uses zero additional leeway.
    public static let captureTimerLeewayNanoseconds = 0
    public static let menuBarHeightPoints: Float = 26
    public static let nominalVideoFrameRate: Int32 = 30

    public static func menuBarHeightPixels(backingScaleFactor: CGFloat) -> Float {
        Float(backingScaleFactor) * menuBarHeightPoints
    }
}

// Captured surfaces are retained and treated as immutable by every consumer.
public struct CapturedScreenFrame: @unchecked Sendable {
    public let image: CGImage
    let pixelBuffer: CVPixelBuffer?
    public let displayID: CGDirectDisplayID
    public let backingScaleFactor: CGFloat

    public init(image: CGImage, displayID: CGDirectDisplayID, backingScaleFactor: CGFloat) {
        self.image = image
        self.pixelBuffer = nil
        self.displayID = displayID
        self.backingScaleFactor = backingScaleFactor
    }

    /// Internal native capture path. Callers must not mutate the retained buffer.
    init(pixelBuffer: CVPixelBuffer, displayID: CGDirectDisplayID,
         backingScaleFactor: CGFloat) throws {
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil,
            imageOut: &image) == noErr, let image else {
            throw ScreenDifferError.imageConversion
        }
        self.image = image
        self.pixelBuffer = pixelBuffer
        self.displayID = displayID
        self.backingScaleFactor = backingScaleFactor
    }

    /// The AppKit point size represented by the captured backing pixels.
    /// Passing raw Retina pixel dimensions to `NSImage` makes its intrinsic
    /// content size twice the display size and can expand a constrained window.
    public var logicalDisplaySize: CGSize {
        let scale = backingScaleFactor > 0 ? backingScaleFactor : 1
        return CGSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
    }
}

public enum WindowCaptureError: Error {
    case noDisplay
    case noWindows
    case captureFailed
}

/// Captures only the WindowServer IDs admitted by the privacy-aware selector.
/// A window which disappears between selection and capture is omitted; the
/// screenshot must never fall back to an unfiltered display capture.
public enum WindowCapture {
    private static let captureBackgroundColor = CGColor(gray: 0, alpha: 1)
    public static func capture(
        displayID: CGDirectDisplayID,
        windowIDs: [CGWindowID]
    ) async throws -> CapturedScreenFrame {
        let signposter = CaptureDiffInstrumentation.signposter
        let interval = signposter.beginInterval("ScreenshotCapture", id: signposter.makeSignpostID())
        defer { signposter.endInterval("ScreenshotCapture", interval) }
        guard !windowIDs.isEmpty else { throw WindowCaptureError.noWindows }
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw WindowCaptureError.noDisplay
        }
        let selectedIDs = Set(windowIDs)
        let windows = content.windows.filter { selectedIDs.contains($0.windowID) }
        guard !windows.isEmpty else { throw WindowCaptureError.noWindows }
        let filter = SCContentFilter(display: display, including: windows)
        // Neither menus nor automatically included child windows may expand
        // the caller's approved window set after its privacy selection.
        filter.includeMenuBar = false
        let mode = CGDisplayCopyDisplayMode(displayID)
        let configuration = screenshotConfiguration(
            pixelWidth: mode?.pixelWidth ?? CGDisplayPixelsWide(displayID),
            pixelHeight: mode?.pixelHeight ?? CGDisplayPixelsHigh(displayID)
        )
        try Task.checkCancellation()
        let sample = try await SCScreenshotManager.captureSampleBuffer(
            contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        let bounds = display.frame
        guard bounds.width > 0, bounds.height > 0 else { throw WindowCaptureError.noDisplay }
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw ScreenDifferError.imageConversion
        }
        return try CapturedScreenFrame(pixelBuffer: buffer, displayID: displayID,
            backingScaleFactor: CGFloat(CVPixelBufferGetWidth(buffer)) / bounds.width)
    }

    static func screenshotConfiguration(pixelWidth: Int, pixelHeight: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.includeChildWindows = false
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.captureDynamicRange = .SDR
        // Ask the capture compositor for a standard SDR working format. Using
        // the display's wide-gamut profile otherwise repeats an expensive CPU
        // color transform for every diff and downstream image consumer.
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.queueDepth = 1
        configuration.backgroundColor = captureBackgroundColor
        // Leave sourceRect unset: the filter supplies full-display geometry,
        // including displays whose global desktop origin is nonzero.
        return configuration
    }

    /// Resolves the display containing the pointer using the same ordered
    /// AppKit screen lookup used by the app capture path.
    public static func pointerDisplayID() throws -> CGDirectDisplayID {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { screen in
            let frame = screen.frame
            return point.x >= frame.minX && point.x <= frame.maxX
                && point.y >= frame.minY && point.y <= frame.maxY
        } ?? NSScreen.main
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber else {
            throw WindowCaptureError.noDisplay
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard displayID != 0 else { throw WindowCaptureError.noDisplay }
        return displayID
    }

}

public struct ScreenDifferenceDecision: Equatable, Sendable {
    public let changedPixels: Int
    public let isFirstFrame: Bool
    public let admitted: Bool
}

public enum ScreenDifferError: Error {
    case imageConversion
}

/// Byte-exact CPU equivalent for the observable gate when the inputs are
/// 8-bit display screenshots. A normalized channel delta greater than
/// 0.0390625 is exactly an integer byte delta of at least 10. The Metal
/// primitive has no output texture for a new display/dimension, but the
/// controller admits the original screenshot to seed a recording chunk.
public struct ScreenDiffer {
    private var previousByDisplay: [CGDirectDisplayID: PreviousScreenFrame] = [:]

    public init() {}

    public mutating func process(_ frame: CapturedScreenFrame) throws -> ScreenDifferenceDecision {
        let current = try CanonicalFrame(image: frame.image)
        let menuBarHeight = CaptureContract.menuBarHeightPixels(
            backingScaleFactor: frame.backingScaleFactor
        )
        guard let prior = previousByDisplay[frame.displayID],
              prior.menuBarHeight == menuBarHeight,
              prior.frame.width == current.width,
              prior.frame.height == current.height else {
            previousByDisplay[frame.displayID] = PreviousScreenFrame(
                frame: current,
                menuBarHeight: menuBarHeight
            )
            return ScreenDifferenceDecision(changedPixels: 0, isFirstFrame: true, admitted: true)
        }
        let previous = prior.frame
        defer {
            previousByDisplay[frame.displayID] = PreviousScreenFrame(
                frame: current,
                menuBarHeight: menuBarHeight
            )
        }

        // This loop visits every pixel of a full Retina capture (~5.9M on a
        // 3024x1964 display) on every admission. Indexing two Swift `Array`s
        // here pays bounds checks and buffer retain/release per access, and the
        // profile showed it dominating the main thread. Read both through raw
        // buffer pointers instead; the arithmetic and thresholds are unchanged.
        var count = 0
        let width = current.width
        let height = current.height
        let bytesPerRow = current.bytesPerRow
        let firstRow = menuBarHeight < 0
            ? 0
            : min(height, Int(menuBarHeight.rounded(.down)) + 1)
        previous.bytes.withUnsafeBufferPointer { previousBytes in
            current.bytes.withUnsafeBufferPointer { currentBytes in
                guard let previousBase = previousBytes.baseAddress,
                      let currentBase = currentBytes.baseAddress else { return }
                for y in firstRow..<height where Float(y) > menuBarHeight {
                    let row = y * bytesPerRow
                    var offset = row
                    for _ in 0..<width {
                        // Canonical layout is BGRA; alpha is intentionally ignored.
                        let previousBlue = Int(previousBase[offset])
                        let currentBlue = Int(currentBase[offset])
                        let previousGreen = Int(previousBase[offset + 1])
                        let currentGreen = Int(currentBase[offset + 1])
                        let previousRed = Int(previousBase[offset + 2])
                        let currentRed = Int(currentBase[offset + 2])
                        if abs(previousBlue - currentBlue) >= 10
                            || abs(previousGreen - currentGreen) >= 10
                            || abs(previousRed - currentRed) >= 10 {
                            count += 1
                        }
                        offset += 4
                    }
                }
            }
        }
        return ScreenDifferenceDecision(
            changedPixels: count,
            isFirstFrame: false,
            admitted: CaptureAdmissionPolicy.admits(changedPixels: count)
        )
    }
}

private struct PreviousScreenFrame {
    let frame: CanonicalFrame
    let menuBarHeight: Float
}

private struct CanonicalFrame {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    init(image: CGImage) throws {
        let imageWidth = image.width
        let imageHeight = image.height
        let rowBytes = imageWidth * 4
        width = imageWidth
        height = imageHeight
        bytesPerRow = rowBytes
        var storage = Array(repeating: UInt8(0), count: rowBytes * imageHeight)
        let madeContext = storage.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress,
                width: imageWidth,
                height: imageHeight,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        }
        guard let context = madeContext else { throw ScreenDifferError.imageConversion }
        context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        bytes = storage
    }
}
#endif
