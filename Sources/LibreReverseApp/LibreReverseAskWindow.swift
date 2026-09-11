#if os(macOS)
import AppKit
import LibreReverseCore

@MainActor
final class LibreReverseAskWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    typealias AnswerHandler = @Sendable (String, String) async throws -> LibreReverseAskAnswer
    typealias ProgressAnswerHandler = @Sendable (String, String, @escaping @Sendable (String) -> Void) async throws -> LibreReverseAskAnswer
    typealias ConversationAnswerHandler = @Sendable (String, String, [LibreReverseAskConversationTurn], Date?, @escaping @Sendable (String) -> Void) async throws -> LibreReverseAskAnswer
    private let answerHandler: AnswerHandler
    private let progressAnswerHandler: ProgressAnswerHandler?
    private let conversationAnswerHandler: ConversationAnswerHandler?
    private let loadAPIKey: () throws -> String?
    private let openAISettings: () -> Void
    private let openMoment: (Date) -> Void
    private let elapsedNow: () -> TimeInterval
    private let chatStore: LibreReverseAskChatStore?
    private var contentRoot: NSView?
    private var isEmbedded = false
    private var restoringChat = false
    private var contextMoment: Date?
    private let historyPopup = NSPopUpButton()
    private var historySummaries: [LibreReverseAskChatSummary] = []
    private var historyHasMore = false
    private var savedTurns: [LibreReverseAskSavedTurn] = []
    private var chatID = UUID()
    private var historyOwners: [UUID: Task<Void, Never>] = [:]
    private var historySaveIDs: Set<UUID> = []
    private var historyRefreshID: UUID?
    private var historyLoadID: UUID?
    private var lastSaveTask: Task<Void, Never>?
    private var presentationWindow: NSWindow? { contentRoot?.window ?? (isEmbedded ? nil : window) }
    private let headerTitle = NSTextField(labelWithString: "Ask")
    private let questionField = LibreReverseAskComposer()
    private let composerPanel = NSStackView()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let profileLabel = NSTextField(labelWithString: "")
    private let setupCard = NSStackView()
    private let chatScroll = NSScrollView()
    private let chatDocument = LibreReverseAskChatDocument()
    private let messages = NSStackView()
    private let introduction = NSTextField(wrappingLabelWithString: "Ask about your meetings and screen history.\nFollow up to explore the same conversation.")
    private let saveStatus = NSTextField(wrappingLabelWithString: "")
    private let activity = LibreReverseAskDisclosure(title: "Search activity", identifier: "ask.activity")
    private let progress = NSProgressIndicator()
    private var activityMessages: [String] = []
    private var apiKey = ""
    private var answer: LibreReverseAskAnswer?
    private var completedTurns: [LibreReverseAskConversationTurn] = []
    private var visibleExchanges: [NSStackView] = []
    private var requestTask: Task<Void, Never>?
    private var requestID: UUID?
    private var requestOwners: [UUID: Task<Void, Never>] = [:]
    private var elapsedTimer: Timer?
    private var requestStartedAt: TimeInterval?
    private var stepStartedAt: TimeInterval?
    private var shuttingDown = false

    init(answerHandler: @escaping AnswerHandler, loadAPIKey: @escaping () throws -> String?,
         openAISettings: @escaping () -> Void, openMoment: @escaping (Date) -> Void,
         progressAnswerHandler: ProgressAnswerHandler? = nil,
         elapsedNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         conversationAnswerHandler: ConversationAnswerHandler? = nil,
         chatStore: LibreReverseAskChatStore? = nil) {
        self.answerHandler = answerHandler
        self.loadAPIKey = loadAPIKey
        self.openAISettings = openAISettings
        self.openMoment = openMoment
        self.progressAnswerHandler = progressAnswerHandler
        self.conversationAnswerHandler = conversationAnswerHandler
        self.elapsedNow = elapsedNow
        self.chatStore = chatStore
        let window = LibreReverseAskChatWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Ask LibreReverse"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 600, height: 620)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        reloadConnection()
        refreshHistory()
    }
    required init?(coder: NSCoder) { nil }

    func takeContentForEmbedding() -> NSView {
        isEmbedded = true
        headerTitle.isHidden = true
        window?.orderOut(nil)
        let content = contentRoot!
        if window?.contentView === content { window?.contentView = nil }
        return content
    }
    func prepareEmbedded(query: String = "", contextMoment: Date? = nil) {
        self.contextMoment = contextMoment
        refreshConfiguration()
        if !query.isEmpty { prefill(question: query) }
        if !apiKey.isEmpty, requestID == nil { presentationWindow?.makeFirstResponder(questionField) }
    }
    func setEmbeddedVisible(_ visible: Bool) {
        if visible {
            refreshConfiguration()
            if !apiKey.isEmpty, requestID == nil { presentationWindow?.makeFirstResponder(questionField) }
        } else {
            if requestID != nil { cancelAnswer() }
            historyLoadID = nil
        }
    }
    func refreshConfiguration() {
        guard !shuttingDown, requestID == nil else { return }
        reloadConnection()
        refreshHistory()
    }

    func present() {
        guard !shuttingDown else { return }
        if requestID == nil { reloadConnection() }
        if isEmbedded { presentationWindow?.makeFirstResponder(questionField); return }
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !apiKey.isEmpty, requestID == nil { presentationWindow?.makeFirstResponder(questionField) }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard !shuttingDown, requestID == nil else { return }
        reloadConnection()
    }
    func windowDidResize(_ notification: Notification) { layoutMessages() }
    func windowWillClose(_ notification: Notification) { cancelCurrentRequest() }
    func prefill(question: String) { questionField.string = question; presentationWindow?.makeFirstResponder(questionField) }
    func presentFixture(question: String, answer: LibreReverseAskAnswer) {
        resetConversation()
        appendFixture(question: question, answer: answer)
    }
    func submitFixtureRequest() { submit() }

    func appendFixture(question: String, answer: LibreReverseAskAnswer) {
        apiKey = "fixture-key"
        setupCard.isHidden = true
        composerPanel.isHidden = false
        questionField.isEditable = true
        sendButton.isEnabled = true
        let exchange = appendQuestion(question)
        appendAnswer(answer, question: question, exchange: exchange, scroll: true)
        statusLabel.stringValue = ""
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        contentRoot = content
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1).cgColor
        let title = headerTitle
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let newChat = NSButton(title: "New chat", target: self, action: #selector(newQuestion))
        newChat.setAccessibilityIdentifier("ask.new-chat")
        let settings = NSButton(title: "AI Settings", target: self, action: #selector(openSettings))
        settings.setAccessibilityIdentifier("ask.ai-settings")
        for button in [newChat, settings] { button.isBordered = false; button.contentTintColor = .secondaryLabelColor }
        historyPopup.setAccessibilityIdentifier("ask.saved-chats")
        historyPopup.target = self
        historyPopup.action = #selector(selectHistory)
        historyPopup.addItem(withTitle: "Saved chats")
        historyPopup.isHidden = chatStore == nil
        historyPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        let header = NSStackView(views: [title, NSView(), historyPopup, newChat, settings])
        header.spacing = 12
        let setupTitle = NSTextField(labelWithString: "Set up your AI profile")
        setupTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        let setupDetail = NSTextField(wrappingLabelWithString: "Choose your profile and manage its API key in Settings → AI, then return here.")
        setupDetail.textColor = .secondaryLabelColor
        let setupButton = NSButton(title: "Open AI Settings", target: self, action: #selector(openSettings))
        setupButton.setAccessibilityIdentifier("ask.setup.ai-settings")
        setupCard.orientation = .vertical; setupCard.alignment = .leading; setupCard.spacing = 10
        [setupTitle, setupDetail, setupButton].forEach { setupCard.addArrangedSubview($0) }
        setupDetail.widthAnchor.constraint(equalTo: setupCard.widthAnchor).isActive = true

        chatScroll.drawsBackground = false; chatScroll.borderType = .noBorder
        chatScroll.hasVerticalScroller = true; chatScroll.autohidesScrollers = true
        chatScroll.setAccessibilityIdentifier("ask.chat")
        chatDocument.translatesAutoresizingMaskIntoConstraints = false
        messages.translatesAutoresizingMaskIntoConstraints = false
        messages.orientation = .vertical; messages.alignment = .leading; messages.spacing = 30
        chatDocument.addSubview(messages)
        chatScroll.documentView = chatDocument
        let preferred = chatDocument.heightAnchor.constraint(equalTo: messages.heightAnchor, constant: 40)
        preferred.priority = .defaultLow
        NSLayoutConstraint.activate([
            chatDocument.widthAnchor.constraint(equalTo: chatScroll.contentView.widthAnchor),
            chatDocument.heightAnchor.constraint(greaterThanOrEqualTo: chatScroll.contentView.heightAnchor),
            chatDocument.heightAnchor.constraint(greaterThanOrEqualTo: messages.heightAnchor, constant: 40), preferred,
            messages.topAnchor.constraint(equalTo: chatDocument.topAnchor, constant: 20),
            messages.leadingAnchor.constraint(equalTo: chatDocument.leadingAnchor, constant: 14),
            messages.trailingAnchor.constraint(equalTo: chatDocument.trailingAnchor, constant: -14)
        ])
        introduction.font = .systemFont(ofSize: 17)
        introduction.textColor = .secondaryLabelColor
        saveStatus.font = .systemFont(ofSize: 11); saveStatus.textColor = .secondaryLabelColor
        saveStatus.setAccessibilityIdentifier("ask.save-status"); saveStatus.isHidden = true
        resetMessages()

        questionField.font = .systemFont(ofSize: 15)
        questionField.textColor = .labelColor
        questionField.drawsBackground = false
        questionField.textContainerInset = NSSize(width: 10, height: 10)
        questionField.isRichText = false
        questionField.isVerticallyResizable = true
        questionField.isHorizontallyResizable = false
        questionField.autoresizingMask = [.width]
        questionField.textContainer?.widthTracksTextView = true
        questionField.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        questionField.setAccessibilityIdentifier("ask.question")
        questionField.setAccessibilityLabel("Message Ask LibreReverse")
        questionField.setAccessibilityHelp("Return sends. Shift-Return adds a new line.")
        questionField.onSubmit = { [weak self] in self?.submit() }
        let inputScroll = NSScrollView()
        inputScroll.documentView = questionField
        inputScroll.drawsBackground = true
        inputScroll.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1)
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.wantsLayer = true; inputScroll.layer?.cornerRadius = 12
        inputScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
        sendButton.target = self; sendButton.action = #selector(submit)
        sendButton.setAccessibilityIdentifier("ask.send")
        sendButton.bezelStyle = .rounded
        cancelButton.target = self; cancelButton.action = #selector(cancelAnswer)
        cancelButton.setAccessibilityIdentifier("ask.cancel"); cancelButton.isHidden = true
        let hint = NSTextField(labelWithString: "Return to send · Shift-Return for a new line")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .tertiaryLabelColor
        let controls = NSStackView(views: [hint, NSView(), cancelButton, sendButton])
        controls.spacing = 10
        composerPanel.orientation = .vertical; composerPanel.alignment = .leading; composerPanel.spacing = 8
        composerPanel.addArrangedSubview(inputScroll); composerPanel.addArrangedSubview(controls)
        inputScroll.widthAnchor.constraint(equalTo: composerPanel.widthAnchor).isActive = true
        controls.widthAnchor.constraint(equalTo: composerPanel.widthAnchor).isActive = true
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 12); statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("ask.status")
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor; elapsedLabel.setAccessibilityIdentifier("ask.elapsed")
        elapsedLabel.isHidden = true
        let statusText = NSStackView(views: [statusLabel, elapsedLabel])
        statusText.orientation = .vertical; statusText.alignment = .leading; statusText.spacing = 3
        let statusRow = NSStackView(views: [progress, statusText, NSView()]); statusRow.spacing = 8
        profileLabel.font = .systemFont(ofSize: 11); profileLabel.textColor = .secondaryLabelColor
        let root = NSStackView(views: [header, setupCard, chatScroll, activity, statusRow, composerPanel, saveStatus, profileLabel])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            chatScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        chatScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        chatScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    private func resetMessages() {
        for view in messages.arrangedSubviews { messages.removeArrangedSubview(view); view.removeFromSuperview() }
        messages.addArrangedSubview(introduction)
        if !messages.constraints.contains(where: { $0.identifier == "chat.introduction.width" }) {
            let width = introduction.widthAnchor.constraint(equalTo: messages.widthAnchor)
            width.identifier = "chat.introduction.width"
            width.isActive = true
        }
    }
    private func appendQuestion(_ question: String) -> NSStackView {
        introduction.isHidden = true
        let exchange = NSStackView()
        exchange.orientation = .vertical; exchange.alignment = .leading; exchange.spacing = 22
        let user = NSStackView()
        user.orientation = .vertical; user.alignment = .leading; user.spacing = 5
        let label = NSTextField(labelWithString: "You")
        label.font = .systemFont(ofSize: 12, weight: .semibold); label.textColor = .secondaryLabelColor
        let text = LibreReverseAskMessageText(text: question, identifier: "ask.user-message")
        user.addArrangedSubview(label); user.addArrangedSubview(text)
        text.widthAnchor.constraint(equalTo: user.widthAnchor).isActive = true
        exchange.addArrangedSubview(user)
        user.widthAnchor.constraint(equalTo: exchange.widthAnchor).isActive = true
        messages.addArrangedSubview(exchange)
        exchange.widthAnchor.constraint(equalTo: messages.widthAnchor).isActive = true
        visibleExchanges.append(exchange)
        if !restoringChat { layoutMessages(scroll: true) }
        return exchange
    }
    private func appendAnswer(_ result: LibreReverseAskAnswer, question: String, exchange: NSStackView, scroll: Bool) {
        let displayed = LibreReverseAskAnswer(text: result.text, citations: result.citations.map {
            var citation = $0
            citation.evidence = nil
            return citation
        }, coverageNotes: result.coverageNotes, conversationScope: result.conversationScope)
        answer = displayed
        savedTurns.append(.init(question: question, answer: displayed))
        let view = LibreReverseAskAnswerView(answer: displayed, openMoment: openMoment)
        view.onResize = { [weak self] in self?.layoutMessages() }
        view.onCopy = { [weak self] in if self?.requestID == nil { self?.statusLabel.stringValue = "Copied to clipboard." } }
        exchange.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: exchange.widthAnchor).isActive = true
        completedTurns.append(.init(question: question, answer: result.text, scope: result.conversationScope))
        if completedTurns.count > 6 { completedTurns.removeFirst(completedTurns.count - 6) }
        if !restoringChat { layoutMessages(scroll: scroll) }
    }
    private var nearBottom: Bool { chatDocument.bounds.height - chatScroll.contentView.bounds.maxY < 80 }
    private func layoutMessages(scroll: Bool = false) {
        contentRoot?.layoutSubtreeIfNeeded()
        // Measuring text updates intrinsic heights, then a second pass resolves the document.
        contentRoot?.layoutSubtreeIfNeeded()
        if scroll {
            chatScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, chatDocument.bounds.height - chatScroll.contentSize.height)))
            chatScroll.reflectScrolledClipView(chatScroll.contentView)
        }
    }
    private func reloadConnection() {
        let profile = LibreReverseAIProfiles.selected()
        profileLabel.stringValue = profile.name + " · Follow-ups use the last 6 exchanges"
        do { apiKey = try loadAPIKey() ?? "" }
        catch { apiKey = ""; statusLabel.stringValue = error.localizedDescription }
        setupCard.isHidden = !apiKey.isEmpty
        composerPanel.isHidden = apiKey.isEmpty
        questionField.isEditable = !apiKey.isEmpty
        sendButton.isEnabled = !apiKey.isEmpty
    }
    @objc private func openSettings() { guard !shuttingDown else { return }; openAISettings() }
    @objc private func submit() { requestAnswer(question: questionField.string) }

    @discardableResult
    func requestAnswer(question rawQuestion: String) -> Task<Void, Never>? {
        guard !shuttingDown else { return nil }
        if requestID == nil { reloadConnection() }
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !apiKey.isEmpty else { NSSound.beep(); return nil }
        guard visibleExchanges.count < 200 else {
            statusLabel.stringValue = "This chat has reached 200 exchanges. Start a new chat to continue."
            return nil
        }
        cancelCurrentRequest()
        historyLoadID = nil
        questionField.string = question
        questionField.isEditable = false; sendButton.isEnabled = false
        activityMessages = []; activity.setText("", collapse: true)
        let history = completedTurns
        let selectedMoment = contextMoment
        let exchange = appendQuestion(question)
        statusLabel.stringValue = "Finding evidence and preparing an answer…"
        progress.startAnimation(nil)
        let identifier = UUID(); requestID = identifier
        startElapsedUpdates()
        let key = apiKey
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                requestOwners[identifier] = nil
                if requestID == identifier {
                    stopElapsedUpdates(); requestID = nil; requestTask = nil
                    progress.stopAnimation(nil)
                    questionField.isEditable = true; sendButton.isEnabled = true
                }
            }
            let report: @Sendable (String) -> Void = { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, !self.shuttingDown, self.requestID == identifier else { return }
                    self.recordActivity(message)
                }
            }
            do {
                try Task.checkCancellation()
                let result: LibreReverseAskAnswer
                if let conversationAnswerHandler { result = try await conversationAnswerHandler(question, key, history, selectedMoment, report) }
                else if let progressAnswerHandler { result = try await progressAnswerHandler(question, key, report) }
                else { result = try await answerHandler(question, key) }
                guard !Task.isCancelled, !shuttingDown, requestID == identifier else { return }
                appendAnswer(result, question: question, exchange: exchange, scroll: nearBottom)
                persistChat()
                activity.setText(activityMessages.joined(separator: "\n"), collapse: true)
                questionField.string = ""
                statusLabel.stringValue = ""
                presentationWindow?.makeFirstResponder(questionField)
            } catch {
                guard !shuttingDown, requestID == identifier else { return }
                statusLabel.stringValue = error is CancellationError ? "Request cancelled." : error.localizedDescription
            }
        }
        requestTask = task; requestOwners[identifier] = task
        return task
    }
    private func cancelCurrentRequest() {
        requestTask?.cancel(); requestTask = nil; requestID = nil
        stopElapsedUpdates(); progress.stopAnimation(nil)
        questionField.isEditable = !apiKey.isEmpty && !shuttingDown
        sendButton.isEnabled = !apiKey.isEmpty && !shuttingDown
    }
    @objc private func cancelAnswer() {
        guard !shuttingDown, requestID != nil else { return }
        cancelCurrentRequest(); statusLabel.stringValue = "Request cancelled."
        presentationWindow?.makeFirstResponder(questionField)
    }
    func beginShutdown() -> [Task<Void, Never>] {
        shuttingDown = true; cancelCurrentRequest()
        historyLoadID = nil; historyRefreshID = nil
        for owner in requestOwners.values { owner.cancel() }
        for (id, owner) in historyOwners where !historySaveIDs.contains(id) { owner.cancel() }
        // A displayed answer's pending save must finish before the application closes its database.
        return Array(requestOwners.values) + Array(historyOwners.values)
    }
    override func close() { cancelCurrentRequest(); super.close() }
    @objc private func newQuestion() { guard !shuttingDown else { return }; resetConversation(); presentationWindow?.makeFirstResponder(questionField) }
    private func resetConversation() {
        cancelCurrentRequest(); answer = nil; completedTurns = []; visibleExchanges = []
        chatID = UUID(); savedTurns = []; historyLoadID = nil
        saveStatus.stringValue = ""; saveStatus.isHidden = true
        resetMessages(); introduction.isHidden = false
        activityMessages = []; activity.setText("", collapse: true)
        questionField.string = ""; statusLabel.stringValue = ""
        layoutMessages(scroll: true)
    }
    private func refreshHistory(append: Bool = false) {
        guard !shuttingDown, let chatStore else { return }
        let identifier = UUID(); historyRefreshID = identifier
        let offset = append ? historySummaries.count : 0
        let task = Task { [weak self] in
            guard let self else { return }
            defer { historyOwners[identifier] = nil }
            do {
                let summaries = try await chatStore.list(limit: 100, offset: offset)
                guard !Task.isCancelled, !shuttingDown, historyRefreshID == identifier else { return }
                if append { historySummaries.append(contentsOf: summaries) } else { historySummaries = summaries }
                historyHasMore = summaries.count == 100
                historyPopup.removeAllItems()
                historyPopup.addItem(withTitle: historySummaries.isEmpty ? "No saved chats" : "Saved chats")
                for summary in historySummaries {
                    let item = NSMenuItem(title: String(summary.title.prefix(65)), action: nil, keyEquivalent: "")
                    item.representedObject = summary.id
                    historyPopup.menu?.addItem(item)
                }
                if historyHasMore { historyPopup.menu?.addItem(NSMenuItem(title: "Load more chats…", action: nil, keyEquivalent: "")) }
                historyPopup.isEnabled = !historySummaries.isEmpty
            } catch {
                guard !shuttingDown, !Task.isCancelled else { return }
                historyPopup.toolTip = "Could not load chats: \(error.localizedDescription)"
            }
        }
        historyOwners[identifier] = task
    }
    private func persistChat() {
        guard !shuttingDown, let chatStore, !savedTurns.isEmpty else { return }
        let identifier = UUID(), id = chatID, snapshot = savedTurns
        let predecessor = lastSaveTask
        let task = Task { [weak self] in
            guard let self else { return }
            defer { historyOwners[identifier] = nil; historySaveIDs.remove(identifier) }
            do {
                await predecessor?.value
                try await chatStore.save(id: id, turns: snapshot)
                guard !shuttingDown else { return }
                if chatID == id { saveStatus.stringValue = ""; saveStatus.isHidden = true }
                refreshHistory()
            } catch {
                guard !shuttingDown else { return }
                historyPopup.toolTip = "Chat could not be saved: \(error.localizedDescription)"
                saveStatus.stringValue = "Chat could not be saved. \(error.localizedDescription)"
                saveStatus.isHidden = false
            }
        }
        historySaveIDs.insert(identifier)
        historyOwners[identifier] = task
        lastSaveTask = task
    }
    @objc private func selectHistory() {
        let index = historyPopup.indexOfSelectedItem - 1
        if historyHasMore, index == historySummaries.count {
            historyPopup.selectItem(at: 0)
            refreshHistory(append: true)
            return
        }
        guard historySummaries.indices.contains(index) else { return }
        let id = historySummaries[index].id
        historyPopup.selectItem(at: 0)
        loadChat(id: id)
    }
    func loadChat(id: UUID) {
        guard !shuttingDown, let chatStore else { return }
        cancelCurrentRequest()
        let identifier = UUID(); historyLoadID = identifier
        let pendingSave = lastSaveTask
        statusLabel.stringValue = "Loading saved chat…"
        let task = Task { [weak self] in
            guard let self else { return }
            defer { historyOwners[identifier] = nil }
            do {
                // Saves may be queued behind an earlier snapshot. Read only after
                // all saves admitted before this selection have actually finished.
                await pendingSave?.value
                guard !shuttingDown, !Task.isCancelled, historyLoadID == identifier else { return }
                let loaded = try await chatStore.load(id: id)
                guard !shuttingDown, !Task.isCancelled, historyLoadID == identifier else { return }
                guard let saved = loaded else { statusLabel.stringValue = "This saved chat is no longer available."; return }
                resetConversation(); chatID = saved.id
                restoringChat = true
                for turn in saved.turns {
                    let exchange = appendQuestion(turn.question)
                    appendAnswer(turn.answer, question: turn.question, exchange: exchange, scroll: false)
                }
                restoringChat = false
                statusLabel.stringValue = ""
                layoutMessages(scroll: true)
            } catch {
                guard !shuttingDown, historyLoadID == identifier else { return }
                statusLabel.stringValue = "Could not load chat. \(error.localizedDescription)"
            }
        }
        historyOwners[identifier] = task
    }

    private func startElapsedUpdates() {
        requestStartedAt = elapsedNow(); stepStartedAt = requestStartedAt
        cancelButton.isHidden = false; elapsedLabel.isHidden = false; refreshElapsed()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshElapsed() }
        }
    }
    private func stopElapsedUpdates() {
        elapsedTimer?.invalidate(); elapsedTimer = nil; requestStartedAt = nil; stepStartedAt = nil
        elapsedLabel.stringValue = ""; elapsedLabel.isHidden = true; cancelButton.isHidden = true
    }
    private func refreshElapsed() {
        guard requestID != nil, !shuttingDown, let start = requestStartedAt, let step = stepStartedAt else { return }
        let now = elapsedNow()
        func duration(_ seconds: TimeInterval) -> String {
            let value = Int(max(0, min(seconds, 365 * 24 * 60 * 60)))
            return String(format: "%d:%02d", value / 60, value % 60)
        }
        elapsedLabel.stringValue = "\(duration(now - start)) elapsed · \(duration(now - step)) on this step"
    }
    private func recordActivity(_ rawMessage: String) {
        let marker = "progress.update:"
        let update = rawMessage.hasPrefix(marker)
        let message = String((update ? String(rawMessage.dropFirst(marker.count)) : rawMessage).trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        guard !message.isEmpty else { return }
        statusLabel.stringValue = message
        guard !update else { return }
        if activityMessages.last != message {
            stepStartedAt = elapsedNow(); refreshElapsed(); activityMessages.append(message)
            if activityMessages.count > 40 { activityMessages.removeFirst(activityMessages.count - 40) }
        }
        activity.setText(activityMessages.joined(separator: "\n"))
    }
    #if DEBUG
    var fixtureHasElapsedTimer: Bool { elapsedTimer?.isValid == true }
    func fixtureRefreshElapsed() { refreshElapsed() }
    var fixtureCitationCopyText: String? { answer?.textWithCitations }
    var fixtureConversationCount: Int { completedTurns.count }
    var fixtureCurrentChatID: UUID { chatID }
    func fixtureWaitForHistory() async {
        for _ in 0..<8 {
            let owners = Array(historyOwners.values)
            if owners.isEmpty { return }
            for owner in owners { await owner.value }
        }
    }
    #endif
}
#endif
