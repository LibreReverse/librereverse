#if os(macOS)
import AppKit

import LibreReverseCore

private enum LibreReverseTimelineNativePresentation {
    case appGroup(index: Int, offset: TimeInterval, duration: TimeInterval)
    case audio(index: Int, offset: TimeInterval, duration: TimeInterval)
    case star(index: Int, offset: TimeInterval)

    var offset: TimeInterval {
        switch self {
        case .appGroup(_, let offset, _), .audio(_, let offset, _), .star(_, let offset):
            offset
        }
    }

    var duration: TimeInterval {
        switch self {
        case .appGroup(_, _, let duration), .audio(_, _, let duration): duration
        case .star: 0
        }
    }

    var mediaType: TimelineMediaType {
        switch self {
        case .appGroup: .screenshot
        case .audio: .audio
        case .star: .star
        }
    }

    var indexPath: IndexPath {
        switch self {
        case .appGroup(let index, _, _): IndexPath(item: index, section: 0)
        case .audio(let index, _, _): IndexPath(item: index, section: 1)
        case .star(let index, _): IndexPath(item: index, section: 2)
        }
    }
}

/// Bottom-screen timeline surface. It intentionally owns no database or player
/// state: callers provide a snapshot/current date and receive seek/control events.
@MainActor
final class LibreReverseTimelineOverlayView: NSView {
    private let transportGlass = LibreReverseTimelineGlassView(frame: .zero)
    private static let transportAccent = NSColor(srgbRed: 1, green: 0.32, blue: 0.12, alpha: 1)
    private static let calendarSymbol = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(paletteColors: [.white.withAlphaComponent(0.7)]))


    /// Completed local envelopes only. Decoding and hydration never happen in drawing.
    var meetingWaveformProvider: ((TimelineSegment) -> MeetingWaveformEnvelope?)? {
        didSet { configureVisibleNativeItems() }
    }

    func refreshWaveforms() { configureVisibleNativeItems() }

    var snapshot: LibreReverseTimelineSnapshot {
        didSet {
            // Rebase before laying out: an offset belongs to its snapshot.
            // Painting a replacement with the previous snapshot's offset
            // briefly sends the playhead back to a different wall date.
            if let currentDate, let rebased = snapshot.contiguousOffset(atWallDate: currentDate) {
                visualContiguousOffset = rebased
                if currentOffsetOverride != nil { currentOffsetOverride = rebased }
            }
            if isDraggingTimeline, let panStartDate,
                let rebased = snapshot.contiguousOffset(atWallDate: panStartDate) {
                panStartOffset = rebased
            }
            rebuildGroupPresentations()
            updateLogZoomRange()
            foregroundView.needsDisplay = true
            guideView.needsDisplay = true
        }
    }

    /// Gesture-owned playhead offset. Preserve this alongside currentDate because
    /// converting through a wall date inside a gap quantizes the position to a
    /// segment boundary. Leave nil for date-driven jumps, search, and live updates.
    var currentOffsetOverride: TimeInterval? {
        didSet {
            guard let currentOffsetOverride, !isDraggingTimeline else { return }
            setNativeScrollOffset(currentOffsetOverride)
            foregroundView.needsDisplay = true
            guideView.needsDisplay = true
        }
    }

    var playbackIsAdvancing = false
    var currentDate: Date? {
        didSet {
            if playbackIsAdvancing, let oldValue, let currentDate, currentDate < oldValue {
                self.currentDate = oldValue
                return
            }
            if !isDraggingTimeline {
                scrollToCurrentDate()
            }
            foregroundView.needsDisplay = true
            guideView.needsDisplay = true
        }
    }

    /// `pinToEnd` is a persistent navigation state. While it owns the seek,
    /// the playhead reads Now even when the newest persisted segment trails wall time.
    var isPinnedToEnd = true {
        didSet {
            guard oldValue != isPinnedToEnd else { return }
            foregroundView.needsDisplay = true
            guideView.needsDisplay = true
        }
    }

    /// Continuous UI state. Layout receives its exponential transform.
    private(set) var zoomLevel: Float
    private(set) var logZoomRange: Float

    var selectedSegmentIDs: Set<Int64> = [] {
        didSet {
            needsDisplay = true
            foregroundView.needsDisplay = true
            guideView.needsDisplay = true
            configureVisibleNativeItems()
            rebuildAccessibilityElements()
        }
    }

    var onSeek: ((Date) -> Void)?
    var onSeekRequest: ((TimelineSeekRequest) -> Void)?
    /// Audio bars retain their owning meeting segment through media resolution.
    var onMeetingSeek: ((Date, Int64) -> Void)?
    /// Clicking the moment chip discloses date selection.
    var onMomentChipActivated: (() -> Void)?
    var onDragStarted: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onZoomChange: ((Float) -> Void)?
    var onOverflow: (() -> Void)?
    var onSearch: (() -> Void)?
    var onJumpToNow: (() -> Void)?
    var onVisibleMeetingSegmentsChanged: (([TimelineSegment]) -> Void)? {
        didSet { publishVisibleMeetings(force: true) }
    }
    private(set) var visibleMeetingSegments: [TimelineSegment] = []

    private func publishVisibleMeetings(force: Bool = false) {
        let anchor = visualContiguousOffset ?? currentDate.flatMap(snapshot.contiguousOffset(atWallDate:)) ?? 0
        let half = Double(effectiveLogZoomRange) / 2
        let visible = snapshot.processedAudioSegments.filter {
            guard let start = $0.contiguousStartOffset, let end = $0.contiguousEndOffset else { return false }
            return end >= anchor - half && start <= anchor + half
        }
        guard force || visible != visibleMeetingSegments else { return }
        visibleMeetingSegments = visible
        onVisibleMeetingSegmentsChanged?(visible)
    }

    private var searchRect: NSRect {
        MemoryExplorerVisualShell.searchFrame(viewportWidth: bounds.width)
    }
    private var zoomInRect: NSRect {
        MemoryExplorerVisualShell.zoomInFrame(viewportWidth: bounds.width)
    }

    var latestCapturedDate: Date? {
        didSet { guideView.needsDisplay = true; foregroundView.needsDisplay = true; configureVisibleNativeItems() }
    }
    private var nowLabel: (text: String, rect: NSRect)? {
        guard latestCapturedDate != nil else { return nil }
        let belt = timelineProjection.belt
        // Live data and accessibility can arrive before the initial window
        // layout. A collapsed belt has no room for this control yet.
        guard belt.minX.isFinite, belt.maxX.isFinite, belt.width >= 24 else { return nil }
        let visibleX = nowPosition.flatMap { x in
            x >= belt.minX + 12 && x <= belt.maxX - 12 ? x : nil
        }
        let text = visibleX == nil ? "NOW ›" : "NOW"
        let width = Self.nowText.run(for: text).size.width
        guard width <= belt.width else { return nil }
        let center = visibleX ?? (belt.maxX - width / 2)
        return (text, NSRect(x: center - width / 2,
            y: MemoryExplorerVisualShell.timelineCenterFromBottom - 22, width: width, height: 12))
    }
    private var returnToNowRect: NSRect? {
        nowLabel?.rect.insetBy(dx: -5, dy: -5)
    }
    private static let nowText = LibreReverseTimelineText(
        font: .monospacedSystemFont(ofSize: 9, weight: .medium), color: .white.withAlphaComponent(0.65))
    private static let rulerText = LibreReverseTimelineText(
        font: .monospacedSystemFont(ofSize: 9, weight: .regular), color: .white.withAlphaComponent(0.55))
    private static let dateText = LibreReverseTimelineText(
        font: .systemFont(ofSize: 11, weight: .regular), color: .white.withAlphaComponent(0.84), capacity: 32)
    private static let timeText = LibreReverseTimelineText(
        font: .monospacedSystemFont(ofSize: 16, weight: .regular), color: .white.withAlphaComponent(0.95))

    /// Exact renderer injection point for canonical DomainMetadata favicons.
    /// LibreReverse leaves it nil until provenance-cleared favicon assets exist.
    var primaryTimelineImageProvider: ((TimelineSegment) -> NSImage?)? {
        didSet { configureVisibleNativeItems() }
    }
    /// Canonical application image resolved from AppMetadata by bundle ID.
    var applicationTimelineImageProvider: ((TimelineSegment) -> NSImage?)? {
        didSet { configureVisibleNativeItems() }
    }
    /// Supplies the model-derived base color painted before the canonical
    /// gradient. When unavailable, a gray fallback is used.
    var timelineBaseColorProvider: ((TimelineSegment) -> NSColor?)? {
        didSet { configureVisibleNativeItems() }
    }

    private struct GroupPresentation {
        let startOffset: TimeInterval
        let duration: TimeInterval
        let group: AppSegmentGroup
    }

    private var groupPresentations: [GroupPresentation] = []
    private var rulerStarOffsets: [Double] = []
    private var iconCache: [String: NSImage] = [:]
    private var visualContiguousOffset: TimeInterval?
    /// Explicit width of the scroll view's document view. See the constraint
    /// setup in `init` for why this cannot be a plain frame assignment.
    private var documentWidthConstraint: NSLayoutConstraint?
    private var panStartDate: Date?
    private var panStartOffset: TimeInterval = 0
    private var isDraggingTimeline = false
    private var isApplyingProgrammaticScroll = false
    private var boundsObservation: NSObjectProtocol?
    private let nativeTimelineLayout = LibreReverseTimelineCollectionLayout()
    private let nativeCollectionView = LibreReverseTimelineCoordinateCollectionView()
    private let nativeScrollView = LibreReverseTimelineCoordinateScrollView()
    private var timelineAccessibilityElements: [LibreReverseTimelinePressAccessibilityElement] = []
    private lazy var staticGuideView: LibreReverseTimelineForegroundView = {
        let view = LibreReverseTimelineForegroundView { [weak self] _ in
            self?.drawTimelineGuide()
        }
        // The white guide is viewport-fixed. Keep its transparent backing apart
        // from the changing ruler so scrolling reuses AppKit's rendered pixels.
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        view.identifier = NSUserInterfaceItemIdentifier("timeline.staticGuide")
        return view
    }()
    private lazy var guideView = LibreReverseTimelineForegroundView { [weak self] _ in
        guard let self else { return }
        self.drawTimeRuler(projection: self.timelineProjection)
    }
    private lazy var foregroundView = LibreReverseTimelineForegroundView { [weak self] _ in
        guard let self else { return }
        self.drawNowBoundary()
        self.drawPlayhead()
        self.drawTimeBubble()
        self.drawControls()
    }
    private var zoomRect: NSRect {
        MemoryExplorerVisualShell.zoomFrame(viewportWidth: bounds.width)
    }

    init(
        snapshot: LibreReverseTimelineSnapshot,
        currentDate: Date?,
        zoomLevel: Float = TimelineLayout.defaultZoomLevel
    ) {
        self.snapshot = snapshot
        self.currentDate = currentDate
        self.zoomLevel = min(
            TimelineLayout.zoomLevelRange.upperBound,
            max(TimelineLayout.zoomLevelRange.lowerBound, zoomLevel)
        )
        if let range = TimelineLayout.zoomRange(
            validSeekDuration: snapshot.validSeekInterval?.duration
        ) {
            self.logZoomRange = TimelineLayout.logZoomRange(
                zoomLevel: self.zoomLevel,
                rangeLower: range.lowerBound,
                rangeUpper: range.upperBound
            )
        } else {
            self.logZoomRange = TimelineLayout.minimumVisibleDuration
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Application timeline")
        transportGlass.appearance = NSAppearance(named: .darkAqua)
        addSubview(transportGlass)

        nativeCollectionView.collectionViewLayout = nativeTimelineLayout
        nativeCollectionView.dataSource = self
        nativeCollectionView.isSelectable = false
        nativeCollectionView.backgroundColors = [.clear]
        nativeCollectionView.register(
            LibreReverseAppSegmentGroupItem.self,
            forItemWithIdentifier: LibreReverseAppSegmentGroupItem.identifier
        )
        nativeCollectionView.register(
            LibreReverseAudioSegmentItem.self,
            forItemWithIdentifier: LibreReverseAudioSegmentItem.identifier
        )
        nativeCollectionView.register(
            LibreReverseStarredFrameItem.self,
            forItemWithIdentifier: LibreReverseStarredFrameItem.identifier
        )
        nativeScrollView.documentView = nativeCollectionView
        // NSScrollView installs constraints pinning the document view to the
        // clip view's width. Setting the frame directly is reverted on the next
        // Auto Layout pass, which left the clip view with nothing to scroll and
        // clamped every scroll origin to 0. Own the width explicitly instead.
        nativeCollectionView.translatesAutoresizingMaskIntoConstraints = false
        let clip = nativeScrollView.contentView
        let width = nativeCollectionView.widthAnchor.constraint(equalToConstant: 1)
        width.priority = .required
        documentWidthConstraint = width
        NSLayoutConstraint.activate([
            nativeCollectionView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            nativeCollectionView.topAnchor.constraint(equalTo: clip.topAnchor),
            nativeCollectionView.heightAnchor.constraint(equalTo: clip.heightAnchor),
            width,
        ])
        nativeScrollView.drawsBackground = false
        nativeScrollView.hasVerticalScroller = false
        nativeScrollView.verticalScrollElasticity = .none
        nativeScrollView.automaticallyAdjustsContentInsets = false
        nativeScrollView.contentView.postsBoundsChangedNotifications = true
        transportGlass.contentView.addSubview(staticGuideView)
        transportGlass.contentView.addSubview(guideView)
        transportGlass.contentView.addSubview(nativeScrollView)

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleTimelinePan(_:)))
        addGestureRecognizer(pan)
        boundsObservation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: nativeScrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.nativeTimelineBoundsDidChange()
            }
        }
        transportGlass.contentView.addSubview(foregroundView)

        rebuildGroupPresentations()
        reloadNativeTimelineLayout(preservingCurrentOffset: false)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let boundsObservation {
            NotificationCenter.default.removeObserver(boundsObservation)
        }
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard MemoryExplorerVisualShell.transportFrame(viewportWidth: bounds.width).contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        let timelineShell = MemoryExplorerVisualShell.timelineShellFrame(
            viewportWidth: bounds.width
        )
        let previousSize = nativeScrollView.frame.size
        transportGlass.frame = MemoryExplorerVisualShell.transportFrame(viewportWidth: bounds.width)
        let origin = transportGlass.frame.origin
        nativeScrollView.frame = timelineShell.offsetBy(dx: -origin.x, dy: -origin.y)
        foregroundView.frame = bounds.offsetBy(dx: -origin.x, dy: -origin.y)
        guideView.frame = foregroundView.frame
        if staticGuideView.frame != foregroundView.frame {
            staticGuideView.frame = foregroundView.frame
            staticGuideView.needsDisplay = true
        }
        if previousSize != timelineShell.size {
            reloadNativeTimelineLayout(preservingCurrentOffset: true)
        }
        rebuildAccessibilityElements()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }

    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // Canonical TimelineBackgroundView owns the open-hand cursor. Native
        // app-group items install arrow/pointing-hand rectangles themselves.
        addCursorRect(MemoryExplorerVisualShell.transportFrame(viewportWidth: bounds.width), cursor: .openHand)
        addCursorRect(momentChipRect, cursor: .pointingHand)
        addCursorRect(zoomRect, cursor: .pointingHand)
        addCursorRect(zoomInRect, cursor: .pointingHand)
        addCursorRect(overflowRect, cursor: .pointingHand)
        addCursorRect(searchRect, cursor: .pointingHand)
        if let returnToNowRect { addCursorRect(returnToNowRect, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let returnToNowRect, returnToNowRect.contains(point) {
            onJumpToNow?()
            return
        }
        if searchRect.contains(point) {
            onSearch?()
            return
        }
        if zoomRect.contains(point) {
            setZoomLevel(zoomLevel - 10)
            return
        }
        if zoomInRect.contains(point) {
            setZoomLevel(zoomLevel + 10)
            return
        }
        if overflowRect.contains(point) {
            onOverflow?()
            return
        }
        if momentChipRect.contains(point) {
            onMomentChipActivated?()
            return
        }
        let projection = timelineProjection
        if projection.belt.contains(point) {
            let offset = min(latestVisibleOffset ?? snapshot.contiguousDuration,
                max(0, projection.anchor + (point.x - floor(projection.belt.midX)) / projection.scale))
            if let date = snapshot.wallDate(atContiguousOffset: offset) {
                emitSeek(date, source: .click, contiguousOffset: offset)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private var overflowRect: NSRect {
        MemoryExplorerVisualShell.overflowFrame(viewportWidth: bounds.width)
    }

    var overflowMenuAnchor: NSPoint {
        NSPoint(x: overflowRect.midX, y: overflowRect.maxY + 6)
    }

    func resetZoom() {
        setZoomLevel(TimelineLayout.defaultZoomLevel)
    }

    private var contextualOpenContext: LibreReverseTimelineSelectionContext? {
        guard
            let context = LibreReverseTimelineContextResolver.selectedContext(
                in: snapshot,
                selectedSegmentIDs: currentDate == nil ? selectedSegmentIDs : [],
                at: currentDate
            ), LibreReverseContextualOpenContract.presentsControl(for: context.openAction)
        else {
            return nil
        }
        return context
    }

    var contextualOpenAction: LibreReverseContextualOpenAction? { contextualOpenContext?.openAction }

    // Playback geometry uses seconds of presentation time. Navigation retains
    // its original zoom and units, including while playback is paused.
    var playbackPresentationEnabled = false {
        didSet { updateLogZoomRange() }
    }
    private var effectiveLogZoomRange: Float {
        playbackPresentationEnabled ? max(1, Float(nativeScrollView.frame.width / LibreReverseTimelinePresentationPolicy.pointsPerSecond(zoomLevel: zoomLevel))) : max(1, logZoomRange)
    }

    func setZoomLevel(_ proposed: Float) {
        let value = min(
            TimelineLayout.zoomLevelRange.upperBound,
            max(TimelineLayout.zoomLevelRange.lowerBound, proposed)
        )
        guard value != zoomLevel else { return }
        zoomLevel = value
        updateLogZoomRange()
        onZoomChange?(value)
    }

    private func updateLogZoomRange() {
        if let range = TimelineLayout.zoomRange(
            validSeekDuration: snapshot.validSeekInterval?.duration
        ) {
            logZoomRange = TimelineLayout.logZoomRange(
                zoomLevel: zoomLevel,
                rangeLower: range.lowerBound,
                rangeUpper: range.upperBound
            )
        } else {
            logZoomRange = TimelineLayout.minimumVisibleDuration
        }
        reloadNativeTimelineLayout(preservingCurrentOffset: true)
    }

    private func reloadNativeTimelineLayout(preservingCurrentOffset: Bool) {
        // A gesture-supplied contiguous offset takes precedence during a pan so
        // window publication cannot quantize the playhead to segment boundaries.
        // Otherwise the wall date is authoritative: a cached offset would drift
        // backward as live capture appends new segments.
        let preservedOffset =
            currentOffsetOverride
            ?? (isDraggingTimeline
                ? visualContiguousOffset
                : currentDate.flatMap(snapshot.contiguousOffset(atWallDate:)))
            ?? visualContiguousOffset
        var nativePresentations = groupPresentations.enumerated().map { index, presentation in
            LibreReverseTimelineNativePresentation.appGroup(
                index: index,
                offset: presentation.startOffset,
                duration: presentation.duration
            )
        }
        nativePresentations.append(
            contentsOf: snapshot.starredFrames.enumerated().map {
                index, star in
                .star(index: index, offset: star.contiguousOffset)
            })
        nativePresentations.append(
            contentsOf: snapshot.processedAudioSegments.enumerated().compactMap {
                index, segment in
                guard let start = segment.contiguousStartOffset,
                    let end = segment.contiguousEndOffset
                else { return nil }
                return .audio(index: index, offset: start, duration: max(0, end - start))
            })
        // The canonical range matcher performs binary searches over its item
        // presentations. Preserve source order for equal offsets while making
        // that statically required monotonic ordering explicit.
        nativePresentations = nativePresentations.enumerated().sorted {
            if $0.element.offset == $1.element.offset { return $0.offset < $1.offset }
            return $0.element.offset < $1.element.offset
        }.map(\.element)
        // Recreating every item on each live admission (roughly twice a second)
        // is what made recent state visibly flicker while history sat still.
        // With the anchor-relative projection, a changed position needs only a
        // layout invalidation; `reloadData()` is required solely when the set
        // of items itself changes.
        let previousIdentity = nativeTimelineLayout.presentations.map(\.indexPath)
        let nextIdentity = nativePresentations.map(\.indexPath)
        let itemsChanged = previousIdentity != nextIdentity
        nativeTimelineLayout.presentations = nativePresentations
        nativeTimelineLayout.contiguousTimelineDuration = snapshot.contiguousDuration
        nativeTimelineLayout.logZoomRange = effectiveLogZoomRange
        nativeTimelineLayout.invalidateLayout()
        if itemsChanged {
            nativeCollectionView.reloadData()
            nativeCollectionView.layoutSubtreeIfNeeded()
        }
        // The document view must actually be as wide as the layout's content,
        // or `NSClipView` clamps the scroll origin to
        // `max(0, docWidth - viewportWidth)`. Left at the clip width that
        // clamp is exactly 0, so every requested origin was discarded, the
        // timeline never scrolled, and all history rendered to the right of
        // the playhead instead of the left.
        sizeNativeDocumentViewToContent()
        if preservingCurrentOffset, let preservedOffset {
            setNativeScrollOffset(preservedOffset)
        }
        // Index paths describe slots, not the records currently occupying them.
        // Paging often keeps the same item count while replacing every group.
        // Rebind retained cells after geometry and the anchor have been updated.
        nativeCollectionView.layoutSubtreeIfNeeded()
        configureVisibleNativeItems()
        guideView.needsDisplay = true
        foregroundView.needsDisplay = true
        publishVisibleMeetings()
    }

    private func scrollToCurrentDate() {
        // A gesture-supplied offset is authoritative; do not re-derive it.
        if let currentOffsetOverride {
            setNativeScrollOffset(currentOffsetOverride)
            return
        }
        guard let currentDate else {
            LibreReverseTimelineTrace.log("scrollToCurrentDate SKIPPED currentDate=nil")
            return
        }
        guard let offset = snapshot.contiguousOffset(atWallDate: currentDate) else {
            LibreReverseTimelineTrace.log(
                "scrollToCurrentDate SKIPPED no offset for \(currentDate) "
                    + "segments=\(snapshot.processedScreenshotSegments.count)"
            )
            return
        }
        setNativeScrollOffset(offset)
    }

    /// Grows the collection view to the layout's content width so the clip view
    /// has something to scroll.
    private func sizeNativeDocumentViewToContent() {
        let contentSize = nativeTimelineLayout.collectionViewContentSize
        guard contentSize.width > 0 else { return }
        guard let documentWidthConstraint else { return }
        if documentWidthConstraint.constant != contentSize.width {
            documentWidthConstraint.constant = contentSize.width
            nativeScrollView.layoutSubtreeIfNeeded()
        }
        LibreReverseTimelineTrace.log(
            "sizeDoc want=\(contentSize.width) docWidth=\(nativeCollectionView.frame.width)"
        )
    }

    private func setNativeScrollOffset(_ offset: TimeInterval) {
        visualContiguousOffset = offset
        nativeTimelineLayout.anchorOffset = offset
        guideView.needsDisplay = true
        foregroundView.needsDisplay = true
        publishVisibleMeetings()
        LibreReverseTimelineTrace.log(
            "anchor offset=\(offset) duration=\(snapshot.contiguousDuration) "
                + "items=\(nativeTimelineLayout.presentations.count) "
                + "viewportWidth=\(nativeScrollView.frame.width)"
        )
    }

    private func unusedLegacyScrollOffset(_ offset: TimeInterval) {
        sizeNativeDocumentViewToContent()
        guard
            let originX = TimelineLayout.scrollOriginX(
                contiguousOffset: offset,
                viewportWidth: nativeScrollView.frame.width,
                logZoomRange: effectiveLogZoomRange
            )
        else {
            LibreReverseTimelineTrace.log(
                "setNativeScrollOffset REJECTED offset=\(offset) "
                    + "viewportWidth=\(nativeScrollView.frame.width) "
                    + "logZoomRange=\(effectiveLogZoomRange)"
            )
            return
        }
        visualContiguousOffset = offset
        isApplyingProgrammaticScroll = true
        nativeScrollView.contentView.setBoundsOrigin(NSPoint(x: originX, y: 0))
        isApplyingProgrammaticScroll = false
        LibreReverseTimelineTrace.log(
            "setNativeScrollOffset offset=\(offset) requestedOriginX=\(originX) "
                + "actualOriginX=\(nativeScrollView.contentView.bounds.origin.x) "
                + "docWidth=\(nativeCollectionView.frame.width) "
                + "contentSize=\(nativeTimelineLayout.collectionViewContentSize.width) "
                + "viewportWidth=\(nativeScrollView.frame.width) "
                + "duration=\(snapshot.contiguousDuration) "
                + "logZoomRange=\(effectiveLogZoomRange) "
                + "items=\(nativeTimelineLayout.presentations.count)"
        )
    }

    /// Deliberately inert.
    ///
    /// Item positions are projected relative to `anchorOffset`, so the clip
    /// view never scrolls and its bounds origin is permanently zero. Deriving a
    /// seek from that origin resolved to contiguous offset 0 — the *oldest*
    /// loaded moment — and emitted a `.drag` seek there. That re-anchored the
    /// layout, which changed bounds, which re-emitted: a feedback loop that
    /// re-resolved the same moment hundreds of times a second and made the
    /// image alternate between the requested frame and the oldest loaded one.
    ///
    /// The pan recognizer is the authoritative gesture source instead.
    private func nativeTimelineBoundsDidChange() {}

    @objc private func handleTimelinePan(_ recognizer: NSPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard MemoryExplorerVisualShell.timelineShellFrame(viewportWidth: bounds.width)
                .contains(recognizer.location(in: self)) else { return }
            onDragStarted?()
            window?.disableCursorRects()
            NSCursor.closedHand.push()
            panStartDate = currentDate
            panStartOffset =
                visualContiguousOffset
                ?? currentDate.flatMap(snapshot.contiguousOffset(atWallDate:))
                ?? 0
            isDraggingTimeline = true
        case .ended, .cancelled:
            guard isDraggingTimeline else { return }
            emitCurrentPanPosition(recognizer)
            onDragEnded?()
            NSCursor.pop()
            NSCursor.pointingHand.set()
            window?.enableCursorRects()
            isDraggingTimeline = false
        default:
            guard isDraggingTimeline else { return }
            // Translate the drag into contiguous seconds by dividing its pixel
            // displacement by the same scale used to draw the timeline.
            emitCurrentPanPosition(recognizer)
        }
    }

    private func emitCurrentPanPosition(_ recognizer: NSPanGestureRecognizer) {
        guard nativeScrollView.frame.width > 0, effectiveLogZoomRange > 0 else { return }
        let scale = Double(nativeScrollView.frame.width) / Double(effectiveLogZoomRange)
        let translationX = recognizer.translation(in: self).x
        let candidate = panStartOffset - Double(floor(translationX)) / scale
        let clamped = min(max(0, candidate), snapshot.contiguousDuration)
        guard let date = snapshot.wallDate(atContiguousOffset: clamped) else { return }
        setNativeScrollOffset(clamped)
        emitSeek(date, source: .drag, contiguousOffset: clamped)
    }

    private func rebuildGroupPresentations() {
        rulerStarOffsets = snapshot.starredFrames.map(\.contiguousOffset).sorted()
        groupPresentations.removeAll(keepingCapacity: true)
        groupPresentations.reserveCapacity(snapshot.appGroups.count)

        for group in LibreReverseTimelinePresentationPolicy.appGroups(snapshot.processedScreenshotSegments) {
            guard let first = group.segments.first,
                let last = group.segments.last,
                let startOffset = first.contiguousStartOffset,
                let endOffset = last.contiguousEndOffset
            else { continue }
            // Group widths and child positions use gap-compressed contiguous offsets.
            // Groups can contain captures separated by minutes of wall time; using
            // that wall-clock span would overlap neighboring groups and create false gaps.
            let presentation = GroupPresentation(
                startOffset: startOffset,
                duration: max(0, endOffset - startOffset),
                group: group
            )
            groupPresentations.append(presentation)
        }
    }

    private var timelineProjection: (belt: NSRect, anchor: Double, scale: Double) {
        let belt = MemoryExplorerVisualShell.timelineShellFrame(viewportWidth: bounds.width)
        let anchor = visualContiguousOffset ?? currentDate.flatMap(snapshot.contiguousOffset(atWallDate:)) ?? 0
        return (belt, anchor, belt.width / Double(effectiveLogZoomRange))
    }

    private var latestVisibleOffset: Double? {
        guard let latestCapturedDate, let interval = snapshot.validSeekInterval,
              latestCapturedDate >= interval.start, latestCapturedDate <= interval.end else { return nil }
        return snapshot.contiguousOffset(atWallDate: latestCapturedDate)
    }

    private var nowPosition: CGFloat? {
        guard let offset = latestVisibleOffset else { return nil }
        let projection = timelineProjection
        return floor(projection.belt.midX) + (offset - projection.anchor) * projection.scale
    }

    private func drawTimelineGuide() {
        let projection = timelineProjection
        let baseline = MemoryExplorerVisualShell.timelineCenterFromBottom
        let dots = NSBezierPath()
        var x = projection.belt.minX + 1
        while x < projection.belt.maxX {
            dots.appendOval(in: NSRect(x: x - 0.5, y: baseline - 0.5, width: 1, height: 1))
            x += MemoryExplorerVisualShell.timelineDotPitch
        }
        NSColor.white.withAlphaComponent(0.32).setFill()
        dots.fill()
    }

    private func drawTimeRuler(projection: (belt: NSRect, anchor: Double, scale: Double)) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let halfRange = projection.belt.width / projection.scale / 2
        guard let start = snapshot.wallDate(atContiguousOffset: max(0, projection.anchor - halfRange)),
              let end = snapshot.wallDate(atContiguousOffset: min(latestVisibleOffset ?? snapshot.contiguousDuration, projection.anchor + halfRange)),
              end > start else { return }
        // Choose real wall-clock instants first, then project them through the
        // nonlinear axis. Fixed pixel spacing would imply a false hourly scale.
        let target = end.timeIntervalSince(start) / max(1, floor(projection.belt.width / 160))
        let steps: [Double] = [1, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 21600, 43200, 86400, 604800]
        let step = steps.first(where: { $0 >= target }) ?? max(604800, target)
        var instant = ceil(start.timeIntervalSince1970 / step) * step
        var lastX = projection.belt.minX - 120
        let baseline = MemoryExplorerVisualShell.timelineCenterFromBottom
        // A small, bounded number of candidates per visible frame; no per-frame
        // scan over capture history and no new data fetches for ruler labels.
        for _ in 0..<24 {
            guard instant <= end.timeIntervalSince1970 else { break }
            defer { instant += step }
            let date = Date(timeIntervalSince1970: instant)
            guard let offset = snapshot.contiguousOffset(atWallDate: date) else { continue }
            let x = floor(projection.belt.midX) + (offset - projection.anchor) * projection.scale
            guard x >= projection.belt.minX + 24, x <= projection.belt.maxX - 24,
                  x - lastX >= 90, abs(x - projection.belt.midX) >= 28,
                  nowPosition.map({ abs(x - $0) >= 32 }) ?? true else { continue }
            let text = (step >= 60 ? Self.rulerMinuteFormatter : Self.transportTimeFormatter).string(from: date)
            let run = Self.rulerText.run(for: text)
            let size = run.size
            let labelRect = NSRect(x: x - size.width / 2, y: baseline - 21,
                                   width: size.width, height: size.height)
            guard Self.rulerLabelAvoidsNow(labelRect, nowLabelRect: nowLabel?.rect) else { continue }
            NSColor.white.withAlphaComponent(0.3).setFill()
            NSRect(x: x - 0.25, y: baseline - 9, width: 0.5, height: 4).fill()
            run.draw(at: labelRect.origin, in: context)
            lastX = x
        }
    }

    static func rulerLabelAvoidsNow(_ labelRect: NSRect, nowLabelRect: NSRect?) -> Bool {
        // The offscreen Now action stays at the belt edge, independently of
        // the actual latest-date position. Reserve its rendered text bounds.
        guard let nowLabelRect else { return true }
        return !labelRect.intersects(nowLabelRect.insetBy(dx: -6, dy: -2))
    }

    private static let rulerMinuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func drawNowBoundary() {
        if let label = nowLabel, let context = NSGraphicsContext.current?.cgContext {
            Self.nowText.run(for: label.text).draw(at: label.rect.origin, in: context)
        }
        guard let x = nowPosition else { return }
        let belt = timelineProjection.belt
        guard x >= belt.minX + 1, x <= belt.maxX - 1 else { return }
        let baseline = MemoryExplorerVisualShell.timelineCenterFromBottom
        if abs(x - floor(belt.midX)) > 1 {
            NSColor.white.withAlphaComponent(0.6).setFill()
            NSRect(x: x - 0.5, y: baseline - 12, width: 1, height: 24).fill()
        }
    }

    private func drawPlayhead() {
        let rect = MemoryExplorerVisualShell.playheadFrame(viewportWidth: bounds.width)
        NSColor.white.withAlphaComponent(0.68).setFill()
        rect.fill()
        Self.transportAccent.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.midX - 2.5,
            y: MemoryExplorerVisualShell.timelineCenterFromBottom - 2.5,
            width: 5, height: 5), xRadius: 0.6, yRadius: 0.6).fill()
    }

    /// Permanent date/readout module; the full module is the calendar target.
    var momentChipRect: CGRect {
        MemoryExplorerVisualShell.momentChipFrame(viewportWidth: bounds.width)
    }

    private func drawTimeBubble() {
        // NSVisualEffectView's layer compositor may bypass draw(_:); keep the
        // engraved module divider in the same foreground as the readout.
        NSColor.white.withAlphaComponent(0.17).setFill()
        for divider in MemoryExplorerVisualShell.moduleDividers(viewportWidth: bounds.width) { divider.fill() }
        let rect = momentChipRect
        let date = currentDate
        let dateText = date.map(Self.transportDateFormatter.string(from:)) ?? "CHOOSE DATE"
        let timeText = date.map(Self.transportTimeFormatter.string(from:)) ?? "—:—:—"
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Self.calendarSymbol?.draw(in: NSRect(x: rect.minX + 1, y: rect.maxY - 21, width: 12, height: 12))
        Self.dateText.run(for: dateText).draw(at: NSPoint(x: rect.minX + 20, y: rect.maxY - 21), in: context)
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: rect.maxX - 10, y: rect.maxY - 15))
        chevron.line(to: NSPoint(x: rect.maxX - 7, y: rect.maxY - 18))
        chevron.line(to: NSPoint(x: rect.maxX - 4, y: rect.maxY - 15))
        NSColor.white.withAlphaComponent(0.6).setStroke()
        chevron.lineWidth = 0.8
        chevron.stroke()
        Self.transportAccent.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 3, y: rect.minY + 12, width: 5, height: 5),
            xRadius: 0.6, yRadius: 0.6).fill()
        Self.timeText.run(for: timeText).draw(at: NSPoint(x: rect.minX + 20, y: rect.minY + 6), in: context)

    }

    private static let transportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d yyyy")
        return formatter
    }()
    private static let transportTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func drawControls() {
        // Shared stroke geometry gives both columns the same optical centers;
        // font baselines and SF Symbol alignment boxes differ for these shapes.
        let path = NSBezierPath()
        path.lineWidth = 1.25
        path.lineCapStyle = .round
        func line(_ rect: NSRect, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            path.move(to: NSPoint(x: rect.midX + x1, y: rect.midY + y1))
            path.line(to: NSPoint(x: rect.midX + x2, y: rect.midY + y2))
        }
        line(zoomRect, -4.5, 0, 4.5, 0)
        line(zoomInRect, -4.5, 0, 4.5, 0)
        line(zoomInRect, 0, -4.5, 0, 4.5)
        for y: CGFloat in [-4, 0, 4] { line(overflowRect, -5, y, 5, y) }
        path.appendOval(in: NSRect(x: searchRect.midX - 5.5, y: searchRect.midY - 2.5,
                                  width: 8, height: 8))
        line(searchRect, 1.4, -1.4, 5.5, -5.5)
        NSColor.white.withAlphaComponent(0.85).setStroke()
        path.stroke()
    }

    private func emitSeek(
        _ date: Date,
        source: SeekPositionUpdateSource,
        contiguousOffset: TimeInterval? = nil
    ) {
        if let onSeekRequest {
            onSeekRequest(
                TimelineSeekRequest(
                    date: date,
                    source: source,
                    contiguousOffset: contiguousOffset
                )
            )
        } else {
            onSeek?(date)
        }
    }

    private func applicationIcon(bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = image
        return image
    }

    #if DEBUG
    var interactionTestStaticGuideDrawCount: Int { staticGuideView.drawCount }
    var interactionTestRulerDrawCount: Int { guideView.drawCount }

    var interactionTestAppIdentityFrames: [Int: NSRect] {
        Dictionary(uniqueKeysWithValues: nativeCollectionView.visibleItems().compactMap { item in
            guard let index = nativeCollectionView.indexPath(for: item), index.section == 0,
                  let view = (item as? LibreReverseAppSegmentGroupItem)?.drawingView else { return nil }
            return (index.item, view.convert(view.identityIconFrame, to: self))
        })
    }

    var interactionTestVisibleGroupIDs: [Int: [Int64]] {
        Dictionary(uniqueKeysWithValues: nativeCollectionView.visibleItems().compactMap { item in
            guard let index = nativeCollectionView.indexPath(for: item), index.section == 0,
                  let group = (item as? LibreReverseAppSegmentGroupItem)?.drawingView.presentation?.group else { return nil }
            return (index.item, group.segments.map(\.rawID))
        })
    }
    #endif

    private func configureVisibleNativeItems() {
        for item in nativeCollectionView.visibleItems() {
            guard let indexPath = nativeCollectionView.indexPath(for: item) else { continue }
            configureNativeItem(item, at: indexPath)
        }
    }

    private func configureNativeItem(_ item: NSCollectionViewItem, at indexPath: IndexPath) {
        switch indexPath.section {
        case 0:
            guard groupPresentations.indices.contains(indexPath.item),
                let item = item as? LibreReverseAppSegmentGroupItem
            else { return }
            item.drawingView.presentation = .init(
                group: groupPresentations[indexPath.item].group,
                selectedSegmentIDs: selectedSegmentIDs,
                primaryImageProvider: primaryTimelineImageProvider,
                applicationImageProvider: { [weak self] segment in
                    guard let self else { return nil }
                    return self.applicationTimelineImageProvider?(segment)
                        ?? self.applicationIcon(bundleID: segment.bundleID)
                },
                baseColorProvider: timelineBaseColorProvider,
                starOffsets: rulerStarOffsets,
                lastVisibleOffset: latestVisibleOffset,
                wallDateAtOffset: { [weak self] offset in self?.snapshot.wallDate(atContiguousOffset: offset) },
                onClick: { [weak self] date, rawID in
                    guard let self else { return }
                    // Exact binder order: click/seek action, then raw-ID selection.
                    self.emitSeek(date, source: .click)
                    self.selectedSegmentIDs = [rawID]
                }
            )
        case 1:
            guard snapshot.processedAudioSegments.indices.contains(indexPath.item),
                let item = item as? LibreReverseAudioSegmentItem
            else { return }
            let segment = snapshot.processedAudioSegments[indexPath.item]
            let memberIDs = Set([segment.rawID] + (segment.mergedSegmentIDs ?? []))
            item.drawingView.presentation = .init(
                segment: segment,
                selected: !memberIDs.isDisjoint(with: selectedSegmentIDs),
                waveform: meetingWaveformProvider?(segment),
                starOffsets: rulerStarOffsets,
                lastVisibleOffset: latestVisibleOffset,
                wallDateAtOffset: { [weak self] offset in self?.snapshot.wallDate(atContiguousOffset: offset) },
                onClick: { [weak self] date, rawID in
                    guard let self else { return }
                    let selection = self.snapshot.meetingSelection(
                        at: date,
                        anchoredBy: rawID
                    )
                    let selectedID = selection?.segmentID ?? rawID
                    let selectedDate = selection?.seekDate ?? date
                    self.selectedSegmentIDs = [selectedID]
                    if let onMeetingSeek = self.onMeetingSeek {
                        onMeetingSeek(selectedDate, selectedID)
                    } else {
                        self.emitSeek(selectedDate, source: .click)
                    }
                }
            )
        case 2:
            guard snapshot.starredFrames.indices.contains(indexPath.item),
                let item = item as? LibreReverseStarredFrameItem
            else { return }
            item.drawingView.starredFrameDate = snapshot.starredFrames[indexPath.item].date
            item.drawingView.onSelect = { [weak self] date in self?.emitSeek(date, source: .click) }
        default:
            return
        }
    }

    private func rebuildAccessibilityElements() {
        // Canonical app-group items expose no custom accessibility press
        // method. Their NSCollectionViewElement/NSView semantics are inherited,
        // while pointer activation is owned by mouseDown: on the drawing view.
        var elements: [LibreReverseTimelinePressAccessibilityElement] = []
        elements.append(LibreReverseTimelinePressAccessibilityElement(
            label: "Choose date, " + (currentDate.map(Self.transportDateFormatter.string(from:)) ?? "No recording selected"),
            frameInParent: momentChipRect, parent: self
        ) { [weak self] in self?.onMomentChipActivated?() })
        if let returnToNowRect {
            elements.append(LibreReverseTimelinePressAccessibilityElement(
                label: "Jump to Now", frameInParent: returnToNowRect, parent: self
            ) { [weak self] in self?.onJumpToNow?() })
        }
        elements.append(LibreReverseTimelinePressAccessibilityElement(
            label: "Search recordings", frameInParent: searchRect, parent: self
        ) { [weak self] in self?.onSearch?() })
        elements.append(
            LibreReverseTimelinePressAccessibilityElement(
                label: "Zoom out timeline",
                frameInParent: zoomRect,
                parent: self
            ) { [weak self] in
                guard let self else { return }; self.setZoomLevel(self.zoomLevel - 10)
            })
        elements.append(LibreReverseTimelinePressAccessibilityElement(
            label: "Zoom in timeline", frameInParent: zoomInRect, parent: self
        ) { [weak self] in guard let self else { return }; self.setZoomLevel(self.zoomLevel + 10) })
        elements.append(
            LibreReverseTimelinePressAccessibilityElement(
                label: "Timeline menu",
                frameInParent: overflowRect,
                parent: self
            ) { [weak self] in self?.onOverflow?() })

        timelineAccessibilityElements = elements
        // Preserve AppKit's inherited scroll/collection/item accessibility
        // hierarchy. Canonical app-group and star views add no custom methods,
        // labels, or press actions of their own.
        var accessibilityChildren: [Any] = [nativeScrollView]
        accessibilityChildren.append(contentsOf: elements)
        setAccessibilityChildren(accessibilityChildren)
    }

}

