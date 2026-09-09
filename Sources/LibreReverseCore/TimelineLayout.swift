import Foundation

/// Timeline and application-group geometry in screen points.
public enum TimelineMediaType: UInt8, CaseIterable, Sendable {
    case audio = 0
    case screenshot = 1
    case star = 2

    public var bottomInset: Double {
        switch self {
        case .audio: 77.5
        case .screenshot: 75
        case .star: 71
        }
    }

    public var height: Double {
        switch self {
        case .audio: 55
        case .screenshot: 30
        case .star: 16
        }
    }

    /// Collection z-order places stars over screenshots and screenshots over audio.
    public var zIndex: Int { Int(rawValue) }
}

public struct TimelineRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
}

/// Fast-scroll state records its timestamp and whether it was manual.
public struct TimelineFastScrollEvent: Equatable, Sendable {
    public var date: Date
    public var isManual: Bool

    public init(date: Date, isManual: Bool) {
        self.date = date
        self.isManual = isManual
    }
}

public enum TimelineLayout {
    public static let contentHeight: Double = 140
    public static let appGroupHeight: Double = 30
    public static let appSegmentBarHeight: Double = 10
    /// Initial continuous zoom level.
    public static let defaultZoomLevel: Float = 60
    /// The SwiftUI slider binds continuously across this closed range. It has
    /// no discrete `step` argument.
    public static let zoomLevelRange: ClosedRange<Float> = 0...100
    /// Visible duration range expressed in seconds.
    public static let minimumVisibleDuration: Float = 60
    public static let maximumVisibleDuration: Float = 10_800

    /// Half-viewport leading and trailing space keeps the playhead centered,
    /// including at odd viewport widths.
    public static func contentWidth(
        contiguousDuration: TimeInterval,
        viewportWidth: Double,
        logZoomRange: Float
    ) -> Double {
        floor(contiguousDuration * viewportWidth / Double(logZoomRange))
            + 2 * floor(viewportWidth * 0.5)
    }

    /// Fixed-playhead scroll origin for a contiguous offset. Half-viewport padding
    /// belongs to item geometry and is absent from the clip-view origin.
    public static func scrollOriginX(
        contiguousOffset: TimeInterval,
        viewportWidth: Double,
        logZoomRange: Float
    ) -> Double? {
        guard viewportWidth > 0, logZoomRange > 0 else { return nil }
        return contiguousOffset * viewportWidth / Double(logZoomRange)
    }

    /// Inverse of ``scrollOriginX(contiguousOffset:viewportWidth:logZoomRange:)``.
    public static func contiguousOffset(
        scrollOriginX: Double,
        viewportWidth: Double,
        logZoomRange: Float
    ) -> TimeInterval? {
        guard viewportWidth > 0, logZoomRange > 0 else { return nil }
        return scrollOriginX / (viewportWidth / Double(logZoomRange))
    }

    /// Offset zero is fixed at the horizontal center/playhead.
    public static func itemFrame(
        offset: TimeInterval,
        duration: TimeInterval,
        mediaType: TimelineMediaType,
        viewportWidth: Double,
        contentHeight: Double = contentHeight,
        logZoomRange: Float
    ) -> TimelineRect {
        let scale = viewportWidth / Double(logZoomRange)
        let itemWidth = mediaType == .star
            ? TimelineDrawingStyle.starWidth
            : floor(duration * scale)
        return TimelineRect(
            x: floor(offset * scale) + floor(viewportWidth * 0.5),
            y: contentHeight - mediaType.bottomInset,
            width: itemWidth,
            height: mediaType.height
        )
    }

    /// Float-domain mapping from the supplied range bounds to visible duration.
    public static func logZoomRange(
        zoomLevel: Float,
        rangeLower: Float,
        rangeUpper: Float
    ) -> Float {
        let normalized = (powf(1.11, 100 - zoomLevel) * 0.003 - 0.003) / 100
        return rangeLower + (rangeUpper - rangeLower) * normalized
    }

    /// Requested interactive database-window duration. Keep it separate from the
    /// actual duration returned by paged loading: feeding an overshooting page
    /// duration into later requests expands the window on every scrub.
    public static func interactiveFetchWindowDuration(
        zoomLevel: Float,
        validSeekDuration: TimeInterval?,
        lastFastScroll: TimelineFastScrollEvent? = nil,
        now: Date = Date()
    ) -> TimeInterval {
        guard let range = zoomRange(validSeekDuration: validSeekDuration) else {
            return 0
        }
        // Keep intermediate arithmetic in Float; convert only the final duration.
        var duration = logZoomRange(
            zoomLevel: zoomLevel,
            rangeLower: range.lowerBound,
            rangeUpper: range.upperBound
        ) * 10
        if let lastFastScroll,
           lastFastScroll.date.timeIntervalSince(now) > -10 {
            let initialMultiplier: Float = lastFastScroll.isManual ? 2 : 4
            let multiplied = duration * initialMultiplier
            duration = zoomLevel < 300 ? multiplied * 2 : multiplied
        }
        return TimeInterval(duration)
    }

    /// Zoom bounds are available only after a valid seek interval is known.
    public static func zoomRange(validSeekDuration: TimeInterval?) -> ClosedRange<Float>? {
        guard let validSeekDuration else { return nil }
        let upper = min(
            maximumVisibleDuration,
            max(minimumVisibleDuration, Float(validSeekDuration))
        )
        return minimumVisibleDuration...upper
    }

