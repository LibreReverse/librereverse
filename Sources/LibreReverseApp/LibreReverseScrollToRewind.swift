#if os(macOS)
import AppKit
import LibreReverseCore

/// Owns the two AppKit monitor tokens used by the scroll-to-open path.
/// Local events continue through normal AppKit delivery after the timeline
/// becomes key; only the global opening event is forwarded explicitly.
final class LibreReverseScrollToRewindController {
    private static var dismissedAt: TimeInterval?

    static func timelineDidDismiss() {
        dismissedAt = ProcessInfo.processInfo.systemUptime
    }

    typealias OpenHandler = (_ triggeringEvent: NSEvent, _ isGlobal: Bool) -> Void

    private let isTimelineOpen: () -> Bool
    private let openHandler: OpenHandler
    private var isPressingModifierKeys = false
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

    init(
        isTimelineOpen: @escaping () -> Bool,
        openHandler: @escaping OpenHandler
    ) {
        self.isTimelineOpen = isTimelineOpen
        self.openHandler = openHandler
    }

    var isEnabled: Bool {
        globalEventMonitor != nil || localEventMonitor != nil
    }

    func setEnabled(_ enabled: Bool) {
        stop()
        guard enabled else { return }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            self?.handle(event, isGlobal: false)
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            self?.handle(event, isGlobal: true)
        }
    }

    func stop() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        isPressingModifierKeys = false
    }

    deinit {
        stop()
    }

    private func handle(_ event: NSEvent, isGlobal: Bool) {
        guard !isTimelineOpen() else { return }
        if let last = Self.dismissedAt {
            let now = ProcessInfo.processInfo.systemUptime
            let freshGesture = event.phase.contains(.began)
            let freshWheel = event.phase.isEmpty && event.momentumPhase.isEmpty && now - last > 0.3
            guard freshGesture || freshWheel else {
                Self.dismissedAt = now
                isPressingModifierKeys = false
                return
            }
            Self.dismissedAt = nil
        }
        let flags = event.modifierFlags
        let decision = ScrollToRewindInvocation.decision(
            previousIsPressingModifierKeys: isPressingModifierKeys,
            event: ScrollToRewindEvent(
                scrollingDeltaX: event.scrollingDeltaX,
                scrollingDeltaY: event.scrollingDeltaY,
                phaseRawValue: event.phase.rawValue,
                momentumPhaseRawValue: event.momentumPhase.rawValue,
                modifiers: ScrollToRewindModifiers(
                    command: flags.contains(.command),
                    option: flags.contains(.option),
                    shift: flags.contains(.shift)
                )
            )
        )
        isPressingModifierKeys = decision.isPressingModifierKeys
        guard decision.shouldOpen else { return }
        openHandler(event, isGlobal)
    }
}
#endif