extension LibreReverseTimelineOverlayView: NSCollectionViewDataSource {
    nonisolated func numberOfSections(in collectionView: NSCollectionView) -> Int { 3 }

    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        switch section {
        case 0: groupPresentations.count
        case 1: snapshot.processedAudioSegments.count
        case 2: snapshot.starredFrames.count
        default: 0
        }
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let identifier: NSUserInterfaceItemIdentifier
        switch indexPath.section {
        case 0: identifier = LibreReverseAppSegmentGroupItem.identifier
        case 1: identifier = LibreReverseAudioSegmentItem.identifier
        default: identifier = LibreReverseStarredFrameItem.identifier
        }
        let item = collectionView.makeItem(withIdentifier: identifier, for: indexPath)
        configureNativeItem(item, at: indexPath)
        return item
    }
}

/// Identity text yields to starred instants without changing either time position.
private enum LibreReverseTimelineLabelGeometry {
    static func availableEnd(startX: CGFloat, endX: CGFloat, spanStart: Double,
        spanEnd: Double, width: CGFloat, starOffsets: [Double]) -> CGFloat {
        guard spanEnd > spanStart, width > 0 else { return endX }
        let lowerOffset = spanStart + (startX - 8) / width * (spanEnd - spanStart)
        var lower = 0
        var upper = starOffsets.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if starOffsets[middle] < lowerOffset { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower < starOffsets.count else { return endX }
        let starX = (starOffsets[lower] - spanStart) / (spanEnd - spanStart) * width
        return min(endX, starX - 9)
    }
}

enum LibreReverseTimelineWaveformColumns {
    static func firstCenter(visibleMinX: CGFloat, pitch: CGFloat) -> CGFloat {
        ceil((visibleMinX - 1) / pitch) * pitch + 1
    }
}

@MainActor
private final class LibreReverseTimelineForegroundView: NSView {
    #if DEBUG
    private(set) var drawCount = 0
    #endif
    private let drawBody: (NSRect) -> Void

