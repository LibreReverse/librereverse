#if os(macOS)
import AppKit
import LibreReverseCore

enum LibreReverseSearchOverlayFilter: String, CaseIterable, Hashable, Sendable {
    case apps
    case meetings
    case starred

    var title: String {
        switch self {
        case .apps: "Apps"
        case .meetings: "Meetings"
        case .starred: "Starred"
        }
    }
}

struct LibreReverseSearchOverlayState: Equatable, Sendable {
    var query: String
    var filters: Set<LibreReverseSearchOverlayFilter>
    /// Preserve selection order when building SQL bindings.
    var applicationBundleIDs: [String]

    init(
        query: String = "",
        filters: Set<LibreReverseSearchOverlayFilter> = [],
        applicationBundleIDs: [String] = []
    ) {
        self.query = query
        self.filters = filters
        self.applicationBundleIDs = applicationBundleIDs
        if applicationBundleIDs.isEmpty {
            self.filters.remove(.apps)
        } else {
            self.filters.insert(.apps)
            self.filters.remove(.meetings)
        }
    }

    var canSubmit: Bool { SearchQuery.matchExpression(for: query) != nil || filters.contains(.meetings) }

    var searchFacets: SearchFacets {
        SearchFacets(
            applicationBundleIDs: applicationBundleIDs,
            isStarred: filters.contains(.starred),
            isTranscript: filters.contains(.meetings)
        )
    }
}

enum LibreReverseSearchOverlayPresentation: Sendable {
    /// Modifier-scroll clears the text query while preserving selected facets.
    case blankSearch

    /// Command-Shift-Space reuses the overlay's current query and filters.
    case preserveLastSearch
}

struct LibreReverseSearchApplicationOption: Equatable, Sendable {
    let bundleID: String
    let title: String
    let count: Int
}

/// The compact, centered search surface shown above the memory explorer.
///
/// This view owns only search input and filter selection. A caller supplies
/// search execution and result presentation through callbacks; the overlay
/// deliberately contains no placeholder or fabricated result rows.
@MainActor
final class LibreReverseSearchOverlayView: NSView, NSSearchFieldDelegate {
    static let preferredSize = NSSize(width: 500, height: 86)

    private var querySubmissionTask: Task<Void, Never>?
    var onStateChange: ((LibreReverseSearchOverlayState) -> Void)?
    var onQueryChange: ((String) -> Void)?
    var onFiltersChange: ((Set<LibreReverseSearchOverlayFilter>) -> Void)?
    var onSubmit: ((LibreReverseSearchOverlayState) -> Void)?
    var onConfirm: ((LibreReverseSearchOverlayState) -> Void)?
    var onAsk: ((String) -> Void)?
    var onExitAI: (() -> Void)?
    private(set) var aiMode = false
    var onExpand: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onEscape: (() -> Void)?

    private(set) var state: LibreReverseSearchOverlayState

    private let searchField = NSSearchField(frame: .zero)
    private let backdrop = NSVisualEffectView()
    private let askButton = LibreReverseSearchChipButton(title: "AI", symbolName: "sparkles")
    private let aiTitle = NSTextField(labelWithString: "Ask about your history")
    private let aiDetail = NSTextField(labelWithString: "Ask about this moment, then follow up")
    private let filterRow = NSStackView()
    private let searchIcon = NSImageView(frame: .zero)
    /// Sized against the field's 24pt text rather than the cell's metrics.
    private static let searchIconPointSize: CGFloat = 16
    private let expandButton = NSButton(frame: .zero)
    private var widthConstraint: NSLayoutConstraint!
    private var filterButtons: [LibreReverseSearchOverlayFilter: LibreReverseSearchChipButton] = [:]
    private var availableApplications: [LibreReverseSearchApplicationOption] = []
    private var applicationPopover: NSPopover?
    private var focusWhenAttached = false

    override var intrinsicContentSize: NSSize { Self.preferredSize }

    /// Suitable for `NSWindow.initialFirstResponder` when the overlay is
    /// installed before the window becomes key.
    var preferredFirstResponder: NSResponder { searchField }

