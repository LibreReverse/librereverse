#if os(macOS)
import AppKit
import LibreReverseCore

@MainActor
final class LibreReverseSearchResultsView: NSView,
    NSCollectionViewDataSource, NSCollectionViewDelegate {
    static let preferredSize = NSSize(width: 500, height: 278)

    var query: String = ""
    var onAsk: (() -> Void)?
    var onSelect: ((OCRSearchResult) -> Void)?
    var onSelectTranscript: ((TranscriptSearchResult) -> Void)?
    var onOpenBrowserURL: ((OCRSearchResult) -> Void)?
    var onLoadMore: (() -> Void)?
    var previewProvider: ((OCRSearchResult) async -> NSImage?)?

    private let scrollView = NSScrollView(frame: .zero)
    private let collectionView = NSCollectionView(frame: .zero)
    private let progress = NSProgressIndicator(frame: .zero)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton(title: "Open moment", target: nil, action: nil)
    private var heightConstraint: NSLayoutConstraint!
    private var results: [OCRSearchResult] = []
    private var transcriptResults: [TranscriptSearchResult] = []
    private var hasMore = false
    private var isLoadingMore = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.preferredSize.width, height: heightConstraint?.constant ?? Self.preferredSize.height)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer?.borderColor = NSColor.white.withAlphaComponent(0.17).cgColor
        layer?.borderWidth = 0.5
        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.30).cgColor
        backdrop.layer?.cornerRadius = 14
        backdrop.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        backdrop.layer?.masksToBounds = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 480, height: 78)
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 1
        layout.sectionInset = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            LibreReverseSearchResultItem.self,
            forItemWithIdentifier: LibreReverseSearchResultItem.identifier
        )

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.style = .spinning
        progress.controlSize = .regular
        progress.isDisplayedWhenStopped = false

        message.translatesAutoresizingMaskIntoConstraints = false
        message.font = .systemFont(ofSize: 13, weight: .regular)
        message.textColor = NSColor.white.withAlphaComponent(0.68)
        message.alignment = .center
        message.isHidden = true

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        let askButton = NSButton(title: "Ask AI", target: self, action: #selector(ask))
        askButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        askButton.imagePosition = .imageLeading
        openButton.target = self
        openButton.action = #selector(openFirstResult)
        openButton.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)
        openButton.toolTip = "Open the first matching moment"
        openButton.imagePosition = .imageTrailing
        for button in [askButton, openButton] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 12, weight: .regular)
            button.contentTintColor = NSColor.white.withAlphaComponent(0.72)
            button.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(button)
        }
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(divider)
        addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 36),
            askButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 18),
            askButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            openButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -18),
            openButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            divider.topAnchor.constraint(equalTo: footer.topAnchor),
        ])
        addSubview(scrollView)
        addSubview(progress)
        addSubview(message)
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.preferredSize.height)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.preferredSize.width),
            heightConstraint,
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            progress.centerXAnchor.constraint(equalTo: centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.centerXAnchor.constraint(equalTo: centerXAnchor),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -64),
        ])
    }

    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    func showLoading(preservingResults: Bool = false) {
        if preservingResults, !results.isEmpty || !transcriptResults.isEmpty {
            hasMore = false
            isLoadingMore = false
            return
        }
        results = []
        transcriptResults = []
        hasMore = false
        isLoadingMore = false
        collectionView.reloadData()
        updateHeight()
        message.isHidden = true
        progress.startAnimation(nil)
    }

    func show(results: [OCRSearchResult], hasMore: Bool = false) {
        progress.stopAnimation(nil)
        self.results = results
        transcriptResults = []
        self.hasMore = hasMore
        isLoadingMore = false
        collectionView.reloadData()
        updateHeight()
        message.stringValue = "No matching screens"
        message.isHidden = !results.isEmpty
    }

    func presentFirstPreviewForValidation() {
        layoutSubtreeIfNeeded()
        (collectionView.item(at: IndexPath(item: 0, section: 0)) as? LibreReverseSearchResultItem)?.presentPreviewForValidation()
    }

    func show(
        transcriptResults: [TranscriptSearchResult],
        hasMore: Bool = false
    ) {
        progress.stopAnimation(nil)
        results = []
        self.transcriptResults = transcriptResults
        self.hasMore = hasMore
        isLoadingMore = false
        collectionView.reloadData()
        updateHeight()
        message.stringValue = "No matching meetings"
        message.isHidden = !transcriptResults.isEmpty
    }

    func append(results newResults: [OCRSearchResult], hasMore: Bool) {
        progress.stopAnimation(nil)
        let start = results.count
        results.append(contentsOf: newResults)
        self.hasMore = hasMore
        isLoadingMore = false
        updateHeight()
        if newResults.isEmpty {
            collectionView.reloadData()
        } else {
            collectionView.insertItems(at: Set(
                (start..<results.count).map { IndexPath(item: $0, section: 0) }
            ))
        }
    }

    func append(
        transcriptResults newResults: [TranscriptSearchResult],
        hasMore: Bool
    ) {
        progress.stopAnimation(nil)
        let start = transcriptResults.count
        transcriptResults.append(contentsOf: newResults)
        self.hasMore = hasMore
        isLoadingMore = false
        updateHeight()
        if newResults.isEmpty {
            collectionView.reloadData()
        } else {
            collectionView.insertItems(at: Set(
                (start..<transcriptResults.count).map {
                    IndexPath(item: $0, section: 0)
                }
            ))
        }
    }

    func show(error: Error) {
        progress.stopAnimation(nil)
        results = []
        transcriptResults = []
        collectionView.reloadData()
        updateHeight()
        message.stringValue = error.localizedDescription
        message.isHidden = false
    }

    private func updateHeight() {
        let count = results.count + transcriptResults.count
        heightConstraint.constant = count == 0 ? 184 : CGFloat(min(3, count)) * 79 + 41
        openButton.isEnabled = count > 0
        invalidateIntrinsicContentSize()
    }

    @objc private func ask() { onAsk?() }
    @objc private func openFirstResult() {
        if let first = transcriptResults.first { onSelectTranscript?(first) }
        else if let first = results.first { onSelect?(first) }
    }

    @objc private func scrollBoundsDidChange() {
        guard hasMore, !isLoadingMore else { return }
        let visible = scrollView.contentView.bounds
        let contentHeight = collectionView.collectionViewLayout?.collectionViewContentSize.height
            ?? collectionView.bounds.height
        guard visible.maxY >= contentHeight - 320 else { return }
        isLoadingMore = true
        onLoadMore?()
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int { transcriptResults.isEmpty ? results.count : transcriptResults.count }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: LibreReverseSearchResultItem.identifier,
            for: indexPath
        ) as! LibreReverseSearchResultItem
        if transcriptResults.indices.contains(indexPath.item) {
            let result = transcriptResults[indexPath.item]
            item.configure(result: result, query: query)
            item.onActivate = { [weak self] in self?.onSelectTranscript?(result) }
        } else {
            let result = results[indexPath.item]
            let metadata = result.result.candidate.bundleID.map {
                ApplicationMetadataProvider.shared.metadata(bundleIdentifier: $0)
            }
            item.onActivate = { [weak self] in self?.onSelect?(result) }
            item.configure(
                result: result,
                query: query,
                icon: metadata?.icon,
                appName: metadata?.name,
                previewProvider: previewProvider,
                onOpenBrowserURL: { [weak self] in self?.onOpenBrowserURL?(result) }
            )
        }
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard let index = indexPaths.first?.item else { return }
        collectionView.deselectItems(at: indexPaths)
        if transcriptResults.indices.contains(index) {
            onSelectTranscript?(transcriptResults[index])
        } else if results.indices.contains(index) {
            onSelect?(results[index])
        }
    }
}

