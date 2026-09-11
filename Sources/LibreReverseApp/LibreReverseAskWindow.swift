#if os(macOS)
import AppKit
import LibreReverseCore

@MainActor
final class LibreReverseAskWindowController: NSWindowController, NSTextFieldDelegate {
    typealias AnswerHandler = @Sendable (String, String) async throws -> LibreReverseAskAnswer

    private let answerHandler: AnswerHandler
    private let loadAPIKey: () throws -> String?
    private let saveAPIKey: (String?) throws -> Void
    private let openMoment: (Date) -> Void
    private let questionField = NSTextField(frame: .zero)
    private let introductionTitle = NSTextField(labelWithString: "Ask your history")
    private let introductionDetail = NSTextField(wrappingLabelWithString: "Answers connected to the moments you captured.")
    private let askButton = NSButton(title: "Ask", target: nil, action: nil)
    private let newQuestionButton = NSButton(title: "New question", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let answerText = NSTextView(frame: .zero)
    private let answerScroll = NSScrollView(frame: .zero)
    private var answerHeightConstraint: NSLayoutConstraint?
    private var citationButtons: [LibreReverseAskCitationButton] = []
    private let citationScroll = NSScrollView()
    private let citationList = LibreReverseAskCitationList()
    private var citationHeightConstraint: NSLayoutConstraint?
    private var citationsExpanded = false
    private let moreCitationsButton = NSButton(title: "", target: nil, action: nil)
    private let citationTitle = NSTextField(labelWithString: "Sources")
    private let copyAnswerButton = NSButton(title: "Copy answer", target: nil, action: nil)
    private let copyCitationsButton = NSButton(title: "Copy with citations", target: nil, action: nil)
    private let setupCard = NSView(frame: .zero)
    private let promptCard = NSView(frame: .zero)
    private let apiKeyField = NSSecureTextField(frame: .zero)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    private let conversation = NSStackView()
    private let suggestions = NSStackView()
    private let profileLabel = NSTextField(labelWithString: "")
    private let privacy = NSTextField(wrappingLabelWithString: "Local profiles keep everything on this Mac. Remote profiles receive relevant text, never recordings.")
    private var lastSetupPresentation: Bool?
    private var apiKey = ""
    private var answer: LibreReverseAskAnswer?
    private var requestTask: Task<Void, Never>?
    private var requestID: UUID?
    private var requestOwners: [UUID: Task<Void, Never>] = [:]
    private var shuttingDown = false

    init(
        answerHandler: @escaping AnswerHandler,
        loadAPIKey: @escaping () throws -> String?,
        saveAPIKey: @escaping (String?) throws -> Void,
        openMoment: @escaping (Date) -> Void
    ) {
        self.answerHandler = answerHandler
        self.loadAPIKey = loadAPIKey
        self.saveAPIKey = saveAPIKey
        self.openMoment = openMoment
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ask LibreReverse"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 600, height: 720)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        reloadConnection()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        guard !shuttingDown else { return }
        reloadConnection()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !apiKey.isEmpty { window?.makeFirstResponder(questionField) }
    }

    func prefill(question: String) {
        questionField.stringValue = question
        window?.makeFirstResponder(questionField)
    }

    func presentFixture(question: String, answer: LibreReverseAskAnswer) {
        apiKey = "fixture-key"
        updateWindowForConnection()
        setupCard.isHidden = true
        promptCard.isHidden = false
        questionField.isEnabled = true
        askButton.isEnabled = true
        disconnectButton.isHidden = LibreReverseAIProfiles.selected().provider == .local
        questionField.stringValue = question
        present(answer)
        statusLabel.stringValue = ""
    }

    private func cancelCurrentRequest() {
        requestTask?.cancel()
        requestTask = nil
        requestID = nil
    }

    /// A closed window or a replacement question can still own a canceled
    /// database query. Retain every request until it has actually completed.
    func beginShutdown() -> [Task<Void, Never>] {
        shuttingDown = true
        cancelCurrentRequest()
        let owners = Array(requestOwners.values)
        for owner in owners { owner.cancel() }
        return owners
    }

    override func close() {
        cancelCurrentRequest()
        super.close()
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1).cgColor

        let title = introductionTitle
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.textColor = .white
        let subtitle = introductionDetail
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.62)
        subtitle.maximumNumberOfLines = 2