    init(drawBody: @escaping (NSRect) -> Void) {
        self.drawBody = drawBody
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Explicitly regenerate retained vector pixels when moving between
        // displays, including an onSetNeedsDisplay static guide backing.
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        #if DEBUG
        drawCount += 1
        #endif
        drawBody(dirtyRect)
    }
}

/// Native AppKit coordinate and lifecycle layout.
/// Bound native items own their painting and
/// event arbitration; this layout owns projection, visibility and z-order.
@MainActor
private final class LibreReverseTimelineCollectionLayout: NSCollectionViewLayout {
    var presentations: [LibreReverseTimelineNativePresentation] = [] {
        didSet {
            presentationIndicesByIndexPath = Dictionary(
                uniqueKeysWithValues: presentations.indices.map {
                    (presentations[$0].indexPath, $0)
                }
            )
            presentationIndex = .init(
                intervals: presentations.map {
                    .init(offset: $0.offset, duration: $0.duration)
                })
            cachedAttributes.removeAll(keepingCapacity: true)
        }
    }
    var logZoomRange: Float = 1 {
        didSet {
            if oldValue != logZoomRange { cachedAttributes.removeAll(keepingCapacity: true) }
        }
    }
    var contiguousTimelineDuration: TimeInterval = 1

    private var presentationIndex = TimelinePresentationIndex(intervals: [])
    private var presentationIndicesByIndexPath: [IndexPath: Int] = [:]
    private var cachedAttributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var lastBounds = NSRect.zero

