#if os(macOS)
import AppKit
import LibreReverseCore
import UniformTypeIdentifiers

@MainActor
final class LibreReverseMeetingRecordingView: NSVisualEffectView {
    private let recordingDot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let editButton = NSButton(title: "", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private var presentation: LibreReverseMeetingRecordingPresentation?
    private var elapsedTimer: Timer?
    var onStop: (() -> Void)?
    var onRenameRequested: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        recordingDot.wantsLayer = true
        recordingDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        recordingDot.layer?.cornerRadius = 5
        recordingDot.translatesAutoresizingMaskIntoConstraints = false
        recordingDot.setAccessibilityLabel("Recording")

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        elapsedLabel.textColor = NSColor.white.withAlphaComponent(0.78)
        elapsedLabel.alignment = .right
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        elapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        elapsedLabel.translatesAutoresizingMaskIntoConstraints = false

        editButton.image = NSImage(
            systemSymbolName: "pencil",
            accessibilityDescription: "Rename meeting"
        )
        editButton.target = self
        editButton.action = #selector(requestRename)
        editButton.bezelStyle = .inline
        editButton.controlSize = .small
        editButton.contentTintColor = NSColor.white.withAlphaComponent(0.68)
        editButton.setAccessibilityLabel("Rename meeting")
        editButton.translatesAutoresizingMaskIntoConstraints = false

        stopButton.target = self
        stopButton.action = #selector(stopRecording)
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        stopButton.contentTintColor = .white
        stopButton.setAccessibilityLabel("Stop meeting recording")
        stopButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(recordingDot)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(elapsedLabel)
        addSubview(editButton)
        addSubview(stopButton)
        NSLayoutConstraint.activate([
            recordingDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            recordingDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            recordingDot.widthAnchor.constraint(equalToConstant: 10),
            recordingDot.heightAnchor.constraint(equalToConstant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            titleLabel.leadingAnchor.constraint(equalTo: recordingDot.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: editButton.leadingAnchor, constant: -5),
            editButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            editButton.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -8),
            editButton.widthAnchor.constraint(equalToConstant: 18),
            editButton.heightAnchor.constraint(equalToConstant: 18),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: elapsedLabel.leadingAnchor, constant: -8),
            elapsedLabel.firstBaselineAnchor.constraint(equalTo: detailLabel.firstBaselineAnchor),
            elapsedLabel.trailingAnchor.constraint(
                equalTo: stopButton.leadingAnchor, constant: -10),
            stopButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stopButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityIdentifier("timeline.meetingRecording")
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func present(_ presentation: LibreReverseMeetingRecordingPresentation) {
        self.presentation = presentation
        titleLabel.stringValue = presentation.title
        stopButton.title = "Stop"
        stopButton.isEnabled = onStop != nil
        editButton.isEnabled = onRenameRequested != nil
        recordingDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        isHidden = false
        updateElapsed(at: Date())
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateElapsed(at: Date())
            }
        }
    }

    func setFinishing(_ detail: String = "Finishing recording…") {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        detailLabel.stringValue = detail
        elapsedLabel.stringValue = ""
        stopButton.title = "Finishing…"
        stopButton.isEnabled = false
        editButton.isEnabled = false
        recordingDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
    }

    func clear() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        presentation = nil
        titleLabel.stringValue = ""
        detailLabel.stringValue = ""
        elapsedLabel.stringValue = ""
        isHidden = true
    }

    private func updateElapsed(at date: Date) {
        guard let presentation else { return }
        detailLabel.stringValue = presentation.audioDescription
        elapsedLabel.stringValue = presentation.elapsedDescription(at: date)
    }

    @objc private func stopRecording() {
        guard stopButton.isEnabled else { return }
        setFinishing()
        onStop?()
    }

    @objc private func requestRename() {
        guard editButton.isEnabled else { return }
        onRenameRequested?()
    }
}

@MainActor
private final class LibreReverseMeetingTranscriptTextView: NSTextView {
    var onUserSelectionBegan: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if LibreReverseMeetingTranscriptInteractionPolicy.interruptsPlayback(
            .userTextSelection
        ) {
            onUserSelectionBegan?()
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if LibreReverseMeetingTranscriptInteractionPolicy.interruptsPlayback(
            .userTextSelection
        ) {
            onUserSelectionBegan?()
        }
        super.rightMouseDown(with: event)
    }
}

@MainActor
private final class LibreReverseTranscriptDragHeader: NSView {
    var onDrag: ((NSSize) -> Void)?
    var dragWindow: (() -> Bool)?
    private var previousLocation: NSPoint?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        if dragWindow?() == true { window?.performDrag(with: event); return }
        previousLocation = event.locationInWindow
    }
    override func mouseDragged(with event: NSEvent) {
        guard let previousLocation else { return }
        let next = event.locationInWindow
        self.previousLocation = next
        onDrag?(NSSize(width: next.x - previousLocation.x, height: next.y - previousLocation.y))
    }
    override func mouseUp(with event: NSEvent) { previousLocation = nil }
}