/// Bounded text around the actual matched OCR node, not an unrelated document
/// prefix. Decode UTF-16 safely when a clipping boundary crosses an emoji.
enum LibreReverseSearchSnippet {
    static func text(in transcript: String, query: String) -> String {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        let match = needle.isEmpty ? nil : transcript.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
        let start = match.flatMap { transcript.index($0.lowerBound, offsetBy: -28, limitedBy: transcript.startIndex) } ?? transcript.startIndex
        let end = transcript.index(start, offsetBy: 160, limitedBy: transcript.endIndex) ?? transcript.endIndex
        let excerpt = transcript[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > transcript.startIndex ? "… " : "") + excerpt + (end < transcript.endIndex ? "…" : "")
    }

    static func text(for result: OCRSearchResult) -> String {
        let text = result.result.candidate.text + result.result.candidate.otherText
        let start = max(0, result.firstNode.textOffset - 32)
        let excerpt = String(decoding: text.utf16.dropFirst(start).prefix(180), as: UTF16.self)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > 0 ? "… " : "") + excerpt
    }
}

@MainActor
private final class LibreReverseSearchResultItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("LibreReverseSearchResultItem")
    private let preview = LibreReverseSearchMatchPreview(frame: .zero)
    private let iconButton = LibreReverseSearchPreviewButton(frame: .zero)
    private let contextLabel = NSTextField(wrappingLabelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(wrappingLabelWithString: "")
    private let browserButton = NSButton(frame: .zero)
    private var openBrowserURL: (() -> Void)?
    private var previewTask: Task<Void, Never>?
    private var previewPopover: NSPopover?
    private var fetchPreview: (() async -> NSImage?)?
    private var hoverPreview = false

    var onActivate: (() -> Void)? {
        get { (view as? LibreReverseSearchResultRow)?.onActivate }
        set { (view as? LibreReverseSearchResultRow)?.onActivate = newValue }
    }

    override var isSelected: Bool {
        didSet { (view as? LibreReverseSearchResultRow)?.selected = isSelected }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onActivate = nil
        clearPreview()
    }

    private func clearPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewPopover?.close()
        previewPopover = nil
        preview.image = nil
        preview.node = nil
        preview.transcript = nil
        fetchPreview = nil
    }

    override func loadView() {
        let root = LibreReverseSearchResultRow(frame: NSRect(x: 0, y: 0, width: 480, height: 78))
        for child in [iconButton, titleLabel, dateLabel, contextLabel, browserButton] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        iconButton.isBordered = false
        iconButton.imagePosition = .imageOnly
        iconButton.imageScaling = .scaleProportionallyDown
        iconButton.target = self
        iconButton.action = #selector(showPreview)
        iconButton.toolTip = "Preview this match"
        iconButton.onHover = { [weak self] entered in
            guard let self else { return }
            if entered { self.presentPreview(hover: true) }
            else {
                self.previewTask?.cancel()
                if self.hoverPreview { self.previewPopover?.close() }
            }
        }
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.91)
        titleLabel.lineBreakMode = .byTruncatingTail
        dateLabel.font = .systemFont(ofSize: 11, weight: .regular)
        dateLabel.textColor = NSColor.white.withAlphaComponent(0.52)
        dateLabel.alignment = .right
        dateLabel.maximumNumberOfLines = 2
        contextLabel.font = .systemFont(ofSize: 12, weight: .regular)
        contextLabel.textColor = NSColor.white.withAlphaComponent(0.64)
        contextLabel.maximumNumberOfLines = 2
        contextLabel.lineBreakMode = .byWordWrapping
        contextLabel.cell?.wraps = true
        contextLabel.cell?.usesSingleLineMode = false
        browserButton.target = self
        browserButton.action = #selector(openBrowser)
        browserButton.isBordered = false
        browserButton.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: "Open original page")
        browserButton.imagePosition = .imageOnly
        browserButton.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        browserButton.isHidden = true
        NSLayoutConstraint.activate([
            iconButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            iconButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 17),
            iconButton.widthAnchor.constraint(equalToConstant: 36),
            iconButton.heightAnchor.constraint(equalToConstant: 36),
            titleLabel.leadingAnchor.constraint(equalTo: iconButton.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 13),
            titleLabel.trailingAnchor.constraint(equalTo: dateLabel.leadingAnchor, constant: -12),
            contextLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            contextLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            contextLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            contextLabel.heightAnchor.constraint(lessThanOrEqualToConstant: 32),
            dateLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            dateLabel.topAnchor.constraint(equalTo: titleLabel.topAnchor),
            dateLabel.widthAnchor.constraint(equalToConstant: 76),
            browserButton.trailingAnchor.constraint(equalTo: dateLabel.trailingAnchor),
            browserButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            browserButton.widthAnchor.constraint(equalToConstant: 20),
            browserButton.heightAnchor.constraint(equalToConstant: 20),
        ])
        view = root
    }

    func configure(result: OCRSearchResult, query: String, icon: NSImage?, appName: String?,
        previewProvider: ((OCRSearchResult) async -> NSImage?)?, onOpenBrowserURL: @escaping () -> Void) {
        clearPreview()
        preview.node = result.firstNode
        iconButton.image = icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        iconButton.contentTintColor = nil
        iconButton.setAccessibilityLabel("Preview \(result.result.resolvedTitle)")
        setTitle(result.result.resolvedTitle, context: appName)
        setSnippet(LibreReverseSearchSnippet.text(for: result), query: query)
        setDate(result.result.representativeInstant)
        openBrowserURL = onOpenBrowserURL
        let url = result.result.candidate.browserURL.flatMap(URL.init(string:))
        browserButton.isHidden = url == nil
        browserButton.toolTip = "Open in \(appName ?? "browser")"
        browserButton.setAccessibilityLabel(browserButton.toolTip)
        view.setAccessibilityLabel(result.result.resolvedTitle)
        view.setAccessibilityHelp(contextLabel.stringValue)
        if let previewProvider { fetchPreview = { await previewProvider(result) } }
        iconButton.isEnabled = previewProvider != nil
    }

    func configure(result: TranscriptSearchResult, query: String) {
        clearPreview()
        preview.transcript = result.result.transcriptDetails?.transcript
        iconButton.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Meeting transcript")?
            .withSymbolConfiguration(.init(pointSize: 24, weight: .light))
        iconButton.contentTintColor = .systemOrange
        iconButton.isEnabled = true
        iconButton.setAccessibilityLabel("Preview meeting transcript")
        setTitle(result.result.resolvedTitle, context: nil)
        setSnippet(LibreReverseSearchSnippet.text(in: result.result.transcriptDetails?.transcript ?? "Meeting transcript", query: query), query: query)
        setDate(result.result.representativeInstant)
        openBrowserURL = nil
        browserButton.isHidden = true
        view.setAccessibilityLabel(result.result.resolvedTitle)
        view.setAccessibilityHelp(contextLabel.stringValue)
    }

    private func setTitle(_ title: String, context: String?) {
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.91)])
        if let context, !context.isEmpty {
            text.append(NSAttributedString(string: " · " + context, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.55)]))
        }
        titleLabel.attributedStringValue = text
        titleLabel.toolTip = text.string
    }

    private func setSnippet(_ snippet: String, query: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 1
        let text = NSMutableAttributedString(string: snippet, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.64), .paragraphStyle: paragraph])
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        if !needle.isEmpty {
            let source = snippet as NSString
            var cursor = 0
            while cursor < source.length {
                let match = source.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                    range: NSRange(location: cursor, length: source.length - cursor))
                if match.location == NSNotFound { break }
                text.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: match)
                cursor = NSMaxRange(match)
            }
        }
        contextLabel.attributedStringValue = text
    }

    private func setDate(_ date: Date) {
        let calendar = Calendar.current
        let day = calendar.isDateInToday(date) ? "Today" : calendar.isDateInYesterday(date) ? "Yesterday"
            : Self.dayFormatter.string(from: date)
        dateLabel.stringValue = day + "\n" + Self.timeFormatter.string(from: date)
        dateLabel.toolTip = Self.fullDateFormatter.string(from: date)
    }

    func presentPreviewForValidation() { presentPreview(hover: false) }
    @objc private func showPreview() { presentPreview(hover: false) }
    private func presentPreview(hover: Bool) {
        guard iconButton.isEnabled, iconButton.window != nil else { return }
        previewTask?.cancel()
        hoverPreview = hover
        previewTask = Task { [weak self] in
            if hover { do { try await Task.sleep(for: .milliseconds(350)) } catch { return } }
            guard let self, !Task.isCancelled else { return }
            if self.preview.image == nil, let fetch = self.fetchPreview {
                let image = await fetch()
                guard !Task.isCancelled else { return }
                self.preview.image = image
            }
            guard !Task.isCancelled,
                self.iconButton.window?.isVisible == true,
                !self.iconButton.isHiddenOrHasHiddenAncestor,
                self.preview.image != nil || self.preview.transcript != nil else { return }
            let controller = NSViewController()
            controller.view = self.preview
            let popover = self.previewPopover ?? NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentSize = NSSize(width: 280, height: 150)
            popover.contentViewController = controller
            self.previewPopover = popover
            popover.show(relativeTo: self.iconButton.bounds, of: self.iconButton, preferredEdge: .maxX)
        }
    }
    @objc private func openBrowser() { openBrowserURL?() }
    private static let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()
    private static let timeFormatter: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()
    private static let fullDateFormatter: DateFormatter = { let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .short; return f }()
}

