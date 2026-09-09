#if os(macOS) && canImport(VisionKit)
import AppKit
import AVFoundation
import CoreImage
import LibreReverseCore
import VideoToolbox
import VisionKit

/// Native selectable-text surface over the exact frame currently owned by
/// the historical presenter. VisionKit handles selection; persisted Vision
/// OCR nodes and FTS indexes separately support search.
@MainActor
final class LibreReverseLiveTextOverlay: NSView, ImageAnalysisOverlayViewDelegate {
    private let overlayView = ImageAnalysisOverlayView(frame: .zero)
    private let areaDimmingView = LibreReversePassthroughView(frame: .zero)
    private let areaContainer = NSView(frame: .zero)
    private let areaImageView = NSImageView(frame: .zero)
    private let areaOverlayView = ImageAnalysisOverlayView(frame: .zero)
    private let areaDragView = LibreReverseLiveTextAreaDragView(frame: .zero)
    private let resultBanner = NSView(frame: .zero)
    private let resultInfoIcon = NSImageView(frame: .zero)
    private let areaInstruction = NSTextField(labelWithString: "You can now select and copy text")
    private let analyzer = ImageAnalyzer()
    private weak var representedContentView: NSView?
    private var representedImageSize = CGSize.zero
    private var representedIdentity: String?
    private var analysisTask: Task<Void, Never>?
    private var areaAnalysisTask: Task<Void, Never>?
    private var representedImage: CGImage?
    private var fullAnalysisAvailable = false
    private var selectionState = LiveTextSelectionState()
    private var eventMonitor: Any?
    private var globalMouseMonitor: Any?
    private var areaAnimationGeneration: UInt64 = 0