    /// Offset of the playhead, in contiguous seconds. Item positions are
    /// projected relative to the seek position with
    /// `x = floor(offset * scale) + floor(viewportWidth * 0.5)`.
    /// The content stays one viewport wide and the playhead stays centered,
    /// so AppKit document-view sizing cannot reset the scroll position.
    var anchorOffset: TimeInterval = 0 {
        didSet {
            guard anchorOffset != oldValue else { return }
            invalidateLayout()
        }
    }

    override var collectionViewContentSize: NSSize {
        guard let scrollView = collectionView?.enclosingScrollView else { return .zero }
        return NSSize(width: scrollView.frame.width, height: scrollView.frame.height)
    }

    override func invalidateLayout() {
        cachedAttributes.removeAll(keepingCapacity: true)
        super.invalidateLayout()
    }

    override func invalidateLayout(with context: NSCollectionViewLayoutInvalidationContext) {
        if context.invalidateEverything || context.invalidateDataSourceCounts {
            cachedAttributes.removeAll(keepingCapacity: true)
        }
        super.invalidateLayout(with: context)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        defer { lastBounds = newBounds }
        return lastBounds.size != newBounds.size
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes]
    {
        guard let scrollView = collectionView?.enclosingScrollView,
            scrollView.frame.width > 0, logZoomRange > 0
        else { return [] }
        let scale = scrollView.frame.width / CGFloat(logZoomRange)
        let halfViewport = floor(scrollView.frame.width * 0.5)
        // Items project at `offset - anchorOffset`, so map the query rect back
        // into the absolute offset space that `presentationIndex` is built in.
        let lower = (rect.minX - halfViewport) / scale + anchorOffset
        let upper = (rect.maxX - halfViewport) / scale + anchorOffset
        let range = presentationIndex.visibleRange(
            centeredAt: (lower + upper) * 0.5,
            duration: upper - lower
        )
        return range.compactMap { presentationIndex in
            layoutAttributes(forPresentationAt: presentationIndex)
        }
    }