@MainActor
private final class LibreReverseSearchResultRow: NSView {
    var onActivate: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Preview and browser buttons keep their own actions. Labels and empty
        // row space select this exact result without collection selection churn.
        var ancestor: NSView? = hit
        while let view = ancestor, view !== self {
            if view is NSButton { return hit }
            ancestor = view.superview
        }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else { super.mouseDown(with: event); return }
        onActivate?()
    }
    override func accessibilityPerformPress() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }
    var selected = false { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || selected {
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            NSColor.white.withAlphaComponent(0.035).setFill(); outline.fill()
            NSColor.systemBlue.withAlphaComponent(selected ? 0.7 : 0.35).setStroke()
            outline.lineWidth = 0.5; outline.stroke()
            NSColor.systemBlue.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 9, width: 2, height: bounds.height - 18), xRadius: 1, yRadius: 1).fill()
        } else {
            NSColor.white.withAlphaComponent(0.06).setFill()
            NSRect(x: 58, y: 0, width: max(0, bounds.width - 70), height: 0.5).fill()
        }
    }
}

@MainActor
private final class LibreReverseSearchPreviewButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

@MainActor
private final class LibreReverseSearchMatchPreview: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var node: OCRNode? { didSet { needsDisplay = true } }
    var transcript: String? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.035, alpha: 1).setFill()
        dirtyRect.fill()
        if let transcript, !transcript.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.96),
                .paragraphStyle: paragraph,
            ]
            (transcript as NSString).draw(
                with: bounds.insetBy(dx: 18, dy: 18),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attributes
            )
            return
        }
        guard let image, let node, image.size.width > 0, image.size.height > 0 else { return }
        let sourceSize = image.size
        let match = CGRect(
            x: CGFloat(node.leftX) * sourceSize.width,
            y: CGFloat(node.topY) * sourceSize.height,
            width: max(1, CGFloat(node.width) * sourceSize.width),
            height: max(1, CGFloat(node.height) * sourceSize.height)
        )
        let crop = SearchCropRequest.sourceRectangle(
            match: match,
            targetSize: bounds.size
        )

        // CropRequest origins are relative and may extend beyond the image.
        // Preserve that empty margin instead of clamping and moving the match.
        let intersection = crop.intersection(CGRect(origin: .zero, size: sourceSize))
        if !intersection.isNull {
            let destination = CGRect(
                x: (intersection.minX - crop.minX) / crop.width * bounds.width,
                y: (crop.maxY - intersection.maxY) / crop.height * bounds.height,
                width: intersection.width / crop.width * bounds.width,
                height: intersection.height / crop.height * bounds.height
            )
            let appKitSource = CGRect(
                x: intersection.minX,
                y: sourceSize.height - intersection.maxY,
                width: intersection.width,
                height: intersection.height
            )
            image.draw(
                in: destination,
                from: appKitSource,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }

        let overlay = CGRect(
            x: (match.minX - crop.minX) / crop.width * bounds.width,
            y: bounds.height - (match.maxY - crop.minY) / crop.height * bounds.height,
            width: max(3, match.width / crop.width * bounds.width),
            height: max(3, match.height / crop.height * bounds.height)
        )
        let borderWidth = SearchMatchVisualContract.borderWidth
        let matchRect = overlay.insetBy(dx: -borderWidth, dy: -borderWidth)
        let radius = SearchMatchVisualContract.cornerRadius
        let mask = NSBezierPath(rect: bounds)
        mask.appendRoundedRect(matchRect, xRadius: radius, yRadius: radius)
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(
            SearchMatchVisualContract.maskOpacity
        ).setFill()
        mask.fill()

        let border = NSBezierPath(
            roundedRect: matchRect,
            xRadius: radius,
            yRadius: radius
        )
        border.lineWidth = borderWidth
        NSColor(
            displayP3Red: SearchMatchVisualContract.displayP3Red,
            green: SearchMatchVisualContract.displayP3Green,
            blue: SearchMatchVisualContract.displayP3Blue,
            alpha: SearchMatchVisualContract.borderOpacity
        ).setStroke()
        border.stroke()
    }
}
#endif