    var onTextSelectionChanged: ((Bool) -> Void)?
    var onAreaSelectionAvailabilityChanged: ((Bool) -> Void)?
    var onInteractionBegan: (() -> Void)?
    var isAreaSelectionActive: Bool {
        if case .fullBleed = selectionState.phase { return false }
        return true
    }
    var isAreaModePresented: Bool { !areaDragView.isHidden || !areaContainer.isHidden }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.preferredInteractionTypes = .automatic
        overlayView.delegate = self
        // Keep VisionKit's video action aligned with the floating transport edge,
        // with enough bottom clearance to avoid looking like a detached rail control.
        overlayView.supplementaryInterfaceContentInsets = NSEdgeInsets(
            top: 0, left: 0, bottom: MemoryExplorerVisualShell.bottomOverlayHeight,
            right: MemoryExplorerVisualShell.transportSideInset)
        overlayView.isHidden = true
        areaDimmingView.wantsLayer = true
        areaDimmingView.layer?.backgroundColor = NSColor.black.withAlphaComponent(
            LiveTextContract.areaBackgroundOpacity
        ).cgColor
        areaDimmingView.autoresizingMask = [.width, .height]
        areaDimmingView.isHidden = true
        areaContainer.wantsLayer = true
        areaContainer.layer?.backgroundColor = NSColor.clear.cgColor
        areaContainer.layer?.cornerRadius = LiveTextContract.areaCornerRadius
        areaContainer.layer?.cornerCurve = .continuous
        areaContainer.layer?.masksToBounds = true
        areaContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(
            LiveTextContract.imageBackgroundOpacity
        ).cgColor
        areaContainer.isHidden = true
        areaImageView.imageScaling = .scaleAxesIndependently
        areaImageView.translatesAutoresizingMaskIntoConstraints = false
        areaContainer.addSubview(areaImageView)
        areaOverlayView.translatesAutoresizingMaskIntoConstraints = false
        areaOverlayView.preferredInteractionTypes = .automatic
        areaOverlayView.delegate = self
        areaContainer.addSubview(areaOverlayView)
        NSLayoutConstraint.activate([
            areaImageView.topAnchor.constraint(equalTo: areaContainer.topAnchor),
            areaImageView.leadingAnchor.constraint(equalTo: areaContainer.leadingAnchor),
            areaImageView.trailingAnchor.constraint(equalTo: areaContainer.trailingAnchor),
            areaImageView.bottomAnchor.constraint(equalTo: areaContainer.bottomAnchor),
            areaOverlayView.topAnchor.constraint(equalTo: areaContainer.topAnchor),
            areaOverlayView.leadingAnchor.constraint(equalTo: areaContainer.leadingAnchor),
            areaOverlayView.trailingAnchor.constraint(equalTo: areaContainer.trailingAnchor),
            areaOverlayView.bottomAnchor.constraint(equalTo: areaContainer.bottomAnchor),
        ])
        areaDragView.autoresizingMask = [.width, .height]
        areaDragView.isHidden = true
        areaDragView.onBegin = { [weak self] point in self?.areaDragBegan(at: point) }
        areaDragView.onUpdate = { [weak self] point in self?.areaDragUpdated(to: point) }
        areaDragView.onFinish = { [weak self] point in self?.areaDragFinished(at: point) }
        areaInstruction.font = .systemFont(ofSize: 13, weight: .semibold)
        areaInstruction.textColor = .white
        areaInstruction.alignment = .left
        resultBanner.wantsLayer = true
        resultBanner.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        resultBanner.layer?.cornerRadius = 16.5
        resultBanner.layer?.cornerCurve = .continuous
        resultInfoIcon.image = NSImage(
            systemSymbolName: "info.circle.fill",
            accessibilityDescription: nil
        )
        resultInfoIcon.contentTintColor = .white
        resultInfoIcon.imageScaling = .scaleProportionallyUpOrDown
        resultBanner.addSubview(resultInfoIcon)
        resultBanner.addSubview(areaInstruction)
        resultBanner.isHidden = true
        addSubview(overlayView)
        addSubview(areaDimmingView)
        addSubview(areaContainer)
        addSubview(areaDragView)
        addSubview(resultBanner)
        NSLayoutConstraint.activate([
            overlayView.topAnchor.constraint(equalTo: topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        analysisTask?.cancel()
        areaAnalysisTask?.cancel()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    }

    /// VisionKit's macOS overlay implements no copy action and does not accept
    /// first responder -- `ImageAnalysisOverlayView` answers false to
    /// `acceptsFirstResponder` and does not respond to `copy(_:)`. Selecting
    /// text therefore worked while Cmd-C did nothing, because the keystroke
    /// went to whatever still held focus. The host owns the copy.
    override var acceptsFirstResponder: Bool { true }

    /// The explorer normally activates itself on present, so this rarely
    /// decides anything -- but when it is reached while another application
    /// is frontmost, the press that begins a selection is also the press that
    /// activates, and would otherwise be consumed rather than delivered.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The selection that Cmd-C and the Copy menu item act on. The cropped
    /// area surface owns the selection whenever it is presented.
    var selectedText: String {
        if !areaContainer.isHidden { return areaOverlayView.selectedText }
        return overlayView.selectedText
    }

    /// The whole recognized frame, for Copy All.
    var transcript: String {
        if !areaContainer.isHidden { return areaOverlayView.analysis?.transcript ?? "" }
        return overlayView.analysis?.transcript ?? ""
    }

    @discardableResult
    func copySelection() -> Bool {
        let text = selectedText
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        LibreReverseTimelineTrace.log("LIVETEXT copied chars=\(text.count)")
        return true
    }

    @discardableResult
    func copyAll() -> Bool {
        let text = transcript
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        LibreReverseTimelineTrace.log("LIVETEXT copiedAll chars=\(text.count)")
        return true
    }

    @objc func copy(_ sender: Any?) { copySelection() }

    /// Cmd-C only reaches `copy(_:)` through an Edit menu item, and this is an
    /// accessory app with no main menu. Claim the key equivalent directly so
    /// copying works without depending on a menu that does not exist.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command || modifiers == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c" where modifiers == .command:
            if copySelection() { return true }
        case "c" where modifiers == [.command, .shift]:
            if copyAll() { return true }
        default:
            break
        }
        return super.performKeyEquivalent(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
        } else if eventMonitor == nil {
            installEventMonitor()
        }
    }