    override func layoutAttributesForItem(
        at indexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        guard let presentationIndex = presentationIndicesByIndexPath[indexPath] else { return nil }
        return layoutAttributes(forPresentationAt: presentationIndex)
    }

    private func layoutAttributes(
        forPresentationAt presentationIndex: Int
    ) -> NSCollectionViewLayoutAttributes? {
        guard presentations.indices.contains(presentationIndex),
            let scrollView = collectionView?.enclosingScrollView
        else { return nil }
        let presentation = presentations[presentationIndex]
        let indexPath = presentation.indexPath
        if let cached = cachedAttributes[indexPath] { return cached }
        let frame = TimelineLayout.itemFrame(
            offset: presentation.offset - anchorOffset,
            duration: presentation.duration,
            mediaType: presentation.mediaType,
            viewportWidth: scrollView.frame.width,
            logZoomRange: logZoomRange
        )
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        // All media share the same optical baseline. The upper portion is
        // reserved for identity labels and stars, not a second time track.
        let smoothX = (presentation.offset - anchorOffset) * scrollView.frame.width / Double(logZoomRange)
            + floor(scrollView.frame.width * 0.5)
        let isStar = presentation.mediaType == .star
        attributes.frame = NSRect(x: smoothX - (isStar ? frame.width / 2 : 0), y: isStar ? 12 : 0,
            width: max(1, frame.width), height: isStar ? 38 : 56)
        attributes.zIndex = isStar ? 3 : (presentation.mediaType == .audio ? 2 : 1)
        cachedAttributes[indexPath] = attributes
        return attributes
    }
}

@MainActor
private final class LibreReverseTimelineCoordinateCollectionView: NSCollectionView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

@MainActor
private final class LibreReverseTimelineCoordinateScrollView: NSScrollView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self || hit === contentView || hit === documentView { return nil }
        return hit
    }
}