    init(state: LibreReverseSearchOverlayState = .init()) {
        self.state = state
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize))
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .darkAqua)
        buildHierarchy()
        applyStateToControls()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, focusWhenAttached else { return }
        focusWhenAttached = false
        focusSearchField()
    }

    func cancelPendingSubmission() {
        querySubmissionTask?.cancel()
        querySubmissionTask = nil
        applicationPopover?.close()
    }

    func setState(_ newState: LibreReverseSearchOverlayState, notify: Bool = false) {
        guard newState != state else { return }
        let oldState = state
        state = newState
        applyStateToControls()
        guard notify else { return }
        emitChanges(from: oldState)
    }

    func prepareForPresentation(_ presentation: LibreReverseSearchOverlayPresentation) {
        switch presentation {
        case .blankSearch:
            guard !state.query.isEmpty else { return }
            let oldState = state
            state.query = ""
            applyStateToControls()
            emitChanges(from: oldState)
        case .preserveLastSearch:
            break
        }
    }

    func focusSearchField(selectAll: Bool = false) {
        guard !aiMode else { return }
        guard let window else {
            focusWhenAttached = true
            return
        }
        window.makeFirstResponder(searchField)
        if selectAll {
            searchField.currentEditor()?.selectAll(nil)
        }
    }

    func ownsFirstResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if let editor = searchField.currentEditor(), responder === editor { return true }
        return (responder as? NSView)?.isDescendant(of: self) == true
    }

    func setResultsPresented(_ presented: Bool) {
        widthConstraint.constant = aiMode ? 620 : Self.preferredSize.width
        layer?.maskedCorners = presented
            ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [
                .layerMinXMinYCorner, .layerMaxXMinYCorner,
                .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
            ]
        backdrop.layer?.maskedCorners = layer?.maskedCorners ?? []
        askButton.isHidden = false
        invalidateIntrinsicContentSize()
    }

    func setAvailableApplicationBundleIDs(_ bundleIDs: [String]) {
        var seen: Set<String> = []
        availableApplications = bundleIDs
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .map {
                LibreReverseSearchApplicationOption(
                    bundleID: $0,
                    title: applicationName(for: $0),
                    count: 0
                )
            }
            .sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    func setAvailableApplicationCounts(_ counts: [SearchApplicationCount]) {
        availableApplications = counts.map {
            LibreReverseSearchApplicationOption(
                bundleID: $0.bundleID,
                title: applicationName(for: $0.bundleID),
                count: $0.count
            )
        }
    }

    /// Opens the production Apps facet from deterministic UI validation.
    /// Keeping this entry point on the real overlay prevents the visual probe
    /// from growing a second, fixture-only imitation of the picker.
    func presentApplicationPickerForValidation() {
        guard let button = filterButtons[.apps] else { return }
        presentApplicationPicker(from: button)
    }

    func filterApplicationsForValidation(_ query: String) {
        (applicationPopover?.contentViewController?.view as? LibreReverseSearchApplicationFacetView)?.filterForValidation(query)
    }

    private func buildHierarchy() {
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderColor = NSColor.white.withAlphaComponent(0.17).cgColor
        layer?.borderWidth = 0.5
        shadow = NSShadow()
        shadow?.shadowBlurRadius = 20
        shadow?.shadowOffset = NSSize(width: 0, height: -6)
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.38)
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.30).cgColor
        backdrop.layer?.cornerRadius = 14
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(confirmSearch)
        searchField.placeholderString = "Search your history"
        searchField.font = .systemFont(ofSize: 16, weight: .regular)
        searchField.controlSize = .large
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.textColor = .white
        searchField.setAccessibilityLabel("Search your LibreReverse history")
        // `NSSearchFieldCell` positions its search button and its text origin
        // from its own control metrics, which do not follow an overridden
        // font. At 24pt the glyph landed on top of the first character. Drop
        // the built-in button and carry the magnifier as a sibling sized to
        // the text, so the two cannot collide at any font size.
        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (searchField.cell as? NSSearchFieldCell)?.cancelButtonCell = nil

        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            .init(pointSize: Self.searchIconPointSize, weight: .regular)
        )
        searchIcon.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        searchIcon.imageScaling = .scaleProportionallyUpOrDown
        searchIcon.setAccessibilityHidden(true)

        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.target = self
        expandButton.action = #selector(hideSearch)
        expandButton.isBordered = false
        expandButton.imagePosition = .imageOnly
        expandButton.contentTintColor = NSColor.white.withAlphaComponent(0.74)
        expandButton.toolTip = "Hide search"
        expandButton.setAccessibilityLabel("Hide search")
        if let symbol = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Hide search"
        ) {
            expandButton.image = symbol
        } else {
            expandButton.title = "↗"
            expandButton.imagePosition = .noImage
            expandButton.font = .systemFont(ofSize: 17, weight: .medium)
        }

        askButton.target = self
        askButton.action = #selector(askQuestion)
        askButton.isBordered = false
        askButton.font = .systemFont(ofSize: 12)
        askButton.contentTintColor = .secondaryLabelColor
        askButton.setAccessibilityLabel("Ask AI about your history")
        askButton.setButtonType(.pushOnPushOff)
        askButton.setAccessibilityIdentifier("search.ai-toggle")
        aiTitle.font = .systemFont(ofSize: 16, weight: .medium)
        aiTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        askButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
        aiTitle.isHidden = true
        aiDetail.font = .systemFont(ofSize: 12)
        aiDetail.textColor = .secondaryLabelColor
        aiDetail.isHidden = true
        aiDetail.translatesAutoresizingMaskIntoConstraints = false
        let searchRow = NSStackView(views: [searchIcon, searchField, aiTitle, askButton, expandButton])
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 9

        filterRow.translatesAutoresizingMaskIntoConstraints = false
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.distribution = .fill
        filterRow.spacing = 8

        for (index, filter) in LibreReverseSearchOverlayFilter.allCases.enumerated() {
            let symbolName: String
            switch filter {
            case .apps: symbolName = "app"
            case .meetings: symbolName = "waveform"
            case .starred: symbolName = "star"
            }
            let button = LibreReverseSearchChipButton(
                title: filter == .apps ? "Apps  ⌄" : filter == .starred ? "" : filter.title,
                symbolName: symbolName
            )
            button.tag = index
            button.target = self
            button.action = #selector(toggleFilter(_:))
            button.setAccessibilityLabel("Filter by \(filter.title)")
            button.toolTip = filter.title
            filterButtons[filter] = button
            filterRow.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: {
                switch filter {
                case .apps: 84
                case .meetings: 102
                case .starred: 34
                }
            }()).isActive = true
        }

        addSubview(searchRow)
        addSubview(filterRow)
        addSubview(aiDetail)

        widthConstraint = widthAnchor.constraint(equalToConstant: Self.preferredSize.width)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: Self.preferredSize.height),

            searchRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            searchRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            searchRow.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            searchRow.heightAnchor.constraint(equalToConstant: 28),
            searchIcon.widthAnchor.constraint(equalToConstant: Self.searchIconPointSize + 4),
            expandButton.widthAnchor.constraint(equalToConstant: 30),
            expandButton.heightAnchor.constraint(equalToConstant: 28),

            aiDetail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            aiDetail.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 8),
            aiDetail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            filterRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            filterRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -22),
            filterRow.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 8),
            filterRow.heightAnchor.constraint(equalToConstant: 28),
        ])

        searchField.nextKeyView = expandButton
        expandButton.nextKeyView = filterButtons[.apps]
        filterButtons[.apps]?.nextKeyView = filterButtons[.meetings]
        filterButtons[.meetings]?.nextKeyView = filterButtons[.starred]
        filterButtons[.starred]?.nextKeyView = searchField
    }

    private func applyStateToControls() {
        if searchField.stringValue != state.query {
            searchField.stringValue = state.query
        }
        for (filter, button) in filterButtons {
            if filter == .apps {
                let count = state.applicationBundleIDs.count
                button.title = count == 0 ? "Apps  ⌄" : "\(count) \(count == 1 ? "app" : "apps")  ⌄"
            }
            button.isSelected = state.filters.contains(filter)
        }
    }

    private func emitChanges(from oldState: LibreReverseSearchOverlayState) {
        if oldState.query != state.query {
            onQueryChange?(state.query)
        }
        if oldState.filters != state.filters {
            onFiltersChange?(state.filters)
        }
        onStateChange?(state)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard state.query != searchField.stringValue else { return }
        let oldState = state
        state.query = searchField.stringValue
        emitChanges(from: oldState)
        querySubmissionTask?.cancel()
        if state.canSubmit {
            let requested = state
            querySubmissionTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.state == requested else { return }
                self.onSubmit?(requested)
            }
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
            return false
        }
        onEscape?()
        return true
    }

    func setAIMode(_ enabled: Bool) {
        guard enabled != aiMode else { return }
        aiMode = enabled
        querySubmissionTask?.cancel()
        querySubmissionTask = nil
        askButton.state = enabled ? .on : .off
        askButton.isSelected = enabled
        askButton.contentTintColor = enabled ? .systemBlue : .secondaryLabelColor
        askButton.setAccessibilityLabel(enabled ? "AI search enabled; switch to keyword search" : "Enable AI search")
        searchField.isHidden = enabled
        searchIcon.isHidden = enabled
        expandButton.isHidden = enabled
        filterRow.isHidden = enabled
        aiTitle.isHidden = !enabled
        aiDetail.isHidden = !enabled
        widthConstraint.constant = enabled ? 620 : Self.preferredSize.width
    }

    @objc private func askQuestion() {
        setAIMode(!aiMode)
        if aiMode { onAsk?(state.query) } else { onExitAI?() }
    }

    @objc private func hideSearch() { onDismiss?() }

    @objc private func confirmSearch() {
        querySubmissionTask?.cancel()
        querySubmissionTask = nil
        if let onConfirm { onConfirm(state) } else { onSubmit?(state) }
    }

    @objc private func submitSearch() {
        querySubmissionTask?.cancel()
        querySubmissionTask = nil
        onSubmit?(state)
    }

    @objc private func expand() {
        onExpand?()
    }

    @objc private func toggleFilter(_ sender: NSButton) {
        guard LibreReverseSearchOverlayFilter.allCases.indices.contains(sender.tag) else { return }
        let selected = LibreReverseSearchOverlayFilter.allCases[sender.tag]
        if selected == .apps {
            presentApplicationPicker(from: sender)
            return
        }

        let oldState = state
        if state.filters.contains(selected) {
            state.filters.remove(selected)
        } else if selected == .meetings {
            // Meetings substitutes a synthetic recorder bundle for ordinary
            // app IDs. Runtime tracing proves Starred remains independently
            // composable with it.
            state.filters.remove(.apps)
            state.applicationBundleIDs = []
            state.filters.insert(.meetings)
        } else {
            state.filters.insert(selected)
        }

        applyStateToControls()
        emitChanges(from: oldState)
        if state.canSubmit { submitSearch() }
    }

    private func presentApplicationPicker(from sender: NSButton) {
        if let applicationPopover, applicationPopover.isShown {
            applicationPopover.close()
            return
        }
        let picker = LibreReverseSearchApplicationFacetView(
            options: availableApplications,
            selectedBundleIDs: Set(state.applicationBundleIDs)
        )
        picker.onToggle = { [weak self] bundleID in
            self?.toggleApplication(bundleID)
        }
        let controller = NSViewController()
        controller.view = picker
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = picker.intrinsicContentSize
        popover.contentViewController = controller
        applicationPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    private func toggleApplication(_ bundleID: String) {
        let oldState = state
        if let index = state.applicationBundleIDs.firstIndex(of: bundleID) {
            state.applicationBundleIDs.remove(at: index)
        } else {
            state.applicationBundleIDs.append(bundleID)
        }
        state.filters.remove(.meetings)
        if state.applicationBundleIDs.isEmpty {
            state.filters.remove(.apps)
        } else {
            state.filters.insert(.apps)
        }
        applyStateToControls()
        emitChanges(from: oldState)
        if state.canSubmit { submitSearch() }
    }

    private func applicationName(for bundleID: String) -> String {
        ApplicationMetadataProvider.shared
            .metadata(bundleIdentifier: bundleID).name ?? bundleID
    }
}

