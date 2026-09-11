#if os(macOS)
import AppKit

/// Local responder routing for accessory applications without a global Edit menu.
@MainActor
final class LibreReverseAskChatWindow: NSWindow {
    var selectionPasteboard: NSPasteboard = .general
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isKeyWindow, event.windowNumber == 0 || event.windowNumber == windowNumber else {
            return super.performKeyEquivalent(with: event)
        }
        return routeTextCommand(event) || super.performKeyEquivalent(with: event)
    }
    func routeTextCommand(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let text = firstResponder as? NSTextView, text.window === self else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            let range = text.selectedRange()
            guard text.isSelectable, range.length > 0, NSMaxRange(range) <= (text.string as NSString).length else { return false }
            selectionPasteboard.clearContents()
            selectionPasteboard.setString((text.string as NSString).substring(with: range), forType: .string)
            return true
        case "a": text.selectAll(nil); return true
        case "v" where text.isEditable: text.paste(nil); return true
        case "x" where text.isEditable: text.cut(nil); return true
        case "z" where text.isEditable: text.undoManager?.undo(); return true
        default: return false
        }
    }
}

@MainActor
final class LibreReverseAskComposer: NSTextView {
    var onSubmit: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), !event.modifierFlags.contains(.shift), !hasMarkedText() {
            onSubmit?()
        } else { super.keyDown(with: event) }
    }
}

@MainActor
final class LibreReverseAskChatDocument: NSView {
    override var isFlipped: Bool { true }
}