@MainActor
private final class LibreReverseAppSegmentGroupItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("LibreReverseAppSegmentGroupItem")
    let drawingView = LibreReverseAppSegmentGroupItemDrawingView(frame: .zero)

    override func loadView() { view = drawingView }
}

@MainActor
private final class LibreReverseAudioSegmentItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("LibreReverseAudioSegmentItem")
    let drawingView = LibreReverseAudioSegmentDrawingView(frame: .zero)

    override func loadView() { view = drawingView }
}

@MainActor
private final class LibreReverseStarredFrameItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("LibreReverseStarredFrameItem")
    let drawingView = LibreReverseStarredFrameDrawingView(frame: .zero)

    override func loadView() { view = drawingView }
}

@MainActor
final class LibreReverseAudioSegmentDrawingView: NSView {
    struct Presentation {
        let segment: TimelineSegment
        let selected: Bool
        var waveform: MeetingWaveformEnvelope? = nil
        var starOffsets: [TimeInterval] = []
        var lastVisibleOffset: TimeInterval? = nil
        var wallDateAtOffset: ((TimeInterval) -> Date?)? = nil
        let onClick: (Date, Int64) -> Void
    }

    var presentation: Presentation? {
        didSet {
            needsDisplay = true
            if let segment = presentation?.segment {
                let title = segment.windowName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = title?.isEmpty == false ? title! : "Meeting"
                toolTip = "\(name)\n\(Self.detailDateFormatter.string(from: segment.startDate)) – \(Self.detailTimeFormatter.string(from: segment.endDate))"
                setAccessibilityElement(true)
                setAccessibilityRole(.button)
                setAccessibilityLabel(toolTip)
            }
            window?.invalidateCursorRects(for: self)
        }
    }
    override var frame: NSRect { didSet { if frame != oldValue { needsDisplay = true } } }
    private var hovered = false
    private var hoverTrackingArea: NSTrackingArea?
    private static let ink = NSColor(srgbRed: 0.75, green: 0.70, blue: 0.86, alpha: 1)
    private static let microphoneSymbol = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(paletteColors: [ink]))
    private static let labelParagraph: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return paragraph
    }()
    private static let detailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d HHmm")
        return formatter
    }()
    private static let detailTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    static func labelOrigin(content: NSRect, visible: NSRect, width: CGFloat) -> CGFloat {
        let centered = content.midX - width / 2
        let viewportClamped = max(visible.minX + 10, min(centered, visible.maxX - width - 10))
        return max(content.minX + 5, min(content.maxX - width - 5, viewportClamped))
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
    override func accessibilityPerformPress() -> Bool {
        guard let presentation else { return false }
        presentation.onClick(presentation.segment.startDate, presentation.segment.rawID)
        return true
    }
    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control), let presentation, bounds.width > 0 else {
            super.mouseDown(with: event); return
        }
        let point = convert(event.locationInWindow, from: nil)
        let progress = min(1, max(0, point.x / bounds.width))
        let start = presentation.segment.contiguousStartOffset ?? 0
        let end = presentation.segment.contiguousEndOffset ?? start
        let duration = presentation.segment.endDate.timeIntervalSince(presentation.segment.startDate)
        presentation.onClick(presentation.wallDateAtOffset?(start + (end - start) * progress)
            ?? presentation.segment.startDate.addingTimeInterval(duration * progress), presentation.segment.rawID)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let presentation, !bounds.isEmpty else { return }
        let start = presentation.segment.contiguousStartOffset ?? 0
        let end = presentation.segment.contiguousEndOffset ?? start
        let maximumX = presentation.lastVisibleOffset.map {
            min(bounds.width, max(0, ($0 - start) / max(0.000001, end - start) * bounds.width))
        } ?? bounds.width
        let clippedBounds = NSRect(x: 0, y: 0, width: maximumX, height: bounds.height)
        let visible = dirtyRect.intersection(visibleRect).intersection(clippedBounds)
        guard !visible.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        clippedBounds.clip()
        let baseline: CGFloat = 14
        let pitch = MemoryExplorerVisualShell.timelineDotPitch
        let bars = NSBezierPath()
        let dots = NSBezierPath()
        // Audio columns belong to media time, not the moving viewport grid.
        // Re-anchoring the native item while panning must not change the peak
        // window of every bar and make the recorded waveform appear to pulse.
        var x = LibreReverseTimelineWaveformColumns.firstCenter(visibleMinX: visible.minX, pitch: pitch)
        while x < visible.maxX {
            let left = min(1, max(0, (x - pitch / 2) / max(1, bounds.width)))
            let right = min(1, max(0, (x + pitch / 2) / max(1, bounds.width)))
            let duration = presentation.segment.endDate.timeIntervalSince(presentation.segment.startDate)
            let from = presentation.wallDateAtOffset?(start + (end - start) * left)?
                .timeIntervalSince(presentation.segment.startDate) ?? duration * left
            let to = presentation.wallDateAtOffset?(start + (end - start) * right)?
                .timeIntervalSince(presentation.segment.startDate) ?? duration * right
            let amplitude = presentation.waveform?.peak(from: from, to: to) ?? 0
            if amplitude <= 0.015 {
                // Silence is precisely the capture filament, not a fabricated minimum waveform.
                dots.appendOval(in: NSRect(x: x - 0.5, y: baseline - 0.5, width: 1, height: 1))
            } else {
                let height = min(21, max(2.5, CGFloat(sqrt(amplitude)) * 23))
                bars.move(to: NSPoint(x: x, y: baseline - height / 2))
                bars.line(to: NSPoint(x: x, y: baseline + height / 2))
            }
            x += pitch
        }
        NSColor(calibratedWhite: 0.77, alpha: 0.85).setFill()
        dots.fill()
        Self.ink.withAlphaComponent(hovered || presentation.selected ? 1 : 0.85).setStroke()
        bars.lineWidth = 0.9
        bars.lineCapStyle = .round
        bars.stroke()

        // Engraved start/end gates retain the meeting's identity even when silent
        // or when its local recording has not been hydrated. Their entire item
        // has native hover details and an accessible meeting press action.
        let gates = NSBezierPath()
        for boundary in [CGFloat(0.75), max(0.75, bounds.maxX - 0.75)] {
            gates.move(to: NSPoint(x: boundary, y: baseline - 12))
            gates.line(to: NSPoint(x: boundary, y: baseline + 12))
        }
        Self.ink.withAlphaComponent(hovered || presentation.selected ? 1 : 0.7).setStroke()
        gates.lineWidth = 1
        gates.stroke()
        guard bounds.width >= 56 else { return }
        let visibleBounds = visibleRect.intersection(bounds)
        let title = presentation.segment.windowName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title?.isEmpty == false ? title! : "Meeting"
        let desiredWidth = min(240, visibleBounds.width - 14)
        let labelX = Self.labelOrigin(content: bounds, visible: visibleBounds, width: desiredWidth)
        let labelEnd = LibreReverseTimelineLabelGeometry.availableEnd(startX: labelX,
            endX: min(maximumX, labelX + desiredWidth), spanStart: start, spanEnd: end,
            width: bounds.width, starOffsets: presentation.starOffsets)
        let available = labelEnd - labelX
        guard available > 24 else { return }
        Self.microphoneSymbol?.draw(in: NSRect(x: labelX, y: 35, width: 10, height: 12))
        (name as NSString).draw(in: NSRect(x: labelX + 15, y: 34, width: available - 15, height: 15),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .paragraphStyle: Self.labelParagraph,
                .foregroundColor: NSColor.white.withAlphaComponent(0.8)])
    }
}

