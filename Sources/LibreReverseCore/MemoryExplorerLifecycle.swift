import Foundation

/// Timeline window configuration. Raw AppKit values keep the policy model
/// independent of the window framework.
public enum MemoryExplorerWindowContract {
    public static let styleMask: UInt64 = 32_768
    public static let level = 97
    public static let collectionBehavior: UInt64 = 256
    public static let activationPolicy = 1
    public static let hidesOnDeactivate = true
    public static let releasedWhenClosed = false

    public struct Display: Equatable, Sendable {
        public var frame: CGRect
        public var visibleFrame: CGRect

        public init(frame: CGRect, visibleFrame: CGRect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }

        public var topSystemInset: CGFloat {
            frame.maxY - visibleFrame.maxY
        }
    }

    public static func entranceFrame(on display: Display) -> CGRect {
        display.frame.offsetBy(dx: 0, dy: -display.topSystemInset)
    }

    public static func steadyFrame(on display: Display) -> CGRect {
        display.frame
    }
}

public struct MemoryExplorerLifecycle: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case hidden
        case orderedAtEntranceFrame
        case activeAndSearchFocused
    }

    public enum Dismissal: Equatable, Sendable {
        case escape
        case applicationDeactivated
        case screenParametersChanged
    }

    public private(set) var phase: Phase = .hidden
    public private(set) var frame: CGRect?

    public init() {}

    public mutating func orderFront(
        on display: MemoryExplorerWindowContract.Display
    ) {
        frame = MemoryExplorerWindowContract.entranceFrame(on: display)
        phase = .orderedAtEntranceFrame
    }

    public mutating func finishPresentation(
        on display: MemoryExplorerWindowContract.Display
    ) {
        frame = MemoryExplorerWindowContract.steadyFrame(on: display)
        phase = .activeAndSearchFocused
    }

    public mutating func dismiss(_ reason: Dismissal) {
        _ = reason
        phase = .hidden
    }
}