    /// Projects a segment into its app group using contiguous offsets. The previous
    /// raw frame supplies the non-overlap clamp. Wall dates here would recreate
    /// compressed recording gaps as empty UI.
    public static func rawSegmentFrame(
        segmentStartOffset: TimeInterval,
        segmentEndOffset: TimeInterval,
        groupStartOffset: TimeInterval,
        groupDuration: TimeInterval,
        boundsWidth: Double,
        priorFrame: TimelineRect? = nil,
        boundsY: Double = 0,
        boundsHeight: Double = appGroupHeight
    ) -> TimelineRect? {
        guard groupDuration > 0 else { return nil }
        let projectedX = floor(
            (segmentStartOffset - groupStartOffset) / groupDuration * boundsWidth
        )
        let x = max(priorFrame?.maxX ?? 0, projectedX)
        let remainingWidth = boundsWidth - x
        let projectedWidth = floor(
            (segmentEndOffset - segmentStartOffset) / groupDuration * boundsWidth
        )
        let width = max(1, min(projectedWidth, remainingWidth))
        return TimelineRect(
            x: x,
            y: boundsY,
            width: width,
            height: boundsHeight
        )
    }

    /// Inset visual/hover bar. Click hit testing uses the unpadded raw frame.
    public static func visualSegmentFrame(
        rawFrame: TimelineRect,
        segmentPadding: Double,
        barHeight: Double = appSegmentBarHeight
    ) -> TimelineRect {
        TimelineRect(
            x: min(rawFrame.maxX, rawFrame.x + segmentPadding * 0.5),
            y: rawFrame.y + (rawFrame.height - barHeight) * 0.5,
            width: max(1, rawFrame.width - segmentPadding),
            height: barHeight
        )
    }

    /// Normal-click date interpolation. The caller handles Control-click by
    /// delegating to the native collection view before invoking this function.
    public static func interpolatedClickedDate(
        clickX: Double,
        segmentStart: Date,
        segmentEnd: Date,
        rawFrame: TimelineRect
    ) -> Date {
        if rawFrame.width < 1 { return segmentStart }
        let fraction = (clickX - rawFrame.x) / rawFrame.width
        return segmentStart.addingTimeInterval(
            fraction * segmentEnd.timeIntervalSince(segmentStart)
        )
    }
}

/// Scalar geometry for application-group drawing; callers choose colors and images.
public enum TimelineDrawingStyle {
    /// Child-bar padding. Keep it independent of group height so short application
    /// switches remain visible.
    public static let segmentPadding: Double = 2
    public static let barHeight: Double = 10
    public static let cornerRadius: Double = 5
    public static let starWidth: Double = 16

    public static let normalOutlinePixelWidth: Double = 2
    public static let highlightedOutlineWidth: Double = 4
    public static let highlightedOutlineInset: Double = -2

    public static let gradientWhiteAlpha: Double = 0.20
    public static let gradientBlackAlpha: Double = 0.20
    public static let normalOutlineBlackAlpha: Double = 0.17
    public static let interiorHighlightWhiteAlpha: Double = 0.28
    public static let hoveredOutlineWhiteAlpha: Double = 0.40
    public static let selectedOutlineWhiteAlpha: Double = 0.80

    /// Separate image-square sizes for distinct drawing presentations.
    public static let largeIconSide: Double = 26
    public static let iconPresentationThreshold: Double = 22
    public static let compactIconSide: Double = 18
    public static let iconFitMultiplier: Double = 1.5

    public static func normalOutlineWidth(backingScale: Double) -> Double {
        normalOutlinePixelWidth / max(1, backingScale)
    }

    public static func highlightedFrame(
        for visibleBar: TimelineRect
    ) -> TimelineRect {
        let inset = highlightedOutlineInset
        return TimelineRect(
            x: visibleBar.x + inset,
            y: visibleBar.y + inset,
            width: visibleBar.width - 2 * inset,
            height: visibleBar.height - 2 * inset
        )
    }

    public static func iconFrame(
        in rawFrame: TimelineRect,
        iconSide: Double
    ) -> TimelineRect? {
        guard rawFrame.width > iconSide * iconFitMultiplier else { return nil }
        return centeredSquareFrame(in: rawFrame, side: iconSide)
    }

    public static func centeredSquareFrame(
        in rawFrame: TimelineRect,
        side: Double
    ) -> TimelineRect {
        TimelineRect(
            x: (rawFrame.x + rawFrame.width * 0.5 - side * 0.5).rounded(),
            y: (rawFrame.y + rawFrame.height * 0.5 - side * 0.5).rounded(),
            width: side,
            height: side
        )
    }
}

/// Geometry for the cached star marker.
public enum TimelineStarDrawingStyle {
    public static let systemSymbolName = "star.fill"
    public static let layerSide: Double = 16
    public static let inset: Double = 1
    public static let innerSide: Double = 14
    public static let orangeSRGB = (red: 1.0, green: 0.588, blue: 0.196, alpha: 1.0)
    public static let yellowDisplayP3 = (red: 1.0, green: 0.902, blue: 0.0, alpha: 1.0)

    public static func destinationRect(
        bounds: TimelineRect,
        dirtyRect: TimelineRect
    ) -> TimelineRect {
        TimelineRect(
            x: (bounds.x + bounds.width * 0.5 - layerSide * 0.5).rounded(),
            y: dirtyRect.y + dirtyRect.height - layerSide,
            width: layerSide,
            height: layerSide
        )
    }
}

/// Spacing for audio-track stripes drawn by the timeline view.
public enum TimelineAudioTrackDrawingStyle {
    public static let stripePeriod: Double = 12
    public static let stripeWidth: Double = 4
}
