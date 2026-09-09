#if os(macOS)
import AppKit
import AVFoundation
import AVKit
import CoreGraphics
import Combine
import Darwin
import Foundation
import LibreReverseCore
import ServiceManagement
import UniformTypeIdentifiers
@preconcurrency import UserNotifications
import VideoToolbox

/// Centers the complete search card while its result height changes. The
/// header-only presentation uses its own center constraint instead.
@MainActor
enum LibreReverseSearchCompositionLayout {
    static func centeredResultsConstraint(
        overlay: NSView, results: NSView, in content: NSView
    ) -> NSLayoutConstraint {
        let composition = NSLayoutGuide()
        content.addLayoutGuide(composition)
        NSLayoutConstraint.activate([
            composition.topAnchor.constraint(equalTo: overlay.topAnchor),
            composition.bottomAnchor.constraint(equalTo: results.bottomAnchor),
            composition.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            composition.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
        ])
        return composition.centerYAnchor.constraint(equalTo: content.centerYAnchor)
    }
}

struct LibreReverseTimelineActionsFixtureSeed {
  let start: Date
  let end: Date
  let requestedDate: Date
  let frameID: Int64
  let segmentID: Int64
  let videoID: Int64
  let mediaURL: URL
}

@MainActor
private final class LibreReverseTimelineWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var shouldScrollTimeline: ((NSEvent) -> Bool)?
    /// Left/Right arrow: step exactly one stored frame. Diagnostic navigation.
    var onFrameStep: ((Bool) -> Void)?
    /// Space: toggle real-time playback.
    var onTogglePlayback: (() -> Void)?
    /// Return to the live edge with a keyboard shortcut.
    var onJumpToEnd: (() -> Void)?

    /// Scrubbing collapses search to a corner pill to uncover the frame.
    /// The search shortcut reopens the card as an alternative to clicking the pill.
    var onReopenSearch: (() -> Void)?
    /// In-window Command-Shift-C action.
    var onCopyMoment: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            onEscape?()
            return
        }
        // Text editing owns character input and caret navigation. In particular,
        // a space in a query must never toggle the timeline playback timer.
        if event.type == .keyDown, let editor = firstResponder as? NSTextView, editor.isEditable {
            if handleEditingCommand(event, editor: editor) { return }
            super.sendEvent(event)
            return
        }
        // Return to Now from the viewer when no text field is being edited.
        if event.type == .keyDown,
           event.keyCode == 119
            || (event.keyCode == 124 && event.modifierFlags.contains(.command))
            || (event.charactersIgnoringModifiers == "]" && event.modifierFlags.intersection([.command, .control, .option]).isEmpty) {
            onJumpToEnd?()
            return
        }
        // 123 = Left arrow, 124 = Right arrow.
        if event.type == .keyDown, event.keyCode == 123 || event.keyCode == 124 {
            onFrameStep?(event.keyCode == 124)
            return
        }
        // 3 = F. Command-F reopens the collapsed search.
        if event.type == .keyDown, event.keyCode == 3,
        event.modifierFlags.contains(.command)
      {
            onReopenSearch?()
            return
        }
        // 8 = C. The bundled shortcut guide documents Command-Shift-C as
        // “Copy current screen to your clipboard” while Explorer is open.
        if event.type == .keyDown, event.keyCode == 8,
          event.modifierFlags.contains([.command, .shift])
        {
          onCopyMoment?()
          return
        }
        // 49 = Space (unmodified; the global open shortcut carries modifiers).
        if event.type == .keyDown, event.keyCode == 49,
           !event.modifierFlags.contains(.command),
        !event.modifierFlags.contains(.shift)
      {
            onTogglePlayback?()
            return
        }
        if event.type == .scrollWheel, shouldScrollTimeline?(event) != false {
            onScroll?(event)
            return
        }
        super.sendEvent(event)
    }

    private func handleEditingCommand(_ event: NSEvent, editor: NSTextView) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), flags.intersection([.control, .option]).isEmpty,
            let character = event.charactersIgnoringModifiers?.lowercased(),
            !flags.contains(.shift) || character == "z" else { return false }
        // This accessory app has no Edit menu to dispatch standard key equivalents.
        // Send them to the current native editor, preserving its selection and undo.
        if character == "c" || character == "x" {
            func ownsSecureEditor(_ view: NSView) -> Bool {
                if let field = view as? NSSecureTextField, field.currentEditor() === editor { return true }
                return view.subviews.contains(where: ownsSecureEditor)
            }
            if let contentView, ownsSecureEditor(contentView) { return false }
        }
        switch character {
        case "a": editor.selectAll(nil)
        case "c": editor.copy(nil)
        case "x": editor.cut(nil)
        case "v": editor.paste(nil)
        case "z":
            if flags.contains(.shift) {
                if editor.undoManager?.canRedo == true { editor.undoManager?.redo() }
            } else if editor.undoManager?.canUndo == true { editor.undoManager?.undo() }
        default: return false
        }
        return true
    }
}

@MainActor
private final class LibreReverseAppGroupTableView: NSTableView {
    var appGroups: [AppSegmentGroup] = []
    var onSegmentClick: ((Date, Int64) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard appGroups.indices.contains(row), bounds.width > 0 else {
            super.mouseDown(with: event)
            return
        }
        let group = appGroups[row]
        let rowRect = rect(ofRow: row)
        let clickX = point.x - rowRect.minX
        var prior: TimelineRect?
        guard let groupStartOffset = group.segments.first?.contiguousStartOffset,
              let groupEndOffset = group.segments.last?.contiguousEndOffset
        else {
            super.mouseDown(with: event)
            return
        }
        for segment in group.segments {
            guard let segmentStartOffset = segment.contiguousStartOffset,
          let segmentEndOffset = segment.contiguousEndOffset
        else { continue }
        guard
          let rawFrame = TimelineLayout.rawSegmentFrame(
                segmentStartOffset: segmentStartOffset,
                segmentEndOffset: segmentEndOffset,
                groupStartOffset: groupStartOffset,
                groupDuration: groupEndOffset - groupStartOffset,
                boundsWidth: rowRect.width,
                priorFrame: prior
          )
        else { continue }
            prior = rawFrame
            if clickX >= rawFrame.x, clickX < rawFrame.maxX {
                let date = TimelineLayout.interpolatedClickedDate(
                    clickX: clickX,
                    segmentStart: segment.startDate,
                    segmentEnd: segment.endDate,
                    rawFrame: rawFrame
                )
                onSegmentClick?(date, segment.rawID)
                return
            }
        }
        super.mouseDown(with: event)
    }
}

#if DEBUG
@MainActor
func probeTimelineNavigationKeys() -> [String] {
    let window = LibreReverseTimelineWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    var actions: [String] = []
    window.onEscape = { actions.append("exit") }
    window.onJumpToEnd = { actions.append("now") }
    window.onFrameStep = { _ in actions.append("frame") }
    for (code, text, modifiers): (UInt16, String, NSEvent.ModifierFlags) in [
        (53, "\u{1b}", []), (30, "]", []), (124, "", [.command])
    ] {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) {
            window.sendEvent(event)
        }
    }
    return actions
}

@MainActor
func probeTimelineSearchEditingKeys() -> (timelineActions: [String], editingKeys: [UInt16]) {
    final class Editor: NSTextView {
        var received: [UInt16] = []
        override func keyDown(with event: NSEvent) { received.append(event.keyCode) }
    }
    let window = LibreReverseTimelineWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
        styleMask: [], backing: .buffered, defer: false)
    let editor = Editor(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
    window.contentView?.addSubview(editor)
    window.makeFirstResponder(editor)
    var actions: [String] = []
    window.onJumpToEnd = { actions.append("now") }
    window.onFrameStep = { _ in actions.append("frame") }
    window.onTogglePlayback = { actions.append("play") }
    for (code, text, flags): (UInt16, String, NSEvent.ModifierFlags) in [
        (49, " ", []), (123, "", []), (124, "", []), (30, "]", []), (124, "", [.command])
    ] {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) {
            window.sendEvent(event)
        }
    }
    return (actions, editor.received)
}

@MainActor
func probeTimelineEditingCommands() -> (selection: NSRange, replacement: String, undone: String, redone: String, clipboardActions: [String]) {
    final class Editor: NSTextView {
        var clipboardActions: [String] = []
        override func copy(_ sender: Any?) { clipboardActions.append("copy") }
        override func cut(_ sender: Any?) { clipboardActions.append("cut") }
        override func paste(_ sender: Any?) { clipboardActions.append("paste") }
    }
    let window = LibreReverseTimelineWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
        styleMask: [], backing: .buffered, defer: false)
    let editor = Editor(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
    editor.allowsUndo = true
    window.contentView?.addSubview(editor)
    window.makeFirstResponder(editor)
    editor.string = "Launch"
    editor.setSelectedRange(NSRange(location: 6, length: 0))
    func send(_ character: String, code: UInt16, shift: Bool = false) {
        let flags: NSEvent.ModifierFlags = shift ? [.command, .shift] : [.command]
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        window.sendEvent(event)
    }
    send("a", code: 0)
    let selection = editor.selectedRange()
    editor.insertText("Project schedule", replacementRange: selection)
    editor.breakUndoCoalescing()
    let replacement = editor.string
    send("z", code: 6)
    let undone = editor.string
    send("z", code: 6, shift: true)
    let redone = editor.string
    send("c", code: 8); send("x", code: 7); send("v", code: 9)
    return (selection, replacement, undone, redone, editor.clipboardActions)
}

@MainActor
func probeScrollFromFreshLiveFrame(window: HistoricalTimelineSegmentWindow) -> Bool {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let controller = LibreReverseTimelineWindowController(dataDirectory: root,
        libraryConfiguration: .init(databaseURL: root.appendingPathComponent("library.sqlite3"),
            keyFileURL: root.appendingPathComponent("key"), mediaRoot: root),
        transcriptionQueue: .init(root: root), allowsLibraryMutations: false)
    return controller.probeScrollFromFreshLiveFrame(window: window)
}

@MainActor
func probeHistoryBelt(window: HistoricalTimelineSegmentWindow) -> [Double] {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let controller = LibreReverseTimelineWindowController(dataDirectory: root,
        libraryConfiguration: .init(databaseURL: root.appendingPathComponent("library.sqlite3"),
            keyFileURL: root.appendingPathComponent("key"), mediaRoot: root),
        transcriptionQueue: .init(root: root), allowsLibraryMutations: false)
    return controller.probeHistoryBelt(window: window)
}

@MainActor
func probeShortcutPlaybackScale(window: HistoricalTimelineSegmentWindow) -> [Bool] {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let controller = LibreReverseTimelineWindowController(dataDirectory: root,
        libraryConfiguration: .init(databaseURL: root.appendingPathComponent("library.sqlite3"),
            keyFileURL: root.appendingPathComponent("key"), mediaRoot: root),
        transcriptionQueue: .init(root: root), allowsLibraryMutations: false)
    return controller.probeShortcutPlaybackScale(window: window)
}
#endif