        questionField.placeholderString = "What would you like to remember?"
        questionField.font = .systemFont(ofSize: 18, weight: .medium)
        questionField.isBordered = false
        questionField.drawsBackground = false
        questionField.textColor = .white
        questionField.focusRingType = .none
        questionField.delegate = self
        questionField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        questionField.setAccessibilityLabel("Ask LibreReverse a question")
        questionField.setAccessibilityIdentifier("ask.question")
        questionField.target = self
        questionField.action = #selector(submit)
        questionField.translatesAutoresizingMaskIntoConstraints = false
        questionField.maximumNumberOfLines = 2
        questionField.lineBreakMode = .byWordWrapping
        questionField.cell?.wraps = true
        questionField.cell?.usesSingleLineMode = false
        questionField.heightAnchor.constraint(equalToConstant: 48).isActive = true

        askButton.title = "Ask"
        askButton.bezelStyle = .rounded
        askButton.controlSize = .large
        askButton.bezelColor = .systemBlue
        askButton.keyEquivalent = "\r"
        askButton.target = self
        askButton.action = #selector(submit)
        askButton.setAccessibilityIdentifier("ask.submit")
        newQuestionButton.target = self
        newQuestionButton.action = #selector(newQuestion)
        newQuestionButton.isBordered = false
        newQuestionButton.contentTintColor = .secondaryLabelColor

        let promptRow = NSStackView(views: [questionField, askButton])
        promptRow.orientation = .horizontal
        promptRow.spacing = 10
        promptRow.alignment = .centerY

        promptCard.wantsLayer = true
        promptCard.layer?.backgroundColor = NSColor.clear.cgColor
        let promptRule = NSView()
        promptRule.wantsLayer = true
        promptRule.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        promptRule.translatesAutoresizingMaskIntoConstraints = false
        promptCard.addSubview(promptRule)
        NSLayoutConstraint.activate([
            promptRule.leadingAnchor.constraint(equalTo: promptCard.leadingAnchor),
            promptRule.trailingAnchor.constraint(equalTo: promptCard.trailingAnchor),
            promptRule.bottomAnchor.constraint(equalTo: promptCard.bottomAnchor),
            promptRule.heightAnchor.constraint(equalToConstant: 1),
        ])
        promptRow.translatesAutoresizingMaskIntoConstraints = false
        promptCard.addSubview(promptRow)
        NSLayoutConstraint.activate([
            promptRow.leadingAnchor.constraint(equalTo: promptCard.leadingAnchor, constant: 0),
            promptRow.trailingAnchor.constraint(equalTo: promptCard.trailingAnchor, constant: 0),
            promptRow.topAnchor.constraint(equalTo: promptCard.topAnchor, constant: 12),
            promptRow.bottomAnchor.constraint(equalTo: promptCard.bottomAnchor, constant: -12),
        ])
        profileLabel.font = .systemFont(ofSize: 12, weight: .regular)
        profileLabel.textColor = .secondaryLabelColor
        suggestions.orientation = .vertical
        suggestions.alignment = .leading
        suggestions.spacing = 10
        let suggestionTitle = NSTextField(labelWithString: "A place to start")
        suggestionTitle.textColor = .secondaryLabelColor
        suggestionTitle.font = .systemFont(ofSize: 12, weight: .regular)
        suggestions.addArrangedSubview(suggestionTitle)
        for question in ["What did I work on yesterday?", "What decisions did we make in our last meeting?", "Find the conversation about the launch."] {
            let button = NSButton(title: question + "  ↗", target: self, action: #selector(useSuggestion(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(question)
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 14)
            button.contentTintColor = NSColor.white.withAlphaComponent(0.8)
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            suggestions.addArrangedSubview(button)
        }
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.setAccessibilityIdentifier("ask.status")
        let statusRow = NSStackView(views: [progress, statusLabel, NSView()])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .centerY

        buildSetupCard()
        buildConversation()

        privacy.font = .systemFont(ofSize: 12)
        privacy.textColor = NSColor.white.withAlphaComponent(0.48)
        privacy.maximumNumberOfLines = 3
        privacy.setAccessibilityIdentifier("ask.privacy")

        let root = NSStackView(views: [title, subtitle, setupCard, promptCard, suggestions, conversation, statusRow, profileLabel, privacy])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.setCustomSpacing(20, after: subtitle)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            title.widthAnchor.constraint(equalTo: root.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: root.widthAnchor),
            suggestions.widthAnchor.constraint(equalTo: root.widthAnchor),
            setupCard.widthAnchor.constraint(equalTo: root.widthAnchor),
            promptCard.widthAnchor.constraint(equalTo: root.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            conversation.widthAnchor.constraint(equalTo: root.widthAnchor),
            privacy.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
    }