@MainActor
private final class LibreReverseAppSegmentGroupItemDrawingView: NSView {
    struct Presentation {
        let group: AppSegmentGroup
        let selectedSegmentIDs: Set<Int64>
        let primaryImageProvider: ((TimelineSegment) -> NSImage?)?
        let applicationImageProvider: (TimelineSegment) -> NSImage?
        let baseColorProvider: ((TimelineSegment) -> NSColor?)?
        var starOffsets: [TimeInterval] = []
        var lastVisibleOffset: TimeInterval? = nil
        var wallDateAtOffset: ((TimeInterval) -> Date?)? = nil
        let onClick: (Date, Int64) -> Void
    }

    var presentation: Presentation? {
        didSet {
            if oldValue?.group != presentation?.group {
                mouseLocation = nil
                hoverRect = nil
            }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    private var mouseLocation: NSPoint?
    private var hoverRect: NSRect?
    // Collection items redraw repeatedly during scrolling. Retain only the last
    // rasterized icon, invalidating when its image or display environment changes.
    private var cachedIcon: (image: NSImage, side: Double, scale: CGFloat, appearance: String, layer: CGLayer)?

    private func iconLayer(_ image: NSImage, side: Double, in context: CGContext) -> CGLayer? {
        let scale = window?.backingScaleFactor ?? 1
        let appearance = effectiveAppearance.name.rawValue
        if let cachedIcon, cachedIcon.image === image, cachedIcon.side == side,
            cachedIcon.scale == scale, cachedIcon.appearance == appearance {
            return cachedIcon.layer
        }
        guard let layer = Self.makeIconLayer(image, side: side, in: context) else { return nil }
        cachedIcon = (image, side, scale, appearance, layer)
        return layer
    }

    override var frame: NSRect {
        didSet {
            // A position-only collection layout can reuse the existing backing
            // store without invoking layout(). Pinned identity and viewport-
            // phased dots must be repainted whenever that position changes.
            if frame != oldValue { needsDisplay = true }
        }
    }

    private var viewportBounds: NSRect {
        guard let clip = enclosingScrollView?.contentView else { return bounds }
        return convert(clip.bounds, from: clip)
    }

    fileprivate var identityIconFrame: NSRect {
        let x = max(bounds.minX + 6, viewportBounds.minX + 6)
        // Align the icon and its label together in window coordinates. Local
        // pixel rounding would change phase as the item moves under the cursor.
        let windowX = convert(NSPoint(x: x, y: 0), to: nil).x
        let scale = window?.backingScaleFactor ?? 1
        let alignedX = x + (windowX * scale).rounded() / scale - windowX
        return NSRect(x: alignedX, y: 33, width: 16, height: 16)
    }

    override func layout() {
        super.layout()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [
                        .mouseEnteredAndExited,
                        .mouseMoved,
                        .activeInActiveApp,
                        .inVisibleRect,
                    ],
                    owner: self,
                    userInfo: nil
                ))
        } else {
            trackingAreas.forEach(removeTrackingArea)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateMouseLocation(event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateMouseLocation(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        mouseLocation = nil
        needsDisplay = true
    }

    private func updateMouseLocation(_ event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        if let presentation, let point = mouseLocation,
            let first = presentation.group.segments.first, let last = presentation.group.segments.last,
            let start = first.contiguousStartOffset, let end = last.contiguousEndOffset {
            let fraction = min(1, max(0, point.x / max(1, bounds.width)))
            let date = presentation.wallDateAtOffset?(start + (end - start) * fraction)
                ?? first.startDate.addingTimeInterval(last.endDate.timeIntervalSince(first.startDate) * fraction)
            let child = presentation.group.segments.last(where: { $0.startDate <= date }) ?? first
            toolTip = [child.bundleID?.split(separator: ".").last.map(String.init), child.windowName, child.browserURL]
                .compactMap { $0 }.joined(separator: "\n")
        }
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let hoverRect {
            addCursorRect(hoverRect, cursor: .pointingHand)
        } else {
            addCursorRect(bounds, cursor: .arrow)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
            return
        }
        guard let presentation else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), let first = presentation.group.segments.first,
            let last = presentation.group.segments.last,
            let start = first.contiguousStartOffset, let end = last.contiguousEndOffset else { return }
        let fraction = min(1, max(0, (point.x - bounds.minX) / max(0.001, bounds.width)))
        let date = presentation.wallDateAtOffset?(start + (end - start) * fraction)
            ?? first.startDate.addingTimeInterval(last.endDate.timeIntervalSince(first.startDate) * fraction)
        let child = presentation.group.segments.last(where: { $0.startDate <= date }) ?? first
        presentation.onClick(date, child.rawID)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let presentation, let first = presentation.group.segments.first else { return }
        let start = first.contiguousStartOffset ?? 0
        let end = presentation.group.segments.last?.contiguousEndOffset ?? start
        let maximumX = presentation.lastVisibleOffset.map {
            min(bounds.width, max(0, ($0 - start) / max(0.000001, end - start) * bounds.width))
        } ?? bounds.width
        let clippedBounds = NSRect(x: 0, y: 0, width: maximumX, height: bounds.height)
        let visible = dirtyRect.intersection(visibleRect).intersection(clippedBounds)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        clippedBounds.clip()

        guard !visible.isEmpty else { return }
        let selected = presentation.group.segments.contains { presentation.selectedSegmentIDs.contains($0.rawID) }
        let hovered = mouseLocation.map(bounds.contains) ?? false
        let source = presentation.baseColorProvider?(first) ?? .lightGray
        let ink = source.blended(withFraction: 0.35, of: .lightGray) ?? .lightGray
        ink.withAlphaComponent(selected || hovered ? 1 : 0.78).setFill()
        let dots = NSBezierPath()
        let pitch = MemoryExplorerVisualShell.timelineDotPitch
        let size = MemoryExplorerVisualShell.activityDotSize
        // Match the fixed white guide phase through scrolling and zoom.
        let originX = enclosingScrollView.map { convert(.zero, to: $0.contentView).x } ?? 0
        var x = ceil((visible.minX + originX - 1) / pitch) * pitch + 1 - originX
        while x < visible.maxX {
            dots.appendRoundedRect(NSRect(x: x - size.width / 2, y: 14 - size.height / 2,
                width: size.width, height: size.height), xRadius: size.width / 2, yRadius: size.width / 2)
            x += pitch
        }
        dots.fill()
        // App runs retain their true mapped width. Labels disappear before
        // they collide; hover keeps the source window available at every zoom.
        let name = first.bundleID.flatMap { ApplicationMetadataProvider.shared.metadata(bundleIdentifier: $0).name }
            ?? first.bundleID?.split(separator: ".").last.map(String.init) ?? "Capture"
        if mouseLocation == nil {
            toolTip = [name, first.windowName, first.browserURL].compactMap { $0 }.joined(separator: "\n")
        }
        let available = bounds.width - 12
        if available >= 20 {
            let icon = presentation.primaryImageProvider?(first) ?? presentation.applicationImageProvider(first)
            let iconFrame = identityIconFrame
            let startX = iconFrame.minX
            let labelEnd = LibreReverseTimelineLabelGeometry.availableEnd(startX: startX,
                endX: min(maximumX, viewportBounds.maxX) - 6, spanStart: start, spanEnd: end,
                width: bounds.width, starOffsets: presentation.starOffsets)
            if let icon, startX + 16 <= labelEnd,
                let context = NSGraphicsContext.current?.cgContext,
                let layer = iconLayer(icon, side: 16, in: context) {
                context.draw(layer, in: iconFrame)
            }
            let labelWidth = min(160, labelEnd - startX - 22)
            if labelWidth >= 36 {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                (name as NSString).draw(in: NSRect(x: startX + 22, y: 34, width: labelWidth, height: 15),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .regular),
                        .foregroundColor: NSColor.white.withAlphaComponent(selected || hovered ? 0.95 : 0.7),
                        .paragraphStyle: paragraph])
            }
        }
        let nextHoverRect = hovered ? bounds : nil
        if hoverRect != nextHoverRect {
            hoverRect = nextHoverRect
            window?.invalidateCursorRects(for: self)
        }
    }

    private static func makeIconLayer(
        _ image: NSImage,
        side: Double,
        in context: CGContext
    ) -> CGLayer? {
        guard
            let layer = CGLayer(
                context,
                size: CGSize(width: side, height: side),
                auxiliaryInfo: nil
            ), let layerContext = layer.context
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(
            cgContext: layerContext,
            flipped: false
        )
        image.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()
        return layer
    }
}