/// A selectable message that grows with its text inside the outer chat scroll view.
@MainActor
final class LibreReverseAskMessageText: NSTextView {
    private let messageStorage: NSTextStorage
    private var measuredWidth: CGFloat = 0
    private var measuredHeight: CGFloat = 24
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight) }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard abs(newSize.width - measuredWidth) > 0.5 else { return }
        measure(width: newSize.width)
    }
    func measure(width: CGFloat) {
        guard width > 1, let container = textContainer, let manager = layoutManager else { return }
        measuredWidth = width
        container.containerSize = NSSize(width: width - textContainerInset.width * 2, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let height = max(24, ceil(manager.usedRect(for: container).height + textContainerInset.height * 2))
        if abs(height - measuredHeight) > 0.5 { measuredHeight = height; invalidateIntrinsicContentSize() }
    }
    init(text: String, identifier: String, attributed: NSAttributedString? = nil) {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        messageStorage = storage
        manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isVerticallyResizable = false
        isHorizontallyResizable = false
        drawsBackground = false
        textContainerInset = NSSize(width: 0, height: 3)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        font = .systemFont(ofSize: 15)
        textColor = .labelColor
        if let attributed { textStorage?.setAttributedString(attributed) } else { string = text }
        setAccessibilityIdentifier(identifier)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { nil }
}

@MainActor
final class LibreReverseAskDisclosure: NSStackView {
    let toggle = NSButton()
    let scroll = NSScrollView()
    let textView = NSTextView()
    private let label: String
    private var expanded = false
    private var height: NSLayoutConstraint!
    var onResize: (() -> Void)?
    init(title: String, identifier: String, text: String = "") {
        label = title
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 5
        toggle.isBordered = false
        toggle.alignment = .left
        toggle.font = .systemFont(ofSize: 12)
        toggle.contentTintColor = .secondaryLabelColor
        toggle.target = self
        toggle.action = #selector(toggleExpanded)
        toggle.setAccessibilityIdentifier("\(identifier).toggle")
        toggle.setAccessibilityLabel(title)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.setAccessibilityIdentifier("\(identifier).details")
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .secondaryLabelColor
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityIdentifier("\(identifier).text")
        scroll.documentView = textView
        addArrangedSubview(toggle)
        addArrangedSubview(scroll)
        toggle.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        height = scroll.heightAnchor.constraint(equalToConstant: 90)
        height.isActive = true
        setText(text, collapse: true)
    }
    required init?(coder: NSCoder) { nil }
    func setText(_ text: String, collapse: Bool = false) {
        textView.string = text
        if collapse { expanded = false }
        isHidden = text.isEmpty
        toggle.isHidden = text.isEmpty
        update()
    }
    @objc private func toggleExpanded() { expanded.toggle(); update(); onResize?() }
    private func update() {
        toggle.title = "\(expanded ? "▾" : "▸") \(label)"
        toggle.setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
        scroll.isHidden = !expanded || textView.string.isEmpty
        if expanded {
            window?.contentView?.layoutSubtreeIfNeeded()
            let width = max(1, scroll.contentSize.width)
            textView.setFrameSize(NSSize(width: width, height: 90))
            if let container = textView.textContainer, let manager = textView.layoutManager {
                container.containerSize.width = width
                manager.ensureLayout(for: container)
                let measured = max(24, ceil(manager.usedRect(for: container).height + 8))
                textView.setFrameSize(NSSize(width: width, height: measured))
                height.constant = min(90, measured)
            }
        }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

@MainActor
final class LibreReverseAskAnswerView: NSStackView {
    let answer: LibreReverseAskAnswer
    let message: LibreReverseAskMessageText
    private let sourcesScroll = NSScrollView()
    private let sourcesDocument = LibreReverseAskChatDocument()
    private let sourcesToggle = NSButton()
    private var sourceButtons: [LibreReverseAskCitationButton] = []
    private var sourceHeight: NSLayoutConstraint!
    private var expanded = false
    var onResize: (() -> Void)?
    var onCopy: (() -> Void)?
    init(answer: LibreReverseAskAnswer, openMoment: @escaping (Date) -> Void) {
        self.answer = answer
        message = LibreReverseAskMessageText(text: answer.text, identifier: "ask.answer",
            attributed: LibreReverseAskMarkdown.render(answer.text))
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        let role = NSTextField(labelWithString: "LibreReverse")
        role.font = .systemFont(ofSize: 12, weight: .semibold)
        role.textColor = .secondaryLabelColor
        addArrangedSubview(role)
        addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        let coverage = LibreReverseAskDisclosure(title: "Search coverage", identifier: "ask.coverage",
            text: answer.coverageNotes.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n"))
        coverage.onResize = { [weak self] in self?.onResize?() }
        addArrangedSubview(coverage)
        coverage.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        sourcesScroll.drawsBackground = false
        sourcesScroll.borderType = .noBorder
        sourcesScroll.hasVerticalScroller = true
        sourcesScroll.autohidesScrollers = true
        sourcesScroll.documentView = sourcesDocument
        sourcesScroll.setAccessibilityIdentifier("ask.sources.list")
        sourcesDocument.autoresizingMask = [.width]
        sourceHeight = sourcesScroll.heightAnchor.constraint(equalToConstant: 120)
        sourceHeight.isActive = true
        for (index, citation) in answer.citations.enumerated() {
            let button = LibreReverseAskCitationButton()
            button.configure(citation: citation, index: index + 1)
            button.setAccessibilityIdentifier("ask.source.\(index + 1)")
            button.autoresizingMask = [.width]
            button.onOpen = { openMoment(citation.passageInstant ?? citation.instant) }
            sourcesDocument.addSubview(button)
            sourceButtons.append(button)
        }
        sourcesToggle.isBordered = false
        sourcesToggle.alignment = .left
        sourcesToggle.contentTintColor = .systemBlue
        sourcesToggle.font = .systemFont(ofSize: 12)
        sourcesToggle.target = self
        sourcesToggle.action = #selector(toggleSources)
        sourcesToggle.setAccessibilityIdentifier("ask.sources.toggle")
        let sourcesTitle = NSTextField(labelWithString: "Sources")
        sourcesTitle.font = .systemFont(ofSize: 12, weight: .medium)
        sourcesTitle.isHidden = answer.citations.isEmpty
        addArrangedSubview(sourcesTitle)
        addArrangedSubview(sourcesScroll)
        addArrangedSubview(sourcesToggle)
        sourcesScroll.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        sourcesToggle.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        let copyAnswer = NSButton(title: "Copy answer", target: self, action: #selector(copyText))
        let copyCitations = NSButton(title: "Copy with citations", target: self, action: #selector(copySources))
        for button in [copyAnswer, copyCitations] {
            button.isBordered = false; button.contentTintColor = .secondaryLabelColor; button.font = .systemFont(ofSize: 11)
        }
        let actions = NSStackView(views: [copyAnswer, copyCitations])
        actions.spacing = 14
        addArrangedSubview(actions)
        updateSources()
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); message.measure(width: bounds.width); layoutSourceRows() }
    @objc private func toggleSources() { expanded.toggle(); updateSources(); onResize?() }
    private func updateSources() {
        let count = expanded ? sourceButtons.count : min(3, sourceButtons.count)
        sourceHeight.constant = CGFloat(min(count, 6)) * 40
        sourcesScroll.isHidden = count == 0
        sourcesToggle.isHidden = sourceButtons.count <= 3
        sourcesToggle.title = expanded ? "Show fewer sources" : "Show all \(sourceButtons.count) sources"
        sourcesToggle.setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
        layoutSourceRows()
        sourcesScroll.contentView.scroll(to: .zero)
        sourcesScroll.reflectScrolledClipView(sourcesScroll.contentView)
    }
    private func layoutSourceRows() {
        let count = expanded ? sourceButtons.count : min(3, sourceButtons.count)
        let width = max(1, sourcesScroll.contentSize.width)
        sourcesDocument.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(count) * 40)
        for (index, button) in sourceButtons.enumerated() {
            button.isHidden = index >= count
            button.frame = NSRect(x: 0, y: CGFloat(index) * 40, width: width, height: 40)
        }
    }
    @objc private func copyText() { copy(answer.text) }
    @objc private func copySources() { copy(answer.textWithCitations) }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); onCopy?()
    }
}
final class LibreReverseAskCitationButton: NSButton {
    var onOpen: (() -> Void)?
    private var citation: LibreReverseAskCitation?
    private var citationIndex = 0
    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d  HH:mm"
        return formatter
    }()

    init() {
        super.init(frame: .zero)
        title = "Moment"
        isBordered = false
        alignment = .left
        lineBreakMode = .byTruncatingTail
        contentTintColor = .labelColor
        font = .systemFont(ofSize: 12, weight: .regular)
        target = self
        action = #selector(open)
    }

    func configure(citation: LibreReverseAskCitation, index: Int) {
        self.citation = citation
        citationIndex = index
        title = ""
        toolTip = citation.plainText
        needsDisplay = true
        setAccessibilityLabel("Moment \(index), \(citation.plainText)")
        setAccessibilityHelp("Opens this cited moment in the timeline")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let citation else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        func draw(_ text: String, x: CGFloat, width: CGFloat, font: NSFont, color: NSColor) {
            (text as NSString).draw(in: NSRect(x: x, y: (bounds.height - 18) / 2,
                width: max(0, width), height: 18), withAttributes: [
                    .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
                ])
        }
        draw("\(citationIndex)", x: 0, width: 22,
             font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: .systemBlue)
        draw(Self.timestamp.string(from: citation.instant), x: 26, width: 108,
             font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor)
        draw(citation.title, x: 144, width: bounds.width - 172,
             font: .systemFont(ofSize: 13), color: NSColor.white.withAlphaComponent(0.86))
        draw("→", x: bounds.width - 17, width: 17,
             font: .systemFont(ofSize: 14), color: .systemBlue)
        NSColor.white.withAlphaComponent(0.09).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
    }

    required init?(coder: NSCoder) { nil }
    @objc private func open() { onOpen?() }
}

#endif