@MainActor
final class LibreReverseTimelineWindowController: NSWindowController,
    NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate {
    private enum SeekIntent { case live, historical }
    private let libraryDatabase: LibraryDatabaseConfiguration
    private let libraryConfiguration: LibreReverseLibraryConfiguration
    private let transcriptionQueue: LibreReverseMeetingTranscriptionQueue
    private let playerCache: LibreReversePlayerCache
    private let mutationLifetime: LibreReverseUIMutationLifetime
    private var mutationAdmissionClosed = false
    private var playerLeases: [URL: LibreReverseMediaLease] = [:]
    // Share key derivation across LRU lease changes, including release on eviction.
    private lazy var playerLeaseSession = LibreReverseLibraryWriteSession(
        configuration: libraryConfiguration
    )
    private var primaryReplacementDepth = 0
    private var primaryReplacementGeneration: UInt64 = 0
    private let playerView = LibreReversePlayerLayerView()
    private let searchMatchOverlay = LibreReverseSearchMatchOverlay(frame: .zero)
    private let liveTextOverlay = LibreReverseLiveTextOverlay(frame: .zero)
    private let meetingRecordingView = LibreReverseMeetingRecordingView(frame: .zero)
    private let meetingTranscriptView = LibreReverseMeetingTranscriptView(frame: .zero)
    // Keep the movable card above the native text-selection action as well as the rail.
    private let transcriptControlClearance: CGFloat = 52
    private var transcriptTrailingConstraint: NSLayoutConstraint!
    private var transcriptBottomConstraint: NSLayoutConstraint!
    private var pinnedTranscriptWindow: LibreReversePinnedTranscriptWindowController?
    private var pendingPinnedPlaybackSegmentID: Int64?
    private var playbackFixtureStatusURL: URL?
    private var playbackFixtureMediaURL: URL?
    private var playbackFixtureRemoteOnly = false
    private var playbackFixtureDidStart = false
    private let meetingStopHandler: (() -> Void)?
    private let meetingRenameHandler: (() -> Void)?
    private let meetingTitleUpdateHandler: ((Int64, String) async throws -> String?)?
    private let meetingContextUpdateHandler:
        ((Int64, [String], String?) async throws -> LibreReverseMeetingContextUpdate)?
    private let meetingDeletionHandler: ((Int64) async throws -> Void)?
    private let meetingTranscriptionRetryHandler: ((Int64) throws -> Void)?
    private let screenCaptureIsPaused: (() -> Bool)?
    private let screenCaptureToggleHandler: (() -> Void)?
    private let openSettingsHandler: (() -> Void)?
    private let openStorageSettingsHandler: (() -> Void)?
    private var archiveRequestTask: Task<Void, Never>?
    private let allowsLibraryMutations: Bool
    private struct LibrarySearchValidation {
      let query: String
      let facet: String
      let statusURL: URL?
      let selectsFirstResult: Bool
      var requestedNextPage = false
      var firstPageCount: Int?
      var restoredDriveShardOrdinal: Int64?
      var restoredDriveShardBytes: Int64?
      var driveRestoreMilliseconds: Double?
      var initialCursor: SearchRecencyCursor?
      var restoredDriveShardInterval: DateInterval?
    }
    private var librarySearchValidation: LibrarySearchValidation?
    private var librarySearchValidationInventory: HistoricalSearchValidationInventory?
    /// The player currently presented, so pause and teardown do not need
    /// to walk the cache.
    private var presentedPlayer: AVPlayer?
    private var presentedPlayerItem: AVPlayerItem?
    private var presentedPlayerFallbackImage: NSImage?
    private var playbackItemObservers: [NSObjectProtocol] = []
    private var playbackItemGeneration: UInt64 = 0
    /// View-side ownership published by the controller's canonical `onReady`
    /// callback after each successful changed-URL transaction.
    private var presentedVideoOutput: AVPlayerItemVideoOutput?
    private var presentedMoment: HistoricalTimelineMoment?
    private var latestLiveFrameImage: NSImage?
    private var timelineActionFeedbackTask: Task<Void, Never>?
    private var starMutationTask: Task<Void, Never>?
    private let timelineActionsFixtureStatusURL = LibreReverseDevelopmentEnvironment.values[
      "LIBREREVERSE_TIMELINE_ACTIONS_UI_FIXTURE_STATUS"
    ].map(URL.init(fileURLWithPath:))
    private var pendingTimelineActionsFixtureDeepLink: Date?
    /// The single in-flight player presentation task.
    private var presentationTask: Task<Void, Never>?
    /// Reuse the keyed connection so each seek avoids SQLCipher key derivation.
    private lazy var librarySession = LibraryDatabaseSession(
        configuration: libraryDatabase
    )
    private let persistedMediaLoader: LibreReversePersistedMediaLoader
    private var shardResolver: LibreReverseShardResolver?
    private let archiveDownloads: LibreReverseArchiveDownloadCoordinator?
    private var archiveStatusGeneration: UInt64 = 0
    private var archiveDownloadSnapshots: [String: LibreReverseDownloadStatus] = [:]
    private var archiveHoursWithoutDownloads: Set<Date> = []
    private var archiveResolutionPendingDate: Date?
    /// Bounds and scroll work maintain independent leading-edge dates.
    private var boundsSeekThrottle = TimelineSeekThrottle()
    private var scrollSeekThrottle = TimelineSeekThrottle()
    private var settledScrollTask: Task<Void, Never>?
    private let liveImageView = NSImageView()
    private let tableView = LibreReverseAppGroupTableView()
    private let dateLabel = NSTextField(labelWithString: "Loading timeline…")
    private let archivePlaceholder = LibreReverseArchiveDownloadView()
    private var archivePlaceholderTitle: NSTextField { archivePlaceholder.titleLabel }
    private var archivePlaceholderDetail: NSTextField { archivePlaceholder.detailLabel }
    private var archiveDownloadButton: NSButton { archivePlaceholder.downloadButton }
    private var pendingArchivedMoment: HistoricalTimelineMoment?
    private var pendingArchivedShard: (date: Date, ordinal: Int64)?
    private var unavailableShards: [HistoricalUnavailableShard] = []
    private var archiveConnectionAvailableForValidation = false
    private var archiveConnectionNeedsReconnect = false
    private let timelineSlider = NSSlider(
      value: 0, minValue: 0, maxValue: 0, target: nil, action: nil)
    private let previousButton = NSButton(title: "Previous", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private var jumpToDatePopover: NSPopover?
    private var jumpToDateView: LibreReverseJumpToDateView?
    private var jumpToDateState: JumpToDateState?
    private var jumpValidDaysTask: Task<Void, Never>?
    private var jumpValidHoursTask: Task<Void, Never>?
    private var snapshot = LibreReverseTimelineSnapshot(rawSegments: [])
    private var allStarredDates: [Date] = []
    private let starRefreshSubject = PassthroughSubject<Void, Never>()
    private var starRefreshCancellable: AnyCancellable?
    private var loadedRawSegments: [TimelineSegment] = []
    private var loadedGlobalSeekInterval: DateInterval? {
        didSet { timelineOverlay.latestCapturedDate = loadedGlobalSeekInterval?.end }
    }
    private var lastFetchedWindowDuration: TimeInterval = 0
    private var lastFetchedWindowDate: Date?
    private var lastFastScrollEvent: TimelineFastScrollEvent?
    private var timelineZoomLevel = TimelineLayout.defaultZoomLevel
    private lazy var timelineOverlay = LibreReverseTimelineOverlayView(
        snapshot: snapshot,
        currentDate: nil,
        zoomLevel: timelineZoomLevel
    )
    private var waveformPresentedMediaURL: URL?
    private lazy var timelineWaveforms = LibreReverseTimelineWaveforms { [weak self] segment in
        guard let self else { return nil }
        if self.playbackFixtureMediaURL != nil {
            return self.presentedMoment?.segmentID == segment.rawID ? self.presentedMoment : nil
        }
        return try? await self.librarySession.meetingMoment(segmentID: segment.rawID, at: segment.startDate)
    }
    var onAskQuestion: ((String) -> Void)?
    private let searchOverlay = LibreReverseSearchOverlayView()
    private let searchResultsView = LibreReverseSearchResultsView()
    private let collapsedSearchButton = NSButton(title: "Search", target: nil, action: nil)
    private var explorerSearch = ExplorerSearchState()
    private var searchTask: Task<Void, Never>?
    private var displayedSearchState: LibreReverseSearchOverlayState?
    private var searchConfirmationRevision: UInt64?
    private var activeSearchState: LibreReverseSearchOverlayState?
    private var searchResults: [OCRSearchResult] = []
    private var transcriptSearchResults: [TranscriptSearchResult] = []
    private var searchCursor: SearchRecencyCursor?
    private var searchHasMore = false
    private var searchOffsetsByDocument: [Int64: String] = [:]
    private var searchCountsTask: Task<Void, Never>?
    private struct ActiveSearchMatch {
        let frameID: Int64
        let documentID: Int64
        let offsetString: String
        let primaryText: String
        let otherText: String
        var matchingNodes: [OCRNode]
    }
    private var activeSearchMatch: ActiveSearchMatch?
    private var activeMeetingSegmentID: Int64?
    private var searchOverlayCenterConstraint: NSLayoutConstraint!
    private var searchCompositionCenterConstraint: NSLayoutConstraint!
    private var searchHorizontalCenterConstraint: NSLayoutConstraint!
    private var currentSeekDate: Date?
    /// Explicit live-desktop ownership. Pin on a live request or forward end clamp
    /// and unpin on backward navigation. Comparing against a moving recording
    /// timestamp would alternate live and historical surfaces near the boundary.
    private var isAtLiveEdge = true {
        didSet {
            timelineOverlay.isPinnedToEnd = isAtLiveEdge
        }
    }
    /// Cache admission at gesture start and reuse it for later samples, including
    /// momentum. Phaseless mouse-wheel events are admitted individually.
    private var scrollGestureAdmitted = true
    /// Once one physical gesture reaches the live clamp, its remaining
    /// `.changed` samples and momentum tail cannot undo that transition.
    /// Trackpads routinely report a one-unit opposite-axis wobble immediately
    /// before `.ended`; ignore that wobble after pinning live.
    /// A new `.began` sample clears this latch,
    /// so a deliberate new backward gesture still leaves live immediately.
    private var liveGestureLatch = LibreReverseTimelineLiveGestureLatch()
    private var endScrollPolicy = TimelineEndScrollPolicy()
    private var scrollNavigationRevision: UInt64 = 0
    private var seekSourceReducer = SeekSourceReducer()
    /// Authoritative scroll accumulator. Nil until seeded, and cleared by
    /// any non-scroll seek.
    private var accumulatedScrollOffset: TimeInterval?
    /// Last presentation written to the view tree. Equality prevents redundant
    /// image/player mutations when the mode and hidden state have not changed.
    private var appliedPresentation: FrameDetailPresentation?
    /// Retain the last decoded image between moments. Loading holds the
    /// existing surface until a replacement is ready, preventing blank frames.
    private let frameImageRetention = FrameDetailImageRetention<NSImage>()
    private var realTimePlaybackTimer: DispatchSourceTimer?
    private var realTimePlaybackClock: LibreReverseWallClockPlaybackClock?
    private var historyPlaybackStep: LibreReverseHistoryPlaybackStep?
    private var historyBeltClock: LibreReverseWallClockPlaybackClock?
    private var historyBeltFrame: Date?
    private var playbackTimelinePresentation: PlaybackTimelinePresentation?
    private var playbackTimelineRefresh: Task<Void, Never>?
    private var pendingVisualScroll: Double = 0
    private var visualScrollTask: Task<Void, Never>?
    private var visualScrollLastMediaTime: TimeInterval = 0
    private var playbackTranscriptThrottle = TimelineSeekThrottle()
    private var playbackBoundaryTask: Task<Void, Never>?
    /// Readiness belongs to the currently selected moment, not merely to a
    /// retained AVPlayer. Without this bit, Space could start the timer and a
    /// stale player while an archived meeting was still remote-only.
    private var playbackReadiness = LibreReverseMeetingPlaybackReadiness()
    private var surfaceSampler: DispatchSourceTimer?
    /// Observe scrolling for the visible explorer’s lifetime. A transparent
    /// accessory window can remain visible while another app is foreground,
    /// so local window events alone cannot cover all interactions.
    private var visibleTimelineGlobalScrollMonitor: Any?
    private var initialReloadTask: Task<Void, Never>?
    private var windowReplacementTask: Task<Void, Never>?
    private var stationaryRefreshTask: Task<Void, Never>?
    private var meetingTranscriptSettleTask: Task<Void, Never>?
    private var meetingTranscriptLoadTask: Task<Void, Never>?
    private var meetingTranscriptRevision: UInt64 = 0
    private var meetingTranscriptIsScrubbing = false
    private var retainedCompleteTranscriptID: Int64?
    private var lastMeetingTranscriptRequest: (segmentID: Int64, cursorDate: Date)?
    private var windowPublicationGeneration: UInt64 = 0
    private var recordingPublicationRevision: UInt64 = 0
    private var recentRecordingPublications: [RecordingSegmentPublication] = []
    private var seekTask: Task<Void, Never>?
    // Each media transaction is cancellable and guarded by a generation.
    // Wheel and drag input share the final-position resolution contract.
    private var presentationGeneration: UInt64 = 0
    /// Identity of whatever is currently in `liveImageView`, for flicker tracing.
    private var liveImageSourceTag = "none"
    private var surfaceSequence = 0

    /// Logs the actual visible surface after any mutation that can change pixels.
    private func traceSurface(_ site: String) {
        guard LibreReverseTimelineTrace.isEnabled else { return }
        surfaceSequence += 1
        let sequence = surfaceSequence
        let liveHidden = liveImageView.isHidden
        let playerHidden = playerView.isHidden
        let source = liveImageSourceTag
        let pinned = isAtLiveEdge
        let seek = currentSeekDate.map { String(describing: $0) } ?? "nil"
        let imageSize = liveImageView.image?.size ?? .zero
        let viewSize = liveImageView.frame.size
        var line = "SURFACE #\(sequence) at=\(site)"
        line += " playerHosts=\(playerView.subviews.count)"
        line += " img=\(Int(imageSize.width))x\(Int(imageSize.height))"
        line += " view=\(Int(viewSize.width))x\(Int(viewSize.height))"
        line += " alpha=\(liveImageView.alphaValue)"
        line += " liveHidden=\(liveHidden)"
        line += " playerHidden=\(playerHidden)"
        line += " imageSource=\(source)"
        line += " pinned=\(pinned)"
        line += " seek=\(seek)"
        LibreReverseTimelineTrace.log(line)
    }

    private func renderDiagnostic(_ message: String) {
        LibreReverseTimelineTrace.log("render \(message)")
    }

    init(
        dataDirectory: URL,
        libraryConfiguration: LibreReverseLibraryConfiguration,
      transcriptionQueue: LibreReverseMeetingTranscriptionQueue,
        mediaResolver: (any LocalMediaResolving)? = nil,
      shardResolver: LibreReverseShardResolver? = nil,
      archiveDownloads: LibreReverseArchiveDownloadCoordinator? = nil,
      meetingStopHandler: (() -> Void)? = nil,
      meetingRenameHandler: (() -> Void)? = nil,
      meetingTitleUpdateHandler: ((Int64, String) async throws -> String?)? = nil,
      meetingContextUpdateHandler:
        ((Int64, [String], String?) async throws -> LibreReverseMeetingContextUpdate)? = nil,
      meetingDeletionHandler: ((Int64) async throws -> Void)? = nil,
      meetingTranscriptionRetryHandler: ((Int64) throws -> Void)? = nil,
      screenCaptureIsPaused: (() -> Bool)? = nil,
      screenCaptureToggleHandler: (() -> Void)? = nil,
      openSettingsHandler: (() -> Void)? = nil,
      allowsLibraryMutations: Bool = true,
      playerCache: LibreReversePlayerCache? = nil,
      mutationLifetime: LibreReverseUIMutationLifetime? = nil,
      openStorageSettingsHandler: (() -> Void)? = nil
    ) {
        self.playerCache = playerCache ?? LibreReversePlayerCache()
        self.mutationLifetime = mutationLifetime ?? LibreReverseUIMutationLifetime()
        self.libraryConfiguration = libraryConfiguration
      self.transcriptionQueue = transcriptionQueue
        self.persistedMediaLoader = LibreReversePersistedMediaLoader(resolver: mediaResolver)
        self.shardResolver = shardResolver
        self.archiveDownloads = archiveDownloads
      self.meetingStopHandler = meetingStopHandler
      self.meetingRenameHandler = meetingRenameHandler
      self.meetingTitleUpdateHandler = meetingTitleUpdateHandler
      self.meetingContextUpdateHandler = meetingContextUpdateHandler
      self.meetingDeletionHandler = meetingDeletionHandler
      self.meetingTranscriptionRetryHandler = meetingTranscriptionRetryHandler
      self.screenCaptureIsPaused = screenCaptureIsPaused
      self.screenCaptureToggleHandler = screenCaptureToggleHandler
      self.openSettingsHandler = openSettingsHandler
      self.openStorageSettingsHandler = openStorageSettingsHandler ?? openSettingsHandler
      self.allowsLibraryMutations = allowsLibraryMutations
        self.libraryDatabase = LibraryDatabaseConfiguration(
            databaseURL: libraryConfiguration.databaseURL,
            keyFileURL: libraryConfiguration.keyFileURL,
            mediaRoot: libraryConfiguration.mediaRoot,
            frameImagesRoot: libraryConfiguration.frameImagesRoot
        )
        let window = LibreReverseTimelineWindow(
            contentRect: .zero,
            styleMask: [.fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "LibreReverse"
        window.level = NSWindow.Level(rawValue: MemoryExplorerWindowContract.level)
        window.collectionBehavior = [.moveToActiveSpace]
        window.animationBehavior = .default
        window.hidesOnDeactivate = MemoryExplorerWindowContract.hidesOnDeactivate
        window.isReleasedWhenClosed = MemoryExplorerWindowContract.releasedWhenClosed
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.alphaValue = 1
        window.sharingType = .readOnly
        super.init(window: window)
        self.playerCache.onEvict = { [weak self] url in
            self?.playerLeases.removeValue(forKey: url)?.release()
        }
        window.onEscape = { [weak self] in
            guard let self else { return }
            if self.explorerSearch.expanded { self.resetExplorerSearch(.hide) }
            else { self.dismiss() }
        }
        window.onFrameStep = { [weak self] forward in
            _ = self?.stepOneFrame(forward: forward)
        }
        window.onTogglePlayback = { [weak self] in
        guard let self else { return }
        if !self.meetingTranscriptView.handlePlaybackShortcut() {
          self.toggleRealTimePlayback()
        }
        }
        window.onJumpToEnd = { [weak self] in
            self?.jumpToLiveEdge()
        }
        window.onReopenSearch = { [weak self] in
            self?.restoreExpandedSearch()
        }
        window.onCopyMoment = { [weak self] in
            self?.copyCurrentMomentImage()
        }
        if LibreReverseTimelineTrace.isEnabled {
            let sampler = DispatchSource.makeTimerSource(queue: .main)
            sampler.schedule(deadline: .now() + 0.1, repeating: 0.1)
            sampler.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.traceSurface("sample") }
            }
            surfaceSampler = sampler
            sampler.resume()
        }
        window.shouldScrollTimeline = { [weak self] event in
            guard let self, let content = self.window?.contentView else { return true }
            let point = content.convert(event.locationInWindow, from: nil)
            for view in [self.searchOverlay, self.searchResultsView, self.meetingTranscriptView] {
                if !view.isHidden, view.convert(view.bounds, to: content).contains(point) { return false }
            }
            return true
        }
        window.onScroll = { [weak self] event in
            self?.applyScroll(event, source: .localScroll)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        buildContent()
      starRefreshCancellable =
        starRefreshSubject
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                self?.refreshStarredFrames()
            }
    }

    func setMediaResolver(_ resolver: (any LocalMediaResolving)?) {
        Task { await persistedMediaLoader.setResolver(resolver) }
    }

    func setShardResolver(_ resolver: LibreReverseShardResolver?) {
        shardResolver = resolver
        if resolver != nil { archiveConnectionNeedsReconnect = false }
        guard pendingArchivedShard != nil else { return }
        archiveDownloadButton.title = resolver == nil
            ? "Connect Google Drive"
            : "Download recording"
        archiveDownloadButton.isEnabled = true
    }

    func setArchiveConnectionAvailableForValidation(_ available: Bool) {
        guard !allowsLibraryMutations else { return }
        archiveConnectionAvailableForValidation = available
        guard pendingArchivedShard != nil else { return }
        archiveDownloadButton.title = available
            ? "Download recording"
            : "Connect Google Drive"
        archiveDownloadButton.isEnabled = true
    }

    func setArchiveConnectionNeedsReconnect() {
        archiveConnectionNeedsReconnect = true
        archiveConnectionAvailableForValidation = false
        guard pendingArchivedShard != nil else { return }
        archiveDownloadButton.title = "Reconnect Google Drive"
        archiveDownloadButton.isEnabled = true
    }

    func prepareForShardResidencyChange() async {
        await librarySession.reloadShardCatalog()
        unavailableShards = (try? await librarySession.unavailableShards()) ?? []
    }

    func closeMutationAdmission() {
      mutationAdmissionClosed = true
      transcriptPresentationViews.forEach { $0.closeMutationAdmission() }
    }

    func prepareForPrimaryReplacement() async {
      retainedCompleteTranscriptID = nil
      cancelMeetingTranscriptWork()
      primaryReplacementDepth += 1
      primaryReplacementGeneration &+= 1
      visualScrollTask?.cancel()
      visualScrollTask = nil
      pendingVisualScroll = 0
      playbackTimelineRefresh?.cancel()
      playbackTimelineRefresh = nil
      stopRealTimePlayback()
      setPlaybackMediaAvailable(false)
      _ = beginWindowTransaction()
      _ = beginPresentationTransaction()
      // Release leases against the old primary before it is retired. Cancelled
      // presentation tasks cannot acquire new leases while replacement is pending.
      playerCache.removeAll()
      for lease in playerLeases.values { lease.release() }
      playerLeases.removeAll()
      playerLeaseSession.close()
        await librarySession.closeConnection()
    }

    func primaryReplacementDidComplete() async {
        if primaryReplacementDepth > 0 { primaryReplacementDepth -= 1 }
        await refreshAfterLibraryMutation()
    }

    // Metadata-only updates refresh presentation without completing another
    // operation's replacement barrier. Recheck after each actor suspension.
    func refreshAfterLibraryMutation() async {
        retainedCompleteTranscriptID = nil
        guard primaryReplacementDepth == 0 else { return }
        let replacementGeneration = primaryReplacementGeneration
        await librarySession.reloadShardCatalog()
        guard primaryReplacementDepth == 0,
              replacementGeneration == primaryReplacementGeneration else { return }
        let unavailable = (try? await librarySession.unavailableShards()) ?? []
        guard primaryReplacementDepth == 0,
              replacementGeneration == primaryReplacementGeneration else { return }
        unavailableShards = unavailable
        if window?.isVisible == true {
            reload(startAtLiveEdge: isAtLiveEdge, forwardingGlobalScrollEvent: nil)
        }
    }

    func presentMeetingRecording(
      _ presentation: LibreReverseMeetingRecordingPresentation
    ) {
      meetingRecordingView.present(presentation)
    }

    func meetingCaptureIsFinishing(
      _ detail: String = "Finishing recording…"
    ) {
      meetingRecordingView.setFinishing(detail)
    }

    func clearMeetingRecording() {
      meetingRecordingView.clear()
    }

    func meetingTranscriptionStateDidChange() {
      guard window?.isVisible == true,
        activeMeetingSegmentID != nil,
        let currentSeekDate
      else { return }
      resolveMoment(at: currentSeekDate)
    }

    func presentMeetingUIValidationFixture(_ state: String) {
      _ = beginWindowTransaction()
      _ = beginPresentationTransaction()
      presentedPlayer?.pause()
      updateSearchPresentation(for: .timelineScrubbed)
      collapsedSearchButton.isHidden = true
      playerView.isHidden = true
      dateLabel.isHidden = true
      let day = "Tuesday, August 25"
      switch state {
      case "archived", "downloading":
        liveImageView.isHidden = true
        meetingTranscriptView.clear()
        archivePlaceholderTitle.stringValue =
          state == "archived"
          ? "This meeting is archived"
          : "Downloading this meeting…"
        archivePlaceholderDetail.stringValue =
          state == "archived"
          ? "Download \(day) to view the recording and synchronized transcript."
          : "Getting recordings from Google Drive — 42 MB of 100 MB"
        archiveDownloadButton.title = "Download This Meeting"
        archiveDownloadButton.isEnabled = state == "archived"
        archiveDownloadButton.isHidden = state != "archived"
        archivePlaceholder.setDownloading(state == "downloading")
        if state == "downloading" {
            archivePlaceholder.updateTransfer(id: "fixture", completed: 42, total: 100)
        }
        archivePlaceholder.isHidden = false
      default:
        hideArchivedDayPlaceholder()
        let size = NSSize(width: 1_280, height: 720)
        let image = NSImage(size: size, flipped: false) { rect in
          NSGradient(
            starting: NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.20, alpha: 1),
            ending: NSColor(calibratedRed: 0.18, green: 0.10, blue: 0.28, alpha: 1)
          )?.draw(in: rect, angle: -18)
          let title =
            state == "recording"
            ? "Meeting recording in progress"
            : "Restored meeting recording"
          let detail =
            state == "recording"
            ? "Google Meet  ·  Dense video and synchronized audio"
            : "Google Meet  ·  24:18  ·  Restored from Google Drive"
          title.draw(
            at: NSPoint(x: 72, y: 390),
            withAttributes: [
              .font: NSFont.systemFont(ofSize: 38, weight: .semibold),
              .foregroundColor: NSColor.white,
            ]
          )
          detail.draw(
            at: NSPoint(x: 74, y: 345),
            withAttributes: [
              .font: NSFont.systemFont(ofSize: 18, weight: .medium),
              .foregroundColor: NSColor.white.withAlphaComponent(0.72),
            ]
          )
          return true
        }
        liveImageSourceTag = "meeting-ui-restored-fixture"
        applyPresentation(
          FrameDetailDisplay.presentation(
            isHidden: false,
            hasVideo: false,
            hasImage: true
          ),
          image: image,
          site: "meetingUIRestoredFixture"
        )
        let start = Date(timeIntervalSince1970: 1_777_124_400)
        let text =
          "We captured every frame and both audio sources. The restored transcript stays synchronized with playback."
        presentMeetingTranscript(
          .init(
            segmentID: 9_001,
            title: "Weekly product review",
            text: text,
            startDate: start,
            endDate: start.addingTimeInterval(1_458),
            words: [
              .init(
                id: 1, speechSource: "others", text: "captured", startSeconds: 2,
                durationSeconds: 1, fullTextUTF16Offset: 3),
              .init(
                id: 2, speechSource: "others", text: "restored", startSeconds: 8,
                durationSeconds: 1, fullTextUTF16Offset: 52),
              .init(
                id: 3, speechSource: "others", text: "synchronized",
                startSeconds: 10,
                durationSeconds: 1, fullTextUTF16Offset: 78),
            ]
          ), at: start.addingTimeInterval(8.4))
      }
      if state == "recording" {
        meetingTranscriptView.clear()
        meetingRecordingView.onStop = { [weak self] in
          self?.meetingRecordingView.setFinishing()
        }
        meetingRecordingView.present(
          .init(
            candidate: .init(
              provider: .googleMeet,
              source: .windowDetection,
              title: "Weekly product review"
            ),
            selection: .init(
              capturesSystemAudio: true,
              capturesMicrophone: true,
              microphoneDeviceID: "fixture-mic"
            ),
            microphoneName: "Studio Display Microphone",
            startedAt: Date().addingTimeInterval(-65)
          ))
      } else {
        meetingRecordingView.clear()
      }
    }

    /// Signed, isolated end-to-end validation through the same timeline media,
    /// AVPlayer, transcript, and pin paths used by persisted meetings.
    func presentMeetingPlaybackValidationFixture(
      mediaURL: URL,
      remoteOnly: Bool,
      statusURL: URL?,
      actionsSeed: LibreReverseTimelineActionsFixtureSeed? = nil
    ) {
      // Keep the isolated validation window addressable by Accessibility while
      // the driving process presses the real archive button. The production
      // explorer still hides on deactivation; this
      // override exists only inside the explicit fixture entry point.
      window?.hidesOnDeactivate = false
      window?.orderFrontRegardless()
      // Isolated fixture input must not consume the user's concurrent global
      // wheel/Escape activity or let it invalidate captured state.
      stopVisibleTimelineGlobalScrollObserver()
      _ = beginWindowTransaction()
      let generation = beginPresentationTransaction()
      playbackFixtureStatusURL = statusURL
      playbackFixtureMediaURL = mediaURL
      playbackFixtureRemoteOnly = remoteOnly
      playbackFixtureDidStart = false
      presentedPlayer?.pause()
      updateSearchPresentation(for: .timelineScrubbed)
      collapsedSearchButton.isHidden = true
      dateLabel.isHidden = true
      hideArchivedDayPlaceholder()

      let start = actionsSeed?.start ?? Date(timeIntervalSince1970: 1_777_124_400)
      let end = actionsSeed?.end ?? start.addingTimeInterval(8)
      let requestedDate = actionsSeed?.requestedDate ?? start.addingTimeInterval(1)
      let segment = TimelineSegment(
        startDate: start,
        endDate: end,
        bundleID: "com.google.Chrome",
        contiguousStartOffset: 0,
        contiguousEndOffset: 8,
        windowName: "Weekly product review — Google Meet",
        browserURL: "https://meet.google.com/abc-defg-hij",
        rawID: actionsSeed?.segmentID ?? 9_001,
        rawType: .audio
      )
      loadedRawSegments = [segment]
      loadedGlobalSeekInterval = DateInterval(start: start, end: end)
      snapshot = LibreReverseTimelineSnapshot(
        rawSegments: [segment],
        validSeekInterval: loadedGlobalSeekInterval
      )
      timelineOverlay.snapshot = snapshot
      timelineOverlay.currentDate = requestedDate
      timelineOverlay.selectedSegmentIDs = [segment.rawID]
      timelineOverlay.isHidden = false
      currentSeekDate = requestedDate
      activeMeetingSegmentID = segment.rawID
      isAtLiveEdge = false
      setPlaybackMediaAvailable(false)

      let text =
        "We captured every frame and both audio sources. The restored transcript stays synchronized with playback."
      presentMeetingTranscript(
        .init(
          segmentID: segment.rawID,
          title: "Weekly product review",
          text: text,
          startDate: start,
          endDate: end,
          words: [
            .init(
              id: 1, speechSource: "others", text: "captured",
              startSeconds: 1, durationSeconds: 1, fullTextUTF16Offset: 3),
            .init(
              id: 2, speechSource: "me", text: "restored",
              startSeconds: 3, durationSeconds: 1, fullTextUTF16Offset: 52),
            .init(
              id: 3, speechSource: "others", text: "synchronized",
              startSeconds: 5, durationSeconds: 1, fullTextUTF16Offset: 78),
          ],
          metadata: .init(
            provider: .googleMeet,
            calendarTitle: "Product",
            participants: ["Maya", "Jordan", "Sam"]
          ),
          processingState: .complete
        ),
        at: requestedDate
      )

      let moment = HistoricalTimelineMoment(
        frameID: actionsSeed?.frameID ?? 90_001,
        wallDate: requestedDate,
        databaseVideoID: actionsSeed?.videoID ?? 90_001,
        chunkURL: mediaURL,
        frameImageURL: mediaURL.deletingLastPathComponent().appendingPathComponent(
          "missing-fixture-still.png"),
        mediaTime: 1,
        videoFrameIndex: 30,
        videoFrameRate: 30,
        videoWidth: 1_920,
        videoHeight: 1_080,
        segmentID: segment.rawID,
        bundleID: segment.bundleID,
        segmentStartDate: start,
        segmentEndDate: end,
        windowName: segment.windowName,
        browserURL: segment.browserURL,
        segmentType: SegmentType.audio.rawValue,
        isStarred: false,
        isPendingImage: false
      )
      show(
        moment: moment,
        requestedDate: requestedDate,
        selectedSegment: segment,
        generation: generation
      )
      if actionsSeed != nil {
        writeTimelineActionsFixtureStatus(event: "presented", moment: moment)
      }
      writePlaybackFixtureStatus(
        phase: remoteOnly ? "remoteOnly" : "loadingLocal",
        playerAdvanced: false,
        audioTrackCount: 0
      )
      if remoteOnly,
        LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_MEETING_PLAYBACK_UI_FIXTURE_AUTO_RESTORE"
        ] == "1"
      {
        // Exercise the control's real target/action wiring after its
        // remote-only state has been published for external verification.
        Task { @MainActor [weak self] in
          try? await Task.sleep(nanoseconds: 1_000_000_000)
          self?.archiveDownloadButton.performClick(nil)
        }
      }
    }

    required init?(coder: NSCoder) { nil }

    func showLiveFrame(
        _ frame: CapturedScreenFrame,
        at date: Date,
        admittedFrame: LibreReverseAdmittedFrame? = nil
    ) {
        // Live admissions must not overwrite the still retained for historical
        // playback. At the live edge the transparent explorer reveals the desktop;
        // painting delayed captures there would produce a stuttering duplicate view.
        mergeAdmittedScreenSegment(admittedFrame)
        latestLiveFrameImage = NSImage(
          cgImage: frame.image,
          size: frame.logicalDisplaySize
        )
        LibreReverseTimelineTrace.log(
            "liveFrame at=\(date) pinned=\(isAtLiveEdge) "
                + "liveHidden=\(liveImageView.isHidden) playerHidden=\(playerView.isHidden)"
        )
        guard isAtLiveEdge else { return }
        presentedMoment = nil
        currentSeekDate = date
        updateJumpToDateButton()
        timelineOverlay.currentDate = date
      timelineOverlay.selectedSegmentIDs =
        snapshot.processedScreenshotSegments.last
            .map { [$0.rawID] } ?? []
        // A pinned live edge is a navigation state, not a property inferred
        // from the age of the newest persisted Segment. A visibility comparison
        // against a stale Segment can expose its last frame. Once pinned, keep
        // the real desktop authoritative until a backward navigation action
        // explicitly clears the pin.
        beginPresentationTransaction()
        liveImageSourceTag = "desktop"
        applyPresentation(
            FrameDetailDisplay.presentation(
                isHidden: true,
                hasVideo: false,
                hasImage: false
            ),
            site: "liveFrameTail"
        )
    }

    func present(
        on screen: NSScreen,
        startAtLiveEdge: Bool,
        forwardingGlobalScrollEvent event: NSEvent?
    ) {
        guard let window else { return }
        stopRealTimePlayback()
        // An explicit opening starts a new input lifetime. A retained live-pin
        // owner must not reject the fresh initial query's newer endpoint.
        seekSourceReducer = SeekSourceReducer(canUpdateSeekPosition: seekSourceReducer.canUpdateSeekPosition)
        visualScrollTask?.cancel()
        visualScrollTask = nil
        pendingVisualScroll = 0
        timelineOverlay.isHidden = playbackTimelinePresentation == nil
        endScrollPolicy = TimelineEndScrollPolicy()
        liveGestureLatch = LibreReverseTimelineLiveGestureLatch()
        if startAtLiveEdge || currentSeekDate == nil {
            isAtLiveEdge = true
            currentSeekDate = loadedGlobalSeekInterval?.end ?? Date()
            timelineOverlay.currentOffsetOverride = nil
            timelineOverlay.currentDate = currentSeekDate
            timelineOverlay.isPinnedToEnd = true
            accumulatedScrollOffset = nil
            beginPresentationTransaction()
            // Routed through the single write path. This previously set the
            // surfaces directly, which bypassed the equality gate and, under
            // the fallback-beneath-player z-order, could leave the still
            // visible at the live edge instead of revealing the desktop.
            applyPresentation(
                FrameDetailDisplay.presentation(
                    isHidden: true,
                    hasVideo: false,
                    hasImage: false
                ),
                site: "explorerPresented"
            )
        }
        let display = MemoryExplorerWindowContract.Display(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        window.setFrame(
            MemoryExplorerWindowContract.entranceFrame(on: display),
            display: false
        )
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startVisibleTimelineGlobalScrollObserver()
        timelineWaveforms.update(visible: timelineOverlay.visibleMeetingSegments,
            rawSegments: timelineOverlay.snapshot.rawAudioSegments)
        window.setFrame(
            MemoryExplorerWindowContract.steadyFrame(on: display),
            display: true,
            animate: false
        )
        updateSearchPresentation(for: .explorerPresented, focus: false)
        searchOverlay.prepareForPresentation(
            startAtLiveEdge ? .blankSearch : .preserveLastSearch
        )
        searchOverlay.focusSearchField()
        reload(
            startAtLiveEdge: isAtLiveEdge,
            forwardingGlobalScrollEvent: event
        )
    }

    func navigateToMeeting(_ meeting: LibreReverseDailyRecapMeeting) {
      guard let segmentID = meeting.segmentID else { return }
      isAtLiveEdge = false
      accumulatedScrollOffset = nil
      currentSeekDate = meeting.startDate
      activeMeetingSegmentID = segmentID
      updateSearchPresentation(for: .timelineScrubbed)
      reload(startAtLiveEdge: false, forwardingGlobalScrollEvent: nil)
    }

    func navigateToMoment(_ date: Date) {
      stopRealTimePlayback()
      if timelineActionsFixtureStatusURL != nil {
        pendingTimelineActionsFixtureDeepLink = date
        writeTimelineActionsFixtureStatus(
          event: "deepLinkReceived",
          moment: presentedMoment
        )
      }
      isAtLiveEdge = false
      accumulatedScrollOffset = nil
      currentSeekDate = date
      if let moment = presentedMoment,
        abs(date.timeIntervalSince(moment.wallDate)) < 0.0005
      {
        pendingTimelineActionsFixtureDeepLink = nil
        writeTimelineActionsFixtureStatus(
          event: "deepLinkResolved",
          moment: moment
        )
      }
      activeMeetingSegmentID = nil
      updateSearchPresentation(for: .timelineScrubbed)
      reload(startAtLiveEdge: false, forwardingGlobalScrollEvent: nil)
    }

    /// Exercises the normal Search reducer/query/rendering path against the
    /// actual read-only library and emits content-redacted evidence.
    func presentLibrarySearchValidation(
      query: String,
      facet: String,
      statusURL: URL?,
      selectsFirstResult: Bool,
      initialCursor: SearchRecencyCursor? = nil,
      restoredDriveShardOrdinal: Int64? = nil,
      restoredDriveShardBytes: Int64? = nil,
      driveRestoreMilliseconds: Double? = nil,
      restoredDriveShardInterval: DateInterval? = nil
    ) {
      var state = LibreReverseSearchOverlayState(query: query)
      switch facet {
      case "meetings": state.filters = [.meetings]
      case "starred": state.filters = [.starred]
      case "meetings-starred": state.filters = [.meetings, .starred]
      default:
        if facet.hasPrefix("apps:") {
          let bundleID = String(facet.dropFirst("apps:".count))
          state = LibreReverseSearchOverlayState(
            query: query,
            applicationBundleIDs: bundleID.isEmpty ? [] : [bundleID]
          )
        }
      }
      librarySearchValidation = LibrarySearchValidation(
        query: query,
        facet: facet,
        statusURL: statusURL,
        selectsFirstResult: selectsFirstResult,
        restoredDriveShardOrdinal: restoredDriveShardOrdinal,
        restoredDriveShardBytes: restoredDriveShardBytes,
        driveRestoreMilliseconds: driveRestoreMilliseconds,
        initialCursor: initialCursor,
        restoredDriveShardInterval: restoredDriveShardInterval
      )
      searchOverlay.setState(state)
      Task { [weak self] in
        guard let self else { return }
        do {
          let inventory = try await self.librarySession.searchValidationInventory()
          guard self.librarySearchValidation?.query == query else { return }
          self.librarySearchValidationInventory = inventory
          self.submitSearch(state, initialCursor: initialCursor)
        } catch {
          self.writeLibrarySearchValidationStatus(
            phase: "inventory-error",
            error: error.localizedDescription
          )
        }
      }
    }

    /// Restores one verified shard only into the caller-supplied temporary
    /// library, then enters the same production Search path as the read-only
    /// primary validation. The app delegate refuses this route for any
    /// non-temporary library root.
    func presentDriveShardSearchValidation(
      query: String,
      facet: String,
      statusURL: URL?,
      selectsFirstResult: Bool,
      resolver: LibreReverseShardResolver,
      shardOrdinal: Int64,
      shardInterval: DateInterval,
      expectedBytes: Int64
    ) {
      Task { [weak self] in
        guard let self else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        do {
          try Self.writeArchivedHistoryValidationStatus(
            to: statusURL,
            payload: [
              "phase": "restoring-drive-shard",
              "shardOrdinal": shardOrdinal,
              "expectedBytes": expectedBytes,
              "temporaryLibrary": true,
              "captureStarted": false,
              "remoteMutationStarted": false,
            ]
          )
          _ = try await resolver.restore(ordinal: shardOrdinal) { progress in
            await MainActor.run {
              try? Self.writeArchivedHistoryValidationStatus(
                to: statusURL,
                payload: [
                  "phase": "restoring-drive-shard",
                  "shardOrdinal": shardOrdinal,
                  "expectedBytes": expectedBytes,
                  "completedBytes": progress.completedBytes,
                  "totalBytes": progress.totalBytes,
                  "temporaryLibrary": true,
                  "captureStarted": false,
                  "remoteMutationStarted": false,
                ]
              )
            }
          }
          await librarySession.reloadShardCatalog()
          unavailableShards = (try? await librarySession.unavailableShards()) ?? []
          let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds &- started
          ) / 1_000_000
          presentLibrarySearchValidation(
            query: query,
            facet: facet,
            statusURL: statusURL,
            selectsFirstResult: selectsFirstResult,
            initialCursor: .init(
              documentID: .max,
              instant: shardInterval.end
            ),
            restoredDriveShardOrdinal: shardOrdinal,
            restoredDriveShardBytes: expectedBytes,
            driveRestoreMilliseconds: elapsed,
            restoredDriveShardInterval: shardInterval
          )
        } catch {
          try? Self.writeArchivedHistoryValidationStatus(
            to: statusURL,
            payload: [
              "phase": "drive-shard-restore-error",
              "shardOrdinal": shardOrdinal,
              "expectedBytes": expectedBytes,
              "temporaryLibrary": true,
              "captureStarted": false,
              "remoteMutationStarted": false,
              "error": error.localizedDescription,
            ]
          )
        }
      }
    }

    /// Exercises archived navigation against the real catalog without opening
    /// a shard or starting Drive work. The catalog is content-free and the
    /// resulting proof demonstrates that the action is available as soon as
    /// the interval is known.
    func presentArchivedHistoryValidation(statusURL: URL?) {
      Task { [weak self] in
        guard let self else { return }
        do {
          let shards = try await librarySession.unavailableShards()
          guard let shard = shards.first else {
            try Self.writeArchivedHistoryValidationStatus(
              to: statusURL,
              payload: ["phase": "no-drive-only-history"]
            )
            return
          }
          unavailableShards = shards
          let date = shard.interval.start.addingTimeInterval(1)
          let started = DispatchTime.now().uptimeNanoseconds
          resolveMoment(at: date)
          let presentationMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds &- started
          ) / 1_000_000
          try Self.writeArchivedHistoryValidationStatus(
            to: statusURL,
            payload: [
              "phase": "presented",
              "databaseOpenMode": "SQLITE_OPEN_READONLY",
              "captureStarted": false,
              "archiveMutationStarted": false,
              "currentWritablePrimaryPresent": true,
              "driveOnlyHistoricalShardCount": shards.count,
              "selectedOrdinal": shard.ordinal,
              "presentationMilliseconds": presentationMilliseconds,
              "localFrameLookupRequired": false,
              "buttonTitle": archiveDownloadButton.title,
              "buttonEnabled": archiveDownloadButton.isEnabled,
              "placeholderVisible": !archivePlaceholder.isHidden,
            ]
          )
          if let destination = LibreReverseDevelopmentEnvironment.values[
            "LIBREREVERSE_LIBRARY_UI_VALIDATION_SCREENSHOT"
          ], !destination.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
              self?.writeChromeCapture(to: destination)
            }
          }
        } catch {
          try? Self.writeArchivedHistoryValidationStatus(
            to: statusURL,
            payload: ["phase": "error", "error": error.localizedDescription]
          )
        }
      }
    }

    private static func writeArchivedHistoryValidationStatus(
      to statusURL: URL?,
      payload: [String: Any]
    ) throws {
      guard let statusURL else { return }
      let data = try JSONSerialization.data(
        withJSONObject: payload,
        options: [.prettyPrinted, .sortedKeys]
      )
      try data.write(to: statusURL, options: .atomic)
    }

    /// Test-only. Writes the explorer's own view tree to a PNG.
    ///
    /// `screencapture` needs Screen Recording permission the tooling driving
    /// these probes does not have, which left the UI unreviewable: geometry
    /// could be measured from frames but nothing could be *looked* at, and two
    /// of the defects fixed today were purely visual. `cacheDisplay` renders
    /// the AppKit chrome -- search surfaces, timeline, chips, buttons -- which
    /// is exactly the layer being reviewed. The video underneath comes from an
    /// `AVPlayerLayer` and does not render this way, so it appears empty; that
    /// is fine, and arguably better for judging the chrome.
    private func writeChromeCapture(to destination: String) {
        guard let content = window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
      guard
        let representation = content.bitmapImageRepForCachingDisplay(
            in: content.bounds
        )
      else { return }
        content.cacheDisplay(in: content.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: destination))
        LibreReverseTimelineTrace.log(
            "PROBE captured chrome \(Int(content.bounds.width))x"
            + "\(Int(content.bounds.height)) -> \(destination)"
        )
    }

    private func reload(
        startAtLiveEdge: Bool,
        forwardingGlobalScrollEvent event: NSEvent?
    ) {
        let publicationGeneration = beginWindowTransaction()
        let recordingRevisionAtFetch = recordingPublicationRevision
        let preservedSeekDate = currentSeekDate
      let preservedMeetingSegmentID =
        LibreReverseMeetingReloadSelectionPolicy.retainedSegmentID(
          startAtLiveEdge: startAtLiveEdge,
          preservedSeekDate: preservedSeekDate,
          preservedSegmentID: activeMeetingSegmentID
        )
      let reloadRequest = LibreReverseTimelineReloadRequest.make(
        startAtLiveEdge: startAtLiveEdge,
        preservedSeekDate: preservedSeekDate,
        lastFetchedDuration: lastFetchedWindowDuration,
        defaultDuration: LibraryDatabase.initialTimelineWindowDuration
      )
        let session = librarySession
        let navigationRevisionAtReload = scrollNavigationRevision
        initialReloadTask = Task {
            let result: Result<(
                window: HistoricalTimelineSegmentWindow,
                unavailableShards: [HistoricalUnavailableShard]
            ), Error>
            do {
          let window = try await readTimelineWindow(reloadRequest, includesPlaybackTiming: true)
          let unavailable: [HistoricalUnavailableShard]
          #if DEBUG
          if interactionTestTimelineWindow != nil { unavailable = [] }
          else { unavailable = try await session.unavailableShards() }
          #else
          unavailable = try await session.unavailableShards()
          #endif
          result = .success((window: window, unavailableShards: unavailable))
            } catch {
                result = .failure(error)
            }
        guard ownsWindowPublication(publicationGeneration), !Task.isCancelled else {
          return
        }
            switch result {
        case .success(let loaded):
                let window = loaded.window
                playbackTimelinePresentation = PlaybackTimelinePresentation(window: window, starredDates: allStarredDates)
                timelineOverlay.playbackPresentationEnabled = playbackTimelinePresentation != nil
                timelineOverlay.currentOffsetOverride = nil
                timelineOverlay.snapshot = playbackTimelinePresentation?.snapshot ?? snapshot
                timelineOverlay.isHidden = false
                unavailableShards = loaded.unavailableShards
                publishFetchedWindow(
                    window,
            fetchedAt: {
              if case .around(let date, _) = reloadRequest { return date }
              return window.validSeekInterval?.end ?? Date()
            }(),
                    recordingRevisionAtFetch: recordingRevisionAtFetch
                )
                starRefreshSubject.send()
        case .failure(let error):
                // Keep the last successful publication when the outer fetch task fails.
                dateLabel.stringValue = "Unable to load timeline: \(error.localizedDescription)"
                dateLabel.isHidden = false
                return
            }
            if !snapshot.processedSegments.isEmpty, let end = snapshot.validSeekInterval?.end {
                let last = snapshot.appGroups.count - 1
                if last >= 0 {
                    tableView.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
                    tableView.scrollRowToVisible(last)
                }
                if scrollNavigationRevision != navigationRevisionAtReload {
                    // A loading result must not pull an already moving gesture
                    // back to its opening position.
                } else if startAtLiveEdge || preservedSeekDate == nil {
                    seek(to: end, intent: .live, source: .isInitialLoad)
                } else if let preservedSeekDate {
            seek(
              to: preservedSeekDate,
              intent: .historical,
              source: .isInitialLoad,
              meetingSegmentID: preservedMeetingSegmentID
            )
                }
                if let event, scrollNavigationRevision == navigationRevisionAtReload {
                    applyScroll(event, source: .globalScroll)
                }
            } else if case .success = result {
          activeMeetingSegmentID = nil
          meetingTranscriptView.clear()
          setPlaybackMediaAvailable(false)
                isAtLiveEdge = true
                accumulatedScrollOffset = nil
                beginPresentationTransaction()
                applyPresentation(
                    FrameDetailDisplay.presentation(
                        isHidden: true,
                        hasVideo: false,
                        hasImage: false
                    ),
                    site: "reloadedLive"
                )
            }
        }
    }

    @objc private func screenParametersDidChange() {
        dismiss()
    }

    private func startVisibleTimelineGlobalScrollObserver() {
        guard visibleTimelineGlobalScrollMonitor == nil else { return }
        visibleTimelineGlobalScrollMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.scrollWheel, .keyDown]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.window?.isVisible == true else { return }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.dismiss() }
                    return
                }
                self.applyScroll(event, source: .globalScroll)
            }
        }
    }

    private func stopVisibleTimelineGlobalScrollObserver() {
        if let visibleTimelineGlobalScrollMonitor {
            NSEvent.removeMonitor(visibleTimelineGlobalScrollMonitor)
            self.visibleTimelineGlobalScrollMonitor = nil
        }
    }

    func dismissForApplicationDeactivation() {
        // Explicit validation windows remain addressable while their driver runs.
        guard window?.hidesOnDeactivate == true else { return }
        dismiss()
    }

    func dismiss() {
      LibreReverseScrollToRewindController.timelineDidDismiss()
      endScrollPolicy = TimelineEndScrollPolicy()
      // Dismissal invalidates even an in-flight stationary fetch whose I/O
      // finishes despite cancellation. Reopening starts a fresh transaction.
      _ = beginWindowTransaction()
      initialReloadTask = nil
      windowReplacementTask = nil
      stationaryRefreshTask = nil
      cancelMeetingTranscriptWork()
      settledScrollTask?.cancel()
      settledScrollTask = nil
      timelineWaveforms.suspend()
      visualScrollTask?.cancel()
      visualScrollTask = nil
      pendingVisualScroll = 0
      resetExplorerSearch(.hide)
      // A pinned transcript is an independent, non-floating window by design.
      // Hiding the timeline must not tear down its audio controls; closing the
      // pinned window first clears this property and follows the normal stop.
      if pinnedTranscriptWindow == nil {
        stopRealTimePlayback()
        setPlaybackMediaAvailable(false)
      }
        stopVisibleTimelineGlobalScrollObserver()
        window?.orderOut(nil)
        if pinnedTranscriptWindow == nil {
            _ = beginPresentationTransaction()
        }
        playbackTimelineRefresh?.cancel()
        playbackTimelineRefresh = nil
        // A reopened explorer must respond to its first gesture immediately
        // rather than inheriting the previous session's throttle window.
        boundsSeekThrottle = TimelineSeekThrottle()
        scrollSeekThrottle = TimelineSeekThrottle()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { snapshot.appGroups.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
      -> NSView?
    {
        let identifier = NSUserInterfaceItemIdentifier("TimelineCell")
      let field =
        (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        let group = snapshot.appGroups[row]
        let segment = group.segments[0]
        let application = segment.bundleID ?? "Unknown application"
      let website =
        TimelineSegmentProcessor.websiteHost(for: segment.browserURL)
            .map { "  ·  \($0)" } ?? ""
      field.stringValue =
        "\(group.dateInterval.start.formatted(date: .abbreviated, time: .standard))  ·  \(application)\(website)"
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard snapshot.appGroups.indices.contains(row) else { return }
        seek(
            to: snapshot.appGroups[row].dateInterval.start,
            intent: .historical,
            source: .click
        )
    }

    @objc private func timelineSliderChanged(_ sender: NSSlider) {
      guard let date = snapshot.wallDate(atContiguousOffset: sender.doubleValue) else {
        return
      }
      guard
        boundsSeekThrottle.admits(
            interval: TimelineInteractionTiming.boundsInterval,
            now: Date()
        )
      else { return }
        seek(to: date, intent: .historical, source: .drag)
    }

    private func applyScroll(
        _ event: NSEvent,
        source: TimelineScrubbingSource
    ) {
        guard snapshot.contiguousDuration > 0 else { return }
        LibreReverseTimelineTrace.log(
            "SCROLLEV phase=\(event.phase.rawValue) "
                + "momentum=\(event.momentumPhase.rawValue) "
                + "dx=\(event.scrollingDeltaX) dy=\(event.scrollingDeltaY) "
                + "precise=\(event.hasPreciseScrollingDeltas)"
        )
        let flags = event.modifierFlags
        let result = TimelineScroll.timeDelta(
            scrollingDeltaX: event.scrollingDeltaX,
            scrollingDeltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            modifiers: TimelineScrollModifiers(
                command: flags.contains(.command),
                option: flags.contains(.option),
                shift: flags.contains(.shift)
            ),
            zoomLevel: Double(timelineZoomLevel),
            source: source
        )
        let scrollNow = Date()
        switch result.scrollType {
        case .normal:
            break
        case .manuallyFast:
            lastFastScrollEvent = TimelineFastScrollEvent(
                date: scrollNow,
                isManual: true
            )
        case .shiftPowerUp:
            lastFastScrollEvent = TimelineFastScrollEvent(
                date: scrollNow,
                isManual: false
            )
        }
        // Update the cursor on every admitted input event; throttle only expensive
        // media and window work. Preserve the gesture offset across updates because
        // round-tripping through wall dates loses position inside compressed gaps.
        let isPhaseless = event.phase.isEmpty && event.momentumPhase.isEmpty
      let startsGesture =
        event.phase.contains(.mayBegin)
            || event.phase.contains(.began)
      let endsGesture =
        event.phase.contains(.ended)
            || event.phase.contains(.cancelled)
        if startsGesture {
            scrollGestureAdmitted = true
            LibreReverseTimelineTrace.boundary(
                "BEGIN source=\(source) phase=\(event.phase.rawValue) "
                    + "pinned=\(isAtLiveEdge) duration=\(snapshot.contiguousDuration) "
                    + "seek=\(String(describing: currentSeekDate))"
            )
        } else if isPhaseless {
            scrollGestureAdmitted = true
        }
        guard scrollGestureAdmitted else { return }
        // Momentum must not unpin a gesture that has reached the live edge. It can
        // continue moving historical positions until that boundary is reached.
        let isMomentum = !event.momentumPhase.isEmpty
        let forwardPixels = -(abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY)
            * (event.hasPreciseScrollingDeltas ? 1.0 : 12.0)
        let edge = endScrollPolicy.advance(atLiveEdge: isAtLiveEdge,
            pixels: forwardPixels, momentum: isMomentum)
        if edge.exit { dismiss(); return }
        if isAtLiveEdge && edge.history == 0 { return }
        if liveGestureLatch.prepareForEvent(
            beginsGesture: startsGesture,
            isPhaseless: isPhaseless
        ) {
            LibreReverseTimelineTrace.log(
                "GESTURELATCH suppressed phase=\(event.phase.rawValue) "
                    + "momentum=\(event.momentumPhase.rawValue)"
            )
            if endsGesture || event.momentumPhase.contains(.ended) {
                seekSourceReducer.boundsDidChange()
                liveGestureLatch.gestureEnded()
                LibreReverseTimelineTrace.boundary(
                    "END-LATCH source=\(source) phase=\(event.phase.rawValue) "
                        + "momentum=\(event.momentumPhase.rawValue) pinned=\(isAtLiveEdge)"
                )
            }
            return
        }
        if isMomentum && isAtLiveEdge { return }
        // Discard dominant input below one unit so decaying momentum does not keep
        // issuing seeks after the gesture ends.
      let dominant =
        abs(event.scrollingDeltaY) < abs(event.scrollingDeltaX)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        guard abs(dominant) >= TimelineScroll.minimumDominantDelta else { return }
        scrollNavigationRevision &+= 1
        if playbackTimelinePresentation != nil {
            // The wheel moves the very same axis that is drawn and panned.
            // Pixel gain is independent of media type and database time.
            let gain = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
            let fast = flags.contains(.shift) ? 4.0 : 1.0
            pendingVisualScroll += UnifiedTimelineScroll.distance(pixels: (isAtLiveEdge ? edge.history : -dominant * gain) * fast,
                zoom: timelineZoomLevel)
            stopRealTimePlayback()
            drainVisualScroll()
            if endsGesture || event.momentumPhase.contains(.ended) {
                seekSourceReducer.boundsDidChange()
                liveGestureLatch.gestureEnded()
            }
            return
        }
      let base =
        accumulatedScrollOffset
            ?? currentSeekDate.flatMap(snapshot.contiguousOffset(atWallDate:))
            ?? snapshot.contiguousDuration
        let targetOffset = min(
            max(0, base + result.delta),
            snapshot.contiguousDuration
        )
        let ownerBeforeMutation = seekSourceReducer.source
        let pinBeforeMutation = isAtLiveEdge
        accumulatedScrollOffset = targetOffset
        // Raw didScroll bypasses the shared priority gate and overwrites any
        // prior pin/source with ordinal 7 after mutating the accumulator.
        seekSourceReducer.rawScrollDidMutateOffset()
        // The bounded window's right edge is a paging boundary, not necessarily
        // the newest date. Pinning to the live edge must use the global
        // valid end instead of this local paging boundary.
        guard let localTargetDate = snapshot.wallDate(atContiguousOffset: targetOffset) else {
            return
        }
        let pinTarget = TimelineEndOwnership.pinTarget(
            localOffset: targetOffset,
            localDuration: snapshot.contiguousDuration,
            globalValidEnd: loadedGlobalSeekInterval?.end,
            advancesForward: result.delta > 0
        )
        LibreReverseTimelineTrace.log(
            "SCROLLSTATE delta=\(result.delta) base=\(base) target=\(targetOffset) "
                + "duration=\(snapshot.contiguousDuration) "
                + "localDate=\(localTargetDate) "
                + "globalEnd=\(String(describing: loadedGlobalSeekInterval?.end)) "
                + "ownerBefore=\(String(describing: ownerBeforeMutation)) "
                + "pinBefore=\(pinBeforeMutation) "
                + "pinTarget=\(String(describing: pinTarget))"
        )
        let targetDate = pinTarget ?? localTargetDate
        LibreReverseTimelineTrace.boundary(
            "STEP dx=\(event.scrollingDeltaX) dy=\(event.scrollingDeltaY) delta=\(result.delta) "
            + "base=\(base) target=\(targetOffset) date=\(targetDate.timeIntervalSince1970) "
            + "momentum=\(isMomentum)"
        )
        if pinTarget != nil {
            if !isAtLiveEdge {
                LibreReverseTimelineTrace.log("PINLATCH bounded right clamp -> global end")
            }
            isAtLiveEdge = true
            if !pinBeforeMutation {
                LibreReverseTimelineTrace.boundary(
                    "PIN source=\(source) delta=\(result.delta) "
                        + "target=\(targetOffset) duration=\(snapshot.contiguousDuration)"
                )
            }
            liveGestureLatch.didReachEnd(isPhaseless: isPhaseless)
            // Drop the accumulator so the next backward scroll re-derives its
            // base from the live date. Holding the old offset while capture
            // keeps extending the timeline is what made the playhead unable to
            // stay at the present.
            accumulatedScrollOffset = nil
        } else if result.delta < 0, !isMomentum {
            // Only a real gesture unpins; a decaying tail never does.
            isAtLiveEdge = false
            if pinBeforeMutation {
                LibreReverseTimelineTrace.boundary(
                    "UNPIN source=\(source) delta=\(result.delta) "
                        + "target=\(targetOffset) duration=\(snapshot.contiguousDuration)"
                )
            }
        }
        updateSearchPresentation(for: .timelineScrubbed)
        // Pass the authoritative scroll accumulator directly to the overlay
        // so layout cannot quantize it through segment wall dates.
        timelineOverlay.currentOffsetOverride = playbackTimelinePresentation == nil ? targetOffset : nil
        let admitsThrottledWork = scrollSeekThrottle.admits(
            interval: TimelineInteractionTiming.scrollInterval(for: result.scrollType),
            now: scrollNow
        )
        seek(
            to: targetDate,
            intent: pinTarget == nil ? .historical : .live,
            source: pinTarget == nil ? .scroll : .pinToEnd,
            resolvesMedia: admitsThrottledWork,
            replacesWindow: admitsThrottledWork || pinTarget != nil
        )
        settledScrollTask?.cancel()
        if !admitsThrottledWork, pinTarget == nil {
            // Throttling must not drop the final requested frame. This also
            // handles mouse wheels that provide no gesture-ended event.
            settledScrollTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(120)) }
                catch { return }
                guard let self, !self.isAtLiveEdge,
                    self.currentSeekDate == targetDate else { return }
                self.resolveMoment(at: targetDate)
            }
        }
        if endsGesture || event.momentumPhase.contains(.ended) {
            seekSourceReducer.boundsDidChange()
            liveGestureLatch.gestureEnded()
            LibreReverseTimelineTrace.boundary(
                "END source=\(source) phase=\(event.phase.rawValue) "
                    + "momentum=\(event.momentumPhase.rawValue) pinned=\(isAtLiveEdge) "
                    + "offset=\(String(describing: accumulatedScrollOffset))"
            )
        }
    }

    private func drainVisualScroll() {
      guard visualScrollTask == nil, abs(pendingVisualScroll) > 0.000001,
        let presentation = playbackTimelinePresentation,
        let current = currentSeekDate else { return }
      // Live frames advance beyond this immutable history window. Leaving Now
      // must enter the available history immediately, not repeatedly page for
      // a live timestamp which has not been published into that window yet.
      let origin = isAtLiveEdge && pendingVisualScroll < 0 && current > presentation.interval.end
        ? presentation.interval.end : current
      guard presentation.contains(origin) else {
        loadVisualScrollWindow(around: origin)
        return
      }
      guard let step = UnifiedTimelineScroll.step(snapshot: presentation.snapshot,
        from: origin, distance: pendingVisualScroll) else { return }
      let forward = pendingVisualScroll > 0
      pendingVisualScroll = step.remainder
      let valid = loadedGlobalSeekInterval
      // The loaded tail has a real endpoint. New captures may advance the
      // global date while this gesture is in flight; do not chase that moving
      // target. Crossing the tail enters Now, then the separate exit lane.
      let atEnd = forward && (valid.map { step.date >= $0.end } == true
        || (presentation.includesLiveTail && step.date >= presentation.interval.end))
      let atStart = !forward && valid.map { step.date <= $0.start } == true
      if atEnd || atStart { pendingVisualScroll = 0 }
      seekSourceReducer.rawScrollDidMutateOffset()
      isAtLiveEdge = atEnd
      updateSearchPresentation(for: .timelineScrubbed)
      let now = ProcessInfo.processInfo.systemUptime
      let resolves = now - visualScrollLastMediaTime >= 1.0 / 30.0
      if resolves { visualScrollLastMediaTime = now }
      seek(to: step.date, intent: atEnd ? .live : .historical,
        source: atEnd ? .pinToEnd : .scroll, resolvesMedia: resolves,
        replacesWindow: false)
      // Always resolve the final cursor, including phaseless wheel input.
      settledScrollTask?.cancel()
      if !atEnd {
        let target = step.date
        settledScrollTask = Task { [weak self] in
          do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
          guard let self, self.currentSeekDate == target else { return }
          self.resolveMoment(at: target)
        }
      }
      guard abs(pendingVisualScroll) > 0.000001 else { return }
      // A local visual edge is a page boundary, not the end of history.
      // Retain any unconsumed movement while extending in wall-date units.
      loadVisualScrollWindow(around: step.date)
    }

    private func loadVisualScrollWindow(around date: Date) {
      guard visualScrollTask == nil else { return }
      // Input owns the next page; a superseded jump's background refresh must
      // not later publish another coordinate basis over this gesture.
      playbackTimelineRefresh?.cancel()
      playbackTimelineRefresh = nil
      let oldInterval = playbackTimelinePresentation?.interval
      visualScrollTask = Task { [weak self] in
        guard let self else { return }
        await self.preparePlaybackTimeline(around: date)
        guard !Task.isCancelled else { return }
        self.visualScrollTask = nil
        if self.playbackTimelinePresentation == nil || self.playbackTimelinePresentation?.interval == oldInterval {
          let forward = self.pendingVisualScroll > 0
          self.pendingVisualScroll = 0
          self.presentUnavailableTimelineEdge(at: date, forward: forward)
          return
        }
        self.drainVisualScroll()
      }
    }

    private func presentUnavailableTimelineEdge(at date: Date, forward: Bool) {
      let candidates = unavailableShards.filter {
        forward ? $0.interval.end > date : $0.interval.start < date
      }
      if let shard = candidates.min(by: {
        abs((forward ? $0.interval.start : $0.interval.end).timeIntervalSince(date))
          < abs((forward ? $1.interval.start : $1.interval.end).timeIntervalSince(date))
      }) {
        let target = forward ? max(date, shard.interval.start)
          : min(date, shard.interval.end.addingTimeInterval(-0.001))
        seek(to: target, intent: .historical, source: .scroll, replacesWindow: false)
      } else {
        dateLabel.stringValue = "More history could not be loaded. Try again."
        dateLabel.isHidden = false
      }
    }

    @objc private func jumpToPreviousSegment() {
        applyJump(.previous)
    }

    @objc private func jumpToNextSegment() {
        applyJump(.next)
    }

    private func applyJump(_ direction: TimelineJumpDirection) {
        switch TimelineJumpNavigation.outcome(
            for: direction,
            anchorDate: currentSeekDate,
            processedScreenshotSegments: timelineOverlay.snapshot.processedScreenshotSegments,
            validSeekInterval: loadedGlobalSeekInterval
        ) {
      case .updateSeekPosition(let date, let source):
            precondition(source == .jumpToDate)
            seek(to: date, intent: .historical, source: source)
        case .missingValidSeekInterval:
            dateLabel.stringValue = "No valid recorded interval"
            dateLabel.isHidden = false
        case .noAction:
            break
        }
    }

    private func seek(
        to requestedDate: Date,
        intent: SeekIntent = .historical,
        source: SeekPositionUpdateSource,
        contiguousOffset: TimeInterval? = nil,
        resolvesMedia: Bool = true,
      replacesWindow: Bool = true,
      meetingSegmentID: Int64? = nil,
      preservesPlayback: Bool = false
    ) {
      // These callbacks represent fresh user intent. Their asynchronous media
      // work is guarded by publication generations, not a persistent ordinal
      // lock left behind after the synchronous selection has completed.
      guard seekSourceReducer.canUpdateSeekPosition else { return }
      let beginsNewInteraction = source == .click || source == .search || source == .jumpToEnd
      if beginsNewInteraction, !seekSourceReducer.beginInteraction(source) { return }
      defer {
        if beginsNewInteraction { seekSourceReducer.endInteraction(source) }
      }
      settledScrollTask?.cancel()
      if !preservesPlayback, source != .scroll, source != .pinToEnd {
        visualScrollTask?.cancel()
        visualScrollTask = nil
        pendingVisualScroll = 0
      }
      if !preservesPlayback, realTimePlaybackTimer != nil || playbackTimelinePresentation != nil {
        stopRealTimePlayback()
      }
        let positionChanged = currentSeekDate != requestedDate
      guard
        seekSourceReducer.admit(
            source,
            positionChanged: positionChanged
        ) != .rejected
      else {
            LibreReverseTimelineTrace.log(
                "SEEK rejected source=\(source) owner=\(String(describing: seekSourceReducer.source))"
            )
            return
        }
      if !preservesPlayback {
        setPlaybackMediaAvailable(false)
      }
        // The selected-result highlight belongs only to the exact `.search`
        // navigation that created it. Any later scroll, jump, reload,
        // keyboard move, or pin-to-end invalidates the frame identity before
        // a new asynchronous media transaction can accidentally republish it.
        if source != .search {
            activeSearchMatch = nil
        activeMeetingSegmentID = nil
            searchMatchOverlay.clear()
        }
      if let meetingSegmentID {
        activeMeetingSegmentID = meetingSegmentID
      }
        if intent == .live {
            _ = seekSourceReducer.admit(.pinToEnd, positionChanged: true)
        }
        // Apply the seek position immediately, then replace the bounded window
        // asynchronously. Successive gestures may cancel fetches, but must never
        // delay the playhead, live-edge state, or media resolution.
        currentSeekDate = requestedDate
        timelineOverlay.currentDate = requestedDate
        prepareMeetingTranscriptForSeek(at: requestedDate, source: source, isLive: intent == .live)
        refreshPlaybackTimelineIfNeeded(at: requestedDate)
        // Reaching the newest recorded moment re-pins the live edge so the
        // playhead continues advancing with capture after a scroll.
        LibreReverseTimelineTrace.log(
            "SEEK source=\(source) intent=\(intent) requested=\(requestedDate)"
        )
        // A position set by anything other than scrolling invalidates the
        // accumulator so the next gesture reseeds from the new position.
        if let contiguousOffset {
            accumulatedScrollOffset = contiguousOffset
            timelineOverlay.currentOffsetOverride = playbackTimelinePresentation == nil ? contiguousOffset : nil
        } else if source != .scroll {
            accumulatedScrollOffset = nil
            timelineOverlay.currentOffsetOverride = nil
        }
        let previousPin = isAtLiveEdge
        // Pinning is an explicit state transition, never inferred from a
        // comparison against a moving target.
        //
        // This previously re-pinned whenever `requestedDate >= validSeekInterval.end`.
        // That end advances every capture, so a position within a few seconds
        // of it flipped the pin on and off: pinned drew the newest live frame,
        // unpinned drew the requested historical frame, and the display
        // alternated between them. That is the recent-history flicker.
        //
        // The pinToEnd action reads the global validSeekInterval.end
        // and writes persistent source ordinal 9. The separate five-second
        // segment-publication predicate has no pin or rendering effect.
        isAtLiveEdge = intent == .live
        // Historical loading and letterboxed video must never be transparent
        // onto the user's current desktop, even before the first frame arrives.
        window?.contentView?.layer?.backgroundColor =
            (isAtLiveEdge ? NSColor.clear : NSColor.black).cgColor
        updateJumpToDateButton()
        if isAtLiveEdge {
            // `pinToEnd` owns a moving wall-date target, not the numeric
            // contiguous offset at which the gesture first hit the clamp.
            // Retaining that offset makes newly admitted history grow to the
            // right of the playhead. Clearing both offset caches lets each
            // admitted live date re-project to the new timeline end.
            accumulatedScrollOffset = nil
            timelineOverlay.currentOffsetOverride = nil
        }
        if previousPin != isAtLiveEdge {
            LibreReverseTimelineTrace.log(
                "PIN \(previousPin) -> \(isAtLiveEdge) source=\(source) "
                    + "requested=\(requestedDate)"
            )
        }
        // Window replacement is a sibling action to seek-position mutation.
        // Start it before the live-display early return so pinToEnd immediately
        // swaps a bounded historical window for the recent window.
        if source != .isInitialLoad, replacesWindow {
            replaceWindow(around: requestedDate, intent: intent, source: source)
        }
        // `pinToEnd` is the authoritative live transition. On a static desktop
        // the diff gate may leave persisted segments behind wall time, so segment
        // coverage cannot decide whether to show the live desktop. Only explicit
        // live navigation may reveal it; historical capture gaps remain historical.
        if intent == .live {
            beginPresentationTransaction()
            // Equality-gated: while pinned live this arm ran on every seek and
            // re-applied identical state (measured: 87 writes, every traced
            // field identical), cancelling in-flight presentation work each
            // time. It now only acts on an actual transition into the live
            // presentation.
            let live = FrameDetailDisplay.presentation(
                isHidden: true,
                hasVideo: false,
                hasImage: false
            )
            if appliedPresentation != live {
                liveImageSourceTag = "desktop"
                applyPresentation(live, site: "liveDesktopSeek")
            }
            return
        }
        if let offset = snapshot.contiguousOffset(atWallDate: requestedDate) {
            timelineSlider.doubleValue = offset
        }

        // The cursor updates on every event, while callers independently throttle
        // media resolution and resolve the final gesture position.
        if resolvesMedia {
            resolveMoment(at: requestedDate)
        }

    }

    /// Toggles 1x wall-clock playback from the current position.
    ///
    /// The transcript follower and Space key expose this control. Within one
    /// meeting child the player runs continuously as the playhead and transcript
    /// advance; media is resolved again only when ownership changes.
    private func toggleRealTimePlayback() {
      switch playbackReadiness.toggleDecision(
        hasPresentedPlayer: presentedPlayer != nil,
        isActive: realTimePlaybackTimer != nil
      ) {
      case .stop:
        stopRealTimePlayback()
            LibreReverseTimelineTrace.log("PLAYBACK stopped")
            return
      case .ignore:
        LibreReverseTimelineTrace.log("PLAYBACK unavailable")
        return
      case .start:
        break
        }
      guard let currentSeekDate else { return }
      historyBeltClock = nil
      historyBeltFrame = nil
      timelineOverlay.playbackIsAdvancing = true
      seekSourceReducer.playbackStarted()
      dateLabel.isHidden = true
        // Visual position follows the media clock at 60 Hz. Decoding and
        // transcript work have their own lower-frequency gates below.
        let interval = 1.0 / 60.0
        historyPlaybackStep = nil
        playbackTranscriptThrottle = TimelineSeekThrottle()
      realTimePlaybackClock = LibreReverseWallClockPlaybackClock(
        startWallDate: currentSeekDate,
        startUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
      )
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
          guard let self, let clock = self.realTimePlaybackClock,
            self.playbackBoundaryTask == nil else { return }
          let now = DispatchTime.now().uptimeNanoseconds
          if self.activeMeetingSegmentID == nil {
            self.advanceHistoryPlayback(at: now)
            return
          }
          guard self.playbackReadiness.mediaAvailable else { return }
          if self.activeMeetingSegmentID != nil,
            !LibreReverseMeetingPlaybackItemPolicy.shouldAdvanceWallClock(
              playerIsPlaying: self.presentedPlayer?.timeControlStatus == .playing
            )
          {
            if let currentSeekDate = self.currentSeekDate {
              self.realTimePlaybackClock = .init(
                startWallDate: currentSeekDate,
                startUptimeNanoseconds: now
              )
            }
            return
          }
          let next: Date
          if self.activeMeetingSegmentID != nil,
            let start = self.presentedMoment?.segmentStartDate,
            let mediaTime = self.presentedPlayer?.currentTime().seconds,
            mediaTime.isFinite
          {
            // Audio is the clock. A separate wall timer drifts after buffering
            // or an inexact seek, even when persisted word times are correct.
            next = start.addingTimeInterval(max(0, mediaTime))
          } else {
            let elapsed = max(0, clock.wallDate(at: now).timeIntervalSince(clock.startWallDate))
            next = LibreReverseTimelinePlaybackNavigation.advance(
              from: self.currentSeekDate ?? clock.startWallDate,
              elapsed: elapsed, snapshot: self.snapshot)
              ?? clock.wallDate(at: now)
          }
          self.realTimePlaybackClock = .init(startWallDate: next, startUptimeNanoseconds: now)
          self.accumulatedScrollOffset = nil
          if let activeMeetingSegmentID = self.activeMeetingSegmentID {
            if let selection = self.timelineOverlay.snapshot.meetingSelection(
              at: next,
              anchoredBy: activeMeetingSegmentID,
              clampOuterBounds: false
            ) {
              if selection.seekDate != next {
                self.realTimePlaybackClock = .init(
                  startWallDate: selection.seekDate,
                  startUptimeNanoseconds: now
                )
              }
              if selection.segmentID == activeMeetingSegmentID {
                self.seek(
                  to: next,
                  intent: .historical,
                  source: .audioPlayer,
                  resolvesMedia: false,
                  replacesWindow: false,
                  meetingSegmentID: activeMeetingSegmentID,
                  preservesPlayback: true
                )
                if self.playbackTranscriptThrottle.admits(interval: 0.1, now: Date()) {
                  self.transcriptPresentationViews.forEach { $0.updatePlayback(at: next) }
                }
              } else {
                self.seek(
                  to: selection.seekDate,
                  intent: .historical,
                  source: .audioPlayer,
                  meetingSegmentID: selection.segmentID,
                  preservesPlayback: true
                )
              }
              return
            }
            self.continuePlaybackAfterMeeting()
            return
          }

            }
        }
        realTimePlaybackTimer = timer
        timer.resume()
      if activeMeetingSegmentID != nil { presentedPlayer?.play() }
      else { presentedPlayer?.pause() }
      transcriptPresentationViews.forEach { $0.setPlaybackActive(true) }
        LibreReverseTimelineTrace.log("PLAYBACK started from \(currentSeekDate as Any)")
    }

    private func continuePlaybackAfterMeeting() {
      guard let end = presentedMoment?.segmentEndDate else {
        stopRealTimePlayback()
        return
      }
      presentedPlayer?.pause()
      activeMeetingSegmentID = nil
      meetingTranscriptView.clear()
      timelineOverlay.selectedSegmentIDs = []
      transcriptPresentationViews.forEach { $0.setPlaybackActive(false) }
      historyPlaybackStep = nil
      currentSeekDate = end
      timelineOverlay.currentDate = end
      // Resume frame-based history at the boundary, not at the last audio
      // anchor (which can be minutes earlier than the end of the meeting).
      historyBeltClock = nil
      historyBeltFrame = nil
      if playbackTimelinePresentation == nil { prepareNextHistoryStep(after: end) }
    }

    private func advanceHistoryPlayback(at uptime: UInt64) {
      if let presentation = playbackTimelinePresentation {
        advanceHistoryBelt(at: uptime, presentation: presentation)
        return
      }
      guard playbackReadiness.mediaAvailable else { return }
      guard let step = historyPlaybackStep else {
        guard let date = currentSeekDate else { return }
        prepareNextHistoryStep(after: date)
        return
      }
      let date: Date
      if playbackTimelinePresentation != nil {
        date = step.wallDate(at: uptime)
      } else if let start = snapshot.contiguousOffset(atWallDate: step.start),
        let end = snapshot.contiguousOffset(atWallDate: step.end), end > start {
        date = snapshot.wallDate(atContiguousOffset:
          start + (end - start) * step.fraction(at: uptime)) ?? step.wallDate(at: uptime)
      } else {
        date = step.wallDate(at: uptime)
      }
      currentSeekDate = date
      timelineOverlay.currentOffsetOverride = nil
      timelineOverlay.currentDate = date
      if let offset = snapshot.contiguousOffset(atWallDate: date) {
        timelineSlider.doubleValue = offset
      }
      guard step.isComplete(at: uptime) else { return }
      historyPlaybackStep = nil
      seek(to: step.end, intent: .historical, source: .audioPlayer,
        preservesPlayback: true)
    }

    private func advanceHistoryBelt(at uptime: UInt64, presentation: PlaybackTimelinePresentation) {
      guard let current = currentSeekDate else { return }
      if !archivePlaceholder.isHidden {
        historyBeltClock = .init(startWallDate: current, startUptimeNanoseconds: uptime)
        return
      }
      if historyBeltClock == nil {
        historyBeltClock = .init(startWallDate: current, startUptimeNanoseconds: uptime)
      }
      guard let clock = historyBeltClock else { return }
      let elapsed = Double(uptime - clock.startUptimeNanoseconds) / 1_000_000_000
      guard let position = TimelineBeltPlayback.position(from: clock.startWallDate,
        elapsed: elapsed, snapshot: presentation.snapshot) else { return }
      if let meetingID = position.meetingID {
        historyBeltClock = nil
        historyBeltFrame = nil
        seek(to: position.date, intent: .historical, source: .audioPlayer,
          replacesWindow: false, meetingSegmentID: meetingID, preservesPlayback: true)
        return
      }
      currentSeekDate = position.date
      timelineOverlay.currentOffsetOverride = nil
      timelineOverlay.currentDate = position.date
      // Media work follows the belt; decoding completion never restarts its
      // clock or adds dead time between quarter-second history beats.
      if let frame = TimelineBeltPlayback.frame(at: position.date, dates: presentation.frameDates),
        frame >= clock.startWallDate, frame != historyBeltFrame {
        historyBeltFrame = frame
        resolveMoment(at: frame)
      }
      guard position.reachedWindowEdge else { return }
      if loadedGlobalSeekInterval.map({ position.date >= $0.end }) == true {
        stopRealTimePlayback()
        return
      }
      // Genuine paging waits hold position, then resume without a catch-up burst.
      historyBeltClock = nil
      playbackBoundaryTask = Task { [weak self] in
        guard let self else { return }
        await self.preparePlaybackTimeline(around: position.date)
        guard !Task.isCancelled else { return }
        self.playbackBoundaryTask = nil
        if self.playbackTimelinePresentation?.interval == presentation.interval {
          self.stopRealTimePlayback()
        }
      }
    }

    private func prepareNextHistoryStep(after date: Date) {
      guard playbackBoundaryTask == nil else { return }
      playbackBoundaryTask = Task { [weak self] in
        guard let self else { return }
        do {
          let moment = try await self.librarySession.neighbourMoment(of: date, forward: true)
          guard !Task.isCancelled, self.realTimePlaybackTimer != nil else { return }
          // A meeting start is an explicit boundary even if its anchor frame
          // is missing or another frame shares its timestamp.
          let meetingStart = self.timelineOverlay.snapshot.rawAudioSegments
            .filter { $0.startDate > date }.map(\.startDate).min()
          guard let target = LibreReverseHistoryPlaybackStep.nextDate(
            after: date, frameDate: moment?.wallDate, meetingStart: meetingStart)
          else {
            self.stopRealTimePlayback()
            return
          }
          if let presentation = self.playbackTimelinePresentation,
            !presentation.contains(target) {
            // Hold the current recorded surface while preparing the next visual
            // window. This fetch never publishes to the navigation pager.
            await self.preparePlaybackTimeline(around: target)
            guard !Task.isCancelled, self.realTimePlaybackTimer != nil else { return }
          }
          self.playbackBoundaryTask = nil
          self.historyPlaybackStep = .init(start: date, end: target,
            startUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
        } catch {
          guard !Task.isCancelled else { return }
          self.playbackBoundaryTask = nil
          self.stopRealTimePlayback()
          self.dateLabel.stringValue = "Playback paused: the next recording could not be loaded."
          self.dateLabel.isHidden = false
        }
      }
    }

    private func observePlaybackItem(
      _ item: AVPlayerItem,
      presentedBy player: AVPlayer,
      fallbackImage: NSImage?
    ) {
      removePlaybackItemObservers()
      playbackItemGeneration &+= 1
      let generation = playbackItemGeneration
      presentedPlayerItem = item
      presentedPlayerFallbackImage = fallbackImage

      let center = NotificationCenter.default
      let events: [(Notification.Name, LibreReverseMeetingPlaybackItemEvent)] = [
        (AVPlayerItem.didPlayToEndTimeNotification, .ended),
        (AVPlayerItem.playbackStalledNotification, .stalled),
        (AVPlayerItem.failedToPlayToEndTimeNotification, .failed),
      ]
      playbackItemObservers = events.map { name, event in
        center.addObserver(forName: name, object: item, queue: .main) {
          [weak self, weak item, weak player] _ in
          guard let self, let item, let player else { return }
          Task { @MainActor [weak self, weak item, weak player] in
            guard let self, let item, let player else { return }
            self.handlePlaybackItemEvent(
              event,
              item: item,
              player: player,
              generation: generation
            )
          }
        }
      }
    }

    private func removePlaybackItemObservers() {
      for observer in playbackItemObservers {
        NotificationCenter.default.removeObserver(observer)
      }
      playbackItemObservers.removeAll()
      presentedPlayerItem = nil
      presentedPlayerFallbackImage = nil
    }

    private func handlePlaybackItemEvent(
      _ event: LibreReverseMeetingPlaybackItemEvent,
      item: AVPlayerItem,
      player: AVPlayer,
      generation: UInt64
    ) {
      let ownsPresentedItem =
        generation == playbackItemGeneration
        && presentedPlayerItem === item
        && presentedPlayer === player
        && player.currentItem === item
      let followingSelection = activeMeetingSegmentID.flatMap { segmentID in
        snapshot.followingMeetingSelection(
          after: segmentID,
          anchoredBy: segmentID
        )
      }
      switch LibreReverseMeetingPlaybackItemPolicy.action(
        for: event,
        playbackIsActive: realTimePlaybackTimer != nil && activeMeetingSegmentID != nil,
        ownsPresentedItem: ownsPresentedItem,
        followingSelection: followingSelection
      ) {
      case .ignore:
        return
      case .advance(let selection):
        let now = DispatchTime.now().uptimeNanoseconds
        realTimePlaybackClock = .init(
          startWallDate: selection.seekDate,
          startUptimeNanoseconds: now
        )
        seek(
          to: selection.seekDate,
          intent: .historical,
          source: .audioPlayer,
          meetingSegmentID: selection.segmentID,
          preservesPlayback: true
        )
        LibreReverseTimelineTrace.log(
          "PLAYBACK advanced at media end to meeting child \(selection.segmentID)"
        )
      case .stopAtMeetingEnd:
        continuePlaybackAfterMeeting()
      case .pauseForRetry:
        stopRealTimePlayback()
        if let segmentID = activeMeetingSegmentID {
          transcriptPresentationViews.forEach {
            _ = $0.presentPlaybackNotice(.stalled, segmentID: segmentID)
          }
        }
        dateLabel.stringValue =
          "Meeting playback paused while buffering. Press Play to retry."
        dateLabel.isHidden = false
        LibreReverseTimelineTrace.log("PLAYBACK paused after media stall")
      case .stopAndInvalidate:
        let fallbackImage = presentedPlayerFallbackImage
        playbackItemGeneration &+= 1
        removePlaybackItemObservers()
        _ = playerCache.invalidate(item)
        presentPlaybackFailure(
          fallbackImage: fallbackImage,
          message: "Meeting playback stopped because this recording could not continue.",
          noticeKind: .failedDuringPlayback
        )
        LibreReverseTimelineTrace.log(
          "PLAYBACK failed item=\(item.error?.localizedDescription ?? "unknown")"
        )
      }
    }

    private func presentPlaybackFailure(
      fallbackImage: NSImage?,
      message: String,
      noticeKind: LibreReverseMeetingPlaybackNoticeKind
    ) {
      stopRealTimePlayback()
      presentedPlayer = nil
      presentedVideoOutput = nil
      playerView.clear()
      switch LibreReverseMeetingPlaybackItemPolicy.failureSurface(
        hasPersistedStill: fallbackImage != nil
      ) {
      case .persistedStill:
        guard let fallbackImage else { preconditionFailure("policy mismatch") }
        liveImageSourceTag = "failed-media-fallback"
        applyPresentation(
          FrameDetailDisplay.presentation(
            isHidden: false,
            hasVideo: false,
            hasImage: true
          ),
          image: fallbackImage,
          site: "meetingPlaybackFailed"
        )
      case .errorOnly:
        appliedPresentation = nil
        playerView.isHidden = true
        liveImageView.isHidden = true
        liveImageView.image = nil
        frameImageRetention.clear()
        traceSurface("meetingPlaybackFailedWithoutStill")
      }
      setPlaybackMediaAvailable(false)
      if let segmentID = activeMeetingSegmentID {
        transcriptPresentationViews.forEach {
          _ = $0.presentPlaybackNotice(noticeKind, segmentID: segmentID)
        }
      }
      dateLabel.stringValue = message
      dateLabel.isHidden = false
    }

    private func preparePlaybackTimeline(around date: Date, selectionGeneration: UInt64? = nil) async {
      guard primaryReplacementDepth == 0 else { return }
      let replacementGeneration = primaryReplacementGeneration
      do {
        let window = try await loadPlaybackWindow(around: date)
        guard primaryReplacementDepth == 0,
          primaryReplacementGeneration == replacementGeneration,
          !Task.isCancelled,
          selectionGeneration.map({ ownsPresentation($0) && currentSeekDate == date }) ?? true else { return }
        playbackTimelinePresentation = playbackTimelinePresentation?.refreshed(
            window: window, starredDates: allStarredDates
        ) ?? PlaybackTimelinePresentation(window: window, starredDates: allStarredDates)
      } catch {
        // A failed refresh must not replace the display axis with wall time.
        return
      }
      timelineOverlay.currentOffsetOverride = nil
      timelineOverlay.playbackPresentationEnabled = playbackTimelinePresentation != nil
      timelineOverlay.snapshot = playbackTimelinePresentation?.snapshot ?? snapshot
      timelineOverlay.currentDate = currentSeekDate
    }

    private var playbackWindowPadding: TimeInterval {
      max(1, Double(window?.frame.width ?? 1200)
        / LibreReverseTimelinePresentationPolicy.pointsPerSecond(zoomLevel: timelineZoomLevel))
    }

    private func loadPlaybackWindow(around date: Date) async throws -> HistoricalTimelineSegmentWindow {
      try Task.checkCancellation()
      guard primaryReplacementDepth == 0 else { throw CancellationError() }
      let replacementGeneration = primaryReplacementGeneration
      #if DEBUG
      if let interactionTestPlaybackWindow { return try await interactionTestPlaybackWindow(date) }
      #endif
      // A fixed wall-clock page can contain only a few seconds on the compressed
      // display axis. Grow bounded reads until they cover the visible strip plus
      // one screen of lookahead, or reach history whose timing is not local.
      var duration: TimeInterval = 7200
      var result = try await librarySession.timelineWindow(around: date,
        duration: duration, includesPlaybackTiming: true)
      for _ in 0..<3 {
        try Task.checkCancellation()
        guard primaryReplacementDepth == 0,
          primaryReplacementGeneration == replacementGeneration else { throw CancellationError() }
        guard let presentation = PlaybackTimelinePresentation(window: result),
          presentation.needsMoreHistory(around: date, padding: playbackWindowPadding) else { break }
        duration *= 2
        result = try await librarySession.timelineWindow(around: date,
          duration: duration, includesPlaybackTiming: true)
      }
      return result
    }

    private func restoreArchivedSelection(at date: Date) async {
      let generation = presentationGeneration
      await prepareForShardResidencyChange()
      guard ownsPresentation(generation), currentSeekDate == date, !Task.isCancelled else { return }
      await preparePlaybackTimeline(around: date, selectionGeneration: generation)
      guard ownsPresentation(generation), currentSeekDate == date, !Task.isCancelled else { return }
      if !unavailableShards.contains(where: { $0.interval.contains(date) }) {
        resolveMoment(at: date)
      } else {
        archiveResolutionPendingDate = nil
      }
    }

    private var exhaustedPlaybackPrefetchInterval: DateInterval?

    private func refreshPlaybackTimelineIfNeeded(at date: Date, includeBoundary: Bool = false) {
      guard let presentation = playbackTimelinePresentation,
        playbackTimelineRefresh == nil, visualScrollTask == nil else { return }
      let canExtendLeft = date <= presentation.interval.start && loadedGlobalSeekInterval.map { date > $0.start } == true
      let canExtendRight = date >= presentation.interval.end && loadedGlobalSeekInterval.map { date < $0.end } == true
      let needsLookahead = exhaustedPlaybackPrefetchInterval != presentation.interval
        && presentation.needsMoreHistory(around: date, padding: playbackWindowPadding)
      guard !presentation.contains(date) || needsLookahead
        || (includeBoundary && (canExtendLeft || canExtendRight)) else { return }
      let previousInterval = presentation.interval
      playbackTimelineRefresh = Task { [weak self] in
        guard let self else { return }
        await self.preparePlaybackTimeline(around: date)
        guard !Task.isCancelled else { return }
        self.playbackTimelineRefresh = nil
        if self.playbackTimelinePresentation?.interval == previousInterval {
          self.exhaustedPlaybackPrefetchInterval = previousInterval
        } else {
          self.exhaustedPlaybackPrefetchInterval = nil
        }
        if let current = self.currentSeekDate, current != date { self.refreshPlaybackTimelineIfNeeded(at: current) }
      }
    }

    #if DEBUG
    func probeScrollFromFreshLiveFrame(window: HistoricalTimelineSegmentWindow) -> Bool {
      snapshot = .init(rawSegments: window.segments, validSeekInterval: window.validSeekInterval)
      loadedGlobalSeekInterval = window.validSeekInterval
      playbackTimelinePresentation = PlaybackTimelinePresentation(window: window)
      timelineOverlay.snapshot = playbackTimelinePresentation!.snapshot
      timelineOverlay.playbackPresentationEnabled = true
      let end = playbackTimelinePresentation!.interval.end
      currentSeekDate = end.addingTimeInterval(10)
      isAtLiveEdge = true
      pendingVisualScroll = -0.05
      visualScrollLastMediaTime = ProcessInfo.processInfo.systemUptime
      drainVisualScroll()
      let moved = currentSeekDate! < end && !isAtLiveEdge && visualScrollTask == nil
      // Captures can advance canonical bounds ahead of an in-flight window.
      loadedGlobalSeekInterval = DateInterval(start: window.validSeekInterval!.start,
        end: end.addingTimeInterval(20))
      pendingVisualScroll = 1
      drainVisualScroll()
      let caughtUp = isAtLiveEdge && pendingVisualScroll == 0 && visualScrollTask == nil
      dismiss()
      return moved && caughtUp
    }

    func probeHistoryBelt(window: HistoricalTimelineSegmentWindow) -> [Double] {
      snapshot = .init(rawSegments: window.segments, validSeekInterval: window.validSeekInterval)
      loadedGlobalSeekInterval = window.validSeekInterval
      playbackTimelinePresentation = PlaybackTimelinePresentation(window: window)
      timelineOverlay.snapshot = playbackTimelinePresentation!.snapshot
      timelineOverlay.playbackPresentationEnabled = true
      archivePlaceholder.isHidden = true
      let start = window.segments[0].startDate
      currentSeekDate = start
      historyBeltClock = .init(startWallDate: start, startUptimeNanoseconds: 0)
      setPlaybackMediaAvailable(false)
      return [0.0, 0.1, 0.2, 0.3, 0.4].map { elapsed in
        let target = TimelineBeltPlayback.position(from: start, elapsed: elapsed,
            snapshot: playbackTimelinePresentation!.snapshot)!.date
        historyBeltFrame = TimelineBeltPlayback.frame(at: target, dates: playbackTimelinePresentation!.frameDates)
        advanceHistoryPlayback(at: UInt64(elapsed * 1_000_000_000))
        return timelineOverlay.snapshot.contiguousOffset(atWallDate: currentSeekDate!)!
      }
    }

    func probeShortcutPlaybackScale(window: HistoricalTimelineSegmentWindow) -> [Bool] {
      loadedRawSegments = window.segments
      loadedGlobalSeekInterval = window.validSeekInterval
      snapshot = .init(rawSegments: window.segments, validSeekInterval: window.validSeekInterval)
      playbackTimelinePresentation = PlaybackTimelinePresentation(window: window)
      timelineOverlay.playbackPresentationEnabled = playbackTimelinePresentation != nil
      timelineOverlay.snapshot = playbackTimelinePresentation?.snapshot ?? snapshot
      var values = [timelineOverlay.playbackPresentationEnabled]
      let end = window.validSeekInterval!.end
      seek(to: end, intent: .live, source: .isInitialLoad, resolvesMedia: false, replacesWindow: false)
      values.append(timelineOverlay.playbackPresentationEnabled)
      let date = window.segments[0].startDate
      seek(to: date, intent: .historical, source: .scroll, resolvesMedia: false, replacesWindow: false)
      values.append(timelineOverlay.playbackPresentationEnabled)
      presentedPlayer = AVPlayer()
      setPlaybackMediaAvailable(true)
      toggleRealTimePlayback()
      values.append(timelineOverlay.playbackPresentationEnabled && realTimePlaybackTimer != nil)
      stopRealTimePlayback()
      values.append(timelineOverlay.playbackPresentationEnabled)
      return values
    }
    #endif

    private func stopRealTimePlayback() {
      // Playback owns only the clock/player. It must never reset timeline
      // geometry, including when a shortcut first seeks to the live edge.
      timelineOverlay.playbackIsAdvancing = false
      realTimePlaybackTimer?.cancel()
      realTimePlaybackTimer = nil
      realTimePlaybackClock = nil
      historyBeltClock = nil
      historyBeltFrame = nil
      playbackBoundaryTask?.cancel()
      playbackBoundaryTask = nil
      historyPlaybackStep = nil
      presentedPlayer?.pause()
      transcriptPresentationViews.forEach { $0.setPlaybackActive(false) }
    }

    private func setPlaybackMediaAvailable(_ available: Bool) {
      if available {
        playbackReadiness.mediaDidBecomeReady()
      } else {
        playbackReadiness.invalidate()
      }
      transcriptPresentationViews.forEach { $0.setPlaybackAvailable(available) }
      if available,
        let pendingPinnedPlaybackSegmentID,
        pendingPinnedPlaybackSegmentID == activeMeetingSegmentID
      {
        self.pendingPinnedPlaybackSegmentID = nil
        toggleRealTimePlayback()
      }
      if available { beginPlaybackFixtureProofIfNeeded() }
    }

    private func beginPlaybackFixtureProofIfNeeded() {
      guard playbackFixtureStatusURL != nil,
        !playbackFixtureDidStart,
        let player = presentedPlayer,
        let mediaURL = playbackFixtureMediaURL
      else { return }
      playbackFixtureDidStart = true
      player.isMuted = true
      pinMeetingTranscript()
      toggleRealTimePlayback()
      let startingTime = player.currentTime().seconds
      Task { [weak self, weak player] in
        guard let self, let player else { return }
        var advanced = false
        for _ in 0..<25 {
          try? await Task.sleep(nanoseconds: 200_000_000)
          let current = player.currentTime().seconds
          if current.isFinite, startingTime.isFinite, current > startingTime + 0.2 {
            advanced = true
            break
          }
        }
        let asset = AVURLAsset(
          url: mediaURL,
          options: [
            LibreReversePlayerCache.outOfBandMIMETypeKey:
              LibreReversePlayerCache.outOfBandMIMEType
          ]
        )
        let audioTrackCount =
          (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
        guard self.playbackFixtureDidStart else { return }
        self.writePlaybackFixtureStatus(
          phase: advanced && audioTrackCount > 0 ? "passed" : "failed",
          playerAdvanced: advanced,
          audioTrackCount: audioTrackCount
        )
        if self.timelineActionsFixtureStatusURL != nil {
          // The playback fixture first proves that real A/V advances. The
          // timeline-actions extension then needs a stable decoded frame;
          // otherwise the eight-second sample can reach EOF while an external
          // UI driver is opening the menu, making image actions race between
          // enabled and disabled states.
          self.stopRealTimePlayback()
          await player.seek(
            to: CMTime(seconds: 1, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
          )
          if let wallDate = self.presentedMoment?.wallDate {
            self.currentSeekDate = wallDate
            self.timelineOverlay.currentDate = wallDate
          }
          try? await Task.sleep(nanoseconds: 300_000_000)
          self.writeTimelineActionsFixtureStatus(
            event: "actionsReady",
            moment: self.presentedMoment
          )
        }
      }
    }

    private func writePlaybackFixtureStatus(
      phase: String,
      playerAdvanced: Bool,
      audioTrackCount: Int
    ) {
      guard let playbackFixtureStatusURL else { return }
      let payload: [String: Any] = [
        "phase": phase,
        "mode": playbackFixtureRemoteOnly ? "remote" : "local",
        "mediaExists": playbackFixtureMediaURL.map {
          FileManager.default.fileExists(atPath: $0.path)
        } ?? false,
        "mediaReady": playbackReadiness.mediaAvailable,
        "playerAdvanced": playerAdvanced,
        "audioTrackCount": audioTrackCount,
        "pinned": pinnedTranscriptWindow != nil,
        "muted": presentedPlayer?.isMuted == true,
        "playerRate": presentedPlayer?.rate ?? -1,
        "playerStatus": presentedPlayer.map { String(describing: $0.status) } ?? "missing",
        "itemStatus": presentedPlayer?.currentItem.map {
          String(describing: $0.status)
        } ?? "missing",
        "timeControlStatus": presentedPlayer.map {
          String(describing: $0.timeControlStatus)
        } ?? "missing",
        "currentMediaTime": presentedPlayer.map {
          $0.currentTime().seconds.isFinite ? $0.currentTime().seconds : -1
        } ?? -1,
        "waitReason": presentedPlayer?.reasonForWaitingToPlay?.rawValue ?? "",
      ]
      guard let data = try? JSONSerialization.data(
        withJSONObject: payload,
        options: [.prettyPrinted, .sortedKeys]
      ) else { return }
      try? data.write(to: playbackFixtureStatusURL, options: .atomic)
    }

    private func writeTimelineActionsFixtureStatus(
      event: String,
      moment: HistoricalTimelineMoment?,
      starredOverride: Bool? = nil
    ) {
      guard let timelineActionsFixtureStatusURL else { return }
      var payload: [String: Any] = [
        "event": event,
        "windowVisible": window?.isVisible == true,
        "currentSeekTimestamp": currentSeekDate?.timeIntervalSince1970 ?? -1,
      ]
      if let moment {
        payload["frameID"] = moment.frameID
        payload["wallTimestamp"] = moment.wallDate.timeIntervalSince1970
        payload["starred"] = starredOverride ?? isMomentStarred(moment.wallDate)
        payload["mediaExists"] = moment.chunkURL.map {
          FileManager.default.fileExists(atPath: $0.path)
        } ?? false
      }
      guard let data = try? JSONSerialization.data(
        withJSONObject: payload,
        options: [.prettyPrinted, .sortedKeys]
      ) else { return }
      try? data.write(to: timelineActionsFixtureStatusURL, options: .atomic)
    }

    private var transcriptPresentationViews: [LibreReverseMeetingTranscriptView] {
      var views = [meetingTranscriptView]
      if let pinned = pinnedTranscriptWindow?.transcriptView {
        views.append(pinned)
      }
      return views
    }

    private func presentMeetingTranscript(
      _ transcript: LibreReverseMeetingTranscript?,
      at date: Date
    ) {
      meetingTranscriptView.present(transcript, at: date)
      retainedCompleteTranscriptID = transcript?.processingState == .complete ? transcript?.segmentID : nil
      if pinnedTranscriptWindow != nil || meetingTranscriptIsScrubbing {
        meetingTranscriptView.isHidden = true
      }
    }

    private func cancelMeetingTranscriptWork() {
        meetingTranscriptRevision &+= 1
        meetingTranscriptSettleTask?.cancel()
        meetingTranscriptSettleTask = nil
        meetingTranscriptLoadTask?.cancel()
        meetingTranscriptLoadTask = nil
        lastMeetingTranscriptRequest = nil
        meetingTranscriptIsScrubbing = false
    }

    private func transcriptTarget(at date: Date) -> (segmentID: Int64, mediaDate: Date)? {
        let rawID = activeMeetingSegmentID ?? timelineOverlay.snapshot.rawAudioSegments.last {
            $0.startDate <= date && date < $0.endDate
        }?.rawID
        guard let rawID else { return nil }
        let selection = timelineOverlay.snapshot.meetingSelection(at: date,
            anchoredBy: rawID, clampOuterBounds: false)
        return (selection?.segmentID ?? rawID, selection?.seekDate ?? date)
    }

    private func prepareMeetingTranscriptForSeek(
        at date: Date, source: SeekPositionUpdateSource, isLive: Bool
    ) {
        guard !isLive, let target = transcriptTarget(at: date) else {
            cancelMeetingTranscriptWork()
            meetingTranscriptView.clear()
            return
        }
        if source == .scroll || source == .drag {
            // Keep the existing text/selection intact while hiding the floating
            // reader once per gesture. Decode seeks must not flash or reload it.
            cancelMeetingTranscriptWork()
            meetingTranscriptIsScrubbing = true
            meetingTranscriptView.isHidden = true
            let revision = meetingTranscriptRevision
            meetingTranscriptSettleTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                guard let self, !Task.isCancelled,
                      self.meetingTranscriptRevision == revision,
                      self.window?.isVisible == true,
                      self.currentSeekDate == date, !self.isAtLiveEdge else { return }
                self.meetingTranscriptIsScrubbing = false
                self.requestMeetingTranscript(segmentID: target.segmentID,
                    mediaDate: target.mediaDate, cursorDate: date)
            }
        } else {
            cancelMeetingTranscriptWork()
            revealRetainedTranscript(segmentID: target.segmentID, at: target.mediaDate)
        }
    }

    private func revealRetainedTranscript(segmentID: Int64, at date: Date) {
        guard meetingTranscriptView.presentedSegmentID == segmentID else {
            meetingTranscriptView.isHidden = true
            return
        }
        meetingTranscriptView.updatePlayback(at: date)
        meetingTranscriptView.isHidden = pinnedTranscriptWindow != nil || meetingTranscriptIsScrubbing
    }

    private func requestMeetingTranscript(segmentID: Int64, mediaDate: Date, cursorDate: Date) {
        guard !meetingTranscriptIsScrubbing, currentSeekDate == cursorDate else { return }
        revealRetainedTranscript(segmentID: segmentID, at: mediaDate)
        if retainedCompleteTranscriptID == segmentID,
           meetingTranscriptView.presentedSegmentID == segmentID { return }
        if lastMeetingTranscriptRequest?.segmentID == segmentID,
           lastMeetingTranscriptRequest?.cursorDate == cursorDate { return }
        meetingTranscriptLoadTask?.cancel()
        meetingTranscriptRevision &+= 1
        let revision = meetingTranscriptRevision
        lastMeetingTranscriptRequest = (segmentID, cursorDate)
        meetingTranscriptLoadTask = Task { [weak self] in
            guard let self else { return }
            var transcript = try? await self.readMeetingTranscript(segmentID: segmentID, at: mediaDate)
            if let job = try? self.transcriptionQueue.job(segmentID: segmentID) {
                transcript = transcript?.updatingProcessingState(job.processingState(at: Date()))
            }
            guard !Task.isCancelled, self.meetingTranscriptRevision == revision,
                  self.currentSeekDate == cursorDate, !self.meetingTranscriptIsScrubbing else { return }
            self.presentMeetingTranscript(transcript, at: mediaDate)
        }
    }

    private func readMeetingTranscript(segmentID: Int64, at date: Date) async throws -> LibreReverseMeetingTranscript? {
        #if DEBUG
        if let interactionTestMeetingTranscript { return try await interactionTestMeetingTranscript(segmentID, date) }
        #endif
        return try await librarySession.meetingTranscript(segmentID: segmentID, at: date)
    }

    private func pinMeetingTranscript() {
      guard pinnedTranscriptWindow == nil,
        meetingTranscriptView.presentedSegmentID != nil
      else { return }
      let pinnedView = LibreReverseMeetingTranscriptView(frame: .zero)
      configurePinnedTranscriptView(pinnedView)
      guard meetingTranscriptView.copyPresentation(to: pinnedView) else { return }
      pinnedView.setPinned(true)
      let controller = LibreReversePinnedTranscriptWindowController(
        transcriptView: pinnedView
      )
      controller.onWindowClosed = { [weak self] in
        guard let self else { return }
        self.pinnedTranscriptWindow = nil
        self.pendingPinnedPlaybackSegmentID = nil
        self.meetingTranscriptView.setPinned(false)
        self.meetingTranscriptView.isHidden =
          self.meetingTranscriptView.presentedSegmentID == nil
        self.dismiss()
      }
      pinnedTranscriptWindow = controller
      meetingTranscriptView.setPinned(true)
      meetingTranscriptView.isHidden = true
      controller.present()
    }

    private func configurePinnedTranscriptView(
      _ view: LibreReverseMeetingTranscriptView
    ) {
      view.onWordSeek = { [weak self] date, segmentID in
        self?.seek(
          to: date,
          intent: .historical,
          source: .click,
          meetingSegmentID: segmentID
        )
      }
      view.onTextSelectionBegan = { [weak self] in
        self?.stopRealTimePlayback()
      }
      view.onTogglePlayback = { [weak self, weak view] in
        guard let self, let view,
          let segmentID = view.presentedSegmentID,
          let date = view.presentedDate
        else { return }
        if self.activeMeetingSegmentID == segmentID {
          self.toggleRealTimePlayback()
        } else {
          self.pendingPinnedPlaybackSegmentID = segmentID
          self.seek(
            to: date,
            intent: .historical,
            source: .audioPlayer,
            meetingSegmentID: segmentID
          )
        }
      }
      view.onRetryPlayback = { [weak self, weak view] segmentID in
        guard let self, let date = view?.presentedDate else { return }
        self.pendingPinnedPlaybackSegmentID = segmentID
        self.seek(
          to: date,
          intent: .historical,
          source: .audioPlayer,
          meetingSegmentID: segmentID
        )
      }
      view.onDelete = meetingDeletionHandler
      view.onRename = meetingTitleUpdateHandler
      view.onUpdateContext = meetingContextUpdateHandler
      view.onRetryTranscription = meetingTranscriptionRetryHandler
      view.onTogglePin = { [weak self] in
        self?.unpinMeetingTranscript()
      }
      view.onTranscriptCleared = { [weak self] in
        self?.unpinMeetingTranscript()
      }
    }

    private func unpinMeetingTranscript() {
      guard let controller = pinnedTranscriptWindow else { return }
      pendingPinnedPlaybackSegmentID = nil
      controller.closeWithoutCallback()
      pinnedTranscriptWindow = nil
      meetingTranscriptView.setPinned(false)
      meetingTranscriptView.isHidden = meetingTranscriptView.presentedSegmentID == nil
      window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }

    /// Steps exactly one stored frame without scroll physics, throttling,
    /// or a window refetch.
    @discardableResult
    private func stepOneFrame(forward: Bool) -> Task<Void, Never> {
        let anchor = currentSeekDate ?? snapshot.validSeekInterval?.end ?? Date()
        let publicationGeneration = windowPublicationGeneration
        let mediaGeneration = presentationGeneration
        return Task { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            let neighbour = try? await self.readNeighbourMoment(of: anchor, forward: forward)
            guard self.window?.isVisible == true,
                  self.ownsWindowPublication(publicationGeneration),
                  self.ownsPresentation(mediaGeneration), !Task.isCancelled else { return }
            guard let neighbour else {
                LibreReverseTimelineTrace.log(
                    "STEP \(forward ? "next" : "prev") from=\(anchor) -> none"
                )
                return
            }
            LibreReverseTimelineTrace.log(
                "STEP \(forward ? "next" : "prev") from=\(anchor) -> \(neighbour.wallDate) "
                    + "video=\(neighbour.chunkURL != nil) frameIndex="
                    + "\(neighbour.videoFrameIndex.map(String.init) ?? "nil")"
            )
            self.accumulatedScrollOffset = nil
            self.seek(to: neighbour.wallDate, intent: .historical, source: .keyboardShortcut)
        }
    }

    private func readNeighbourMoment(of date: Date, forward: Bool) async throws -> HistoricalTimelineMoment? {
        #if DEBUG
        if let interactionTestNeighbourMoment { return try await interactionTestNeighbourMoment(date, forward) }
        #endif
        return try await librarySession.neighbourMoment(of: date, forward: forward)
    }

    private func jumpToLiveEdge() {
        guard let end = loadedGlobalSeekInterval?.end else { return }
        seek(
            to: end,
            intent: .live,
            source: .jumpToEnd
        )
    }

    private func presentTimelineActionsMenu() {
      let menu = NSMenu(title: "Moment Actions")
      menu.autoenablesItems = false

      func add(
        _ title: String,
        action: Selector,
        enabled: Bool = true,
        keyEquivalent: String = ""
      ) {
        let item = NSMenuItem(
          title: title,
          action: action,
          keyEquivalent: keyEquivalent
        )
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
      }

      if let action = timelineOverlay.contextualOpenAction {
        add("Open in \(action.application.fallbackDisplayName)",
            action: #selector(openCurrentContextFromMenu))
        menu.addItem(.separator())
      }
      let hasImage = currentMomentImage() != nil
      if allowsLibraryMutations, let presentedMoment {
        add(
          isMomentStarred(presentedMoment.wallDate) ? "Unstar Moment" : "Star Moment",
          action: #selector(toggleCurrentMomentStar),
          keyEquivalent: "s"
        )
        menu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
      }
      add(
        "Save Moment as PNG…",
        action: #selector(saveCurrentMomentImage),
        enabled: hasImage
      )
      add(
        "Copy Moment to Clipboard",
        action: #selector(copyCurrentMomentImage),
        enabled: hasImage,
        keyEquivalent: "c"
      )
      menu.items.last?.keyEquivalentModifierMask = [.command, .shift]
      add(
        "Copy Moment Deeplink",
        action: #selector(copyCurrentMomentDeepLink),
        enabled: currentSeekDate != nil
      )
      menu.addItem(.separator())
      add(
        "Reset Timeline Zoom",
        action: #selector(resetTimelineZoom),
        enabled: timelineOverlay.zoomLevel != TimelineLayout.defaultZoomLevel
      )
      if loadedGlobalSeekInterval?.end != nil, !isAtLiveEdge {
        add("Jump to Now", action: #selector(jumpToLiveFromMenu))
      }
      if screenCaptureToggleHandler != nil {
        menu.addItem(.separator())
        add(
          screenCaptureIsPaused?() == true ? "Resume Screen Capture" : "Pause Screen Capture",
          action: #selector(toggleScreenCaptureFromTimeline)
        )
      }
      if openSettingsHandler != nil {
        menu.addItem(.separator())
        add("Settings…", action: #selector(openSettingsFromTimeline))
      }

      // The overflow control sits against the display's bottom edge. Move the
      // menu's ordinary first-item anchor up by its rendered height so the
      // complete surface grows upward without preselecting a destructive or
      // navigational action.
      let anchor = timelineOverlay.overflowMenuAnchor
      let upwardAnchor = NSPoint(x: anchor.x, y: anchor.y + menu.size.height)
      menu.popUp(
        positioning: nil,
        at: upwardAnchor,
        in: timelineOverlay
      )
    }

    @objc private func openCurrentContextFromMenu() {
      guard let action = timelineOverlay.contextualOpenAction else { return }
      openContext(action)
    }

    @objc private func copyCurrentMomentImage() {
      guard let image = currentMomentImage(), let data = pngData(for: image) else {
        showTimelineActionFeedback("This moment is not available yet")
        return
      }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setData(data, forType: .png)
      if let tiff = image.tiffRepresentation {
        pasteboard.setData(tiff, forType: .tiff)
      }
      showTimelineActionFeedback("Moment copied")
      writeTimelineActionsFixtureStatus(event: "imageCopied", moment: presentedMoment)
    }

    @objc private func saveCurrentMomentImage() {
      guard let image = currentMomentImage(), let data = pngData(for: image) else {
        showTimelineActionFeedback("This moment is not available yet")
        return
      }
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.png]
      panel.canCreateDirectories = true
      panel.isExtensionHidden = false
      panel.nameFieldStringValue = suggestedMomentImageName()
      let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
        guard response == .OK, let destination = panel.url else { return }
        do {
          try data.write(to: destination, options: .atomic)
          self?.showTimelineActionFeedback("Moment saved")
          self?.writeTimelineActionsFixtureStatus(
            event: "imageSaved",
            moment: self?.presentedMoment
          )
        } catch {
          self?.showTimelineActionFeedback("Could not save moment")
        }
      }
      if let window {
        panel.beginSheetModal(for: window, completionHandler: completion)
      } else {
        completion(panel.runModal())
      }
    }

    @objc private func copyCurrentMomentDeepLink() {
      // During A/V playback the seek clock can advance past the most recently
      // decoded/presented persisted frame. A shared moment must identify what
      // the user can actually see, not a newer timer value.
      guard let date = presentedMoment?.wallDate ?? currentSeekDate,
        let url = MomentDeepLink.url(for: date)
      else {
        showTimelineActionFeedback("No moment selected")
        return
      }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      let item = NSPasteboardItem()
      item.setString(url.absoluteString, forType: .string)
      item.setString(url.absoluteString, forType: .URL)
      pasteboard.writeObjects([item])
      showTimelineActionFeedback("Moment link copied")
      writeTimelineActionsFixtureStatus(event: "deepLinkCopied", moment: presentedMoment)
    }

    @objc private func resetTimelineZoom() {
      timelineOverlay.resetZoom()
      showTimelineActionFeedback("Timeline zoom reset")
    }

    @objc private func jumpToLiveFromMenu() {
      jumpToLiveEdge()
    }

    @objc private func toggleScreenCaptureFromTimeline() {
      screenCaptureToggleHandler?()
      showTimelineActionFeedback(
        screenCaptureIsPaused?() == true
          ? "Screen capture paused"
          : "Screen capture resumed"
      )
    }

    @objc private func openSettingsFromTimeline() {
      openSettingsHandler?()
    }

    @objc func toggleCurrentMomentStar() {
      guard allowsLibraryMutations else {
        showTimelineActionFeedback("Read-only validation mode")
        return
      }
      guard let moment = presentedMoment else {
        if presentedMoment == nil {
          showTimelineActionFeedback("Select a saved moment to star")
        }
        return
      }
      setCurrentMomentStarred(!isMomentStarred(moment.wallDate))
    }

    func starCurrentMomentFromShortcut() {
      guard allowsLibraryMutations else {
        showTimelineActionFeedback("Read-only validation mode")
        return
      }
      guard presentedMoment != nil else {
        showTimelineActionFeedback("Select a saved moment to star")
        return
      }
      setCurrentMomentStarred(true)
    }

    private func setCurrentMomentStarred(_ targetState: Bool) {
      guard !mutationAdmissionClosed, allowsLibraryMutations, starMutationTask == nil,
        let moment = presentedMoment
      else { return }
      if isMomentStarred(moment.wallDate) == targetState {
        showTimelineActionFeedback(targetState ? "Moment already starred" : "Star already removed")
        return
      }
      let configuration = libraryConfiguration
      showTimelineActionFeedback(targetState ? "Starring moment…" : "Removing star…")
      starMutationTask = Task { @MainActor [weak self] in
        do {
          guard let self else { return }
          let mutation = try await self.mutationLifetime.perform {
            #if DEBUG
            if let write = self.interactionTestStarMutation {
              return try await write(moment.frameID, moment.wallDate, targetState)
            }
            #endif
            return try await Task.detached(priority: .userInitiated) {
              try LibreReverseLibraryStore.setFrameStarred(
                frameID: moment.frameID,
                wallDate: moment.wallDate,
                isStarred: targetState,
                configuration: configuration
              )
            }.value
          }
          if mutation.isStarred {
            if !self.isMomentStarred(mutation.wallDate) {
              self.allStarredDates.append(mutation.wallDate)
            }
          } else {
            self.allStarredDates.removeAll {
              abs($0.timeIntervalSince(mutation.wallDate)) < 0.0005
            }
          }
          self.rebuildWindowSnapshot()
          self.starRefreshSubject.send()
          self.showTimelineActionFeedback(
            mutation.isStarred ? "Moment starred" : "Star removed"
          )
          self.writeTimelineActionsFixtureStatus(
            event: mutation.isStarred ? "starred" : "unstarred",
            moment: self.presentedMoment,
            starredOverride: mutation.isStarred
          )
        } catch {
          self?.showTimelineActionFeedback("Could not update star")
        }
        self?.starMutationTask = nil
      }
    }

    private func isMomentStarred(_ date: Date) -> Bool {
      allStarredDates.contains { abs($0.timeIntervalSince(date)) < 0.0005 }
    }

    private func currentMomentImage() -> NSImage? {
      if isAtLiveEdge, let latestLiveFrameImage {
        return latestLiveFrameImage
      }
      if !playerView.isHidden, let output = presentedVideoOutput, let player = presentedPlayer {
        var displayTime = CMTime.invalid
        if let buffer = output.copyPixelBuffer(
          forItemTime: player.currentTime(),
          itemTimeForDisplay: &displayTime
        ) {
          var cgImage: CGImage?
          if VTCreateCGImageFromCVPixelBuffer(
            buffer,
            options: nil,
            imageOut: &cgImage
          ) == noErr, let cgImage {
            return NSImage(cgImage: cgImage, size: .zero)
          }
        }
      }
      return liveImageView.isHidden ? nil : liveImageView.image
    }

    private func pngData(for image: NSImage) -> Data? {
      guard let cgImage = Self.cgImage(from: image) else { return nil }
      let representation = NSBitmapImageRep(cgImage: cgImage)
      return representation.representation(using: .png, properties: [:])
    }

    private func suggestedMomentImageName() -> String {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
      return "LibreReverse Moment \(formatter.string(from: currentSeekDate ?? Date())).png"
    }

    private func showTimelineActionFeedback(_ message: String) {
      timelineActionFeedbackTask?.cancel()
      dateLabel.stringValue = message
      dateLabel.isHidden = false
      timelineActionFeedbackTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        guard !Task.isCancelled else { return }
        self?.dateLabel.isHidden = true
      }
    }

    private func replaceWindow(
        around date: Date,
        intent: SeekIntent,
        source: SeekPositionUpdateSource
    ) {
        let publicationGeneration = beginWindowTransaction()
        let recordingRevisionAtFetch = recordingPublicationRevision
        let session = librarySession
        // `fetchNewSegments` computes a fresh zoom-derived request duration.
        // It does not reuse SegmentsManager's actual returned duration; that
        // value belongs exclusively to the stationary recording-refetch path.
        let duration = TimelineLayout.interactiveFetchWindowDuration(
            zoomLevel: timelineZoomLevel,
            validSeekDuration: loadedGlobalSeekInterval?.duration,
            lastFastScroll: lastFastScrollEvent
        )
        let fetchesRecent = source == .jumpToEnd || date == loadedGlobalSeekInterval?.end
        LibreReverseTimelineTrace.log(
            "WINDOW request duration=\(duration) recent=\(fetchesRecent) "
                + "lastActual=\(lastFetchedWindowDuration) source=\(source)"
        )
        LibreReverseTimelineTrace.boundary(
            "FETCH source=\(source) recent=\(fetchesRecent) "
                + "anchor=\(date.timeIntervalSince1970) duration=\(duration) "
                + "localStart=\(String(describing: snapshot.processedScreenshotSegments.first?.startDate.timeIntervalSince1970)) "
                + "localEnd=\(String(describing: snapshot.processedScreenshotSegments.last?.endDate.timeIntervalSince1970))"
        )
        windowReplacementTask = Task { [weak self] in
            guard let self else { return }
            do {
                let window: HistoricalTimelineSegmentWindow
                if fetchesRecent {
                    window = try await session.recentTimelineWindow(duration: duration)
                } else {
                    window = try await session.timelineWindow(around: date, duration: duration)
                }
                // A superseded fetch must leave the retained window alone. The
                // replacement task installed by the newer gesture publishes on
                // its own; blanking here would drop the timeline mid-gesture.
                guard self.ownsWindowPublication(publicationGeneration),
            !Task.isCancelled
          else { return }
                publishFetchedWindow(
                    window,
                    fetchedAt: fetchesRecent
                        ? (window.validSeekInterval?.end ?? Date())
                        : date,
                    recordingRevisionAtFetch: recordingRevisionAtFetch
                )
                // The seek position was already applied before this fetch
                // started. Only the derived window coordinates need re-syncing,
                // because the new window renumbers contiguous offsets.
                timelineOverlay.currentDate = currentSeekDate
                if let current = currentSeekDate,
            let offset = snapshot.contiguousOffset(atWallDate: current)
          {
                    timelineSlider.doubleValue = offset
                }
            } catch {
                // Outer failure preserves the prior publication and window.
            }
        }
    }

    /// Invalidates the current media task. Every asynchronous stage carries
    /// this identity so an obsolete query, decode, readiness callback, or seek
    /// completion cannot publish.
    @discardableResult
    private func beginPresentationTransaction() -> UInt64 {
        presentationGeneration &+= 1
      playbackItemGeneration &+= 1
      removePlaybackItemObservers()
        // Clear only the rendered layer. `activeSearchMatch` intentionally
        // survives its target search transaction until that frame's media
        // reaches the generation-gated publication point.
        searchMatchOverlay.clear()
        liveTextOverlay.clear()
        seekTask?.cancel()
        presentationTask?.cancel()
        // Archive transfers are presentation-independent. Moving the cursor
        // only changes which transfer is surfaced; it must never cancel a
        // database or media download already in progress.
        return presentationGeneration
    }

    private func ownsPresentation(_ generation: UInt64) -> Bool {
        primaryReplacementDepth == 0 && generation == presentationGeneration
    }

    private func frameDetailIsHidden(at date: Date?, now: Date = Date()) -> Bool {
      let hasCapturedScreenSegment =
        date.flatMap {
            TrackItemSelection.segment(
                at: $0,
                type: .capturedScreen,
                in: loadedRawSegments
            )
        } != nil
      let frameDetailHidden = FrameDetailVisibility.isHidden(
            segmentType: hasCapturedScreenSegment ? .capturedScreen : nil,
            currentSeekPosition: date,
            now: now
        )
      let hasSelectedMeetingMedia = activeMeetingSegmentID.flatMap { segmentID in
        date.flatMap {
          snapshot.meetingSelection(
            at: $0,
            anchoredBy: segmentID,
            clampOuterBounds: false
          )
        }
      } != nil
      return LibreReverseTimelineSurfaceVisibility.isHidden(
        frameDetailHidden: frameDetailHidden,
        hasSelectedMeetingMedia: hasSelectedMeetingMedia
      )
    }

    @discardableResult
    private func beginWindowTransaction() -> UInt64 {
        windowPublicationGeneration &+= 1
        initialReloadTask?.cancel()
        windowReplacementTask?.cancel()
        stationaryRefreshTask?.cancel()
        return windowPublicationGeneration
    }

    private func ownsWindowPublication(_ generation: UInt64) -> Bool {
        generation == windowPublicationGeneration
    }

    private func loadMoment(at date: Date, meetingSegmentID: Int64?) async throws -> HistoricalTimelineMoment? {
        #if DEBUG
        if let interactionTestResolver { return try await interactionTestResolver(date, meetingSegmentID) }
        #endif
        if let meetingSegmentID {
            return try await librarySession.meetingMoment(segmentID: meetingSegmentID, at: date)
        }
        return try await librarySession.nearestMoment(to: date)
    }

    private func prepareMedia(_ moment: HistoricalTimelineMoment) async -> LibreReversePreparedPersistedMedia {
        #if DEBUG
        if let interactionTestMediaPreparation { return await interactionTestMediaPreparation(moment) }
        #endif
        return await persistedMediaLoader.prepare(moment: moment)
    }

    #if DEBUG
    // These seams replace I/O only. Tests enter the same view callbacks,
    // selection routing, generation checks, and dismissal path as user input.
    var interactionTestResolver: ((Date, Int64?) async throws -> HistoricalTimelineMoment?)?
    var interactionTestNeighbourMoment: ((Date, Bool) async throws -> HistoricalTimelineMoment?)?
    var interactionTestMeetingTranscript: ((Int64, Date) async throws -> LibreReverseMeetingTranscript?)?

    var interactionTestPendingTranscriptLoad: Task<Void, Never>? { meetingTranscriptLoadTask }
    var interactionTestTranscriptSegmentID: Int64? { meetingTranscriptView.presentedSegmentID }
    var interactionTestTranscriptIsHidden: Bool { meetingTranscriptView.isHidden }

    func interactionTestPresentTranscript(_ transcript: LibreReverseMeetingTranscript, at date: Date) {
        presentMeetingTranscript(transcript, at: date)
    }

    func interactionTestScrollTranscript(to date: Date) {
        seek(to: date, intent: .historical, source: .scroll, resolvesMedia: false, replacesWindow: false)
    }

    func interactionTestDrainTranscript() async {
        await meetingTranscriptSettleTask?.value
        await meetingTranscriptLoadTask?.value
    }

    var interactionTestTimelineWindow: ((LibreReverseTimelineReloadRequest, Bool) async throws -> HistoricalTimelineSegmentWindow)?

    var interactionTestLoadedSegmentIDs: [Int64] { loadedRawSegments.map(\.rawID) }

    func interactionTestRefetchStationaryWindow(around date: Date) async {
        lastFetchedWindowDate = date
        refetchStationaryWindow()
        await stationaryRefreshTask?.value
    }

    func interactionTestStepOneFrame(forward: Bool) async {
        await stepOneFrame(forward: forward).value
    }

    func interactionTestDrainReload() async {
        await initialReloadTask?.value
        await interactionTestDrain()
    }

    var interactionTestStarMutation: ((Int64, Date, Bool) async throws -> LibreReverseFrameStarMutation)?
    var interactionTestPendingStarMutation: Task<Void, Never>? { starMutationTask }
    func interactionTestSetStarred(_ value: Bool) { setCurrentMomentStarred(value) }

    var interactionTestArchiveRequest: ((Date, Int64?, Int64?) async throws -> LibreReverseDownloadStatus?)?
    var interactionTestPendingArchiveRequest: Task<Void, Never>? { archiveRequestTask }
    var interactionTestArchiveTitle: String { archivePlaceholderTitle.stringValue }
    func interactionTestOfferArchive(date: Date, ordinal: Int64) {
        _ = beginPresentationTransaction()
        currentSeekDate = date
        showArchivedShardPlaceholder(for: date, ordinal: ordinal)
    }
    func interactionTestRequestArchive() { downloadArchivedDay() }

    var interactionTestDisplayedImage: NSImage? { liveImageView.isHidden ? nil : liveImageView.image }
    var interactionTestExportImage: NSImage? { currentMomentImage() }
    var interactionTestMediaError: String? { dateLabel.isHidden ? nil : dateLabel.stringValue }
    var interactionTestPendingPlaybackRefresh: Task<Void, Never>? { playbackTimelineRefresh }
    func interactionTestRefreshPlayback(at date: Date) { refreshPlaybackTimelineIfNeeded(at: date) }

    var interactionTestMediaPreparation: ((HistoricalTimelineMoment) async -> LibreReversePreparedPersistedMedia)?
    var interactionTestPlaybackWindow: ((Date) async throws -> HistoricalTimelineSegmentWindow)?

    func interactionTestStartHistory(window: HistoricalTimelineSegmentWindow, at date: Date, uptime: UInt64) {
        snapshot = .init(rawSegments: window.segments, validSeekInterval: window.validSeekInterval)
        loadedGlobalSeekInterval = window.validSeekInterval
        playbackTimelinePresentation = PlaybackTimelinePresentation(window: window)
        timelineOverlay.snapshot = playbackTimelinePresentation!.snapshot
        currentSeekDate = date
        isAtLiveEdge = false
        historyBeltClock = .init(startWallDate: date, startUptimeNanoseconds: uptime)
    }

    func interactionTestAdmit(_ frame: LibreReverseAdmittedFrame, at uptime: UInt64) {
        mergeAdmittedScreenSegment(frame, at: uptime)
    }

    func interactionTestAdvanceHistory(at uptime: UInt64) -> Date? {
        advanceHistoryPlayback(at: uptime)
        return currentSeekDate
    }

    func interactionTestRestoreArchive(at date: Date) async {
        currentSeekDate = date
        await restoreArchivedSelection(at: date)
    }

    var interactionTestPresentationInterval: DateInterval? { playbackTimelinePresentation?.interval }

    func interactionTestScrollBeyondEdge(at date: Date, unavailable: HistoricalUnavailableShard) async -> Int64? {
        unavailableShards = [unavailable]
        pendingVisualScroll = -1
        loadVisualScrollWindow(around: date)
        await visualScrollTask?.value
        return pendingArchivedShard?.ordinal
    }

    func interactionTestSelectOCR(_ result: OCRSearchResult, previousMeetingID: Int64? = nil) {
        if let previousMeetingID { activeMeetingSegmentID = previousMeetingID }
        searchResultsView.onSelect?(result)
    }

    var interactionTestSeekDate: Date? { currentSeekDate }
    var interactionTestIsPinnedToEnd: Bool { isAtLiveEdge }

    var interactionTestTranscriptFrame: NSRect {
        window?.contentView?.layoutSubtreeIfNeeded()
        return meetingTranscriptView.frame
    }

    func interactionTestDragTranscript(by delta: NSSize) { meetingTranscriptView.onDrag?(delta) }

    func interactionTestSetSeekUpdatesEnabled(_ enabled: Bool) {
        seekSourceReducer.canUpdateSeekPosition = enabled
    }

    func interactionTestClick(to date: Date) {
        timelineOverlay.onSeekRequest?(.init(date: date, source: .click))
    }

    func interactionTestJumpToNow() {
        timelineOverlay.onJumpToNow?()
    }

    func interactionTestDrag(to dates: [Date]) {
        timelineOverlay.onDragStarted?()
        // Preconsume the throttle so every drag sample exercises the deferred
        // path; completion must still resolve the final date unconditionally.
        _ = boundsSeekThrottle.admits(interval: 1, now: .distantFuture)
        for date in dates {
            timelineOverlay.onSeekRequest?(.init(date: date, source: .drag))
        }
        timelineOverlay.onDragEnded?()
    }

    func interactionTestRetainPinnedTranscript() {
        pinnedTranscriptWindow = LibreReversePinnedTranscriptWindowController(
            transcriptView: LibreReverseMeetingTranscriptView(frame: .zero))
    }

    func interactionTestEscape() {
        (window as? LibreReverseTimelineWindow)?.onEscape?()
    }

    func interactionTestDrain() async {
        await seekTask?.value
        await presentationTask?.value
    }

    func interactionTestTearDown() {
        pinnedTranscriptWindow?.closeWithoutCallback()
        pinnedTranscriptWindow = nil
        dismiss()
    }
    #endif

    private func resolveMoment(at requestedDate: Date) {
        let generation = beginPresentationTransaction()
      setPlaybackMediaAvailable(false)
        if let unavailable = unavailableShards.first(where: {
            $0.interval.contains(requestedDate)
        }) {
            showArchivedShardPlaceholder(for: requestedDate, ordinal: unavailable.ordinal)
            return
        }
        let session = librarySession
      // Ordinary scrubbing enters the continuous meeting recording without
      // requiring a separate click on the audio lane. App switches remain in
      // the recording's pixels rather than selecting unrelated sparse frames.
      let requestedMeetingSegmentID = activeMeetingSegmentID
        ?? timelineOverlay.snapshot.rawAudioSegments.last(where: {
          $0.startDate <= requestedDate && requestedDate < $0.endDate
        })?.rawID
      let meetingSelection = requestedMeetingSegmentID.flatMap {
        timelineOverlay.snapshot.meetingSelection(
          at: requestedDate,
          anchoredBy: $0,
          clampOuterBounds: false
        )
      }
      let resolvedMeetingSegmentID = meetingSelection?.segmentID ?? requestedMeetingSegmentID
      let mediaRequestedDate = meetingSelection?.seekDate ?? requestedDate
      if let resolvedMeetingSegmentID {
        activeMeetingSegmentID = resolvedMeetingSegmentID
      }
        // Select screenshot and audio segments independently from the retained
        // segment list. The global frame query does not define media ownership.
        let selectedScreenshotSegment = TrackItemSelection.segment(
            at: requestedDate,
            type: .capturedScreen,
            in: timelineOverlay.snapshot.processedSegments
        )
      let selectedAudioSegment = TrackItemSelection.segment(
        at: requestedDate,
        type: .audio,
        in: timelineOverlay.snapshot.processedSegments
      )
      let selectedMeetingSegment = resolvedMeetingSegmentID.flatMap { segmentID in
        timelineOverlay.snapshot.processedSegments.first(where: { $0.rawID == segmentID })
      }
        let resolveStart = DispatchTime.now().uptimeNanoseconds
        seekTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<HistoricalTimelineMoment?, Error>
            do {
                try Task.checkCancellation()
          let moment = try await self.loadMoment(
            at: resolvedMeetingSegmentID == nil ? requestedDate : mediaRequestedDate,
            meetingSegmentID: resolvedMeetingSegmentID)
                try Task.checkCancellation()
                if let moment,
                   var match = activeSearchMatch,
            match.frameID == moment.frameID
          {
                    let allNodes = try await session.ocrNodes(
                        frameID: moment.frameID,
                        instant: moment.wallDate
                    )
                    try Task.checkCancellation()
                    match.matchingNodes = FrameTextNodeResolver.matchingNodes(
                        allNodes,
                        offsetString: match.offsetString,
                        primaryText: match.primaryText,
                        otherText: match.otherText
                    )
                    guard self.ownsPresentation(generation),
              self.activeSearchMatch?.documentID == match.documentID
            else { return }
                    self.activeSearchMatch = match
                }
                result = .success(moment)
            } catch {
                result = .failure(error)
            }
            guard self.ownsPresentation(generation), !Task.isCancelled else { return }
        let queryMs =
          Double(
                DispatchTime.now().uptimeNanoseconds &- resolveStart
            ) / 1_000_000
            LibreReverseTimelineTrace.log(
                String(format: "RESOLVE query %.1fms", queryMs)
            )
            switch result {
        case .success(let moment?):
          if activeMeetingSegmentID == nil { meetingTranscriptView.clear() }
                renderDiagnostic(
                    "selected date=\(moment.wallDate) pending=\(moment.isPendingImage) "
                    + "image=\(moment.frameImageURL.lastPathComponent) "
                    + "video=\(moment.chunkURL != nil)"
                )
                show(
                    moment: moment,
            requestedDate: resolvedMeetingSegmentID == nil
              ? requestedDate
              : mediaRequestedDate,
            selectedSegment: activeMeetingSegmentID == nil
              ? selectedScreenshotSegment
              : (selectedMeetingSegment ?? selectedAudioSegment),
                    generation: generation
                )
          // Submit the video seek before querying the transcript so a long word
          // list cannot delay each scrubbed frame.
          if let resolvedMeetingSegmentID {
            requestMeetingTranscript(segmentID: resolvedMeetingSegmentID,
                mediaDate: mediaRequestedDate, cursorDate: requestedDate)
          }
            case .success(nil):
          if resolvedMeetingSegmentID != nil {
            activeMeetingSegmentID = nil
            setPlaybackMediaAvailable(false)
          }
          meetingTranscriptView.clear()
                renderDiagnostic("selected no moment")
                // Retain the current surface while loading across a gap without a
                // nearby frame, preventing an empty flash during scrubbing.
                applyPresentation(
                    FrameDetailDisplay.presentation(
                        isHidden: false,
                        hasVideo: false,
                        hasImage: false
                    ),
                    site: "noMoment"
                )
        case .failure(let error):
          meetingTranscriptView.clear()
                renderDiagnostic("selected failed \(error.localizedDescription)")
          if case LibraryDatabaseError.shardUnavailable(let ordinal, _) = error {
                    showArchivedShardPlaceholder(for: requestedDate, ordinal: ordinal)
                    return
                }
                applyPresentation(
                    FrameDetailDisplay.presentation(
                        isHidden: false,
                        hasVideo: false,
                        hasImage: false
                    ),
                    site: "loadFailed"
                )
            }
        }
    }

    /// Single write path for the media surface. Apply changes only when mode,
    /// hidden state, or the retained image identity differs. A visible loading
    /// state keeps outgoing content until its replacement is ready.
    @discardableResult
    private func applyPresentation(
        _ presentation: FrameDetailPresentation,
        image: NSImage? = nil,
        site: String
    ) -> Bool {
        hideArchivedDayPlaceholder()
        window?.contentView?.layer?.backgroundColor =
            (isAtLiveEdge ? NSColor.clear : NSColor.black).cgColor
        if presentation.displayMode == .loading, !presentation.isHidden {
            // Retain the current surface. No view mutation, no trace.
            return false
        }
      let imageUnchanged =
        presentation.displayMode != .image
            || image === frameImageRetention.lastImage
        if presentation == appliedPresentation, imageUnchanged { return false }
        appliedPresentation = presentation

        if presentation.isHidden {
            presentedPlayer?.pause()
            playerView.isHidden = true
            liveImageView.isHidden = true
            dateLabel.isHidden = true
            traceSurface(site)
            return true
        }
        switch presentation.displayMode {
        case .image:
            // Show the persisted still when video is unavailable; the player otherwise
            // draws above the retained image.
            if let image {
                liveImageView.image = image
                frameImageRetention.update(with: image)
            }
            liveImageView.isHidden = false
            presentedPlayer?.pause()
            playerView.isHidden = true
            dateLabel.isHidden = true
        case .video:
            // Reveal the player over the retained fallback. The still is left
            // mounted underneath, so this is an occlusion, not a swap.
            liveImageView.isHidden = false
            playerView.isHidden = false
            dateLabel.isHidden = true
        case .loading:
            break
        }
        traceSurface(site)
        return true
    }

    private func show(
        moment: HistoricalTimelineMoment,
      requestedDate: Date,
        selectedSegment: TimelineSegment?,
        generation: UInt64
    ) {
        guard ownsPresentation(generation) else {
            dateLabel.isHidden = true
            return
        }
        presentedMoment = moment
        if let expected = pendingTimelineActionsFixtureDeepLink,
          abs(expected.timeIntervalSince(moment.wallDate)) < 0.0005
        {
          pendingTimelineActionsFixtureDeepLink = nil
          writeTimelineActionsFixtureStatus(
            event: "deepLinkResolved",
            moment: moment
          )
        }
        timelineOverlay.selectedSegmentIDs = selectedSegment.map { [$0.rawID] } ?? []
        dateLabel.isHidden = true
        if let chunkURL = moment.chunkURL,
           moment.databaseVideoID != nil,
        !FileManager.default.fileExists(atPath: chunkURL.path)
      {
            showArchivedDayPlaceholder(for: moment)
            return
        }
        if moment.segmentType == SegmentType.audio.rawValue, let url = moment.chunkURL,
            waveformPresentedMediaURL != url {
            waveformPresentedMediaURL = url
            timelineWaveforms.retry(visible: timelineOverlay.visibleMeetingSegments,
                rawSegments: timelineOverlay.snapshot.rawAudioSegments)
        }
        hideArchivedDayPlaceholder()

        presentationTask = Task { [weak self] in
            guard let self else { return }
            let prepStart = DispatchTime.now().uptimeNanoseconds
            let prepared = await self.prepareMedia(moment)
        let prepMs =
          Double(
                DispatchTime.now().uptimeNanoseconds &- prepStart
            ) / 1_000_000
            guard self.ownsPresentation(generation), !Task.isCancelled else {
                LibreReverseTimelineTrace.log(
                    String(format: "PREPARE cancelled %.1fms", prepMs)
                )
                return
            }
            LibreReverseTimelineTrace.log(String(format: "PREPARE %.1fms", prepMs))
            self.renderDiagnostic(
                "prepared image=\(prepared.frameImage != nil) "
                + "playback=\(prepared.playbackURL != nil)"
            )

            guard let playbackURL = prepared.playbackURL,
                  let frameIndex = moment.videoFrameIndex,
                  let frameRate = moment.videoFrameRate,
          frameRate > 0
        else {
          if self.activeMeetingSegmentID != nil {
            self.presentPlaybackFailure(
              fallbackImage: prepared.frameImage,
              message:
                "This meeting recording is unavailable. Use Retry to load it again.",
              noticeKind: .failedToPrepare
            )
            return
          }
                if let image = prepared.frameImage {
                    guard self.ownsPresentation(generation), !Task.isCancelled else { return }
                    // Use the persisted still when video is missing or failed. A video
                    // that is still loading retains the outgoing surface instead.
                    self.liveImageSourceTag = "historical:\(moment.wallDate)"
                    self.applyPresentation(
                        FrameDetailDisplay.presentation(
                            isHidden: false,
                            hasVideo: false,
                            hasImage: true
                        ),
                        image: image,
                        site: "persistedStill"
                    )
                    self.presentSearchMatchIfCurrent(
                        moment: moment,
                        imageSize: Self.sourceImageSize(for: moment, fallback: image.size),
                        generation: generation
                    )
                    if let sourceImage = Self.cgImage(from: image) {
                        self.liveTextOverlay.present(
                            image: sourceImage,
                            identity: self.liveTextIdentity(for: moment),
                            contentView: self.liveImageView
                        )
                    }
                } else {
                    guard self.ownsPresentation(generation), !Task.isCancelled else { return }
                    // No media resolved. Hold the retained surface rather than
                    // clearing it; clearing here was a blank-frame flicker on
                    // every unresolvable moment crossed while scrubbing.
                    self.applyPresentation(
                        FrameDetailDisplay.presentation(
                            isHidden: false,
                            hasVideo: false,
                            hasImage: false
                        ),
                        site: "noMedia"
                    )
                }
                if let error = prepared.playbackPreparationError {
            self.dateLabel.stringValue =
              "Archived video unavailable: \(error.localizedDescription)"
                    self.dateLabel.isHidden = false
                }
                if prepared.frameImage != nil { self.setPlaybackMediaAvailable(true) }
                self.renderDiagnostic("presented persisted image")
                return
            }

            // Retain the outgoing surface until the incoming player is ready and
            // seeked. Hiding the still earlier would expose a blank frame when
            // crossing from a pending PNG to finalized video.
            self.liveImageSourceTag = "video:\(moment.wallDate)"

            if self.playerLeases[playbackURL] == nil,
          let videoID = moment.databaseVideoID
        {
                do {
                    self.playerLeases[playbackURL] = try LibreReverseMediaLease(
                        videoID: videoID, library: self.libraryConfiguration,
                        databaseSession: self.playerLeaseSession
                    )
                } catch {
                    self.setPlaybackMediaAvailable(false)
                    self.showArchivedDayPlaceholder(for: moment)
                    return
                }
            }
            let (_, created) = self.playerCache.player(for: playbackURL)
            self.renderDiagnostic(
                "player url=\(playbackURL.lastPathComponent) "
                + "created=\(created) retained=\(self.playerCache.retainedCount) "
                + "warmed=true"
            )
        guard
          let mediaTimeSeconds = LibreReverseMeetingPlaybackTiming.mediaTime(
            requestedDate: requestedDate,
            segmentStartDate: moment.segmentStartDate,
            segmentType: moment.segmentType.flatMap(
              SegmentType.init(rawValue:)),
            anchorFrameIndex: frameIndex,
            frameRate: frameRate
          )
        else { return }
            let target = CMTime(
          seconds: mediaTimeSeconds,
                preferredTimescale: 1_000
            )
            let toleranceComponents = PlaybackTiming.seekTolerance(
                frameRate: frameRate
            )
        let tolerance =
          toleranceComponents.map {
                CMTime(value: $0.value, timescale: $0.timescale)
            } ?? .zero

            guard let selection = await self.playerCache.setCurrentPlayer(for: playbackURL)
            else {
                // Evict a failed cached player so retries can create a usable item.
                // Show the exact persisted still and an actionable retry message.
          guard self.ownsPresentation(generation), !Task.isCancelled else { return }
          _ = self.playerCache.invalidate(playbackURL)
          self.presentPlaybackFailure(
            fallbackImage: prepared.frameImage,
            message: self.activeMeetingSegmentID != nil
              ? "This meeting recording could not be prepared. Use Retry to try again."
              : "This recording could not be prepared. Select this moment again to retry.",
            noticeKind: .failedToPrepare
          )
                return
            }
            guard self.ownsPresentation(generation), !Task.isCancelled else { return }
            let player = selection.player
            // A valid video may still be waiting for its first drawable frame.
            // Install an available still underneath without hiding a ready player.
            if self.liveImageView.image == nil, let fallback = prepared.frameImage {
                self.liveImageView.image = fallback
                self.frameImageRetention.update(with: fallback)
            }
        let layerPresentation =
          selection.requiresLayerTransition
                ? self.playerView.prepare(player: player)
                : self.playerView.pendingPresentation(for: player)
            if let output = selection.output {
                self.presentedVideoOutput = output
            }
            self.applyPresentation(
                FrameDetailDisplay.presentation(
                    isHidden: false,
                    hasVideo: true,
                    hasImage: false
                ),
                site: "playerRevealed"
            )
            guard self.ownsPresentation(generation), !Task.isCancelled else { return }
            self.presentedPlayer = player
        self.observePlaybackItem(
          selection.item,
          presentedBy: player,
          fallbackImage: prepared.frameImage
        )
            let seekFinished = await self.playerCache.seek(
                player,
                to: target,
                tolerance: tolerance
            )
            self.renderDiagnostic(
                "seek finished=\(seekFinished) target=\(target.seconds) "
                + "tolerance=\(tolerance.seconds) identity=\(ObjectIdentifier(player))"
            )
            guard self.ownsPresentation(generation), !Task.isCancelled else { return }
        self.setPlaybackMediaAvailable(true)
        if self.realTimePlaybackTimer != nil, self.activeMeetingSegmentID != nil {
          player.play()
        } else {
          // Screen capture chunks are sparse frame stores, not wall-clock
          // movies. Keep them paused at the frame selected by the timeline.
          player.pause()
        }
            // Complete the layer transition even when AVFoundation reports an inexact
            // seek; that result alone must not tear down the incoming surface.
            if let layerPresentation {
                self.playerView.complete(layerPresentation)
            }
            self.presentSearchMatchIfCurrent(
                moment: moment,
                imageSize: Self.sourceImageSize(for: moment),
                generation: generation
            )
            if let output = self.presentedVideoOutput {
                self.liveTextOverlay.presentVideoFrame(
                    output: output,
                    itemTime: player.currentTime(),
                    identity: self.liveTextIdentity(for: moment),
                    contentView: self.playerView
                )
            }
            // Keep the still mounted beneath the player so it is immediately
            // available if playback fails or is torn down.
            self.dateLabel.isHidden = true
        }
    }

    private func showArchivedDayPlaceholder(for moment: HistoricalTimelineMoment) {
        waveformPresentedMediaURL = nil
        setSearchResultsPresented(false)
        updateSearchPresentation(for: .timelineScrubbed)
        searchMatchOverlay.clear()
        liveTextOverlay.clear()
        // Archive suspension uses the same presentation state as local media,
        // so a subsequent video-to-video seek cannot leave the player hidden.
        applyPresentation(
            .init(isHidden: true, displayMode: .loading),
            site: "archiveSuspended"
        )
        pendingArchivedMoment = moment
        pendingArchivedShard = nil
        archivePlaceholder.isHidden = false
        traceSurface("archivedDayPlaceholder")
        refreshArchiveDownloadStatus(at: moment.wallDate)
    }

    private func showArchivedShardPlaceholder(for date: Date, ordinal: Int64) {
        setSearchResultsPresented(false)
        updateSearchPresentation(for: .timelineScrubbed)
        liveTextOverlay.clear()
        applyPresentation(
            .init(isHidden: true, displayMode: .loading),
            site: "archiveSuspended"
        )
        pendingArchivedMoment = nil
        pendingArchivedShard = (date, ordinal)
        archivePlaceholder.isHidden = false
        traceSurface("archivedShardPlaceholder")
        refreshArchiveDownloadStatus(at: date)
    }

    private func hideArchivedDayPlaceholder() {
        archiveStatusGeneration &+= 1
        archiveResolutionPendingDate = nil
        archivePlaceholder.isHidden = true
        setArchiveSpinner(visible: false)
        pendingArchivedMoment = nil
        pendingArchivedShard = nil
    }

    private func setArchiveSpinner(visible: Bool) {
        archivePlaceholder.setDownloading(visible)
    }

    private static func archiveHourLabel(_ interval: DateInterval) -> String {
        let day = DateFormatter.localizedString(
            from: interval.start,
            dateStyle: .medium,
            timeStyle: .none
        )
        let start = DateFormatter.localizedString(
            from: interval.start,
            dateStyle: .none,
            timeStyle: .short
        )
        let end = DateFormatter.localizedString(
            from: interval.end,
            dateStyle: .none,
            timeStyle: .short
        )
        return "\(day), \(start)–\(end)"
    }

    @objc private func downloadArchivedDay() {
        guard !mutationAdmissionClosed, archiveRequestTask == nil,
              let date = pendingArchivedShard?.date ?? pendingArchivedMoment?.wallDate else { return }
        guard archiveDownloads != nil, allowsLibraryMutations else {
            openStorageSettingsHandler?()
            return
        }
        // Capture the whole selection before this task yields. A later seek
        // must not combine the old date with a new shard/video identifier.
        let shardOrdinal = pendingArchivedShard?.ordinal
        let videoID = pendingArchivedMoment?.databaseVideoID
        let generation = presentationGeneration
        archiveRequestTask = Task { [weak self] in
            guard let self else { return }
            defer { archiveRequestTask = nil }
            do {
                let status = try await mutationLifetime.perform {
                    try await self.enqueueArchivedSelection(date: date, shardOrdinal: shardOrdinal, videoID: videoID)
                }
                guard ownsArchiveAction(generation: generation, date: date) else { return }
                if let status {
                    await archiveDownloadDidChange(status)
                    guard ownsArchiveAction(generation: generation, date: date) else { return }
                    if status.phase == .disconnected || status.phase == .unavailable {
                        openStorageSettingsHandler?()
                    }
                }
            } catch {
                guard ownsArchiveAction(generation: generation, date: date) else { return }
                // A request is only accepted after it is safely persisted.
                archivePlaceholderTitle.stringValue = "Couldn’t save this download"
                archivePlaceholderDetail.stringValue = "Free some space, then try again."
                setArchiveSpinner(visible: false)
                archiveDownloadButton.title = "Try Again"
                archiveDownloadButton.isEnabled = true
                renderDiagnostic("Download request could not be saved: \(error.localizedDescription)")
            }
        }
    }

    private func ownsArchiveAction(generation: UInt64, date: Date) -> Bool {
        !mutationAdmissionClosed && ownsPresentation(generation) && currentSeekDate == date
            && window?.isVisible == true && !archivePlaceholder.isHidden
    }

    private func enqueueArchivedSelection(date: Date, shardOrdinal: Int64?, videoID: Int64?) async throws -> LibreReverseDownloadStatus? {
        #if DEBUG
        if let request = interactionTestArchiveRequest { return try await request(date, shardOrdinal, videoID) }
        #endif
        guard let archiveDownloads else { throw CancellationError() }
        try await archiveDownloads.enqueue(date: date, shardOrdinal: shardOrdinal, selectedVideoID: videoID)
        return try await archiveDownloads.status(at: date)
    }

    private func showArchiveDownloadOffer(at date: Date) {
        let hour = LibreReverseArchiveRehydrationPolicy.localHour(containing: date)
        archivePlaceholderTitle.stringValue = "This recording is archived"
        archivePlaceholderDetail.stringValue = "Download recordings for \(Self.archiveHourLabel(hour)) to view them here."
            + (pendingArchivedShard == nil ? "" : " The first download takes a little longer.")
        archiveDownloadButton.title = "Download recording"
        if pendingArchivedShard != nil, shardResolver == nil && !archiveConnectionAvailableForValidation {
            archiveDownloadButton.title = archiveConnectionNeedsReconnect
                ? "Reconnect archive" : "Connect archive"
        }
        archiveDownloadButton.isEnabled = true
        setArchiveSpinner(visible: false)
        archivePlaceholder.setAccessibilityLabel("Archived history")
        archivePlaceholder.setAccessibilityValue(archivePlaceholderDetail.stringValue)
    }

    private func refreshArchiveDownloadStatus(at date: Date) {
        guard let archiveDownloads else {
            showArchiveDownloadOffer(at: date)
            return
        }
        let hourStart = LibreReverseArchiveRehydrationPolicy.localHour(containing: date).start
        // Scroll events render the last known state synchronously. Never show
        // an actionable download offer while the queue lookup is still pending.
        if let cached = archiveDownloadSnapshots.values.first(where: { $0.request.contains(date) }) {
            renderArchiveDownloadStatus(cached, at: date)
        } else if archiveHoursWithoutDownloads.contains(hourStart) {
            showArchiveDownloadOffer(at: date)
        } else {
            archivePlaceholderTitle.stringValue = "Checking download…"
            archivePlaceholderDetail.stringValue = "Checking whether this recording is ready."
            archivePlaceholder.showWaiting("One moment…")
        }
        archiveStatusGeneration &+= 1
        let generation = archiveStatusGeneration
        Task { [weak self] in
            do {
                let status = try await archiveDownloads.status(at: date)
                guard let self, self.archiveStatusGeneration == generation else { return }
                if let status {
                    await self.archiveDownloadDidChange(status)
                } else {
                    self.archiveHoursWithoutDownloads.insert(hourStart)
                    self.showArchiveDownloadOffer(at: date)
                }
            } catch {
                // A lookup failure is not evidence that no download exists.
                guard let self, self.archiveStatusGeneration == generation else { return }
                self.renderDiagnostic("Download status unavailable: \(error.localizedDescription)")
            }
        }
    }

    func archiveDownloadDidChange(_ status: LibreReverseDownloadStatus) async {
        // Keep snapshots even while another moment (or no window) is visible.
        archiveDownloadSnapshots[status.request.id] = status
        archiveHoursWithoutDownloads.remove(status.request.start)
        guard window?.isVisible == true, !archivePlaceholder.isHidden, let date = currentSeekDate,
              status.request.contains(date) else { return }
        renderArchiveDownloadStatus(status, at: date)
        if status.metadataAvailable, pendingArchivedShard != nil {
            guard archiveResolutionPendingDate != date else { return }
            archiveResolutionPendingDate = date
            await restoreArchivedSelection(at: date)
            return
        }
        if let url = pendingArchivedMoment?.chunkURL, FileManager.default.fileExists(atPath: url.path) {
            guard archiveResolutionPendingDate != date else { return }
            archiveResolutionPendingDate = date
            resolveMoment(at: date)
            return
        }
    }

    private func renderArchiveDownloadStatus(_ status: LibreReverseDownloadStatus, at date: Date) {
        switch status.phase {
        case .complete:
            // Cached media may have been evicted since a prior completed request.
            showArchiveDownloadOffer(at: date)
        case .disconnected:
            setArchiveSpinner(visible: false)
            archivePlaceholderTitle.stringValue = "Archive needs reconnecting"
            archivePlaceholderDetail.stringValue = "Your download is saved. Reconnect your archive in Storage settings to continue."
            archiveDownloadButton.title = "Reconnect & retry"
            archiveDownloadButton.isEnabled = true
        case .unavailable:
            setArchiveSpinner(visible: false)
            archivePlaceholderTitle.stringValue = "Not in this archive"
            archivePlaceholderDetail.stringValue = "This history may be stored with another provider. Switch archives in Storage settings to restore it."
            archiveDownloadButton.title = "Open Storage settings"
            archiveDownloadButton.isEnabled = true
        case .queued, .retrying:
            archivePlaceholderTitle.stringValue = status.phase == .queued ? "Download queued" : "Waiting to resume…"
            archivePlaceholderDetail.stringValue = "Your download is saved and will continue automatically."
            archivePlaceholder.showWaiting("No need to keep this window open.")
        case .history, .recording:
            if status.phase == .recording, let videoID = pendingArchivedMoment?.databaseVideoID,
               status.transferID != "video:\(videoID)" {
                archivePlaceholderTitle.stringValue = "Downloading nearby recordings…"
                archivePlaceholderDetail.stringValue = "This recording is in your saved download and will open when ready."
                archivePlaceholder.showWaiting("The download is continuing in the background.")
                return
            }
            archivePlaceholderTitle.stringValue = status.phase == .history ? "Preparing your history…" : "Downloading recording…"
            archivePlaceholderDetail.stringValue = status.phase == .history
                ? "This first step takes a little longer. Then we’ll get your recording."
                : "Your recording will open as soon as it’s ready."
            archivePlaceholder.updateTransfer(id: status.transferID,
                completed: status.completedBytes, total: status.totalBytes)
        }
    }

    private func mergeAdmittedScreenSegment(_ admittedFrame: LibreReverseAdmittedFrame?,
                                            at uptime: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard let segment = admittedFrame?.segment else { return }
        if let presentation = playbackTimelinePresentation,
            presentation.includesLiveTail,
            let admittedFrame {
            playbackTimelinePresentation = presentation.appending(admittedFrame: admittedFrame,
                starredDates: allStarredDates, retaining: isAtLiveEdge ? nil : currentSeekDate)
            if playbackTimelinePresentation?.interval.start != presentation.interval.start,
               historyBeltClock != nil, let currentSeekDate {
                // A trimmed-away origin would clamp to zero and re-add all
                // previous elapsed time. Continue from the displayed cursor.
                historyBeltClock = .init(startWallDate: currentSeekDate, startUptimeNanoseconds: uptime)
            }
            timelineOverlay.snapshot = playbackTimelinePresentation!.snapshot
        }
        recordingPublicationRevision &+= 1
      recentRecordingPublications.append(
        RecordingSegmentPublication(
            revision: recordingPublicationRevision,
            segment: segment
        ))
        // This history only bridges short in-flight DB snapshots. Keep a
        // generous bounded tail without turning it into a second corpus.
        if recentRecordingPublications.count > 2_048 {
            recentRecordingPublications.removeFirst(
                recentRecordingPublications.count - 2_048
            )
        }
        if let index = loadedRawSegments.lastIndex(where: {
            $0.rawID == segment.rawID && $0.rawType == segment.rawType
        }) {
            loadedRawSegments[index] = segment
        } else {
            loadedRawSegments.append(segment)
        }
        refreshSearchApplicationOptions()
        if let interval = loadedGlobalSeekInterval {
            loadedGlobalSeekInterval = DateInterval(
                start: interval.start,
                end: max(interval.end, segment.endDate)
            )
        } else {
            loadedGlobalSeekInterval = DateInterval(
                start: segment.startDate,
                end: segment.endDate
            )
        }
        rebuildWindowSnapshot()
        if lastFetchedWindowDuration > 0,
           snapshot.contiguousDuration
            >= lastFetchedWindowDuration
          + LibraryDatabase.initialTimelineWindowDuration
      {
            refetchStationaryWindow()
        }
    }

    private func rebuildWindowSnapshot() {
        let oldDuration = snapshot.contiguousDuration
        let oldAccumulator = accumulatedScrollOffset
        snapshot = LibreReverseTimelineSnapshot(
            rawSegments: loadedRawSegments,
            validSeekInterval: loadedGlobalSeekInterval,
            starredDates: allStarredDates
        )
        // Playback has separate geometry. Live publications and navigation
        // paging must not overwrite it or adopt its compressed duration.
        if let presentation = playbackTimelinePresentation {
            playbackTimelinePresentation = presentation.withStarredDates(allStarredDates)
            timelineOverlay.snapshot = playbackTimelinePresentation!.snapshot
        } else {
            timelineOverlay.snapshot = snapshot
        }
        timelineSlider.maxValue = snapshot.contiguousDuration
        rebaseScrollAccumulator()
        if oldDuration != snapshot.contiguousDuration {
            LibreReverseTimelineTrace.boundary(
                "BASIS old=\(oldDuration) new=\(snapshot.contiguousDuration) "
                    + "pinned=\(isAtLiveEdge) oldOffset=\(String(describing: oldAccumulator)) "
                    + "newOffset=\(String(describing: accumulatedScrollOffset))"
            )
        }
        LibreReverseTimelineTrace.log(
            "BASIS oldDuration=\(oldDuration) newDuration=\(snapshot.contiguousDuration) "
                + "oldAccumulator=\(String(describing: oldAccumulator)) "
                + "newAccumulator=\(String(describing: accumulatedScrollOffset)) "
                + "seek=\(String(describing: currentSeekDate)) "
                + "pinned=\(isAtLiveEdge)"
        )
    }

    /// Rebase the gesture offset after changing the loaded segment set. Preserve
    /// the wall date: the same numeric offset can identify different history after
    /// live admissions or paging rebuilds the contiguous coordinate basis.
    private func rebaseScrollAccumulator() {
        guard accumulatedScrollOffset != nil,
              let date = currentSeekDate,
              let rebased = snapshot.contiguousOffset(atWallDate: date)
        else { return }
        accumulatedScrollOffset = rebased
        if playbackTimelinePresentation == nil, timelineOverlay.currentOffsetOverride != nil {
            timelineOverlay.currentOffsetOverride = rebased
        }
    }

    /// Installs a completed SegmentList publication in the canonical order:
    /// retained window, actual-duration/date bookkeeping, then UI publication.
    private func publishFetchedWindow(
        _ window: HistoricalTimelineSegmentWindow,
        fetchedAt date: Date,
        recordingRevisionAtFetch: UInt64
    ) {
        let reconciled = RecordingWindowReconciliation.reconcile(
            fetchedSegments: window.segments,
            fetchedValidSeekInterval: window.validSeekInterval,
            recordingPublications: recentRecordingPublications,
            after: recordingRevisionAtFetch
        )
        LibreReverseTimelineTrace.log(
            "WINDOW publish fetchedSegments=\(window.segments.count) "
                + "fetchedTail=\(String(describing: window.segments.last?.endDate)) "
                + "globalEnd=\(String(describing: window.validSeekInterval?.end)) "
                + "fetchRevision=\(recordingRevisionAtFetch) "
                + "currentRevision=\(recordingPublicationRevision) "
                + "reconciledSegments=\(reconciled.segments.count) "
                + "reconciledTail=\(String(describing: reconciled.segments.last?.endDate))"
        )
        loadedRawSegments = reconciled.segments
        refreshSearchApplicationOptions()
        loadedGlobalSeekInterval = reconciled.validSeekInterval
        rebuildWindowSnapshot()
        LibreReverseTimelineTrace.boundary(
            "PUBLISH anchor=\(date.timeIntervalSince1970) "
                + "localStart=\(String(describing: snapshot.processedScreenshotSegments.first?.startDate.timeIntervalSince1970)) "
                + "localEnd=\(String(describing: snapshot.processedScreenshotSegments.last?.endDate.timeIntervalSince1970)) "
                + "seek=\(String(describing: currentSeekDate?.timeIntervalSince1970)) "
                + "pinned=\(isAtLiveEdge)"
        )
        lastFetchedWindowDuration = LibreReverseTimelineSnapshot(rawSegments: window.segments).contiguousDuration
        lastFetchedWindowDate = date
        tableView.appGroups = snapshot.appGroups
        tableView.reloadData()
        timelineSlider.isEnabled = snapshot.contiguousDuration > 0
        previousButton.isEnabled = !snapshot.processedScreenshotSegments.isEmpty
        nextButton.isEnabled = !snapshot.processedScreenshotSegments.isEmpty
    }

    private func readTimelineWindow(
        _ request: LibreReverseTimelineReloadRequest,
        includesPlaybackTiming: Bool
    ) async throws -> HistoricalTimelineSegmentWindow {
        #if DEBUG
        if let interactionTestTimelineWindow {
            return try await interactionTestTimelineWindow(request, includesPlaybackTiming)
        }
        #endif
        switch request {
        case .recent(let duration):
            return try await librarySession.recentTimelineWindow(duration: duration,
                includesPlaybackTiming: includesPlaybackTiming)
        case .around(let date, let duration):
            return try await librarySession.timelineWindow(around: date, duration: duration,
                includesPlaybackTiming: includesPlaybackTiming)
        }
    }

    private func refetchStationaryWindow() {
        guard window?.isVisible == true, let anchor = lastFetchedWindowDate else { return }
        let publicationGeneration = beginWindowTransaction()
        let recordingRevisionAtFetch = recordingPublicationRevision
        let requestedDuration = lastFetchedWindowDuration
        let fetchesRecent = anchor == loadedGlobalSeekInterval?.end
        stationaryRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let request: LibreReverseTimelineReloadRequest = fetchesRecent
                    ? .recent(duration: requestedDuration)
                    : .around(date: anchor, duration: requestedDuration)
                let window = try await readTimelineWindow(request, includesPlaybackTiming: false)
                guard self.ownsWindowPublication(publicationGeneration),
            !Task.isCancelled
          else { return }
                publishFetchedWindow(
                    window,
                    fetchedAt: fetchesRecent
                        ? (window.validSeekInterval?.end ?? Date())
                        : anchor,
                    recordingRevisionAtFetch: recordingRevisionAtFetch
                )
            } catch {
                // Outer failure preserves the prior retained window.
            }
        }
    }

    /// Mirrors TimelineModelCollection's throttled weak-self subscriber: each
    /// admitted refresh starts an unstructured task which is not retained or
    /// cancelled, then publishes the returned date array on the main actor.
    private func refreshStarredFrames() {
        Task { [weak self] in
            guard let self else { return }
            do {
                allStarredDates = try await librarySession.starredFrameDates()
                rebuildWindowSnapshot()
            } catch {
                // Keep the last successfully published star values after a refresh failure.
            }
        }
    }

    private func moveTranscript(by delta: NSSize) {
        guard let content = window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let frame = meetingTranscriptView.frame
        let minY = timelineOverlay.frame.maxY + transcriptControlClearance
        let x = min(max(22, frame.minX + delta.width), max(22, content.bounds.width - frame.width - 22))
        let y = min(max(minY, frame.minY + delta.height), max(minY, content.bounds.height - frame.height - 22))
        transcriptTrailingConstraint.constant = x + frame.width - content.bounds.width
        transcriptBottomConstraint.constant = timelineOverlay.frame.maxY - y
        content.layoutSubtreeIfNeeded()
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.isHidden = true
        liveImageView.translatesAutoresizingMaskIntoConstraints = false
        liveImageView.imageScaling = .scaleProportionallyUpOrDown
        liveImageView.imageAlignment = .alignCenter
        // The explorer window is transparent so the live edge can reveal the
        // real desktop. A historical still is aspect-fit, so without an opaque
        // backdrop the letterboxed remainder showed that same live desktop —
        // compositing "then" and "now" into one frame. Back the still with the
        // black playback surface.
        liveImageView.wantsLayer = true
      liveImageView.layer?.backgroundColor =
        NSColor(
            srgbRed: BrandVibrancyBackgroundContract.brandBlackRed,
            green: BrandVibrancyBackgroundContract.brandBlackGreen,
            blue: BrandVibrancyBackgroundContract.brandBlackBlue,
            alpha: 1
        ).cgColor
        // Persisted TrackItem images are initialized directly from PNG Data,
        // so AppKit reports their pixel dimensions as their intrinsic point
        // size. They are a rendition inside the fixed display-sized explorer,
        // never a source of window geometry. Without these priorities a 2x
        // 3024x1964 capture expands a 1512x982-point window back to 3024x1964.
        liveImageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        liveImageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        liveImageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        liveImageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        liveImageView.isHidden = true
        dateLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.alignment = .center
        dateLabel.textColor = NSColor.white.withAlphaComponent(0.82)
        dateLabel.drawsBackground = false
        dateLabel.isHidden = true
        archivePlaceholder.translatesAutoresizingMaskIntoConstraints = false
        archivePlaceholder.isHidden = true
        archiveDownloadButton.target = self
        archiveDownloadButton.action = #selector(downloadArchivedDay)
        timelineOverlay.translatesAutoresizingMaskIntoConstraints = false
        // The permanent date readout opens the existing date/time navigator.
        timelineOverlay.onMomentChipActivated = { [weak self] in
            self?.toggleJumpToDatePicker()
        }
        timelineOverlay.onSearch = { [weak self] in self?.restoreExpandedSearch() }
        timelineOverlay.meetingWaveformProvider = { [weak self] segment in
            self?.timelineWaveforms.envelope(for: segment)
        }
        timelineWaveforms.onChange = { [weak self] in self?.timelineOverlay.refreshWaveforms() }
        timelineOverlay.onVisibleMeetingSegmentsChanged = { [weak self] segments in
            guard let self else { return }
            self.timelineWaveforms.update(visible: segments,
                rawSegments: self.timelineOverlay.snapshot.rawAudioSegments)
        }
        liveTextOverlay.onInteractionBegan = { [weak self] in
        self?.stopRealTimePlayback()
        }
        searchOverlay.translatesAutoresizingMaskIntoConstraints = false
        collapsedSearchButton.translatesAutoresizingMaskIntoConstraints = false
        collapsedSearchButton.target = self
        collapsedSearchButton.action = #selector(restoreExpandedSearch)
        collapsedSearchButton.isBordered = false
        collapsedSearchButton.imagePosition = .imageLeading
        collapsedSearchButton.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: "Search"
        )
        collapsedSearchButton.contentTintColor = NSColor.white.withAlphaComponent(0.88)
        collapsedSearchButton.font = .systemFont(ofSize: 12, weight: .medium)
        collapsedSearchButton.attributedTitle = NSAttributedString(
            string: "Search",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.88),
            ]
        )
        collapsedSearchButton.imageHugsTitle = true
        collapsedSearchButton.wantsLayer = true
      collapsedSearchButton.layer?.backgroundColor =
        NSColor.black
            .withAlphaComponent(0.68).cgColor
        collapsedSearchButton.layer?.cornerRadius = 16
        collapsedSearchButton.layer?.cornerCurve = .continuous
        collapsedSearchButton.setAccessibilityLabel("Search your LibreReverse history")
        collapsedSearchButton.isHidden = true

        timelineOverlay.onSeekRequest = { [weak self] request in
            guard let self else { return }
        let resolvesMedia =
          request.source != .drag
                || self.boundsSeekThrottle.admits(
                   interval: TimelineInteractionTiming.boundsInterval,
                   now: Date()
                )
            self.updateSearchPresentation(for: .timelineScrubbed)
            let navigationOffset = self.playbackTimelinePresentation == nil ? request.contiguousOffset : nil
            let pinTarget: Date?
            if self.playbackTimelinePresentation != nil {
                pinTarget = self.loadedGlobalSeekInterval.flatMap { request.date >= $0.end ? $0.end : nil }
            } else {
                pinTarget = navigationOffset.flatMap {
                    TimelineEndOwnership.pinTarget(localOffset: $0,
                        localDuration: self.snapshot.contiguousDuration,
                        globalValidEnd: self.loadedGlobalSeekInterval?.end, advancesForward: true)
                }
            }
            let targetDate = pinTarget ?? request.date
            self.seek(
                to: targetDate,
                intent: pinTarget == nil ? .historical : .live,
                source: pinTarget == nil ? request.source : .pinToEnd,
                contiguousOffset: pinTarget == nil ? navigationOffset : nil,
                resolvesMedia: resolvesMedia,
                replacesWindow: self.playbackTimelinePresentation == nil && (resolvesMedia || pinTarget != nil)
            )
            if request.source == .drag {
                self.refreshPlaybackTimelineIfNeeded(at: targetDate, includeBoundary: true)
            }
        }
      timelineOverlay.onMeetingSeek = { [weak self] date, segmentID in
        guard let self else { return }
        self.updateSearchPresentation(for: .timelineScrubbed)
        self.seek(
          to: date,
          intent: .historical,
          source: .click,
          meetingSegmentID: segmentID
        )
      }
        timelineOverlay.onDragStarted = { [weak self] in
            guard let self, self.seekSourceReducer.beginInteraction(.drag) else { return }
            self.beginPresentationTransaction()
            self.stopRealTimePlayback()
        }
        timelineOverlay.onDragEnded = { [weak self] in
            guard let self, self.seekSourceReducer.source == .drag else { return }
            self.seekSourceReducer.dragEnded()
            if self.seekSourceReducer.canUpdateSeekPosition, !self.isAtLiveEdge, let date = self.currentSeekDate {
                self.resolveMoment(at: date)
            }
        }
        let applicationMetadata = ApplicationMetadataProvider.shared
        timelineOverlay.applicationTimelineImageProvider = { segment in
            guard let bundleID = segment.bundleID else { return nil }
            return applicationMetadata.metadata(bundleIdentifier: bundleID).icon
        }
        timelineOverlay.timelineBaseColorProvider = { segment in
            guard let bundleID = segment.bundleID,
                  let color = applicationMetadata.metadata(bundleIdentifier: bundleID).color,
          color != .clear
        else { return nil }
            return ApplicationIconColorExtractor.opaque(color)
        }
        timelineOverlay.onJumpToNow = { [weak self] in self?.jumpToLiveFromMenu() }
        timelineOverlay.onZoomChange = { [weak self] zoomLevel in
            self?.timelineZoomLevel = zoomLevel
        }
        timelineOverlay.onOverflow = { [weak self] in
            self?.presentTimelineActionsMenu()
        }
        searchOverlay.onAsk = { [weak self] query in self?.onAskQuestion?(query) }
        searchOverlay.onDismiss = { [weak self] in self?.resetExplorerSearch(.hide) }
        searchOverlay.onEscape = { [weak self] in self?.resetExplorerSearch(.hide) }
        searchOverlay.onStateChange = { [weak self] state in
            guard let self else { return }
            self.searchTask?.cancel()
            self.searchTask = nil
            self.searchConfirmationRevision = nil
            self.searchCountsTask?.cancel()
            self.explorerSearch.send(.input(state))
            if !state.canSubmit { self.searchResultsView.show(results: []) }
            self.renderExplorerSearch()
        }
        searchOverlay.onSubmit = { [weak self] state in
            self?.submitSearch(state)
        }
        searchOverlay.onConfirm = { [weak self] state in
            guard let self else { return }
            if self.displayedSearchState == state, self.searchTask == nil,
                self.explorerSearch.resultsPresented {
                if let first = self.transcriptSearchResults.first {
                    self.selectTranscriptSearchResult(first)
                    return
                }
                if let first = self.searchResults.first {
                    self.selectSearchResult(first)
                    return
                }
            }
            self.submitSearch(state)
            self.searchConfirmationRevision = self.explorerSearch.revision
        }
        searchResultsView.onAsk = { [weak self] in
            guard let self else { return }
            self.onAskQuestion?(self.searchOverlay.state.query)
        }
        searchResultsView.onSelect = { [weak self] result in
            self?.selectSearchResult(result)
        }
      searchResultsView.onSelectTranscript = { [weak self] result in
        self?.selectTranscriptSearchResult(result)
      }
        searchResultsView.onOpenBrowserURL = { [weak self] result in
            self?.openBrowserURL(from: result)
        }
        searchResultsView.onLoadMore = { [weak self] in
            self?.loadNextSearchPage()
        }
        let searchSession = librarySession
        let searchMediaLoader = persistedMediaLoader
        searchResultsView.previewProvider = { result in
            let started = DispatchTime.now().uptimeNanoseconds
        guard
          let moment = try? await searchSession.nearestMoment(
                to: result.result.representativeInstant
          )
        else { return nil }
            let located = DispatchTime.now().uptimeNanoseconds
            let image = await searchMediaLoader.searchFrame(moment: moment)
            let decoded = DispatchTime.now().uptimeNanoseconds
            LibreReverseTimelineTrace.log(
                String(
                    format: "PREVIEW lookup=%.1fms decode=%.1fms image=%@",
                    Double(located &- started) / 1_000_000,
                    Double(decoded &- located) / 1_000_000,
                    image == nil ? "nil" : "ok"
                )
            )
            return image
        }

        // Keep the still mounted underneath the player. Pending, failed, or removed
        // video then reveals the retained image without a blank surface transition.
        content.addSubview(liveImageView)
        content.addSubview(playerView)
        content.addSubview(searchMatchOverlay)
        content.addSubview(liveTextOverlay)
        content.addSubview(archivePlaceholder)
        content.addSubview(timelineOverlay)
      content.addSubview(meetingRecordingView)
      content.addSubview(meetingTranscriptView)
        content.addSubview(searchOverlay)
        content.addSubview(searchResultsView)
        content.addSubview(collapsedSearchButton)
        content.addSubview(dateLabel)
        searchResultsView.isHidden = true
      meetingRecordingView.onStop = meetingStopHandler
      meetingRecordingView.onRenameRequested = meetingRenameHandler
      meetingTranscriptView.onWordSeek = { [weak self] date, segmentID in
        guard let self else { return }
        self.seek(
          to: date,
          intent: .historical,
          source: .click,
          meetingSegmentID: segmentID
        )
      }
      meetingTranscriptView.onDrag = { [weak self] delta in self?.moveTranscript(by: delta) }
      meetingTranscriptView.onTextSelectionBegan = { [weak self] in
        self?.stopRealTimePlayback()
      }
      meetingTranscriptView.onTogglePlayback = { [weak self] in
        self?.toggleRealTimePlayback()
      }
      meetingTranscriptView.onTogglePin = { [weak self] in
        self?.pinMeetingTranscript()
      }
      meetingTranscriptView.onRetryPlayback = { [weak self] segmentID in
        guard let self,
          self.activeMeetingSegmentID == segmentID,
          let currentSeekDate = self.currentSeekDate
        else { return }
        self.dateLabel.isHidden = true
        self.seek(
          to: currentSeekDate,
          intent: .historical,
          source: .keyboardShortcut,
          meetingSegmentID: segmentID
        )
      }
      meetingTranscriptView.setPlaybackActive(false)
      meetingTranscriptView.onDelete = meetingDeletionHandler
      meetingTranscriptView.onRename = meetingTitleUpdateHandler
      meetingTranscriptView.onUpdateContext = meetingContextUpdateHandler
      meetingTranscriptView.onRetryTranscription = meetingTranscriptionRetryHandler
      meetingTranscriptView.setPinned(false)
        searchOverlayCenterConstraint = searchOverlay.centerYAnchor.constraint(
            equalTo: content.centerYAnchor
        )
        searchCompositionCenterConstraint = LibreReverseSearchCompositionLayout.centeredResultsConstraint(
            overlay: searchOverlay, results: searchResultsView, in: content)
        searchHorizontalCenterConstraint = searchOverlay.centerXAnchor.constraint(equalTo: content.centerXAnchor)
        transcriptTrailingConstraint = meetingTranscriptView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22)
        transcriptBottomConstraint = meetingTranscriptView.bottomAnchor.constraint(equalTo: timelineOverlay.topAnchor, constant: -transcriptControlClearance)
        // Preferred placement yields to required screen bounds when the window shrinks.
        transcriptTrailingConstraint.priority = .defaultHigh
        transcriptBottomConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            searchMatchOverlay.topAnchor.constraint(equalTo: content.topAnchor),
            searchMatchOverlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            searchMatchOverlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            searchMatchOverlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            liveTextOverlay.topAnchor.constraint(equalTo: content.topAnchor),
            liveTextOverlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            liveTextOverlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            liveTextOverlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            liveImageView.topAnchor.constraint(equalTo: content.topAnchor),
            liveImageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            liveImageView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            liveImageView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            archivePlaceholder.topAnchor.constraint(equalTo: content.topAnchor),
            archivePlaceholder.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            archivePlaceholder.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            archivePlaceholder.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            timelineOverlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            timelineOverlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            timelineOverlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            timelineOverlay.heightAnchor.constraint(
                equalToConstant: MemoryExplorerVisualShell.bottomOverlayHeight
            ),

        meetingRecordingView.topAnchor.constraint(
          equalTo: content.topAnchor,
          constant: 22
        ),
        meetingRecordingView.trailingAnchor.constraint(
          equalTo: content.trailingAnchor,
          constant: -22
        ),
        meetingRecordingView.widthAnchor.constraint(equalToConstant: 360),
        meetingRecordingView.heightAnchor.constraint(equalToConstant: 58),

        transcriptTrailingConstraint,
        transcriptBottomConstraint,
        meetingTranscriptView.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 22),
        meetingTranscriptView.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -22),
        meetingTranscriptView.bottomAnchor.constraint(lessThanOrEqualTo: timelineOverlay.topAnchor, constant: -transcriptControlClearance),
        meetingTranscriptView.widthAnchor.constraint(equalToConstant: 360),
        meetingTranscriptView.heightAnchor.constraint(equalToConstant: 320),
        meetingTranscriptView.topAnchor.constraint(
          greaterThanOrEqualTo: content.topAnchor,
          constant: 22
        ),

            searchHorizontalCenterConstraint,
            searchOverlayCenterConstraint,
        searchOverlay.heightAnchor.constraint(
          equalToConstant: LibreReverseSearchOverlayView.preferredSize.height),

            searchResultsView.leadingAnchor.constraint(equalTo: searchOverlay.leadingAnchor),
            searchResultsView.topAnchor.constraint(
                equalTo: searchOverlay.bottomAnchor,
                constant: 0
            ),

        collapsedSearchButton.leadingAnchor.constraint(
          equalTo: content.leadingAnchor, constant: 22),
            collapsedSearchButton.bottomAnchor.constraint(
                equalTo: content.bottomAnchor,
                // Auto Layout measures `bottom` downward, so a positive
                // constant pushes the view *below* the content view. Both of
                // these read as an inset above the bottom edge and so must be
                // negated; at +102 they laid out at y = -102 and never
                // appeared on screen at all.
                constant: -MemoryExplorerVisualShell.momentChipBottom
            ),
            collapsedSearchButton.widthAnchor.constraint(equalToConstant: 100),
            collapsedSearchButton.heightAnchor.constraint(equalToConstant: 32),

            dateLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            dateLabel.bottomAnchor.constraint(equalTo: timelineOverlay.topAnchor, constant: -8),
            dateLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
        ])
    }

    @objc private func restoreExpandedSearch() {
        stopRealTimePlayback()
        resetExplorerSearch(.open)
        searchOverlay.focusSearchField()
    }

    private func resetExplorerSearch(_ action: ExplorerSearchState.Action) {
        searchTask?.cancel()
        searchTask = nil
        searchCountsTask?.cancel()
        searchCountsTask = nil
        searchOverlay.cancelPendingSubmission()
        explorerSearch.send(action)
        searchOverlay.setState(explorerSearch.input)
        activeSearchState = nil
        displayedSearchState = nil
        searchConfirmationRevision = nil
        searchResults = []
        transcriptSearchResults = []
        searchCursor = nil
        searchHasMore = false
        renderExplorerSearch()
    }

    private func renderExplorerSearch() {
        let expanded = explorerSearch.expanded
        let results = expanded && explorerSearch.resultsPresented
        searchOverlay.isHidden = !expanded
        collapsedSearchButton.isHidden = true
        searchOverlay.setResultsPresented(results)
        searchResultsView.isHidden = !results
        searchOverlayCenterConstraint.isActive = !results
        searchCompositionCenterConstraint.isActive = results
        if !expanded, searchOverlay.ownsFirstResponder(window?.firstResponder) {
            window?.makeFirstResponder(liveTextOverlay)
        }
    }

    private var searchRevealedAt: TimeInterval = -.infinity

    private func updateSearchPresentation(
        for event: MemoryExplorerSearchPresentation.Event,
        focus: Bool = false
    ) {
        switch event {
        case .explorerPresented, .collapsedSearchActivated:
            searchRevealedAt = ProcessInfo.processInfo.systemUptime
            resetExplorerSearch(.open)
        case .timelineScrubbed:
            // The wheel gesture opening the explorer is forwarded after reveal.
            // Give that reveal a short grace period; subsequent navigation hides
            // controls and results together and invalidates pending searches.
            guard ProcessInfo.processInfo.systemUptime - searchRevealedAt >= 0.75,
                explorerSearch.expanded else { return }
            resetExplorerSearch(.scroll)
        }
        if explorerSearch.expanded, focus { searchOverlay.focusSearchField() }
    }

    private func setSearchResultsPresented(_ presented: Bool) {
        explorerSearch.send(presented ? .submit : .clearResults)
        renderExplorerSearch()
    }

    /// Reports explorer controls whose laid-out frames leave the content
    /// view, catching controls that exist but cannot be seen or clicked.
    private func auditControlLayout(_ context: String) {
      guard LibreReverseTimelineTrace.isEnabled, let content = window?.contentView else {
        return
      }
        content.layoutSubtreeIfNeeded()
        let controls: [(String, NSView)] = [
            ("searchOverlay", searchOverlay),
            ("searchResultsView", searchResultsView),
            ("collapsedSearchButton", collapsedSearchButton),
            ("dateLabel", dateLabel),
            ("timelineOverlay", timelineOverlay),
        ]
        let bounds = content.bounds
        for (name, view) in controls where !view.isHidden {
            let frame = view.convert(view.bounds, to: content)
            if !bounds.contains(frame) {
                LibreReverseTimelineTrace.log(
                    "LAYOUT OFFSCREEN \(context) \(name) frame=\(frame) content=\(bounds)"
                )
            }
        }
    }

    private func submitSearch(
      _ state: LibreReverseSearchOverlayState,
      initialCursor: SearchRecencyCursor? = nil
    ) {
        guard explorerSearch.expanded else { return }
        explorerSearch.send(.input(state))
        guard state.canSubmit else {
                setSearchResultsPresented(false)
                return
            }
        let effectiveInitialCursor = initialCursor
          ?? librarySearchValidation?.initialCursor
        searchTask?.cancel()
        activeSearchState = state
        searchCursor = effectiveInitialCursor
        searchHasMore = false
        dateLabel.isHidden = true
        setSearchResultsPresented(true)
        searchResultsView.showLoading(preservingResults: true)

        runSearchPage(state: state, cursor: effectiveInitialCursor, appending: false)
        refreshSearchApplicationCounts(for: state)
    }

    /// App facet counts scan every matching document across the primary and
    /// every sealed shard, which for a common term costs far more than the
    /// page itself -- "the" measured at 23.9s against a 0.4s page. They
    /// decorate the filter row and nothing waits on them, so they run beside
    /// the page instead of ahead of it.
    private func refreshSearchApplicationCounts(for state: LibreReverseSearchOverlayState) {
        searchCountsTask?.cancel()
        // A separate read connection keeps full-corpus counts off the seek actor.
        let session = LibraryDatabaseSession(configuration: libraryDatabase)
        let requestRevision = explorerSearch.revision
        searchCountsTask = Task { [weak self] in
            let started = DispatchTime.now().uptimeNanoseconds
        guard
          let counts = try? await session.searchApplicationCounts(
                query: state.query
          )
        else { return }
            guard let self, !Task.isCancelled,
          self.explorerSearch.accepts(requestRevision),
          self.activeSearchState == state
        else { return }
            LibreReverseTimelineTrace.log(
                String(
                    format: "SEARCHSTAGE counts=%.1fms",
                    Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000
                )
            )
            self.searchCountsTask = nil
            self.searchOverlay.setAvailableApplicationCounts(counts)
        }
    }

    private func loadNextSearchPage() {
        guard searchHasMore,
              searchTask == nil,
              let state = activeSearchState, state == explorerSearch.input,
        let cursor = searchCursor
      else { return }
        runSearchPage(state: state, cursor: cursor, appending: true)
    }

    private func runSearchPage(
        state: LibreReverseSearchOverlayState,
        cursor: SearchRecencyCursor?,
        appending: Bool
    ) {
        let bundleIDs = Set(loadedRawSegments.compactMap(\.bundleID))
        var applicationNames: [String: String] = [:]
        for bundleID in bundleIDs {
            if let name = ApplicationMetadataProvider.shared
          .metadata(bundleIdentifier: bundleID).name
        {
                applicationNames[bundleID] = name
            }
        }
        let session = librarySession
        let requestRevision = explorerSearch.revision
        searchTask = Task { [weak self] in
            do {
                let t2 = DispatchTime.now().uptimeNanoseconds
                defer {
                    LibreReverseTimelineTrace.log(
                        String(
                            format: "SEARCHSTAGE page=%.1fms",
                            Double(DispatchTime.now().uptimeNanoseconds &- t2) / 1_000_000
                        )
                    )
                }
          if state.searchFacets.isTranscript {
            let page = try await session.recencyTranscriptSearchPage(
              query: state.query,
              facets: state.searchFacets,
              before: cursor,
              previousResults: appending ? (self?.transcriptSearchResults ?? []) : []
            )
            guard let self, !Task.isCancelled, self.explorerSearch.accepts(requestRevision) else { return }
            self.searchTask = nil
            self.searchCursor = page.nextCursor
            self.searchHasMore = page.hasMore
            if !appending {
              self.searchOffsetsByDocument = [:]
              self.searchResults = []
              self.searchResultsView.query = state.query
              self.displayedSearchState = state
            }
            self.searchOffsetsByDocument.merge(page.offsetsByDocument) { _, new in new }
            if appending {
              self.transcriptSearchResults.append(contentsOf: page.results)
              self.searchResultsView.append(
                transcriptResults: page.results,
                hasMore: page.hasMore
              )
            } else {
              self.transcriptSearchResults = page.results
              self.searchResultsView.show(
                transcriptResults: page.results,
                hasMore: page.hasMore
              )
            }
          } else {
                let page = try await session.recencyOCRSearchPage(
                    query: state.query,
                    facets: state.searchFacets,
                    before: cursor,
                    applicationNames: applicationNames,
                    previousResults: appending ? (self?.searchResults ?? []) : []
                )
                guard let self, !Task.isCancelled, self.explorerSearch.accepts(requestRevision) else { return }
                self.searchTask = nil
                self.searchCursor = page.nextCursor
                self.searchHasMore = page.hasMore
                if !appending {
                    self.searchOffsetsByDocument = [:]
                    self.transcriptSearchResults = []
                    self.searchResultsView.query = state.query
                    self.displayedSearchState = state
                }
                self.searchOffsetsByDocument.merge(page.offsetsByDocument) { _, new in new }
                if appending {
                    self.searchResults.append(contentsOf: page.results)
                    self.searchResultsView.append(
                        results: page.results,
                        hasMore: page.hasMore
                    )
                } else {
                    self.searchResults = page.results
                    self.searchResultsView.show(
                        results: page.results,
                        hasMore: page.hasMore
                    )
                }
          }
          if let self, !appending, self.searchConfirmationRevision == requestRevision {
              self.searchConfirmationRevision = nil
              if let first = self.transcriptSearchResults.first { self.selectTranscriptSearchResult(first) }
              else if let first = self.searchResults.first { self.selectSearchResult(first) }
          }
          self?.completeLibrarySearchValidationPage(appending: appending)
            } catch {
                guard let self, !Task.isCancelled, self.explorerSearch.accepts(requestRevision) else { return }
                LibreReverseTimelineTrace.log("SEARCHPAGE failed=\(error)")
                self.searchTask = nil
                self.searchHasMore = false
                self.searchResultsView.show(error: error)
                self.writeLibrarySearchValidationStatus(
                  phase: "error",
                  error: error.localizedDescription
                )
            }
        }
    }

    private func completeLibrarySearchValidationPage(appending: Bool) {
      guard var validation = librarySearchValidation else { return }
      let totalCount = searchResults.count + transcriptSearchResults.count
      if !appending {
        validation.firstPageCount = totalCount
        if searchHasMore {
          validation.requestedNextPage = true
          librarySearchValidation = validation
          loadNextSearchPage()
          return
        }
      }
      librarySearchValidation = validation
      writeLibrarySearchValidationStatus(phase: "results")
      guard validation.selectsFirstResult else { return }
      let firstResult = transcriptSearchResults.first?.result ?? searchResults.first?.result
      let firstInstant = firstResult.flatMap {
        $0.transcriptDetails?.matchInstant ?? $0.representativeInstant
      }
      if let interval = validation.restoredDriveShardInterval,
        firstInstant.map(interval.contains) != true
      {
        writeLibrarySearchValidationStatus(
          phase: "restored-shard-result-mismatch",
          error: "The first constrained result did not belong to the restored shard."
        )
        return
      }
      if let selected = transcriptSearchResults.first {
        selectTranscriptSearchResult(selected)
      } else if let selected = searchResults.first {
        selectSearchResult(selected)
      } else {
        writeLibrarySearchValidationStatus(phase: "no-result-to-select")
        return
      }
      writeLibrarySearchValidationStatus(phase: "selection-requested")
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        self?.writeLibrarySearchValidationStatus(phase: "selection-resolved")
      }
    }

    private func writeLibrarySearchValidationStatus(
      phase: String,
      error: String? = nil
    ) {
      guard let validation = librarySearchValidation,
        let statusURL = validation.statusURL
      else { return }
      let firstResult = transcriptSearchResults.first?.result ?? searchResults.first?.result
      let expectedInstant = firstResult.flatMap { result -> Date? in
        result.transcriptDetails?.matchInstant ?? result.representativeInstant
      }
      var payload: [String: Any] = [
        "schemaVersion": 1,
        "phase": phase,
        "query": validation.query,
        "facet": validation.facet,
        "databaseOpenMode": "SQLITE_OPEN_READONLY",
        "currentWritablePrimaryPresent": true,
        "captureStarted": false,
        "transcriptionStarted": false,
        "archiveMutationStarted": false,
        "libraryMutationsAllowed": allowsLibraryMutations,
        "firstPageCount": validation.firstPageCount ?? 0,
        "totalLoadedCount": searchResults.count + transcriptSearchResults.count,
        "hasMore": searchHasMore,
        "requestedNextPage": validation.requestedNextPage,
      ]
      if let inventory = librarySearchValidationInventory {
        payload["searchableDocumentCount"] = inventory.searchableDocumentCount
        payload["transcriptDocumentCount"] = inventory.transcriptDocumentCount
        payload["starredFrameCount"] = inventory.starredFrameCount
        payload["locallyResidentShardCount"] = inventory.locallyResidentShardCount
        payload["unavailableShardCount"] = inventory.unavailableShardCount
        payload["driveOnlyHistoricalShardCount"] = inventory.unavailableShardCount
      }
      if let ordinal = validation.restoredDriveShardOrdinal {
        payload["restoredDriveShardOrdinal"] = ordinal
      }
      if let bytes = validation.restoredDriveShardBytes {
        payload["restoredDriveShardBytes"] = bytes
      }
      if let milliseconds = validation.driveRestoreMilliseconds {
        payload["driveRestoreMilliseconds"] = milliseconds
      }
      if let interval = validation.restoredDriveShardInterval {
        payload["restoredDriveShardStartEpoch"] = interval.start.timeIntervalSince1970
        payload["restoredDriveShardEndEpoch"] = interval.end.timeIntervalSince1970
        payload["firstResultWithinRestoredDriveShard"] = expectedInstant.map(
          interval.contains
        ) ?? false
      }
      if let firstResult {
        payload["firstDocumentID"] = firstResult.candidate.docID
        payload["firstSegmentID"] = firstResult.candidate.segmentID
        if let frameID = firstResult.candidate.frameID {
          payload["firstFrameID"] = frameID
        }
        if let bundleID = firstResult.candidate.bundleID {
          payload["firstBundleID"] = bundleID
        }
        payload["firstResultKind"] = firstResult.segmentType == .audio
          ? "transcript" : "ocr"
      }
      if let expectedInstant {
        payload["expectedSelectionEpoch"] = expectedInstant.timeIntervalSince1970
      }
      if validation.selectsFirstResult,
        (phase == "selection-requested" || phase == "selection-resolved"),
        let currentSeekDate
      {
        payload["actualSeekEpoch"] = currentSeekDate.timeIntervalSince1970
        if let expectedInstant {
          payload["seekDeltaSeconds"] = abs(
            currentSeekDate.timeIntervalSince(expectedInstant)
          )
        }
      }
      if let presentedMoment {
        payload["presentedFrameID"] = presentedMoment.frameID
        payload["presentedMomentEpoch"] = presentedMoment.wallDate.timeIntervalSince1970
      }
      if let error { payload["error"] = error }
      guard JSONSerialization.isValidJSONObject(payload),
        let data = try? JSONSerialization.data(
          withJSONObject: payload,
          options: [.prettyPrinted, .sortedKeys]
        )
      else { return }
      try? data.write(to: statusURL, options: .atomic)
      if (phase == "results" || phase == "selection-resolved"),
        let destination = LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_LIBRARY_UI_VALIDATION_SCREENSHOT"
        ], !destination.isEmpty
      {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
          self?.writeChromeCapture(to: destination)
        }
      }
    }

    private func refreshSearchApplicationOptions() {
        searchOverlay.setAvailableApplicationBundleIDs(
            loadedRawSegments.compactMap(\.bundleID)
        )
    }

    private func selectSearchResult(_ selected: OCRSearchResult) {
        activeMeetingSegmentID = nil
        resetExplorerSearch(.hide)
        activeSearchMatch = selected.result.candidate.frameID.flatMap { frameID in
            searchOffsetsByDocument[selected.result.candidate.docID].map { offsetString in
                ActiveSearchMatch(
                    frameID: frameID,
                    documentID: selected.result.candidate.docID,
                    offsetString: offsetString,
                    primaryText: selected.result.candidate.text,
                    otherText: selected.result.candidate.otherText,
                    matchingNodes: []
                )
            }
        }
        seek(
            to: selected.result.representativeInstant,
            intent: .historical,
            source: .search
        )
    }

    private func selectTranscriptSearchResult(
      _ selected: TranscriptSearchResult
    ) {
      resetExplorerSearch(.hide)
      activeSearchMatch = nil
      activeMeetingSegmentID = selected.result.candidate.segmentID
      searchMatchOverlay.clear()
      seek(
        to: selected.result.transcriptDetails?.matchInstant
          ?? selected.result.representativeInstant,
        intent: .historical,
        source: .search
      )
    }

    private func presentSearchMatchIfCurrent(
        moment: HistoricalTimelineMoment,
        imageSize: CGSize,
        generation: UInt64
    ) {
        guard ownsPresentation(generation),
              let activeSearchMatch,
        activeSearchMatch.frameID == moment.frameID
      else {
            searchMatchOverlay.clear()
            return
        }
        searchMatchOverlay.present(
            nodes: activeSearchMatch.matchingNodes,
            imageSize: imageSize
        )
    }

    private static func sourceImageSize(
        for moment: HistoricalTimelineMoment,
        fallback: CGSize = .zero
    ) -> CGSize {
        guard moment.videoWidth > 0, moment.videoHeight > 0 else { return fallback }
        return CGSize(width: moment.videoWidth, height: moment.videoHeight)
    }

    private func openBrowserURL(from selected: OCRSearchResult) {
        guard let rawURL = selected.result.candidate.browserURL,
        let url = LibreReverseTimelineContextResolver.openableWebURL(rawURL)
      else {
            return
        }
        let application = LibreReverseRecordedApplication(
            bundleID: selected.result.candidate.bundleID
        )
        guard application.isSupportedBrowser else { return }
      openContext(
        LibreReverseContextualOpenAction(
            url: url,
            application: application,
            browserProfile: nil
        ))
    }

    private func openContext(_ action: LibreReverseContextualOpenAction) {
        guard let bundleID = action.application.bundleID,
              let applicationURL = NSWorkspace.shared.urlForApplication(
                  withBundleIdentifier: bundleID
        )
      else { return }
        // Use the default workspace launch configuration. Recorded browser
        // profiles do not become command-line launch flags.
        let configuration = NSWorkspace.OpenConfiguration()
        dismiss()
        NSWorkspace.shared.open(
            [action.url],
            withApplicationAt: applicationURL,
            configuration: configuration
        )
    }

    @objc private func toggleJumpToDatePicker() {
        LibreReverseTimelineTrace.log(
            "JUMPTODATE activated chip=\(timelineOverlay.momentChipRect) "
            + "open=\(jumpToDatePopover != nil)"
        )
        if let popover = jumpToDatePopover, popover.isShown {
            closeJumpToDatePicker()
            return
        }
        guard let range = loadedGlobalSeekInterval else { return }
        let selected = currentSeekDate ?? range.end
        var state = JumpToDateState(
            currentSeekPosition: selected,
            pickerDateRange: range,
            calendar: .current
        )
        state.togglePicker()
        state.completePickerAnimation()
        jumpToDateState = state

        let picker = LibreReverseJumpToDateView(
            frame: NSRect(origin: .zero, size: LibreReverseJumpToDateView.preferredContentSize)
        )
        picker.setAccessibilityIdentifier("timeline.jumpToDate.picker")
        picker.onPreviousMonth = { [weak self] in self?.moveJumpMonth(by: -1) }
        picker.onNextMonth = { [weak self] in self?.moveJumpMonth(by: 1) }
        picker.onSelectDay = { [weak self] date in self?.selectJumpDay(date) }
        picker.onSelectHour = { [weak self] date in self?.selectJumpHour(date) }
        jumpToDateView = picker
        let controller = NSViewController()
        controller.view = picker
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = controller
        // Assign the intended size after the content controller, whose initial
        // view frame otherwise replaces an earlier popover contentSize.
        popover.contentSize = LibreReverseJumpToDateView.preferredContentSize
        jumpToDatePopover = popover
        picker.render(state, loadingDays: true, loadingHours: true)
        popover.show(
            relativeTo: timelineOverlay.momentChipRect,
            of: timelineOverlay,
            preferredEdge: .maxY
        )
        loadJumpValidDays()
    }

    private func jumpToSelectedPickerDate() {
        guard let date = jumpToDateState?.selectedDate else { return }
        accumulatedScrollOffset = nil
        seek(to: date, intent: .historical, source: .jumpToDate)
    }

    private func closeJumpToDatePicker() {
        jumpValidDaysTask?.cancel()
        jumpValidHoursTask?.cancel()
        jumpValidDaysTask = nil
        jumpValidHoursTask = nil
        if var state = jumpToDateState {
            state.closePicker()
            state.completePickerAnimation()
            jumpToDateState = state
        }
        jumpToDatePopover?.performClose(nil)
        jumpToDatePopover = nil
        jumpToDateView = nil
    }

    func popoverDidClose(_ notification: Notification) {
        jumpValidDaysTask?.cancel()
        jumpValidHoursTask?.cancel()
        jumpValidDaysTask = nil
        jumpValidHoursTask = nil
        jumpToDatePopover = nil
        jumpToDateView = nil
        if var state = jumpToDateState {
            state.closePicker()
            state.completePickerAnimation()
            jumpToDateState = state
        }
    }

    private func moveJumpMonth(by delta: Int) {
        guard var state = jumpToDateState,
              let month = state.calendar.date(
                byAdding: .month,
                value: delta,
                to: state.viewingMonth
        )
      else { return }
        state.viewMonth(month)
        jumpToDateState = state
        jumpToDateView?.render(state, loadingDays: true, loadingHours: true)
        loadJumpValidDays()
    }

    private func selectJumpDay(_ date: Date) {
        guard var state = jumpToDateState, state.selectDay(date) else { return }
        jumpToDateState = state
        jumpToDateView?.render(state, loadingDays: false, loadingHours: true)
        jumpToSelectedPickerDate()
        loadJumpValidHours()
    }

    private func selectJumpHour(_ date: Date) {
        guard var state = jumpToDateState, state.selectHour(date) else { return }
        jumpToDateState = state
        jumpToDateView?.render(state, loadingDays: false, loadingHours: false)
        jumpToSelectedPickerDate()
    }

    private func loadJumpValidDays() {
        jumpValidDaysTask?.cancel()
        jumpValidHoursTask?.cancel()
        guard let state = jumpToDateState,
              let month = state.monthInterval(),
        month.intersection(with: state.pickerDateRange) != nil
      else { return }
        let viewingMonth = state.viewingMonth
        let periods = jumpAvailabilityPeriods(
            in: month,
            component: .day,
            calendar: state.calendar
        )
        jumpValidDaysTask = Task { [weak self] in
            guard let self else { return }
            do {
                let samples = try await librarySession.firstRecordingInPeriods(periods)
                guard !Task.isCancelled,
                      var latest = jumpToDateState,
            latest.viewingMonth == viewingMonth
          else { return }
                latest.updateValidDays(samples)
                if !latest.validDays.contains(
                    latest.calendar.startOfDay(for: latest.selectedDate)
          ),
            let nearest = latest.validDays.min(by: {
                    abs($0.timeIntervalSince(latest.selectedDate))
                        < abs($1.timeIntervalSince(latest.selectedDate))
            })
          {
                    _ = latest.selectDay(nearest)
                }
                jumpToDateState = latest
                jumpToDateView?.render(
                    latest,
                    loadingDays: false,
                    loadingHours: !latest.validDays.isEmpty
                )
                if !latest.validDays.isEmpty { loadJumpValidHours() }
            } catch {
                guard !Task.isCancelled, let latest = jumpToDateState else { return }
                jumpToDateView?.render(latest, loadingDays: false, loadingHours: false)
            }
        }
    }

    private func loadJumpValidHours() {
        jumpValidHoursTask?.cancel()
        guard let state = jumpToDateState,
              let day = state.selectedDayInterval(),
        day.intersection(with: state.pickerDateRange) != nil
      else { return }
        let selectedDay = state.calendar.startOfDay(for: state.selectedDate)
        let periods = jumpAvailabilityPeriods(
            in: day,
            component: .hour,
            calendar: state.calendar
        )
        jumpValidHoursTask = Task { [weak self] in
            guard let self else { return }
            do {
                let samples = try await librarySession.firstRecordingInPeriods(periods)
                guard !Task.isCancelled,
                      var latest = jumpToDateState,
            latest.calendar.startOfDay(for: latest.selectedDate) == selectedDay
          else {
                    return
                }
                latest.updateValidHours(samples)
                jumpToDateState = latest
                jumpToDateView?.render(latest, loadingDays: false, loadingHours: false)
            } catch {
                guard !Task.isCancelled, let latest = jumpToDateState else { return }
                jumpToDateView?.render(latest, loadingDays: false, loadingHours: false)
            }
        }
    }

    private func jumpAvailabilityPeriods(
        in interval: DateInterval,
        component: Calendar.Component,
        calendar: Calendar
    ) -> [DateInterval] {
        var periods: [DateInterval] = []
        var current = interval.start
        while current < interval.end,
              let next = calendar.date(byAdding: component, value: 1, to: current),
        next > current
      {
            periods.append(DateInterval(start: current, end: min(next, interval.end)))
            current = next
        }
        return periods
    }

    private func updateJumpToDateButton() {
        if var state = jumpToDateState {
            if let range = loadedGlobalSeekInterval { state.updateRange(range) }
            if let date = currentSeekDate { state.updateCurrentSeekPosition(date) }
            jumpToDateState = state
        }
    }

    private static let jumpToDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm:ss a"
        return formatter
    }()

    private func liveTextIdentity(for moment: HistoricalTimelineMoment) -> String {
        "\(moment.wallDate.timeIntervalSinceReferenceDate):"
            + "\(moment.databaseVideoID ?? -1):\(moment.videoFrameIndex ?? -1)"
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
#endif