@MainActor
final class LibreReverseMeetingTranscriptView: NSVisualEffectView, NSTextViewDelegate {
    private let dragHeader = LibreReverseTranscriptDragHeader()
    private let moreButton = NSButton(title: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let playbackButton = NSButton(title: "", target: nil, action: nil)
    private let pinButton = NSButton(title: "", target: nil, action: nil)
    private let transcriptionRetryButton = NSButton(title: "", target: nil, action: nil)
    private let detailsButton = NSButton(title: "", target: nil, action: nil)
    private let renameButton = NSButton(title: "", target: nil, action: nil)
    private let copyButton = NSButton(title: "", target: nil, action: nil)
    private let exportButton = NSButton(title: "", target: nil, action: nil)
    private let deleteButton = NSButton(title: "", target: nil, action: nil)
    private var transcriptionRetryWidthConstraint: NSLayoutConstraint!
    private let scrollView = NSScrollView()
    private let textView = LibreReverseMeetingTranscriptTextView()
    private var transcript: LibreReverseMeetingTranscript?
    private var activeWordIndex: Int?
    private var mutationAdmissionClosed = false
    private var deletionTask: Task<Void, Never>?
    private var renameTask: Task<Void, Never>?
    private var contextTask: Task<Void, Never>?
    private var deletionSegmentID: Int64?
    private var renameSegmentID: Int64?
    private var contextSegmentID: Int64?
    private var transcriptionRetrySegmentID: Int64?
    private var playbackIsActive = false
    private var playbackIsAvailable = false
    private var presentedWallDate: Date?
    private(set) var isPinned = false
    private var playbackNoticeState = LibreReverseMeetingPlaybackNoticeState()
    var onDrag: ((NSSize) -> Void)?
    var onWordSeek: ((Date, Int64) -> Void)?
    var onTextSelectionBegan: (() -> Void)?
    var onTogglePlayback: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onTranscriptCleared: (() -> Void)?
    var onRetryPlayback: ((Int64) -> Void)?
    var onRetryTranscription: ((Int64) throws -> Void)?
    var onRename: ((Int64, String) async throws -> String?)?
    var onUpdateContext:
        ((Int64, [String], String?) async throws -> LibreReverseMeetingContextUpdate)?
    var onDelete: ((Int64) async throws -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2
        detailLabel.cell?.wraps = true
        detailLabel.cell?.usesSingleLineMode = false
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        playbackButton.target = self
        playbackButton.action = #selector(togglePlayback)
        playbackButton.bezelStyle = .inline
        playbackButton.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        playbackButton.translatesAutoresizingMaskIntoConstraints = false
        setPlaybackActive(false)

        pinButton.target = self
        pinButton.action = #selector(togglePin)
        pinButton.bezelStyle = .inline
        pinButton.setAccessibilityIdentifier("timeline.meetingTranscript.pin")
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        setPinned(false)

        transcriptionRetryButton.image = NSImage(
            systemSymbolName: "text.bubble.fill",
            accessibilityDescription: "Retry transcription now"
        )
        transcriptionRetryButton.target = self
        transcriptionRetryButton.action = #selector(retryTranscription)
        transcriptionRetryButton.bezelStyle = .inline
        transcriptionRetryButton.contentTintColor = NSColor.systemOrange
        transcriptionRetryButton.setAccessibilityLabel("Retry transcription now")
        transcriptionRetryButton.toolTip = "Retry transcription now"
        transcriptionRetryButton.translatesAutoresizingMaskIntoConstraints = false
        transcriptionRetryButton.isHidden = true

        renameButton.image = NSImage(
            systemSymbolName: "pencil",
            accessibilityDescription: "Rename meeting"
        )
        renameButton.target = self
        renameButton.action = #selector(renameMeeting)
        renameButton.bezelStyle = .inline
        renameButton.contentTintColor = NSColor.white.withAlphaComponent(0.82)
        renameButton.setAccessibilityLabel("Rename meeting")
        renameButton.translatesAutoresizingMaskIntoConstraints = false

        detailsButton.image = NSImage(
            systemSymbolName: "person.2",
            accessibilityDescription: "Edit meeting details"
        )
        detailsButton.target = self
        detailsButton.action = #selector(editMeetingContext)
        detailsButton.bezelStyle = .inline
        detailsButton.contentTintColor = NSColor.white.withAlphaComponent(0.82)
        detailsButton.setAccessibilityLabel("Edit participants and calendar label")
        detailsButton.translatesAutoresizingMaskIntoConstraints = false

        copyButton.target = self
        copyButton.action = #selector(copyTranscript)
        copyButton.bezelStyle = .inline
        copyButton.image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: "Copy meeting transcript"
        )
        copyButton.contentTintColor = NSColor.white.withAlphaComponent(0.82)
        copyButton.setAccessibilityLabel("Copy meeting transcript")
        copyButton.toolTip = "Copy meeting transcript"
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        exportButton.target = self
        exportButton.action = #selector(exportTranscript)
        exportButton.bezelStyle = .inline
        exportButton.image = NSImage(
            systemSymbolName: "square.and.arrow.up",
            accessibilityDescription: "Export meeting transcript"
        )
        exportButton.contentTintColor = NSColor.white.withAlphaComponent(0.82)
        exportButton.setAccessibilityLabel("Export meeting transcript")
        exportButton.toolTip = "Export meeting transcript"
        exportButton.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.target = self
        deleteButton.action = #selector(confirmDeletion)
        deleteButton.bezelStyle = .inline
        deleteButton.image = NSImage(
            systemSymbolName: "trash",
            accessibilityDescription: "Delete meeting recording and transcript"
        )
        deleteButton.contentTintColor = NSColor.systemRed.withAlphaComponent(0.9)
        deleteButton.hasDestructiveAction = true
        deleteButton.setAccessibilityLabel("Delete meeting recording and transcript")
        deleteButton.toolTip = "Delete meeting recording and transcript"
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.delegate = self
        textView.onUserSelectionBegan = { [weak self] in
            self?.onTextSelectionBegan?()
        }
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.86),
            .underlineStyle: 0,
        ]
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        dragHeader.translatesAutoresizingMaskIntoConstraints = false
        dragHeader.toolTip = "Move transcript"
        dragHeader.setAccessibilityLabel("Move transcript")
        dragHeader.setAccessibilityIdentifier("timeline.meetingTranscript.drag")
        dragHeader.onDrag = { [weak self] delta in self?.onDrag?(delta) }
        dragHeader.dragWindow = { [weak self] in self?.isPinned == true }
        addSubview(dragHeader)
        dragHeader.addSubview(titleLabel)
        dragHeader.addSubview(detailLabel)
        moreButton.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "More meeting actions")
        moreButton.isBordered = false
        moreButton.contentTintColor = .secondaryLabelColor
        moreButton.target = self
        moreButton.action = #selector(showMoreActions)
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.toolTip = "More meeting actions"
        moreButton.setAccessibilityIdentifier("timeline.meetingTranscript.more")
        addSubview(moreButton)
        addSubview(playbackButton)
        addSubview(pinButton)
        addSubview(transcriptionRetryButton)
        addSubview(detailsButton)
        addSubview(renameButton)
        addSubview(copyButton)
        addSubview(exportButton)
        addSubview(deleteButton)
        addSubview(scrollView)
        transcriptionRetryWidthConstraint =
            transcriptionRetryButton.widthAnchor.constraint(equalToConstant: 0)
        for button in [detailsButton, renameButton, exportButton, deleteButton] { button.isHidden = true }
        NSLayoutConstraint.activate([
            dragHeader.topAnchor.constraint(equalTo: topAnchor),
            dragHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            dragHeader.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragHeader.bottomAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: dragHeader.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: dragHeader.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: dragHeader.trailingAnchor, constant: -20),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.heightAnchor.constraint(lessThanOrEqualToConstant: 30),
            playbackButton.topAnchor.constraint(equalTo: dragHeader.bottomAnchor),
            playbackButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            playbackButton.widthAnchor.constraint(equalToConstant: 28),
            playbackButton.heightAnchor.constraint(equalToConstant: 28),
            transcriptionRetryButton.leadingAnchor.constraint(equalTo: playbackButton.trailingAnchor, constant: 8),
            transcriptionRetryButton.centerYAnchor.constraint(equalTo: playbackButton.centerYAnchor),
            transcriptionRetryWidthConstraint,
            transcriptionRetryButton.heightAnchor.constraint(equalToConstant: 24),
            copyButton.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -12),
            copyButton.centerYAnchor.constraint(equalTo: playbackButton.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 24),
            copyButton.heightAnchor.constraint(equalToConstant: 24),
            pinButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -12),
            pinButton.centerYAnchor.constraint(equalTo: playbackButton.centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 24),
            pinButton.heightAnchor.constraint(equalToConstant: 24),
            moreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            moreButton.centerYAnchor.constraint(equalTo: playbackButton.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 24),
            moreButton.heightAnchor.constraint(equalToConstant: 24),
            scrollView.topAnchor.constraint(equalTo: playbackButton.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        setAccessibilityIdentifier("timeline.meetingTranscript")
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func present(_ transcript: LibreReverseMeetingTranscript?, at wallDate: Date) {
        guard let transcript else {
            clear()
            return
        }
        let changed = LibreReverseMeetingTranscriptInteractionPolicy.requiresTextRebuild(
            previous: self.transcript,
            next: transcript
        )
        playbackNoticeState.transcriptDidPresent(segmentID: transcript.segmentID)
        self.transcript = transcript
        presentedWallDate = wallDate
        titleLabel.stringValue = transcript.title.isEmpty ? "Meeting transcript" : transcript.title
        titleLabel.toolTip = titleLabel.stringValue
        isHidden = false
        refreshMutationPresentation()
        updatePlaybackButtonPresentation()
        let active = transcript.activeWordIndex(at: wallDate)
        if changed {
            activeWordIndex = active
            rebuildText()
        } else {
            updateActiveWord(active)
        }
    }

    func updatePlayback(at wallDate: Date) {
        guard let transcript else { return }
        presentedWallDate = wallDate
        let active = transcript.activeWordIndex(at: wallDate)
        updateActiveWord(active)
    }

    // Playback changes decoration, never the text or its metrics. Replacing
    // text storage on each word invalidates layout and native text selection.
    private func updateActiveWord(_ active: Int?) {
        guard active != activeWordIndex, let transcript,
            let storage = textView.textStorage else { return }
        let previous = activeWordIndex
        activeWordIndex = active
        storage.beginEditing()
        for index in [previous, active].compactMap({ $0 }) {
            guard transcript.words.indices.contains(index) else { continue }
            let word = transcript.words[index]
            guard let range = LibreReverseMeetingTranscriptInteractionPolicy.linkRange(
                fullTextUTF16Length: storage.length,
                wordTextUTF16Length: (word.text as NSString).length,
                offset: word.fullTextUTF16Offset
            ) else { continue }
            storage.removeAttribute(.backgroundColor, range: range)
            storage.addAttribute(.foregroundColor,
                value: NSColor.white.withAlphaComponent(0.76), range: range)
            switch LibreReverseMeetingSpeechSourceKind(persistedValue: word.speechSource) {
            case .me:
                storage.addAttribute(.backgroundColor,
                    value: NSColor.systemCyan.withAlphaComponent(0.14), range: range)
            case .others:
                storage.addAttribute(.backgroundColor,
                    value: NSColor.systemPurple.withAlphaComponent(0.14), range: range)
            case .unknown: break
            }
            if index == active {
                storage.addAttributes([
                    .foregroundColor: NSColor.white,
                    .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.34)
                ], range: range)
            }
        }
        storage.endEditing()
        scrollToActiveWord()
    }

    func setPlaybackActive(_ active: Bool) {
        playbackIsActive = active
        if active, let segmentID = transcript?.segmentID {
            playbackNoticeState.mediaDidBecomeReady(segmentID: segmentID)
        }
        refreshMutationPresentation()
        updatePlaybackButtonPresentation()
    }

    func setPlaybackAvailable(_ available: Bool) {
        playbackIsAvailable = available
        if available, let segmentID = transcript?.segmentID {
            playbackNoticeState.mediaDidBecomeReady(segmentID: segmentID)
        }
        refreshMutationPresentation()
        updatePlaybackButtonPresentation()
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        layer?.cornerRadius = pinned ? 0 : 12
        layer?.borderWidth = pinned ? 0 : 0.5
        material = pinned ? .windowBackground : .hudWindow
        let label = pinned ? "Unpin meeting transcript" : "Pin meeting transcript"
        pinButton.image = NSImage(
            systemSymbolName: pinned ? "pin.fill" : "pin",
            accessibilityDescription: label
        )
        pinButton.contentTintColor = pinned
            ? NSColor.systemBlue
            : NSColor.white.withAlphaComponent(0.82)
        pinButton.setAccessibilityLabel(label)
        pinButton.toolTip = label
        pinButton.isEnabled = transcript != nil && onTogglePin != nil
    }

    func copyPresentation(to destination: LibreReverseMeetingTranscriptView) -> Bool {
        guard let transcript, let presentedWallDate else { return false }
        destination.present(transcript, at: presentedWallDate)
        destination.setPlaybackAvailable(playbackIsAvailable)
        destination.setPlaybackActive(playbackIsActive)
        if let notice = playbackNoticeState.notice {
            _ = destination.presentPlaybackNotice(notice.kind, segmentID: notice.segmentID)
        }
        return true
    }

    var presentedSegmentID: Int64? { transcript?.segmentID }
    var presentedDate: Date? { presentedWallDate }

    @discardableResult
    func presentPlaybackNotice(
        _ kind: LibreReverseMeetingPlaybackNoticeKind,
        segmentID: Int64
    ) -> Bool {
        guard
            playbackNoticeState.present(
                kind,
                for: segmentID,
                selectedSegmentID: transcript?.segmentID
            )
        else { return false }
        refreshMutationPresentation()
        updatePlaybackButtonPresentation()
        return true
    }

    #if DEBUG
    func presentFixtureAction(_ action: String) {
        switch action {
        case "actions": showMoreActions()
        case "rename": renameMeeting()
        case "context": editMeetingContext()
        case "export": exportTranscript()
        case "delete": confirmDeletion()
        default: break
        }
    }
    #endif

    func makeActionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, button) in [("Rename meeting…", renameButton), ("Edit meeting details…", detailsButton),
                                ("Export transcript…", exportButton), ("Delete meeting…", deleteButton)] {
            if button === deleteButton { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: #selector(performMoreAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = button
            item.isEnabled = button.isEnabled
            item.image = button.image
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showMoreActions() {
        makeActionsMenu().popUp(positioning: nil, at: NSPoint(x: moreButton.bounds.maxX, y: moreButton.bounds.minY), in: moreButton)
    }

    @objc private func performMoreAction(_ item: NSMenuItem) {
        guard let button = item.representedObject as? NSButton, button.isEnabled,
            let action = button.action else { return }
        NSApp.sendAction(action, to: button.target, from: button)
    }

    private func updatePlaybackButtonPresentation() {
        if let notice = playbackNoticeState.notice,
            notice.segmentID == transcript?.segmentID
        {
            switch notice.kind {
            case .failedToPrepare, .failedDuringPlayback:
                playbackButton.image = NSImage(
                    systemSymbolName: "arrow.clockwise",
                    accessibilityDescription: "Retry loading meeting recording"
                )
                playbackButton.setAccessibilityLabel("Retry loading meeting recording")
                playbackButton.toolTip = "Retry loading meeting recording"
                playbackButton.isEnabled = onRetryPlayback != nil
                return
            case .retrying:
                playbackButton.image = NSImage(
                    systemSymbolName: "arrow.triangle.2.circlepath",
                    accessibilityDescription: "Loading meeting recording"
                )
                playbackButton.setAccessibilityLabel("Loading meeting recording")
                playbackButton.toolTip = "Loading meeting recording…"
                playbackButton.isEnabled = false
                return
            case .stalled:
                break
            }
        }
        let retryingStall = playbackNoticeState.notice?.kind == .stalled
        let accessibilityLabel =
            playbackIsActive
            ? "Pause meeting" : (retryingStall ? "Retry meeting playback" : "Play meeting")
        playbackButton.image = NSImage(
            systemSymbolName: playbackIsActive ? "pause.fill" : "play.fill",
            accessibilityDescription: accessibilityLabel
        )
        playbackButton.setAccessibilityLabel(accessibilityLabel)
        playbackButton.toolTip = "\(accessibilityLabel) (Space)"
        // An in-flight child transition temporarily has no ready replacement
        // media, but an already-playing meeting must remain pausable.
        playbackButton.isEnabled = LibreReverseMeetingPlaybackControlPolicy.isEnabled(
            hasAction: onTogglePlayback != nil,
            isActive: playbackIsActive,
            mediaAvailable: playbackIsAvailable
        )
    }

    func clear() {
        let hadTranscript = transcript != nil
        transcript = nil
        presentedWallDate = nil
        activeWordIndex = nil
        transcriptionRetrySegmentID = nil
        playbackNoticeState.clear()
        transcriptionRetryButton.isHidden = true
        transcriptionRetryWidthConstraint.constant = 0
        titleLabel.stringValue = ""
        detailLabel.stringValue = ""
        detailLabel.toolTip = nil
        textView.textStorage?.setAttributedString(NSAttributedString())
        updatePlaybackButtonPresentation()
        setPinned(false)
        isHidden = true
        if hadTranscript { onTranscriptCleared?() }
    }

    func applyCompletedDeletion(segmentID: Int64) {
        let remaining = LibreReverseMeetingTranscriptMutationResult.applyingDeletion(
            operationSegmentID: segmentID, to: transcript)
        if remaining == nil {
            // Keep the old identity until clear records whether it must notify
            // the pinned-window owner; assigning nil first suppresses closure.
            clear()
        } else {
            refreshMutationPresentation()
        }
    }

    @objc private func togglePin() {
        guard transcript != nil else { return }
        onTogglePin?()
    }

    private func rebuildText() {
        guard let transcript else { return }
        guard transcript.hasTranscriptText else {
            textView.textStorage?.setAttributedString(
                NSAttributedString(
                    string: transcript.processingState.emptyStateDescription,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 14, weight: .regular),
                        .foregroundColor: NSColor.white.withAlphaComponent(0.46),
                        .obliqueness: 0.12,
                    ]
                ))
            return
        }
        let fullTextUTF16Length = (transcript.text as NSString).length
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.paragraphSpacing = 8
        let rendered = NSMutableAttributedString(
            string: transcript.text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.84),
                .paragraphStyle: paragraph,
            ]
        )
        for (index, word) in transcript.words.enumerated() {
            let length = (word.text as NSString).length
            guard
                let range = LibreReverseMeetingTranscriptInteractionPolicy.linkRange(
                    fullTextUTF16Length: fullTextUTF16Length,
                    wordTextUTF16Length: length,
                    offset: word.fullTextUTF16Offset
                ),
                let link = URL(string: "librereverse-word://\(index)")
            else { continue }
            rendered.addAttribute(.link, value: link, range: range)
            let source = LibreReverseMeetingSpeechSourceKind(
                persistedValue: word.speechSource
            )
            switch source {
            case .me:
                rendered.addAttribute(
                    .backgroundColor,
                    value: NSColor.systemCyan.withAlphaComponent(0.14),
                    range: range
                )
            case .others:
                rendered.addAttribute(
                    .backgroundColor,
                    value: NSColor.systemPurple.withAlphaComponent(0.14),
                    range: range
                )
            case .unknown:
                break
            }
            if index == activeWordIndex {
                rendered.addAttributes(
                    [
                        .foregroundColor: NSColor.white,
                        .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.34),
                    ], range: range)
            }
        }
        textView.textStorage?.setAttributedString(rendered)
        scrollToActiveWord()
    }

    private func scrollToActiveWord() {
        // A user selecting text owns the scroll position until selection ends.
        guard textView.selectedRange().length == 0, let transcript else { return }
        if let activeWordIndex,
            transcript.words.indices.contains(activeWordIndex),
            let range = LibreReverseMeetingTranscriptInteractionPolicy.linkRange(
                fullTextUTF16Length: (transcript.text as NSString).length,
                wordTextUTF16Length: (transcript.words[activeWordIndex].text as NSString).length,
                offset: transcript.words[activeWordIndex].fullTextUTF16Offset
            )
        {
            textView.scrollRangeToVisible(NSRange(location: range.location, length: 1))
        }
    }

    func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        guard let url = link as? URL,
            url.scheme == "librereverse-word",
            let index = Int(url.host ?? ""),
            let transcript,
            let seekDate = transcript.wallDate(forWordAt: index)
        else { return false }
        onWordSeek?(seekDate, transcript.segmentID)
        return true
    }

    @objc private func copyTranscript() {
        guard let text = transcript?.text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func retryTranscription() {
        guard !mutationAdmissionClosed else { return }
        guard transcriptionRetrySegmentID == nil,
            let transcript,
            case .retrying = transcript.processingState,
            let onRetryTranscription
        else { return }
        transcriptionRetrySegmentID = transcript.segmentID
        refreshMutationPresentation()
        do {
            try onRetryTranscription(transcript.segmentID)
            if self.transcript?.segmentID == transcript.segmentID {
                self.transcript = self.transcript?.updatingProcessingState(.queued)
                rebuildText()
            }
            transcriptionRetrySegmentID = nil
            refreshMutationPresentation()
        } catch {
            transcriptionRetrySegmentID = nil
            refreshMutationPresentation()
            if let window {
                NSAlert(error: error).beginSheetModal(for: window) { _ in }
            }
        }
    }

    @objc private func togglePlayback() {
        guard playbackButton.isEnabled else { return }
        if let segmentID = transcript?.segmentID,
            playbackNoticeState.retryDidBegin(segmentID: segmentID)
        {
            refreshMutationPresentation()
            updatePlaybackButtonPresentation()
            onRetryPlayback?(segmentID)
            return
        }
        onTogglePlayback?()
    }

    /// Routes Space through the same enabled state and retry action as the
    /// disclosed control. Returning true consumes the shortcut while the
    /// meeting follower owns it, including remote/unavailable disabled states.
    func handlePlaybackShortcut() -> Bool {
        guard !isHidden else { return false }
        if playbackButton.isEnabled { togglePlayback() }
        return true
    }

    @objc private func exportTranscript() {
        guard let transcript, let window else { return }
        let panel = NSSavePanel()
        #if DEBUG
        if LibreReverseDevelopmentEnvironment.values["LIBREREVERSE_PINNED_TRANSCRIPT_UI_FIXTURE"] != nil,
           let directory = LibreReverseDevelopmentEnvironment.values["LIBREREVERSE_SETTINGS_FIXTURE_ROOT"] {
            panel.directoryURL = URL(fileURLWithPath: directory)
        }
        #endif
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "Export transcript"
        panel.nameFieldStringValue = LibreReverseMeetingTranscriptExport.suggestedFileName(
            transcript
        )
        LibreReverseTranscriptExportPanel.configure(panel)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try LibreReverseMeetingTranscriptExport.data(transcript, format: LibreReverseTranscriptExportPanel.selectedFormat(in: panel))
                    .write(to: destination, options: .atomic)
            } catch {
                let alert = NSAlert(error: error)
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func renameMeeting() {
        guard !mutationAdmissionClosed else { return }
        guard renameTask == nil,
            deletionTask == nil,
            contextTask == nil,
            let transcript,
            let onRename,
            let window
        else { return }
        let alert = NSAlert()
        alert.messageText = "Meeting title"
        alert.informativeText =
            "The new title will be used in the transcript, search, timeline, and archived meeting."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = transcript.title
        field.placeholderString = "Meeting"
        field.setAccessibilityLabel("Meeting title")
        alert.accessoryView = field
        field.selectText(nil)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                let self, !self.mutationAdmissionClosed,
                LibreReverseMeetingTranscriptMutationResult.canBegin(
                    operationSegmentID: transcript.segmentID,
                    selectedSegmentID: self.transcript?.segmentID
                )
            else { return }
            let requested = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard requested != transcript.title else { return }
            self.renameSegmentID = transcript.segmentID
            self.setRenaming(true)
            self.renameTask = Task { [weak self] in
                do {
                    let stored = try await onRename(transcript.segmentID, requested) ?? ""
                    guard let self else { return }
                    self.renameTask = nil
                    self.transcript = LibreReverseMeetingTranscriptMutationResult.applyingTitle(
                        stored,
                        operationSegmentID: transcript.segmentID,
                        to: self.transcript
                    )
                    if let updated = self.transcript,
                        updated.segmentID == transcript.segmentID
                    {
                        self.titleLabel.stringValue =
                            stored.isEmpty
                            ? "Meeting transcript" : stored
                    }
                    self.setRenaming(false)
                } catch {
                    guard let self else { return }
                    self.renameTask = nil
                    self.setRenaming(false)
                    if let window = self.window {
                        NSAlert(error: error).beginSheetModal(for: window) { _ in }
                    }
                }
            }
        }
    }

    @objc private func editMeetingContext() {
        guard !mutationAdmissionClosed else { return }
        guard contextTask == nil,
            renameTask == nil,
            deletionTask == nil,
            let transcript,
            let onUpdateContext,
            let window
        else { return }

        let alert = NSAlert()
        alert.messageText = "Meeting details"
        alert.informativeText =
            "Separate participant names with commas."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let participantsLabel = NSTextField(labelWithString: "Participants")
        let participantsField = NSTextField(
            string: LibreReverseMeetingContextUpdate(
                participants: transcript.metadata.participants,
                calendarTitle: transcript.metadata.calendarTitle
            ).participantText
        )
        participantsField.placeholderString = "Ada, Grace"
        participantsField.setAccessibilityLabel("Meeting participants")
        let calendarLabel = NSTextField(labelWithString: "Calendar label")
        let calendarField = NSTextField(string: transcript.metadata.calendarTitle ?? "")
        calendarField.placeholderString = "Work"
        calendarField.setAccessibilityLabel("Meeting calendar label")
        for label in [participantsLabel, calendarLabel] {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
        }
        let stack = NSStackView(views: [
            participantsLabel, participantsField, calendarLabel, calendarField,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.setFrameSize(NSSize(width: 340, height: 92))
        participantsField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        calendarField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        alert.accessoryView = stack
        participantsField.selectText(nil)

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                let self, !self.mutationAdmissionClosed,
                LibreReverseMeetingTranscriptMutationResult.canBegin(
                    operationSegmentID: transcript.segmentID,
                    selectedSegmentID: self.transcript?.segmentID
                )
            else { return }
            let requested = LibreReverseMeetingContextUpdate(
                participantText: participantsField.stringValue,
                calendarTitle: calendarField.stringValue
            )
            let existing = LibreReverseMeetingContextUpdate(
                participants: transcript.metadata.participants,
                calendarTitle: transcript.metadata.calendarTitle
            )
            guard requested != existing else { return }
            self.contextSegmentID = transcript.segmentID
            self.setUpdatingContext(true)
            self.contextTask = Task { [weak self] in
                do {
                    let stored = try await onUpdateContext(
                        transcript.segmentID,
                        requested.participants,
                        requested.calendarTitle
                    )
                    guard let self else { return }
                    self.contextTask = nil
                    self.transcript = LibreReverseMeetingTranscriptMutationResult.applyingContext(
                        stored,
                        operationSegmentID: transcript.segmentID,
                        to: self.transcript
                    )
                    if let updated = self.transcript,
                        updated.segmentID == transcript.segmentID
                    {
                        self.updateDetailLabel(updated)
                    }
                    self.setUpdatingContext(false)
                } catch {
                    guard let self else { return }
                    self.contextTask = nil
                    self.setUpdatingContext(false)
                    if let window = self.window {
                        NSAlert(error: error).beginSheetModal(for: window) { _ in }
                    }
                }
            }
        }
    }

    @objc private func confirmDeletion() {
        guard !mutationAdmissionClosed else { return }
        guard deletionTask == nil,
            renameTask == nil,
            contextTask == nil,
            let transcript,
            let onDelete,
            let window
        else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this meeting?"
        alert.informativeText =
            "The recording and transcript will be permanently removed from this Mac and the selected cloud archive. This can’t be undone."
        let delete = alert.addButton(withTitle: "Delete Meeting")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                let self, !self.mutationAdmissionClosed,
                LibreReverseMeetingTranscriptMutationResult.canBegin(
                    operationSegmentID: transcript.segmentID,
                    selectedSegmentID: self.transcript?.segmentID
                )
            else { return }
            self.deletionSegmentID = transcript.segmentID
            self.setDeleting(true)
            self.deletionTask = Task { [weak self] in
                do {
                    try await onDelete(transcript.segmentID)
                    guard let self else { return }
                    self.deletionTask = nil
                    self.deletionSegmentID = nil
                    self.applyCompletedDeletion(segmentID: transcript.segmentID)
                } catch {
                    guard let self else { return }
                    self.deletionTask = nil
                    self.setDeleting(false)
                    if let window = self.window {
                        NSAlert(error: error).beginSheetModal(for: window) { _ in }
                    }
                }
            }
        }
    }

    private func setDeleting(_ deleting: Bool) {
        if !deleting { deletionSegmentID = nil }
        refreshMutationPresentation()
    }

    private func setRenaming(_ renaming: Bool) {
        if !renaming { renameSegmentID = nil }
        refreshMutationPresentation()
    }

    private func setUpdatingContext(_ updating: Bool) {
        if !updating { contextSegmentID = nil }
        refreshMutationPresentation()
    }

    func closeMutationAdmission() {
        mutationAdmissionClosed = true
        refreshMutationPresentation()
    }

    private func refreshMutationPresentation() {
        guard let transcript else { return }
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        detailLabel.setAccessibilityLabel(nil)
        detailLabel.toolTip = nil
        let mutationInFlight = mutationAdmissionClosed ||
            deletionTask != nil || renameTask != nil || contextTask != nil
            || deletionSegmentID != nil || renameSegmentID != nil || contextSegmentID != nil
            || transcriptionRetrySegmentID != nil
        renameButton.isEnabled = !mutationInFlight && onRename != nil
        detailsButton.isEnabled = !mutationInFlight && onUpdateContext != nil
        deleteButton.isEnabled = !mutationInFlight && onDelete != nil
        copyButton.isEnabled = !mutationInFlight && transcript.hasTranscriptText
        exportButton.isEnabled = !mutationInFlight
        pinButton.isEnabled = !mutationInFlight && onTogglePin != nil
        textView.isSelectable = !mutationInFlight
        let transcriptionCanRetry: Bool
        if case .retrying = transcript.processingState {
            transcriptionCanRetry = true
        } else {
            transcriptionCanRetry = false
        }
        transcriptionRetryButton.isHidden = !transcriptionCanRetry
        transcriptionRetryWidthConstraint.constant = transcriptionCanRetry ? 20 : 0
        transcriptionRetryButton.isEnabled =
            transcriptionCanRetry && !mutationInFlight && onRetryTranscription != nil
        deleteButton.title = deletionSegmentID == transcript.segmentID ? "Deleting…" : "Delete"
        if deletionSegmentID == transcript.segmentID {
            detailLabel.stringValue = "Removing recording, transcript, and archived copies…"
        } else if renameSegmentID == transcript.segmentID {
            detailLabel.stringValue = "Renaming meeting…"
        } else if contextSegmentID == transcript.segmentID {
            detailLabel.stringValue = "Saving meeting details…"
        } else if transcriptionRetrySegmentID == transcript.segmentID {
            detailLabel.stringValue = "Retrying transcription now…"
        } else if let notice = playbackNoticeState.notice,
            notice.segmentID == transcript.segmentID
        {
            updatePlaybackNoticeLabel(notice.kind)
        } else {
            updateDetailLabel(transcript)
        }
    }

    private func updatePlaybackNoticeLabel(_ kind: LibreReverseMeetingPlaybackNoticeKind) {
        let message: String
        switch kind {
        case .stalled:
            message = "Playback paused while buffering. Press Play to retry."
        case .failedToPrepare:
            message = "Recording couldn’t be loaded. Use Retry to try again."
        case .failedDuringPlayback:
            message = "Playback stopped unexpectedly. Use Retry to reload the recording."
        case .retrying:
            message = "Loading the meeting recording again…"
        }
        detailLabel.stringValue = message
        detailLabel.toolTip = message
        detailLabel.textColor =
            kind == .retrying
            ? NSColor.white.withAlphaComponent(0.68) : NSColor.systemOrange
        detailLabel.setAccessibilityLabel(message)
    }

    private func updateDetailLabel(_ transcript: LibreReverseMeetingTranscript) {
        let duration = max(0, transcript.endDate.timeIntervalSince(transcript.startDate))
        var details = [
            Self.detailDateFormatter.string(from: transcript.startDate),
            "\(Int(duration) / 60)m \(String(format: "%02d", Int(duration) % 60))s",
        ]
        details.append(contentsOf: transcript.metadata.compactLabels)
        let sourceNames = transcript.presentedSpeechSources.compactMap(\.displayName)
        detailLabel.stringValue = details.prefix(2).joined(separator: " · ")
            + (details.count > 2 ? "\n" + details.dropFirst(2).joined(separator: " · ") : "")
        detailLabel.toolTip = (details + (transcript.metadata.participants.isEmpty
            ? [] : [transcript.metadata.participants.joined(separator: ", ")])
            + (sourceNames.isEmpty ? [] : ["Audio: " + sourceNames.joined(separator: "/")])).joined(separator: "\n")
    }

    private static let detailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

@MainActor
enum LibreReverseTranscriptExportPanel {
    static func configure(_ panel: NSSavePanel) {
        panel.allowedContentTypes = [.plainText, webVTTType, .json]
        // macOS provides a native File Format control and updates filename
        // extensions with its selection. Keep that behavior in the save panel.
        panel.showsContentTypes = true
        panel.currentContentType = .plainText
    }

    static func selectedFormat(in panel: NSSavePanel) -> LibreReverseMeetingTranscriptExport.Format {
        if panel.currentContentType == webVTTType { return .webVTT }
        if panel.currentContentType == .json { return .losslessJSON }
        return .plainText
    }

    private static let webVTTType = UTType(filenameExtension: "vtt") ?? .plainText
}

@MainActor
final class LibreReversePinnedTranscriptWindowController: NSWindowController, NSWindowDelegate {
    let transcriptView: LibreReverseMeetingTranscriptView
    var onWindowClosed: (() -> Void)?
    private var closesSilently = false

    init(transcriptView: LibreReverseMeetingTranscriptView) {
        self.transcriptView = transcriptView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.title = "Meeting Transcript"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 360, height: 260)
        window.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.setFrameAutosaveName("LibreReverse.PinnedMeetingTranscript")

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.addSubview(transcriptView)
        NSLayoutConstraint.activate([
            transcriptView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 0),
            transcriptView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: 0),
            transcriptView.topAnchor.constraint(equalTo: content.topAnchor, constant: 0),
            transcriptView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWithoutCallback() {
        closesSilently = true
        close()
    }

    func windowWillClose(_ notification: Notification) {
        let shouldNotify = !closesSilently
        closesSilently = false
        if shouldNotify { onWindowClosed?() }
    }
}
#endif