@MainActor
final class LibreReverseSearchApplicationFacetView: NSView,
    NSSearchFieldDelegate {
    var onToggle: ((String) -> Void)?

    private let searchField = NSSearchField(frame: .zero)
    private let stack = NSStackView()
    private var rows: [(option: LibreReverseSearchApplicationOption, button: NSButton)] = []

    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 310) }

    init(
        options: [LibreReverseSearchApplicationOption],
        selectedBundleIDs: Set<String>
    ) {
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 220, height: 310)))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter apps"
        searchField.delegate = self
        searchField.font = .systemFont(ofSize: 12, weight: .regular)
        searchField.focusRingType = .none
        searchField.setAccessibilityLabel("Filter apps")

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2

        let scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let document = LibreReverseSearchFacetDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        let preferredHeight = document.heightAnchor.constraint(equalTo: stack.heightAnchor)
        preferredHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: stack.heightAnchor),
            preferredHeight,
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])

        addSubview(searchField)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: intrinsicContentSize.width),
            heightAnchor.constraint(equalToConstant: intrinsicContentSize.height),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 9),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        if options.isEmpty {
            let empty = NSTextField(labelWithString: "No matching apps")
            empty.textColor = NSColor.white.withAlphaComponent(0.6)
            empty.alignment = .center
            stack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else {
            for (index, option) in options.enumerated() {
                let button = LibreReverseSearchApplicationButton(
                    title: option.title,
                    target: self,
                    action: #selector(toggle(_:))
                )
                button.tag = index
                button.setButtonType(.pushOnPushOff)
                button.state = selectedBundleIDs.contains(option.bundleID) ? .on : .off
                button.isBordered = false
                button.font = .systemFont(ofSize: 13, weight: .regular)
                button.image = ApplicationMetadataProvider.shared
                    .metadata(bundleIdentifier: option.bundleID).icon
                    ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))
                button.setAccessibilityLabel(option.title)
                button.setAccessibilityValue(
                    selectedBundleIDs.contains(option.bundleID) ? "Selected" : "Not selected"
                )
                stack.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                button.heightAnchor.constraint(equalToConstant: 32).isActive = true
                rows.append((option, button))
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    func filterForValidation(_ query: String) {
        searchField.stringValue = query
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
    }

    func controlTextDidChange(_ notification: Notification) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        for row in rows {
            row.button.isHidden = !query.isEmpty
                && !row.option.title.localizedCaseInsensitiveContains(query)
                && !row.option.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    @objc private func toggle(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        sender.needsDisplay = true
        sender.setAccessibilityValue(sender.state == .on ? "Selected" : "Not selected")
        onToggle?(rows[sender.tag].option.bundleID)
    }
}

@MainActor
private final class LibreReverseSearchFacetDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Fixed icon slots prevent differently sized application artwork from shifting labels.
@MainActor
private final class LibreReverseSearchApplicationButton: NSButton {
    private static let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(paletteColors: [.labelColor]))
    override func draw(_ dirtyRect: NSRect) {
        if state == .on || isHighlighted {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(state == .on ? 0.28 : 0.14).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        image?.draw(in: NSRect(x: 8, y: bounds.midY - 9, width: 18, height: 18),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high])
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style]
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(in: NSRect(x: 34, y: bounds.midY - height / 2,
            width: max(0, bounds.width - 60), height: height), withAttributes: attributes)
        if state == .on {
            Self.check?.draw(in: NSRect(x: bounds.maxX - 22, y: bounds.midY - 6, width: 12, height: 12))
        }
    }
}

@MainActor
private final class LibreReverseSearchChipButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }

    var isSelected = false {
        didSet { updateAppearance() }
    }

    init(title: String, symbolName: String) {
        super.init(frame: .zero)
        self.title = title
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        font = .systemFont(ofSize: 13, weight: .medium)
        contentTintColor = .white
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        imageScaling = .scaleProportionallyDown
        imageHugsTitle = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    private func updateAppearance() {
        layer?.backgroundColor = (
            isSelected
                ? NSColor.systemBlue.withAlphaComponent(0.12)
                : NSColor.white.withAlphaComponent(0.065)
        ).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(
            isSelected ? 0.15 : 0.065
        ).cgColor
        layer?.borderWidth = 0.5
        contentTintColor = isSelected
            ? (title.isEmpty ? .systemYellow : .systemBlue)
            : NSColor.white.withAlphaComponent(0.66)
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(isSelected ? 1 : 0.78),
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            ]
        )
        setAccessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}
#endif
