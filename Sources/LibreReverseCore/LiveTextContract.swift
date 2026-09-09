#if os(macOS)
import CoreGraphics
import Foundation

/// Geometry and timing for Live Text selection and display.
public enum LiveTextContract {
    /// Delay before loading analysis for the full-image surface, in milliseconds.
    public static let fullFrameDelayMilliseconds = 500

    /// Selected areas use continuous corners and a half-opaque backdrop.
    public static let areaCornerRadius: CGFloat = 16
    public static let areaBackgroundOpacity: CGFloat = 0.5
    /// Maximum enlargement of a selected area.
    public static let maximumAreaZoom: CGFloat = 2
    public static let dismissAnimationDuration: TimeInterval = 0.2
    public static let overlayPaddingTop: CGFloat = 75
    public static let overlayPaddingLeading: CGFloat = 75
    public static let overlayPaddingBottom: CGFloat = 75
    public static let overlayPaddingTrailing: CGFloat = 50
    public static let springResponse: TimeInterval = 0.33
    public static let springDampingFraction: CGFloat = 0.9
    public static let imageBackgroundOpacity: CGFloat = 0.4
    public static let resultBannerGap: CGFloat = 16
    public static let resultBannerHeight: CGFloat = 33

    /// Beginning native text or data-detector interaction pauses playback while
    /// allowing VisionKit to handle the selection.
    public static let allowsEveryNativeInteraction = true

    /// Rectangle occupied by an aspect-fit image in the explorer surface.
    public static func aspectFitRect(imageSize: CGSize, contentSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              contentSize.width > 0, contentSize.height > 0 else { return .zero }
        let scale = min(
            contentSize.width / imageSize.width,
            contentSize.height / imageSize.height
        )
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (contentSize.width - size.width) / 2,
            y: (contentSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// `ImageAnalysisOverlayView` resolves its delegate's `contentsRect` in
    /// **unit** coordinates: the framework's own default is `(0, 0, 1, 1)`.
    /// Handing it the point-space aspect-fit rect scaled every analysis
    /// bounding box by the content view's dimensions, which pushed every text
    /// item far outside the surface and made selection unhittable.
    public static func aspectFitUnitRect(
        imageSize: CGSize,
        contentSize: CGSize
    ) -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard contentSize.width > 0, contentSize.height > 0 else { return unit }
        let fit = aspectFitRect(imageSize: imageSize, contentSize: contentSize)
        guard fit.width > 0, fit.height > 0 else { return unit }
        return CGRect(
            x: fit.minX / contentSize.width,
            y: fit.minY / contentSize.height,
            width: fit.width / contentSize.width,
            height: fit.height / contentSize.height
        )
    }

    /// Maps centered content-space selection into source pixels using the larger
    /// width/height scale for an aspect-fill crop.
    public static func sourceCropRect(
        imageSize: CGSize,
        contentSize: CGSize,
        selectionRect: CGRect
    ) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0 else { return .zero }
        let scale = max(
            imageSize.width / contentSize.width,
            imageSize.height / contentSize.height
        )
        let cropSize = CGSize(
            width: selectionRect.width * scale,
            height: selectionRect.height * scale
        )
        return CGRect(
            x: selectionRect.origin.x * scale - cropSize.width / 2,
            y: selectionRect.origin.y * scale - cropSize.height / 2,
            width: cropSize.width,
            height: cropSize.height
        )
    }

    /// Doubles each selection dimension, capped by the available surface and padding.
    public static func areaOverlaySize(
        selectionSize: CGSize,
        availableSize: CGSize
    ) -> CGSize {
        guard selectionSize.width > 0, selectionSize.height > 0 else { return .zero }
        return CGSize(
            width: min(
                selectionSize.width * maximumAreaZoom,
                max(0, availableSize.width - overlayPaddingLeading - overlayPaddingTrailing)
            ),
            height: min(
                selectionSize.height * maximumAreaZoom,
                max(0, availableSize.height - overlayPaddingTop - overlayPaddingBottom)
            )
        )
    }

    /// Preserves the selection center, then clamps to the four asymmetric margins.
    public static func areaOverlayFrame(
        selectionRect: CGRect,
        availableSize: CGSize
    ) -> CGRect {
        let size = areaOverlaySize(
            selectionSize: selectionRect.size,
            availableSize: availableSize
        )
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        let minCenterX = overlayPaddingLeading + halfWidth
        let maxCenterX = availableSize.width - overlayPaddingTrailing - halfWidth
        let minCenterY = overlayPaddingTop + halfHeight
        let maxCenterY = availableSize.height - overlayPaddingBottom - halfHeight
        let centerX = min(max(selectionRect.midX, minCenterX), maxCenterX)
        let centerY = min(max(selectionRect.midY, minCenterY), maxCenterY)
        return CGRect(
            x: centerX - halfWidth,
            y: centerY - halfHeight,
            width: size.width,
            height: size.height
        )
    }
}

public enum LiveTextSelectionPhase: Equatable, Sendable {
    case fullBleed
    case selectingArea(origin: CGPoint, current: CGPoint)
    case analyzingArea(CGRect)
    case areaSelection(CGRect)
}

/// Replacing the represented frame restores full-image ownership and
/// invalidates any previous cropped analysis.
public struct LiveTextSelectionState: Equatable, Sendable {
    public private(set) var phase: LiveTextSelectionPhase = .fullBleed

    public init() {}

    public mutating func representedFrameChanged() { phase = .fullBleed }

    public mutating func beginAreaSelection(at point: CGPoint) {
        phase = .selectingArea(origin: point, current: point)
    }

    public mutating func updateAreaSelection(to point: CGPoint) {
        guard case .selectingArea(let origin, _) = phase else { return }
        phase = .selectingArea(origin: origin, current: point)
    }

    @discardableResult
    public mutating func finishAreaSelection(at point: CGPoint) -> CGRect? {
        guard case .selectingArea(let origin, _) = phase else { return nil }
        let rect = Self.standardizedRect(from: origin, to: point)
        guard rect.width > 0, rect.height > 0 else {
            phase = .fullBleed
            return nil
        }
        phase = .analyzingArea(rect)
        return rect
    }

    public mutating func areaAnalysisCompleted() {
        guard case .analyzingArea(let rect) = phase else { return }
        phase = .areaSelection(rect)
    }

    public mutating func areaAnalysisFailed() { phase = .fullBleed }
    public mutating func cancelAreaSelection() { phase = .fullBleed }

    public var selectionRect: CGRect? {
        switch phase {
        case .fullBleed: return nil
        case .selectingArea(let origin, let current):
            return Self.standardizedRect(from: origin, to: current)
        case .analyzingArea(let rect), .areaSelection(let rect): return rect
        }
    }

    private static func standardizedRect(from first: CGPoint, to second: CGPoint) -> CGRect {
        CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }
}
#endif
