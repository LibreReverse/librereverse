import Foundation

/// Measured screen-space geometry for the current Memory Explorer overlay.
/// Coordinates use an AppKit-style bottom-left origin and logical points.
public enum MemoryExplorerVisualShell {
    public static let expandedSearchSize = CGSize(width: 500, height: 114)

    public static let bottomOverlayHeight: CGFloat = 116
    public static let gradientHeight: CGFloat = 0
    public static let gradientMaximumBlackAlpha: CGFloat = 0

    public static let transportHeight: CGFloat = 80
    public static let transportBottom: CGFloat = 24
    public static let transportSideInset: CGFloat = 32
    public static let timelineBarHeight: CGFloat = 1.5
    public static let timelineDotPitch: CGFloat = 4
    public static let activityDotSize = CGSize(width: 1.1, height: 2.5)
    public static let timelineCenterFromBottom: CGFloat = 52
    public static let timelineShellHeight: CGFloat = 70
    public static let timelineShellBottom: CGFloat = 24

    public static let playheadWidth: CGFloat = 1
    public static let playheadHeight: CGFloat = 32
    public static let momentChipMinimumWidth: CGFloat = 158
    public static let momentChipHeight: CGFloat = 60
    public static let momentChipBottom: CGFloat = 34
    public static let playheadFontSize: CGFloat = 16
    public static let playheadTimeSpacing: CGFloat = 6
    public static let playheadArrowSize = CGSize(width: 6, height: 6)
    public static let selectedPlayheadOpacity: CGFloat = 1
    public static let unselectedPlayheadOpacity: CGFloat = 1
    public static let darkPlayheadTrackOpacity: CGFloat = 0.75
    public static let lightPlayheadTrackOpacity: CGFloat = 0.75

    public static let zoomDiameter: CGFloat = 28
    public static let overflowDiameter: CGFloat = 28
    public static let controlStackGap: CGFloat = 3
    public static let trailingControlBottom: CGFloat = transportBottom + (transportHeight - 2 * zoomDiameter - controlStackGap) / 2
    public static let overflowRightInset: CGFloat = 50
    public static let trailingControlGap: CGFloat = 4

    public static func transportFrame(viewportWidth: CGFloat) -> CGRect {
        CGRect(x: transportSideInset, y: transportBottom,
            width: max(0, viewportWidth - 2 * transportSideInset), height: transportHeight)
    }

    public static func expandedSearchFrame(in viewport: CGSize) -> CGRect {
        CGRect(
            x: (viewport.width - expandedSearchSize.width) * 0.5,
            y: (viewport.height - expandedSearchSize.height) * 0.5,
            width: expandedSearchSize.width,
            height: expandedSearchSize.height
        )
    }

    public static func playheadFrame(viewportWidth: CGFloat) -> CGRect {
        let belt = timelineShellFrame(viewportWidth: viewportWidth)
        return CGRect(x: belt.midX - playheadWidth * 0.5,
            y: timelineCenterFromBottom - playheadHeight * 0.5,
            width: playheadWidth, height: playheadHeight)
    }

    public static func timelineShellFrame(viewportWidth: CGFloat) -> CGRect {
        CGRect(x: transportSideInset + 238, y: timelineShellBottom,
            width: max(1, viewportWidth - transportSideInset - 238 - 112), height: timelineShellHeight)
    }

    public static func momentChipFrame(
        viewportWidth: CGFloat,
        contentWidth: CGFloat = momentChipMinimumWidth
    ) -> CGRect {
        CGRect(x: transportSideInset + 16, y: momentChipBottom,
            width: momentChipMinimumWidth, height: momentChipHeight)
    }

    public static func zoomFrame(viewportWidth: CGFloat) -> CGRect {
        let readout = momentChipFrame(viewportWidth: viewportWidth)
        return CGRect(x: readout.maxX + 22, y: trailingControlBottom,
            width: zoomDiameter, height: zoomDiameter)
    }

    public static func overflowFrame(viewportWidth: CGFloat) -> CGRect {
        CGRect(x: viewportWidth - overflowRightInset - overflowDiameter,
            y: trailingControlBottom, width: overflowDiameter, height: overflowDiameter)
    }

    public static func zoomInFrame(viewportWidth: CGFloat) -> CGRect {
        zoomFrame(viewportWidth: viewportWidth).offsetBy(dx: 0, dy: zoomDiameter + controlStackGap)
    }

    public static func searchFrame(viewportWidth: CGFloat) -> CGRect {
        overflowFrame(viewportWidth: viewportWidth).offsetBy(dx: 0, dy: zoomDiameter + controlStackGap)
    }

    public static func moduleDividers(viewportWidth: CGFloat) -> [CGRect] {
        [momentChipFrame(viewportWidth: viewportWidth).maxX + 16,
         timelineShellFrame(viewportWidth: viewportWidth).maxX + 16].map {
            CGRect(x: $0, y: transportBottom + 16, width: 0.5, height: transportHeight - 32)
         }
    }

}

/// Search has only two shell presentations: the centered input surface and the
/// minimized bottom-left affordance shown after the user starts scrubbing.
public enum MemoryExplorerSearchPresentation: Equatable, Sendable {
    case expanded
    case collapsed

    public enum Event: Sendable {
        case explorerPresented
        case timelineScrubbed
        case collapsedSearchActivated
    }

    public mutating func apply(_ event: Event) {
        switch event {
        case .explorerPresented, .collapsedSearchActivated:
            self = .expanded
        case .timelineScrubbed:
            self = .collapsed
        }
    }
}

/// The exact branch result produced upstream of the playhead's visible string.
/// Keeping this decision separate from Foundation formatters makes the signed
/// threshold behavior deterministic and directly testable.
public enum PlayheadTimePresentation: Equatable, Sendable {
    case empty
    case now
    case absolute(Date)
    case relative(Date, relativeTo: Date)
}

public enum PlayheadTimeText {
    public static let nowThreshold: TimeInterval = 3
    public static let absoluteThreshold: TimeInterval = 3_600
    public static let absoluteDateFormat = "MMM d h:mm a"

    public static func presentation(
        for seekDate: Date?,
        relativeTo now: Date
    ) -> PlayheadTimePresentation {
        guard let seekDate else { return .empty }
        let distanceToNow = seekDate.distance(to: now)
        if abs(distanceToNow) < nowThreshold {
            return .now
        }
        if distanceToNow > absoluteThreshold {
            return .absolute(seekDate)
        }
        return .relative(seekDate, relativeTo: now)
    }
}

/// Scalar and label-layout contract for the timeline zoom control.
public enum TimelineZoomControlContract {
    public static let expandedMaximumWidth: CGFloat = 200
    public static let symbolSize: CGFloat = 16
    public static let minimumLeadingPadding: CGFloat = 2
    public static let minimumTrailingPadding: CGFloat = 6
    public static let maximumLeadingPadding: CGFloat = 6
    public static let maximumTrailingPadding: CGFloat = 2
    public static let springResponse: Double = 0.5
    public static let springDampingFraction: Double = 1
    public static let springBlendDuration: Double = 0
    public static let animationSpeed: Double = 2
    public static let dismissalDelay: TimeInterval = 5
}