    override func layout() {
        super.layout()
        areaDimmingView.frame = bounds
        areaDragView.frame = bounds
        // The explorer window resizes from its entrance frame to its steady
        // frame, and the represented image's aspect-fit box moves with it.
        // VisionKit caches the resolved contents rect, so it has to be told.
        overlayView.setContentsRectNeedsUpdate()
        areaOverlayView.setContentsRectNeedsUpdate()
    }

    private static let unitContentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    func clear() {
        analysisTask?.cancel()
        areaAnalysisTask?.cancel()
        analysisTask = nil
        areaAnalysisTask = nil
        selectionState.representedFrameChanged()
        representedIdentity = nil
        representedContentView = nil
        representedImageSize = .zero
        representedImage = nil
        fullAnalysisAvailable = false
        overlayView.analysis = nil
        overlayView.resetSelection()
        overlayView.isHidden = true
        areaOverlayView.analysis = nil
        areaOverlayView.resetSelection()
        areaAnimationGeneration &+= 1
        areaContainer.layer?.removeAllAnimations()
        areaDimmingView.layer?.removeAllAnimations()
        areaDimmingView.alphaValue = 1
        areaDimmingView.isHidden = true
        areaContainer.isHidden = true
        areaImageView.image = nil
        areaDragView.isHidden = true
        areaDragView.interceptsEvents = false
        areaDragView.lastCompletedSelection = nil
        resultBanner.isHidden = true
        onTextSelectionChanged?(false)
        onAreaSelectionAvailabilityChanged?(false)
    }

    func present(
        image: CGImage,
        identity: String,
        contentView: NSView,
        delayMilliseconds: Int = LiveTextContract.fullFrameDelayMilliseconds
    ) {
        begin(
            identity: identity,
            imageSize: CGSize(width: image.width, height: image.height),
            contentView: contentView,
            delayMilliseconds: delayMilliseconds
        ) { image }
    }

    func presentVideoFrame(
        output: AVPlayerItemVideoOutput,
        itemTime: CMTime,
        identity: String,
        contentView: NSView
    ) {
        begin(
            identity: identity,
            imageSize: .zero,
            contentView: contentView,
            delayMilliseconds: LiveTextContract.fullFrameDelayMilliseconds
        ) {
            var displayTime = CMTime.invalid
            guard let buffer = output.copyPixelBuffer(
                forItemTime: itemTime,
                itemTimeForDisplay: &displayTime
            ) else { return nil }
            var image: CGImage?
            guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr
            else { return nil }
            return image
        }
    }