    private func buildSetupCard() {
        setupCard.wantsLayer = true
        setupCard.layer?.cornerRadius = 14
        setupCard.layer?.backgroundColor = NSColor.clear.cgColor
        setupCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        setupCard.layer?.borderWidth = 0
        let title = NSTextField(labelWithString: "Connect your AI profile")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString:
            "Add an API key for questions and meeting summaries. It is encrypted on this Mac."
        )
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 13)
        detail.maximumNumberOfLines = 2
        apiKeyField.placeholderString = "AI profile API key"
        apiKeyField.setAccessibilityLabel("AI profile API key")
        apiKeyField.setAccessibilityIdentifier("ask.api-key")
        connectButton.target = self
        connectButton.action = #selector(connect)
        connectButton.setAccessibilityIdentifier("ask.connect")
        let keyRow = NSStackView(views: [apiKeyField, connectButton])
        keyRow.orientation = .horizontal
        keyRow.spacing = 10
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let stack = NSStackView(views: [title, detail, keyRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        setupCard.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: setupCard.topAnchor, constant: 0),
            stack.leadingAnchor.constraint(equalTo: setupCard.leadingAnchor, constant: 0),
            stack.trailingAnchor.constraint(equalTo: setupCard.trailingAnchor, constant: 0),
            stack.bottomAnchor.constraint(equalTo: setupCard.bottomAnchor, constant: 0),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            keyRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func buildConversation() {
        answerText.isEditable = false
        answerText.isSelectable = true
        answerText.isVerticallyResizable = true
        answerText.isHorizontallyResizable = false
        answerText.autoresizingMask = [.width]
        answerText.textContainer?.widthTracksTextView = true
        answerText.textContainer?.lineFragmentPadding = 0
        answerText.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        answerText.drawsBackground = false
        answerText.textColor = .white
        answerText.font = .systemFont(ofSize: 15)
        answerText.textContainerInset = NSSize(width: 0, height: 8)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        answerText.defaultParagraphStyle = paragraph
        answerText.setAccessibilityLabel("Ask LibreReverse answer")
        answerText.setAccessibilityIdentifier("ask.answer")
        answerScroll.documentView = answerText
        answerScroll.drawsBackground = false
        answerScroll.hasVerticalScroller = true
        answerScroll.borderType = .noBorder
        answerScroll.translatesAutoresizingMaskIntoConstraints = false
        let answerHeight = answerScroll.heightAnchor.constraint(equalToConstant: 180)
        answerHeight.priority = .defaultHigh
        answerHeight.isActive = true
        answerScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        answerHeightConstraint = answerHeight

        citationScroll.drawsBackground = false
        citationScroll.borderType = .noBorder
        citationScroll.hasVerticalScroller = true
        citationScroll.autohidesScrollers = true
        citationScroll.setAccessibilityIdentifier("ask.sources.list")
        citationScroll.documentView = citationList
        citationList.autoresizingMask = [.width]
        citationHeightConstraint = citationScroll.heightAnchor.constraint(equalToConstant: 120)
        citationHeightConstraint?.isActive = true
        moreCitationsButton.font = .systemFont(ofSize: 12)
        moreCitationsButton.isBordered = false
        moreCitationsButton.alignment = .left
        moreCitationsButton.contentTintColor = .systemBlue
        moreCitationsButton.target = self
        moreCitationsButton.action = #selector(toggleCitations)
        moreCitationsButton.setAccessibilityIdentifier("ask.sources.toggle")

        copyAnswerButton.target = self
        copyAnswerButton.action = #selector(copyAnswer)
        copyCitationsButton.target = self
        copyCitationsButton.action = #selector(copyWithCitations)
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnect)
        disconnectButton.isBordered = false
        disconnectButton.contentTintColor = .secondaryLabelColor
        for button in [copyAnswerButton, copyCitationsButton, newQuestionButton] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 12)
            button.contentTintColor = .systemBlue
            button.imagePosition = .imageLeading
        }
        copyAnswerButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyCitationsButton.image = NSImage(systemSymbolName: "quote.opening", accessibilityDescription: nil)
        newQuestionButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        let actions = NSStackView(views: [copyAnswerButton, copyCitationsButton, NSView(), newQuestionButton, disconnectButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        citationTitle.font = .systemFont(ofSize: 14, weight: .regular)
        citationTitle.textColor = .secondaryLabelColor

        conversation.wantsLayer = true
        conversation.layer?.backgroundColor = NSColor.clear.cgColor
        conversation.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        conversation.orientation = .vertical
        conversation.alignment = .leading
        conversation.spacing = 8
        conversation.addArrangedSubview(answerScroll)
        conversation.addArrangedSubview(citationTitle)
        conversation.addArrangedSubview(citationScroll)
        conversation.addArrangedSubview(moreCitationsButton)
        conversation.setCustomSpacing(24, after: moreCitationsButton)
        conversation.addArrangedSubview(actions)
        for view in [answerScroll, actions, citationTitle, citationScroll, moreCitationsButton] {
            view.widthAnchor.constraint(equalTo: conversation.widthAnchor, constant: 0).isActive = true
        }
        conversation.isHidden = true
    }

    @objc private func useSuggestion(_ sender: NSButton) {
        prefill(question: sender.identifier?.rawValue ?? "")
    }

    #if DEBUG
    func submitFixtureRequest() { submit() }
    #endif

    private func updateWindowForConnection() {
        let showsSetup = apiKey.isEmpty
        guard lastSetupPresentation != showsSetup else { return }
        lastSetupPresentation = showsSetup
        // Resize only on entering a different connection state. Reopening an
        // unchanged Ask window preserves the user's chosen reading size.
        window?.minSize = NSSize(width: 600, height: showsSetup ? 380 : 600)
        window?.setContentSize(NSSize(width: 680, height: showsSetup ? 400 : 640))
    }

    private func reloadConnection() {
        let profile = LibreReverseAIProfiles.selected()
        profileLabel.stringValue = profile.name + " · AI profile"
        privacy.stringValue = profile.provider == .local
            ? "Answers are generated on this Mac."
            : "Relevant text is sent to \(profile.name). Screenshots, video, and audio are not sent to the AI provider."
        disconnectButton.isHidden = profile.provider == .local
        do {
            apiKey = try loadAPIKey() ?? ""
            updateWindowForConnection()
            setupCard.isHidden = !apiKey.isEmpty
            promptCard.isHidden = apiKey.isEmpty
            suggestions.isHidden = apiKey.isEmpty || answer != nil
            questionField.isEnabled = !apiKey.isEmpty
            askButton.isEnabled = !apiKey.isEmpty
            disconnectButton.isHidden = apiKey.isEmpty || profile.provider == .local
            if apiKey.isEmpty { statusLabel.stringValue = "" }
        } catch {
            statusLabel.stringValue = error.localizedDescription
            setupCard.isHidden = false
            promptCard.isHidden = true
            questionField.isEnabled = false
            askButton.isEnabled = false
        }
    }

    @objc private func connect() {
        guard !shuttingDown else { return }
        let candidate = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            statusLabel.stringValue = "Enter an API key first."
            NSSound.beep()
            return
        }
        do {
            try saveAPIKey(candidate)
            apiKey = candidate
            updateWindowForConnection()
            suggestions.isHidden = answer != nil
            apiKeyField.stringValue = ""
            setupCard.isHidden = true
        promptCard.isHidden = false
            questionField.isEnabled = true
            askButton.isEnabled = true
            disconnectButton.isHidden = false
            statusLabel.stringValue = "API key saved."
            window?.makeFirstResponder(questionField)
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func disconnect() {
        guard !shuttingDown else { return }
        do {
            try saveAPIKey(nil)
            apiKey = ""
            updateWindowForConnection()
            setupCard.isHidden = false
            promptCard.isHidden = true
            questionField.isEnabled = false
            askButton.isEnabled = false
            disconnectButton.isHidden = true
            newQuestion()
            statusLabel.stringValue = "Disconnected. Saved key removed."
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func submit() {
        requestAnswer(question: questionField.stringValue)
    }

    @discardableResult
    func requestAnswer(question rawQuestion: String) -> Task<Void, Never>? {
        guard !shuttingDown else { return nil }
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !apiKey.isEmpty else { NSSound.beep(); return nil }
        cancelCurrentRequest()
        progress.startAnimation(nil)
        askButton.isEnabled = false
        questionField.isEnabled = false
        statusLabel.stringValue = "Searching your local screen text and transcripts…"
        conversation.isHidden = true
        suggestions.isHidden = true
        let apiKey = (try? loadAPIKey()) ?? ""
        let identifier = UUID()
        requestID = identifier
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                requestOwners[identifier] = nil
                if requestID == identifier {
                    requestTask = nil
                    requestID = nil
                }
            }
            do {
                try Task.checkCancellation()
                let result = try await answerHandler(question, apiKey)
                guard !Task.isCancelled, !shuttingDown, requestID == identifier else { return }
                present(result)
                statusLabel.stringValue = ""
            } catch is CancellationError {
                guard !shuttingDown, requestID == identifier else { return }
                statusLabel.stringValue = "Request cancelled."
            } catch {
                guard !shuttingDown, requestID == identifier else { return }
                statusLabel.stringValue = error.localizedDescription
                conversation.isHidden = true
            }
            progress.stopAnimation(nil)
            askButton.isEnabled = true
            questionField.isEnabled = true
        }
        requestTask = task
        requestOwners[identifier] = task
        return task
    }

    private func present(_ answer: LibreReverseAskAnswer) {
        self.answer = answer
        introductionTitle.isHidden = true
        askButton.isHidden = true
        privacy.isHidden = true
        introductionDetail.isHidden = true
        questionField.font = .systemFont(ofSize: 20, weight: .semibold)
        suggestions.isHidden = true
        answerText.string = answer.text
        citationsExpanded = false
        for button in citationButtons { button.removeFromSuperview() }
        citationButtons = answer.citations.enumerated().map { index, citation in
            let button = LibreReverseAskCitationButton()
            button.configure(citation: citation, index: index + 1)
            button.identifier = NSUserInterfaceItemIdentifier("ask.source.\(index + 1)")
            button.setAccessibilityIdentifier("ask.source.\(index + 1)")
            button.autoresizingMask = [.width]
            button.onOpen = { [weak self] in self?.openMoment(citation.instant) }
            citationList.addSubview(button)
            return button
        }
        updateCitationVisibility()
        conversation.isHidden = false
        conversation.layoutSubtreeIfNeeded()
        if let container = answerText.textContainer, let layout = answerText.layoutManager {
            container.containerSize.width = max(1, answerScroll.contentSize.width)
            layout.ensureLayout(for: container)
            answerHeightConstraint?.constant = min(320, max(72, ceil(layout.usedRect(for: container).height + 20)))
        }
        window?.makeFirstResponder(answerText)
    }

    @objc private func toggleCitations() {
        guard !shuttingDown, citationButtons.count > 3 else { return }
        citationsExpanded.toggle()
        updateCitationVisibility()
    }

    private func updateCitationVisibility() {
        let count = citationsExpanded ? citationButtons.count : min(3, citationButtons.count)
        let width = max(1, citationScroll.contentSize.width)
        citationList.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(count) * 40)
        for (index, button) in citationButtons.enumerated() {
            button.isHidden = index >= count
            button.frame = NSRect(x: 0, y: CGFloat(index) * 40, width: width, height: 40)
        }
        citationHeightConstraint?.constant = CGFloat(min(count, 6)) * 40
        citationScroll.isHidden = count == 0
        citationTitle.isHidden = count == 0
        moreCitationsButton.isHidden = citationButtons.count <= 3
        moreCitationsButton.title = citationsExpanded
            ? "Show fewer sources" : "Show all \(citationButtons.count) sources"
        moreCitationsButton.setAccessibilityValue(citationsExpanded ? "Expanded" : "Collapsed")
        citationScroll.contentView.scroll(to: .zero)
        citationScroll.reflectScrolledClipView(citationScroll.contentView)
    }

    #if DEBUG
    var fixtureCitationCopyText: String? { answer?.textWithCitations }
    #endif

    @objc private func newQuestion() {
        guard !shuttingDown else { return }
        answer = nil
        introductionTitle.isHidden = false
        askButton.isHidden = false
        privacy.isHidden = false
        introductionDetail.isHidden = false
        questionField.font = .systemFont(ofSize: 18, weight: .medium)
        suggestions.isHidden = false
        cancelCurrentRequest()
        questionField.stringValue = ""
        conversation.isHidden = true
        statusLabel.stringValue = ""
        progress.stopAnimation(nil)
        questionField.isEnabled = !apiKey.isEmpty
        askButton.isEnabled = !apiKey.isEmpty
        window?.makeFirstResponder(questionField)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === questionField else { return }
        askButton.isHidden = false
    }

    @objc private func copyAnswer() { copy(answer?.text) }
    @objc private func copyWithCitations() { copy(answer?.textWithCitations) }

    private func copy(_ value: String?) {
        guard let value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        statusLabel.stringValue = "Copied to clipboard."
    }

}

@MainActor
private final class LibreReverseAskCitationList: NSView {
    override var isFlipped: Bool { true }
}

private final class LibreReverseAskCitationButton: NSButton {
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