@MainActor
private final class LibreReverseStarredFrameDrawingView: NSView {
    var onSelect: ((Date) -> Void)?
    var starredFrameDate: Date? {
        didSet {
            needsDisplay = true
            toolTip = starredFrameDate.map { "Starred moment · " + Self.dateFormatter.string(from: $0) }
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(toolTip)
        }
    }
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control), let starredFrameDate else {
            super.mouseDown(with: event); return
        }
        onSelect?(starredFrameDate)
    }
    override func accessibilityPerformPress() -> Bool {
        guard let starredFrameDate else { return false }
        onSelect?(starredFrameDate)
        return true
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard starredFrameDate != nil,
            let context = NSGraphicsContext.current?.cgContext,
            let layer = Self.markerLayer(in: context)
        else { return }
        // One starred instant: the glyph is connected to its exact point on
        // the guide, rather than floating as an unrelated app-row decoration.
        NSColor.systemOrange.withAlphaComponent(0.4).setFill()
        NSRect(x: bounds.midX - 0.25, y: 10, width: 0.5, height: 16).fill()
        NSColor.systemOrange.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - 1, y: 7, width: 2, height: 2)).fill()
        context.draw(layer, in: CGRect(x: bounds.midX - 5, y: 28, width: 10, height: 10))

    }

    private static var cachedMarkerLayer: CGLayer?

    private static func markerLayer(in context: CGContext) -> CGLayer? {
        if let cachedMarkerLayer { return cachedMarkerLayer }
        guard
            let symbol = NSImage(
                systemSymbolName: "star",
                accessibilityDescription: nil
            )
        else { return nil }
        let orangeComponents = TimelineStarDrawingStyle.orangeSRGB
        let orange = NSColor(
            srgbRed: orangeComponents.red,
            green: orangeComponents.green,
            blue: orangeComponents.blue,
            alpha: orangeComponents.alpha
        )
        let outer = symbol.withSymbolConfiguration(.init(paletteColors: [orange])) ?? symbol
        let side = TimelineStarDrawingStyle.layerSide
        guard
            let layer = CGLayer(
                context,
                size: CGSize(width: side, height: side),
                auxiliaryInfo: nil
            ), let layerContext = layer.context
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(
            cgContext: layerContext,
            flipped: false
        )
        outer.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        cachedMarkerLayer = layer
        return layer
    }
}

@MainActor
private final class LibreReverseTimelinePressAccessibilityElement: NSAccessibilityElement {
    private let press: () -> Void

    init(label: String, frameInParent: NSRect, parent: Any, press: @escaping () -> Void) {
        self.press = press
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityParent(parent)
        setAccessibilityFrameInParentSpace(frameInParent)
    }

    required init?(coder: NSCoder) { nil }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}
#endif