    private func begin(
        identity: String,
        imageSize: CGSize,
        contentView: NSView,
        delayMilliseconds: Int,
        image: @escaping @MainActor () -> CGImage?
    ) {
        analysisTask?.cancel()
        areaAnalysisTask?.cancel()
        overlayView.analysis = nil
        overlayView.resetSelection()
        overlayView.isHidden = true
        areaOverlayView.analysis = nil
        areaOverlayView.resetSelection()
        areaDimmingView.isHidden = true
        areaDimmingView.alphaValue = 1
        areaContainer.isHidden = true
        areaImageView.image = nil
        areaDragView.isHidden = true
        areaDragView.interceptsEvents = false
        resultBanner.isHidden = true
        selectionState.representedFrameChanged()
        representedImage = nil
        fullAnalysisAvailable = false
        onTextSelectionChanged?(false)
        onAreaSelectionAvailabilityChanged?(false)
        representedIdentity = identity
        representedImageSize = imageSize
        representedContentView = contentView
        analysisTask = Task { [weak self] in
            guard let self else { return }
            if delayMilliseconds > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(delayMilliseconds) * 1_000_000
                )
            }
            guard !Task.isCancelled,
                  self.representedIdentity == identity,
                  let sourceImage = image() else { return }
            self.representedImage = sourceImage
            self.onAreaSelectionAvailabilityChanged?(true)
            self.representedImageSize = CGSize(
                width: sourceImage.width, height: sourceImage.height
            )
            // The represented size is only known once the source image
            // resolves; the video path begins with `.zero`. Invalidate the
            // cached contents rect so the analysis lands on the real box.
            self.overlayView.setContentsRectNeedsUpdate()
            do {
                let configuration = ImageAnalyzer.Configuration([.text])
                let analysis = try await self.analyzer.analyze(
                    sourceImage,
                    orientation: .up,
                    configuration: configuration
                )
                try Task.checkCancellation()
                guard self.representedIdentity == identity else { return }
                self.overlayView.analysis = analysis
                self.overlayView.isHidden = false
                self.fullAnalysisAvailable = true
                LibreReverseTimelineTrace.log(
                    "LIVETEXT analyzed identity=\(identity) "
                    + "image=\(Int(self.representedImageSize.width))x"
                    + "\(Int(self.representedImageSize.height)) "
                    + "content=\(self.representedContentView?.bounds.size ?? .zero) "
                    + "contentsRect=\(self.contentsRect(for: self.overlayView)) "
                    + "transcript=\(analysis.transcript.count) "
                    + "hasText=\(analysis.hasResults(for: .text)) "
                    + "preferred=\(self.overlayView.preferredInteractionTypes.rawValue) "
                    + "active=\(self.overlayView.activeInteractionTypes.rawValue) "
                    + "overlayFrame=\(self.overlayView.frame)"
                )
                self.traceInteractiveMap()
            } catch {
                // Cancellation is the expected result of every superseding
                // scrub. A real failure leaves the overlay absent, never stale.
            }
        }
    }

    func contentView(for overlayView: ImageAnalysisOverlayView) -> NSView? {
        if overlayView === areaOverlayView { return areaContainer }
        return representedContentView
    }

    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        // VisionKit resolves this in unit coordinates, not points: its own
        // default is `(0, 0, 1, 1)`. The area surface scales its image on both
        // axes independently, so it always fills its container exactly.
        if overlayView === areaOverlayView { return Self.unitContentsRect }
        guard let contentView = representedContentView else { return Self.unitContentsRect }
        return LiveTextContract.aspectFitUnitRect(
            imageSize: representedImageSize,
            contentSize: contentView.bounds.size
        )
    }

    func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
        let selected: String
        selected = overlayView.selectedText
        LibreReverseTimelineTrace.log(
            "LIVETEXT selection active=\(overlayView.hasActiveTextSelection) "
            + "chars=\(selected.count) head=\(selected.prefix(48))"
        )
        onTextSelectionChanged?(overlayView.hasActiveTextSelection)
    }

    func overlayView(
        _ overlayView: ImageAnalysisOverlayView,
        shouldBeginAt point: CGPoint,
        forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes
    ) -> Bool {
        LibreReverseTimelineTrace.log(
            "LIVETEXT shouldBegin point=\(point) type=\(analysisType.rawValue)"
        )
        onInteractionBegan?()
        return LiveTextContract.allowsEveryNativeInteraction
    }

    func beginAreaSelection() {
        guard representedImage != nil else { return }
        onInteractionBegan?()
        areaAnalysisTask?.cancel()
        areaOverlayView.analysis = nil
        areaOverlayView.resetSelection()
        areaDimmingView.isHidden = true
        areaDimmingView.alphaValue = 1
        areaContainer.isHidden = true
        overlayView.resetSelection()
        overlayView.isHidden = true
        selectionState.cancelAreaSelection()
        areaDragView.selectionRect = .zero
        areaDragView.lastCompletedSelection = nil
        areaDragView.isHidden = false
        areaDragView.interceptsEvents = true
        resultBanner.isHidden = true
        window?.makeFirstResponder(areaDragView)
    }

    func cancelAreaSelection() {
        cancelAreaSelection(animated: true)
    }

    private func cancelAreaSelection(animated: Bool) {
        areaAnalysisTask?.cancel()
        areaAnalysisTask = nil
        selectionState.cancelAreaSelection()
        areaDragView.selectionRect = .zero
        areaDragView.interceptsEvents = false
        resultBanner.isHidden = true
        areaOverlayView.analysis = nil
        areaOverlayView.resetSelection()
        onTextSelectionChanged?(false)
        areaAnimationGeneration &+= 1
        let generation = areaAnimationGeneration
        areaContainer.layer?.removeAllAnimations()
        areaDimmingView.layer?.removeAllAnimations()

        guard animated, !areaContainer.isHidden,
              let selection = selectionState.selectionRect ?? areaDragView.lastCompletedSelection
        else {
            completeAreaDismissal(generation: generation)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = LiveTextContract.dismissAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            areaContainer.animator().frame = selection
            areaDimmingView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.completeAreaDismissal(generation: generation)
            }
        }
    }

    private func completeAreaDismissal(generation: UInt64) {
        guard generation == areaAnimationGeneration else { return }
        areaContainer.isHidden = true
        areaDimmingView.isHidden = true
        areaDimmingView.alphaValue = 1
        areaImageView.image = nil
        areaDragView.isHidden = true
        areaDragView.lastCompletedSelection = nil
        overlayView.isHidden = !fullAnalysisAvailable
    }

    private func areaDragBegan(at point: CGPoint) {
        selectionState.beginAreaSelection(at: clampedToVisibleImage(point))
        areaDragView.selectionRect = selectionState.selectionRect ?? .zero
    }

    private func areaDragUpdated(to point: CGPoint) {
        selectionState.updateAreaSelection(to: clampedToVisibleImage(point))
        areaDragView.selectionRect = selectionState.selectionRect ?? .zero
    }

    private func areaDragFinished(at point: CGPoint) {
        let visibleImageRect = LiveTextContract.aspectFitRect(
            imageSize: representedImageSize,
            contentSize: bounds.size
        )
        guard let selection = selectionState.finishAreaSelection(
                at: clampedToVisibleImage(point)
              ),
              let image = representedImage,
              let identity = representedIdentity else {
            cancelAreaSelection()
            return
        }
        areaDragView.selectionRect = selection
        let centeredSelection = CGRect(
            x: selection.midX - visibleImageRect.minX,
            y: selection.midY - visibleImageRect.minY,
            width: selection.width,
            height: selection.height
        )
        let rawCrop = LiveTextContract.sourceCropRect(
            imageSize: representedImageSize,
            contentSize: visibleImageRect.size,
            selectionRect: centeredSelection
        ).standardized.integral
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        )
        let crop = rawCrop.intersection(imageBounds)
        guard !crop.isNull, crop.width > 0, crop.height > 0,
              let cropped = image.cropping(to: crop) else {
            selectionState.areaAnalysisFailed()
            cancelAreaSelection()
            return
        }
        areaDragView.selectionRect = .zero
        areaDragView.interceptsEvents = false
        areaAnalysisTask?.cancel()
        areaAnalysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let analysis = try await analyzer.analyze(
                    cropped,
                    orientation: .up,
                    configuration: ImageAnalyzer.Configuration([.text])
                )
                try Task.checkCancellation()
                guard representedIdentity == identity,
                      case .analyzingArea = selectionState.phase else { return }
                selectionState.areaAnalysisCompleted()
                let finalFrame = LiveTextContract.areaOverlayFrame(
                    selectionRect: selection,
                    availableSize: bounds.size
                )
                areaAnimationGeneration &+= 1
                let generation = areaAnimationGeneration
                areaDragView.lastCompletedSelection = selection
                areaContainer.frame = finalFrame
                areaImageView.image = NSImage(cgImage: cropped, size: areaContainer.bounds.size)
                areaOverlayView.analysis = analysis
                areaDimmingView.alphaValue = 1
                areaDimmingView.isHidden = false
                areaContainer.isHidden = false
                areaDragView.isHidden = true
                positionResultBanner()
                animateAreaPresentation(
                    from: selection,
                    to: finalFrame,
                    generation: generation
                )
            } catch {
                guard !Task.isCancelled else { return }
                selectionState.areaAnalysisFailed()
                cancelAreaSelection()
            }
        }
    }

    /// Samples a coarse grid and asks VisionKit which points it considers
    /// interactive. `contentsRect` is the only thing mapping analysis
    /// coordinates onto the surface, and a wrong mapping produces an overlay
    /// that looks correct, reports text, and is unhittable everywhere.
    private func traceInteractiveMap() {
        guard LibreReverseTimelineTrace.isEnabled else { return }
        let step: CGFloat = 100
        var hits: [String] = []
        var tested = 0
        var y = step / 2
        while y < bounds.height {
            var x = step / 2
            while x < bounds.width {
                tested += 1
                if overlayView.hasInteractiveItem(at: CGPoint(x: x, y: y)) {
                    hits.append("(\(Int(x)),\(Int(y)))")
                }
                x += step
            }
            y += step
        }
        LibreReverseTimelineTrace.log(
            "LIVETEXT interactive tested=\(tested) hits=\(hits.count) "
            + "at=\(hits.prefix(12).joined(separator: " "))"
        )
    }

    private func installEventMonitor() {
        if LibreReverseTimelineTrace.isEnabled, globalMouseMonitor == nil {
            // A local monitor only sees what already reached this process.
            // When the explorer is not frontmost the press never arrives at
            // all, and the two cases are indistinguishable without this.
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown]
            ) { _ in
                Task { @MainActor in
                    LibreReverseTimelineTrace.log("LIVETEXT globalMouseDown (not delivered to us)")
                }
            }
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown {
                let local = self.convert(event.locationInWindow, from: nil)
                let hit = self.window?.contentView?.hitTest(event.locationInWindow)
                LibreReverseTimelineTrace.log(
                    "LIVETEXT mouseDown ourWindow=\(event.window === self.window) "
                    + "key=\(self.window?.isKeyWindow ?? false) "
                    + "active=\(NSApp.isActive) point=\(local) "
                    + "inBounds=\(self.bounds.contains(local)) "
                    + "hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") "
                    + "overlayHidden=\(self.overlayView.isHidden) "
                    + "analysis=\(self.fullAnalysisAvailable)"
                )
            }
            if event.type == .leftMouseDown,
               event.window === self.window,
               !self.overlayView.isHidden,
               let hit = self.window?.contentView?.hitTest(event.locationInWindow),
               hit.isDescendant(of: self) {
                // Cmd-C is delivered to the first responder, and the explorer
                // focuses its search field on present. Without claiming focus
                // here the field kept it -- hidden, once scrubbing collapsed
                // the search -- and swallowed every copy of a live selection.
                self.window?.makeFirstResponder(self)
            }
            guard event.window === self.window else { return event }
            if event.type == .keyDown, event.keyCode == 53, self.isAreaSelectionActive {
                self.cancelAreaSelection()
                return nil
            }
            guard event.type != .keyDown else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }

            if event.type == .leftMouseDown,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift),
               self.representedImage != nil {
                self.onInteractionBegan?()
                self.areaAnalysisTask?.cancel()
                self.areaOverlayView.analysis = nil
                self.areaContainer.isHidden = true
                self.overlayView.resetSelection()
                self.overlayView.isHidden = true
                self.selectionState.cancelAreaSelection()
                self.areaDragView.selectionRect = .zero
                self.areaDragView.isHidden = false
                self.areaDragView.interceptsEvents = true
                self.resultBanner.isHidden = true
                self.areaDragBegan(at: point)
                return nil
            }
            if case .selectingArea = self.selectionState.phase {
                if event.type == .leftMouseDragged {
                    self.areaDragUpdated(to: point)
                    return nil
                }
                if event.type == .leftMouseUp {
                    self.areaDragFinished(at: point)
                    return nil
                }
            }

            return event
        }
    }

    private func positionResultBanner() {
        let size = CGSize(width: 269.5, height: LiveTextContract.resultBannerHeight)
        let x = areaContainer.frame.midX - size.width / 2
        let y = areaContainer.frame.minY - LiveTextContract.resultBannerGap - size.height
        resultBanner.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        resultInfoIcon.frame = CGRect(x: 9, y: 8.5, width: 16, height: 16)
        areaInstruction.frame = CGRect(x: 33, y: 8, width: 220.5, height: 17)
    }

    private func animateAreaPresentation(
        from selection: CGRect,
        to finalFrame: CGRect,
        generation: UInt64
    ) {
        guard let layer = areaContainer.layer else {
            resultBanner.isHidden = false
            return
        }
        layer.removeAllAnimations()
        let omega = 2 * Double.pi / LiveTextContract.springResponse
        let stiffness = omega * omega
        let damping = 2 * Double(LiveTextContract.springDampingFraction) * omega

        let position = CASpringAnimation(keyPath: "position")
        position.mass = 1
        position.stiffness = stiffness
        position.damping = damping
        position.initialVelocity = 0
        position.fromValue = CGPoint(x: selection.midX, y: selection.midY)
        position.toValue = CGPoint(x: finalFrame.midX, y: finalFrame.midY)
        position.duration = LiveTextContract.springResponse

        let bounds = CASpringAnimation(keyPath: "bounds.size")
        bounds.mass = position.mass
        bounds.stiffness = position.stiffness
        bounds.damping = position.damping
        bounds.initialVelocity = position.initialVelocity
        bounds.fromValue = selection.size
        bounds.toValue = finalFrame.size
        bounds.duration = position.duration

        layer.add(position, forKey: "selection-area-position")
        layer.add(bounds, forKey: "selection-area-size")
        resultBanner.isHidden = true
        Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(LiveTextContract.springResponse * 1_000_000_000)
            )
            guard !Task.isCancelled,
                  let self,
                  generation == areaAnimationGeneration,
                  !areaContainer.isHidden else { return }
            positionResultBanner()
            resultBanner.isHidden = false
        }
    }

    private func clampedToVisibleImage(_ point: CGPoint) -> CGPoint {
        let rect = LiveTextContract.aspectFitRect(
            imageSize: representedImageSize,
            contentSize: bounds.size
        )
        guard !rect.isEmpty else { return point }
        return CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }
}

@MainActor
private final class LibreReversePassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class LibreReverseLiveTextAreaDragView: NSView {
    var onBegin: ((CGPoint) -> Void)?
    var onUpdate: ((CGPoint) -> Void)?
    var onFinish: ((CGPoint) -> Void)?
    var selectionRect = CGRect.zero { didSet { needsDisplay = true } }
    var lastCompletedSelection: CGRect?
    var interceptsEvents = false

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        interceptsEvents ? super.hitTest(point) : nil
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        onBegin?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        onUpdate?(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        onFinish?(convert(event.locationInWindow, from: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.saveGraphicsState()
        let path = NSBezierPath(rect: bounds)
        if !selectionRect.isEmpty { path.appendRect(selectionRect) }
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(
            LiveTextContract.areaBackgroundOpacity
        ).setFill()
        path.fill()
        guard !selectionRect.isEmpty else {
            NSGraphicsContext.current?.restoreGraphicsState()
            return
        }
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let border = NSBezierPath(roundedRect: selectionRect, xRadius: 3, yRadius: 3)
        border.lineWidth = 2
        border.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
#endif
