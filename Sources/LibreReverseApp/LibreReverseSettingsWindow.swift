#if os(macOS)
import AppKit
import EventKit
import LibreReverseCore

struct LibreReverseArchiveSettingsSnapshot {
    let providerKind: ArchiveBackendKind
    let destinationID: Int64
    let policy: LibreReverseArchivePolicy
    let status: LibreReverseArchiveStatus
    let residencyForecast: LibreReverseResidencyForecast
    let shardStatus: LibreReverseShardArchiveStatus
    let hasActiveRecording: Bool
    var failureSummaries: [LibreReverseArchiveFailureSummary] = []
}

struct LibreReverseArchiveConnectionSettings {
    let activeKind: ArchiveBackendKind?
    let s3Configuration: S3ArchiveConfiguration?
    var isOperational: Bool? = nil
}

/// Rejects stale polls after provider browsing or a connection replacement,
/// including replacement by another account of the same provider.
struct LibreReverseArchiveSettingsSelection {
    private(set) var provider: ArchiveBackendKind = .googleDrive
    private(set) var generation = 0
    mutating func select(_ provider: ArchiveBackendKind) {
        self.provider = provider
        invalidate()
    }
    mutating func invalidate() { generation += 1 }
    func accepts(generation: Int, provider: ArchiveBackendKind) -> Bool {
        self.generation == generation && self.provider == provider
    }
}

struct LibreReverseS3SettingsDraft {
    var endpoint: String
    var bucket: String
    var region: String
    var accessKey: String
    var secretKey: String
    var sessionToken: String
    var usesSessionToken: Bool

    func configuration(saved: S3ArchiveConfiguration?) throws -> S3ArchiveConfiguration {
        let endpoint = try S3ArchiveConfiguration.endpointURL(endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
        let accessKey = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let canReuse = saved?.endpoint == endpoint && saved?.accessKey == accessKey
        let secret = secretKey.isEmpty && canReuse ? saved?.secretKey ?? "" : secretKey
        let token = usesSessionToken
            ? (sessionToken.isEmpty && canReuse ? saved?.sessionToken : sessionToken)
            : nil
        return try S3ArchiveConfiguration(endpoint: endpoint,
            bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines),
            region: region.trimmingCharacters(in: .whitespacesAndNewlines),
            accessKey: accessKey, secretKey: secret, sessionToken: token)
    }
}

private final class LibreReverseSettingsSidebarCell: NSButtonCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: rect.insetBy(dx: 12, dy: 0))
    }
}

@MainActor
private func settingsFieldContainer(_ field: NSTextField) -> NSView {
    field.drawsBackground = false
    field.textColor = .labelColor
    field.font = .systemFont(ofSize: 13)
    field.isBezeled = false
    field.isBordered = false
    field.focusRingType = .default
    field.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
    container.layer?.cornerRadius = 6
    container.layer?.borderWidth = 0.5
    container.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
    container.addSubview(field)
    NSLayoutConstraint.activate([
        field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9),
        field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -9),
        field.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
        field.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7),
        container.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
    ])
    return container
}

private final class LibreReverseStorageDocumentView: NSView {
    override var isFlipped: Bool { true }
}

struct LibreReverseStorageUsageSnapshot: Equatable {
    let localBytes: Int64
    let recordedDays: Int

    static func measure(configuration: LibreReverseLibraryConfiguration) -> Self {
        let database = LibraryDatabaseConfiguration(databaseURL: configuration.databaseURL,
            keyFileURL: configuration.keyFileURL, mediaRoot: configuration.mediaRoot)
        var intervals = (try? LibraryDatabase.recordingInterval(configuration: database)).map { [$0] } ?? []
        let shards = (try? LibreReverseShardStore.records(configuration: configuration)) ?? []
        intervals += shards.filter { $0.frameCount > 0 }.map {
            DateInterval(start: $0.interval.start, end: $0.interval.end)
        }
        return measure(at: configuration.databaseURL.deletingLastPathComponent(),
                       recordingInterval: coveringHistoryInterval(intervals))
    }

    static func coveringHistoryInterval(_ intervals: [DateInterval]) -> DateInterval? {
        guard let start = intervals.map(\.start).min(), let end = intervals.map(\.end).max() else { return nil }
        return DateInterval(start: start, end: end)
    }

    static func measure(at root: URL, recordingInterval: DateInterval? = nil) -> Self {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            return .init(localBytes: 0, recordedDays: 0)
        }
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        let days = recordingInterval.map {
            max(1, (Calendar.current.dateComponents([.day], from: $0.start, to: $0.end).day ?? 0) + 1)
        } ?? 0
        return .init(localBytes: bytes, recordedDays: days)
    }
}

struct LibreReverseMeetingInputDevice: Equatable {
    let id: String
    let name: String
    let isDefault: Bool
}

struct LibreReverseMeetingAudioSettingsSnapshot {
    let preferences: LibreReverseMeetingAudioPreferences
    let microphoneAuthorized: Bool
    let nativeMicrophoneCaptureSupported: Bool
    let inputDevices: [LibreReverseMeetingInputDevice]
    let isRecording: Bool
    let transcriptionLanguageCode: String?
    let transcriptionBackendAvailable: Bool
}

private struct LibreReverseTransferETAEstimator {
    private var samples: [(date: Date, bytes: Int64)] = []
    private var lastProgressAt: Date?

    mutating func estimate(
        transferred: Int64,
        total: Int64,
        now: Date = Date()
    ) -> TimeInterval? {
        guard total > transferred, transferred >= 0 else {
            samples.removeAll()
            lastProgressAt = nil
            return nil
        }
        if let last = samples.last, transferred < last.bytes {
            samples.removeAll()
            lastProgressAt = nil
        }
        if samples.last?.bytes != transferred {
            lastProgressAt = now
        }
        samples.append((now, transferred))
        samples.removeAll { now.timeIntervalSince($0.date) > 120 }
        guard let first = samples.first,
              let lastProgressAt,
              now.timeIntervalSince(lastProgressAt) < 45 else { return nil }
        let elapsed = now.timeIntervalSince(first.date)
        let advanced = transferred - first.bytes
        guard elapsed >= 10, advanced >= 1_048_576 else { return nil }
        let bytesPerSecond = Double(advanced) / elapsed
        guard bytesPerSecond > 0 else { return nil }
        let result = Double(total - transferred) / bytesPerSecond
        return result.isFinite && result > 0 ? result : nil
    }
}

@MainActor
final class LibreReverseSettingsWindowController: NSWindowController {
    enum Section: Int {
        case general
        case screen
        case audio
        case storage
        case meetings
        case ai
        case shortcuts
    }

    struct SectionDescriptor: Equatable {
        let section: Section
        let label: String
        let symbolName: String
    }

    static let sectionDescriptors: [SectionDescriptor] = [
        .init(section: .general, label: "General", symbolName: "gearshape"),
        .init(section: .screen, label: "Screen", symbolName: "display"),
        .init(section: .meetings, label: "Meetings", symbolName: "calendar"),
        .init(section: .ai, label: "AI", symbolName: "cpu"),
        .init(section: .storage, label: "Storage", symbolName: "externaldrive"),
        .init(section: .shortcuts, label: "Shortcuts", symbolName: "keyboard"),
    ]

    private let sectionBar = NSStackView()
    private var sectionButtons: [Section: NSButton] = [:]
    private let generalController: LibreReverseGeneralSettingsViewController
    private let screenController: LibreReverseScreenSettingsViewController
    private let audioController: LibreReverseAudioSettingsViewController
    private let storageController: LibreReverseStorageSettingsViewController

    func beginShutdown() -> [Task<Void, Never>] {
        storageController.beginShutdown()
    }
    private let meetingsController: LibreReverseMeetingSettingsViewController
    private let aiController: LibreReverseAISettingsViewController
    private let shortcutsController: LibreReverseShortcutsSettingsViewController
    private let contentContainer = NSView()
    private var contentConstraints: [Section: [NSLayoutConstraint]] = [:]

    init(
        googleDriveManager: GoogleDriveConnectionManager,
        connectionValidated: @escaping (GoogleDriveConnectionIdentity) async throws -> Void,
        connectionAuthorized: @escaping (GoogleDriveConnectionManager.PendingAuthorization) async throws -> Void,
        connectionDisconnected: @escaping (ArchiveBackendKind) async throws -> Void,
        archiveConnectionSettings: @escaping () async throws -> LibreReverseArchiveConnectionSettings,
        connectS3: @escaping (S3ArchiveConfiguration) async throws -> Void,
        archiveSnapshot: @escaping () async throws -> LibreReverseArchiveSettingsSnapshot?,
        updateArchivePolicy: @escaping (LibreReverseArchivePolicy) throws -> Void,
        retryArchive: @escaping () -> Void,
        storageUsage: @escaping () async -> LibreReverseStorageUsageSnapshot,
        deleteAllData: @escaping () async throws -> Void,
        generalSettings: @escaping () -> LibreReverseGeneralSettingsSnapshot,
        updateLaunchAtLogin: @escaping (Bool) throws -> Void,
        updateRemindWhenPaused: @escaping (Bool) -> Void,
        updateShowInDock: @escaping (Bool) -> Void,
        screenSettings: @escaping () -> LibreReverseScreenSettingsSnapshot,
        updateOmittedApplications: @escaping (Set<String>) -> Void,
        updateExcludePrivateWindows: @escaping (Bool) -> Void,
        updateOCRLanguageMode: @escaping (LibreReverseOCRLanguageMode) -> Void,
        updateShowRunningProcesses: @escaping (Bool) -> Void,
        shortcutSettings: @escaping () -> LibreReverseShortcutSettings,
        updateShortcutSettings: @escaping (LibreReverseShortcutSettings) throws -> Void,
        askAPIKey: @escaping () throws -> String?,
        updateAskAPIKey: @escaping (String?) throws -> Void,
        meetingPolicy: @escaping () -> LibreReverseMeetingStartPolicy,
        updateMeetingPolicy: @escaping (LibreReverseMeetingStartPolicy) -> Void,
        meetingAudioSettings: @escaping () -> LibreReverseMeetingAudioSettingsSnapshot,
        updateMeetingAudioSettings: @escaping (LibreReverseMeetingAudioPreferences) -> Void,
        updateMeetingTranscriptionLanguage: @escaping (String?) -> Void,
        openMicrophonePrivacy: @escaping () -> Void,
        meetingCalendarSettings: @escaping () -> LibreReverseMeetingCalendarSettingsSnapshot,
        updateMeetingCalendarEnabled: @escaping (Bool) -> Void,
        updateMeetingCalendar: @escaping (String, Bool) -> Void,
        selectAllMeetingCalendars: @escaping () -> Void,
        toggleMeeting: @escaping () -> Void = {},
        showSetup: @escaping () -> Void = {}
    ) {
        generalController = LibreReverseGeneralSettingsViewController(
            snapshot: generalSettings,
            updateLaunchAtLogin: updateLaunchAtLogin,
            updateRemindWhenPaused: updateRemindWhenPaused,
            updateShowInDock: updateShowInDock,
            showSetup: showSetup
        )
        screenController = LibreReverseScreenSettingsViewController(
            snapshot: screenSettings,
            updateOmittedApplications: updateOmittedApplications,
            updateExcludePrivateWindows: updateExcludePrivateWindows,
            updateOCRLanguageMode: updateOCRLanguageMode,
            updateShowRunningProcesses: updateShowRunningProcesses
        )
        audioController = LibreReverseAudioSettingsViewController(
            snapshot: meetingAudioSettings,
            updatePreferences: updateMeetingAudioSettings,
            updateTranscriptionLanguage: updateMeetingTranscriptionLanguage,
            openMicrophonePrivacy: openMicrophonePrivacy,
            toggleMeeting: toggleMeeting
        )
        storageController = LibreReverseStorageSettingsViewController(
            manager: googleDriveManager,
            connectionValidated: connectionValidated,
            connectionAuthorized: connectionAuthorized,
            connectionDisconnected: connectionDisconnected,
            archiveConnectionSettings: archiveConnectionSettings,
            connectS3: connectS3,
            archiveSnapshot: archiveSnapshot,
            updateArchivePolicy: updateArchivePolicy,
            retryArchive: retryArchive,
            storageUsage: storageUsage,
            deleteAllData: deleteAllData
        )
        meetingsController = LibreReverseMeetingSettingsViewController(
            policy: meetingPolicy,
            updatePolicy: updateMeetingPolicy,
            audioSettings: meetingAudioSettings,
            updateAudioSettings: updateMeetingAudioSettings,
            openMicrophonePrivacy: openMicrophonePrivacy,
            calendarSettings: meetingCalendarSettings,
            updateCalendarEnabled: updateMeetingCalendarEnabled,
            updateCalendar: updateMeetingCalendar,
            selectAllCalendars: selectAllMeetingCalendars,
            updateTranscriptionLanguage: updateMeetingTranscriptionLanguage,
            toggleMeeting: toggleMeeting
        )
        shortcutsController = LibreReverseShortcutsSettingsViewController(
            settings: shortcutSettings,
            updateSettings: updateShortcutSettings
        )
        aiController = LibreReverseAISettingsViewController(
            apiKey: askAPIKey,
            updateAPIKey: updateAskAPIKey
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentMinSize = NSSize(width: 800, height: 0)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        window.contentView?.widthAnchor.constraint(greaterThanOrEqualToConstant: 800).isActive = true
        show(section: .general)
    }

    required init?(coder: NSCoder) { nil }

    func open(section: Section = .general) {
        show(section: section)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshMeetings() {
        meetingsController.refresh()
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        sectionBar.orientation = .vertical
        sectionBar.alignment = .leading
        sectionBar.distribution = .fill
        sectionBar.spacing = 6
        sectionBar.setAccessibilityRole(.radioGroup)
        sectionBar.setAccessibilityLabel("Settings section")
        sectionBar.setAccessibilityIdentifier("settings.section")
        sectionBar.translatesAutoresizingMaskIntoConstraints = false
        for descriptor in Self.sectionDescriptors {
            let button = makeSectionButton(descriptor)
            sectionButtons[descriptor.section] = button
            sectionBar.addArrangedSubview(button)
        }
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sectionBar)
        content.addSubview(contentContainer)
        let sidebarDivider = NSBox()
        sidebarDivider.boxType = .separator
        sidebarDivider.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebarDivider)
        NSLayoutConstraint.activate([
            sidebarDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 199),
            sidebarDivider.topAnchor.constraint(equalTo: content.topAnchor),
            sidebarDivider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarDivider.widthAnchor.constraint(equalToConstant: 1),
        ])

        let controllers: [(Section, NSViewController)] = [
            (.general, generalController), (.screen, screenController),
            (.audio, audioController),
            (.storage, storageController), (.meetings, meetingsController),
            (.ai, aiController), (.shortcuts, shortcutsController),
        ]
        for (section, controller) in controllers {
            let view = controller.view
            view.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(view)
            contentConstraints[section] = [
                view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ]
        }

        NSLayoutConstraint.activate([
            sectionBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            sectionBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            sectionBar.widthAnchor.constraint(equalToConstant: 176),
            contentContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            contentContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 200),
            contentContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func makeSectionButton(_ descriptor: SectionDescriptor) -> NSButton {
        let button = NSButton(title: descriptor.label, target: self, action: #selector(sectionChanged(_:)))
        button.cell = LibreReverseSettingsSidebarCell(textCell: descriptor.label)
        button.target = self
        button.action = #selector(sectionChanged(_:))
        button.tag = descriptor.section.rawValue
        button.setButtonType(.toggle)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.imageScaling = .scaleProportionallyDown
        button.image = NSImage(
            systemSymbolName: descriptor.symbolName,
            accessibilityDescription: descriptor.label
        )?.withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        button.toolTip = descriptor.label
        button.setAccessibilityRole(.radioButton)
        button.setAccessibilityLabel(descriptor.label)
        button.setAccessibilityIdentifier(
            "settings.section.\(descriptor.label.lowercased())"
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 176),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        updateSectionButton(button, selected: false)
        return button
    }

    private func updateSectionButton(_ button: NSButton, selected: Bool) {
        button.state = selected ? .on : .off
        button.layer?.backgroundColor = selected
            ? NSColor(calibratedWhite: 0.17, alpha: 1).cgColor
            : NSColor.clear.cgColor
        button.contentTintColor = selected ? .labelColor : .secondaryLabelColor
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
        )
        button.setAccessibilityValue(selected ? "Selected" : "Not selected")
    }

    func refreshScreenApplications() { screenController.refresh() }

    private func show(section requestedSection: Section) {
        let section: Section = requestedSection == .audio ? .meetings : requestedSection
        for (candidate, button) in sectionButtons {
            updateSectionButton(button, selected: candidate == section)
        }
        NSLayoutConstraint.deactivate(contentConstraints.values.flatMap { $0 })
        NSLayoutConstraint.activate(contentConstraints[section] ?? [])
        generalController.view.isHidden = section != .general
        screenController.view.isHidden = section != .screen
        audioController.view.isHidden = section != .audio
        storageController.view.isHidden = section != .storage
        meetingsController.view.isHidden = section != .meetings
        aiController.view.isHidden = section != .ai
        shortcutsController.view.isHidden = section != .shortcuts
        meetingsController.setActive(section == .meetings)
        audioController.setActive(section == .audio)
        if section == .general { generalController.refresh() }
        if section == .screen { screenController.refresh() }
        if section == .storage { storageController.refresh() }
        if section == .shortcuts { shortcutsController.refresh() }
        resizeWindow(for: section)
    }

    private func resizeWindow(for section: Section) {
        guard let window else { return }
        let height: CGFloat
        switch section {
        case .general: height = 660
        case .storage, .audio: height = 680
        case .screen, .meetings, .shortcuts, .ai: height = 820
        }
        let previousTop = window.frame.maxY
        window.setContentSize(NSSize(width: 800, height: height))
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: previousTop - window.frame.height))
    }

    @objc private func sectionChanged(_ sender: NSButton) {
        show(section: Section(rawValue: sender.tag) ?? .general)
    }
}

@MainActor
private final class LibreReverseMeetingSettingsViewController: NSViewController {
    private let policy: () -> LibreReverseMeetingStartPolicy
    private let updatePolicy: (LibreReverseMeetingStartPolicy) -> Void
    private let audioSettings: () -> LibreReverseMeetingAudioSettingsSnapshot
    private let updateAudioSettings: (LibreReverseMeetingAudioPreferences) -> Void
    private let openMicrophonePrivacy: () -> Void
    private let calendarSettings: () -> LibreReverseMeetingCalendarSettingsSnapshot
    private let updateCalendarEnabled: (Bool) -> Void
    private let updateCalendar: (String, Bool) -> Void
    private let selectAllCalendars: () -> Void
    private let policyPopup = NSPopUpButton()
    private let systemAudioButton = NSButton(
        checkboxWithTitle: "Record other people (system audio)",
        target: nil,
        action: nil
    )
    private let microphoneButton = NSButton(
        checkboxWithTitle: "Record my microphone",
        target: nil,
        action: nil
    )
    private let inputPopup = NSPopUpButton()
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    private let recordingLabel = NSTextField(wrappingLabelWithString: "")
    private let privacyButton = NSButton(
        title: "Open Microphone Privacy",
        target: nil,
        action: nil
    )
    private let calendarButton = NSButton(
        checkboxWithTitle: "Use calendar context for detected meetings",
        target: nil,
        action: nil
    )
    private let calendarStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let calendarListStack = NSStackView()
    private let calendarScrollView = NSScrollView()
    private let selectAllCalendarsButton = NSButton(
        title: "Select All Calendars",
        target: nil,
        action: nil
    )
    private let languagePopup = NSPopUpButton()
    private let meetingButton = NSButton(title: "Start Meeting Recording", target: nil, action: nil)
    private let updateTranscriptionLanguage: (String?) -> Void
    private let toggleMeeting: () -> Void
    private var refreshTimer: Timer?

    init(
        policy: @escaping () -> LibreReverseMeetingStartPolicy,
        updatePolicy: @escaping (LibreReverseMeetingStartPolicy) -> Void,
        audioSettings: @escaping () -> LibreReverseMeetingAudioSettingsSnapshot,
        updateAudioSettings: @escaping (LibreReverseMeetingAudioPreferences) -> Void,
        openMicrophonePrivacy: @escaping () -> Void,
        calendarSettings: @escaping () -> LibreReverseMeetingCalendarSettingsSnapshot,
        updateCalendarEnabled: @escaping (Bool) -> Void,
        updateCalendar: @escaping (String, Bool) -> Void,
        selectAllCalendars: @escaping () -> Void,
        updateTranscriptionLanguage: @escaping (String?) -> Void = { _ in },
        toggleMeeting: @escaping () -> Void = {}
    ) {
        self.updateTranscriptionLanguage = updateTranscriptionLanguage
        self.toggleMeeting = toggleMeeting
        self.policy = policy
        self.updatePolicy = updatePolicy
        self.audioSettings = audioSettings
        self.updateAudioSettings = updateAudioSettings
        self.openMicrophonePrivacy = openMicrophonePrivacy
        self.calendarSettings = calendarSettings
        self.updateCalendarEnabled = updateCalendarEnabled
        self.updateCalendar = updateCalendar
        self.selectAllCalendars = selectAllCalendars
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        refreshTimer?.invalidate()
    }

    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: "Meetings")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString:
            "Detect meeting windows on this Mac, or start a recording manually."
        )
        explanation.textColor = .secondaryLabelColor
        policyPopup.addItems(withTitles: [
            "Ask before recording",
            "Record automatically",
            "Detection off",
        ])
        policyPopup.target = self
        policyPopup.action = #selector(policyChanged)
        policyPopup.setAccessibilityIdentifier("meetings.startPolicy")
        let label = NSTextField(labelWithString: "Meeting detection")
        let row = NSStackView(views: [label, policyPopup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let audioTitle = NSTextField(labelWithString: "Audio sources")
        audioTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let audioExplanation = NSTextField(wrappingLabelWithString:
            "Changes during a meeting safely start a new file and continue recording."
        )
        audioExplanation.textColor = .secondaryLabelColor
        systemAudioButton.target = self
        systemAudioButton.action = #selector(audioSelectionChanged)
        systemAudioButton.setAccessibilityIdentifier("meetings.audio.system")
        microphoneButton.target = self
        microphoneButton.action = #selector(audioSelectionChanged)
        microphoneButton.setAccessibilityIdentifier("meetings.audio.microphone")
        inputPopup.target = self
        inputPopup.action = #selector(audioSelectionChanged)
        inputPopup.setAccessibilityIdentifier("meetings.audio.input")
        inputPopup.toolTip = "Bluetooth microphones switch to lower-quality duplex audio. Choose the Mac microphone to avoid this. Speaker capture can suppress notifications and DRM-protected video; enable notifications while mirroring in System Settings if needed."
        let inputLabel = NSTextField(labelWithString: "Microphone input:")
        let inputRow = NSStackView(views: [inputLabel, inputPopup])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 10
        permissionLabel.font = .systemFont(ofSize: 12)
        permissionLabel.textColor = .secondaryLabelColor
        recordingLabel.font = .systemFont(ofSize: 12, weight: .medium)
        privacyButton.target = self
        privacyButton.action = #selector(openPrivacy)
        privacyButton.bezelStyle = .rounded
        privacyButton.controlSize = .small
        privacyButton.setAccessibilityIdentifier("meetings.audio.openPrivacy")
        let calendarTitle = NSTextField(labelWithString: "Calendar context")
        calendarTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let calendarExplanation = NSTextField(wrappingLabelWithString:
            "Match event titles and participants."
        )
        calendarExplanation.textColor = .secondaryLabelColor
        calendarButton.target = self
        calendarButton.action = #selector(calendarSelectionChanged)
        calendarButton.setAccessibilityIdentifier("meetings.calendar.enabled")
        calendarStatusLabel.font = .systemFont(ofSize: 12)
        calendarStatusLabel.textColor = .secondaryLabelColor
        calendarListStack.orientation = .vertical
        calendarListStack.alignment = .leading
        calendarListStack.spacing = 6
        calendarListStack.translatesAutoresizingMaskIntoConstraints = false
        calendarScrollView.documentView = calendarListStack
        calendarScrollView.hasVerticalScroller = true
        calendarScrollView.drawsBackground = false
        calendarScrollView.borderType = .bezelBorder
        calendarScrollView.translatesAutoresizingMaskIntoConstraints = false
        let calendarClipView = calendarScrollView.contentView
        NSLayoutConstraint.activate([
            calendarListStack.topAnchor.constraint(
                equalTo: calendarClipView.topAnchor,
                constant: 6
            ),
            calendarListStack.leadingAnchor.constraint(
                equalTo: calendarClipView.leadingAnchor,
                constant: 8
            ),
            calendarListStack.trailingAnchor.constraint(
                lessThanOrEqualTo: calendarClipView.trailingAnchor,
                constant: -8
            ),
        ])
        NSLayoutConstraint.activate([
            calendarScrollView.heightAnchor.constraint(equalToConstant: 100),
        ])
        selectAllCalendarsButton.target = self
        selectAllCalendarsButton.action = #selector(selectAllCalendarsClicked)
        selectAllCalendarsButton.bezelStyle = .rounded
        selectAllCalendarsButton.controlSize = .small
        selectAllCalendarsButton.setAccessibilityIdentifier(
            "meetings.calendar.selectAll"
        )
        let note = NSTextField(wrappingLabelWithString:
            "Recording and privacy"
        )
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 12)
        meetingButton.target = self
        meetingButton.action = #selector(toggleManualRecording)
        meetingButton.setAccessibilityIdentifier("meetings.recording.toggle")
        languagePopup.addItems(withTitles: LibreReverseTranscriptionLanguage.supported.map(\.name))
        languagePopup.target = self
        languagePopup.action = #selector(transcriptionLanguageChanged)
        languagePopup.setAccessibilityIdentifier("audio.transcriptionLanguage")
        languagePopup.toolTip = "A specific language is faster and more accurate. Automatic detection supports multilingual meetings. Changes apply to queued and future transcription."
        let languageRow = NSStackView(views: [NSTextField(labelWithString: "Transcription language"), languagePopup])
        languageRow.spacing = 10
        func section(_ views: [NSView]) -> NSStackView {
            let group = NSStackView(views: views)
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 8
            return group
        }
        let heading = section([title, explanation])
        let detection = section([row, meetingButton, recordingLabel])
        let audio = section([audioTitle, systemAudioButton, microphoneButton,
            inputPopup, permissionLabel, privacyButton])
        let transcription = section([languageRow])
        let calendar = section([calendarTitle, calendarExplanation, calendarButton,
            calendarStatusLabel, calendarScrollView, selectAllCalendarsButton])
        let help = NSStackView(views: [note, LibreReverseSettingsInfoButton("Manual recording is always available from the menu bar. Detection covers supported meeting windows, not ordinary browser media. Calendar events never start a recording. Recordings stay local unless archiving is enabled. Audio changes safely create a new file and continue the meeting.", identifier: "settings.meetings.help")])
        let stack = NSStackView(views: [heading, detection, audio, transcription, calendar, help])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = LibreReverseStorageDocumentView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        view.addSubview(scroll)
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
        calendarScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 42),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -42),
        ])
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        let selectedIndex = switch policy() {
        case .ask: 0
        case .automatic: 1
        case .disabled: 2
        }
        policyPopup.selectItem(at: selectedIndex)
        let snapshot = audioSettings()
        meetingButton.title = snapshot.isRecording ? "Stop Meeting Recording" : "Start Meeting Recording"
        languagePopup.selectItem(at: LibreReverseTranscriptionLanguage.supported.firstIndex { $0.code == snapshot.transcriptionLanguageCode } ?? 0)
        let preferences = snapshot.preferences
        systemAudioButton.state = preferences.capturesSystemAudio ? .on : .off
        microphoneButton.state = preferences.capturesMicrophone ? .on : .off
        microphoneButton.isEnabled = snapshot.nativeMicrophoneCaptureSupported

        inputPopup.removeAllItems()
        let defaultName = snapshot.inputDevices.first(where: \.isDefault)?.name
            ?? "Current system input"
        inputPopup.addItem(withTitle: "System Default — \(defaultName)")
        inputPopup.lastItem?.representedObject = ""
        if !snapshot.inputDevices.isEmpty {
            inputPopup.menu?.addItem(.separator())
        }
        for device in snapshot.inputDevices {
            inputPopup.addItem(withTitle: device.name + (device.isDefault ? " (current)" : ""))
            inputPopup.lastItem?.representedObject = device.id
        }
        let selectedDeviceIsAvailable = preferences.microphoneDeviceID.map { selectedID in
            snapshot.inputDevices.contains(where: { $0.id == selectedID })
        } ?? true
        if let selectedID = preferences.microphoneDeviceID {
            if let selected = inputPopup.itemArray.first(where: {
                ($0.representedObject as? String) == selectedID
            }) {
                inputPopup.select(selected)
            } else {
                inputPopup.menu?.addItem(.separator())
                inputPopup.addItem(withTitle: "Unavailable selected microphone")
                inputPopup.lastItem?.representedObject = selectedID
                inputPopup.select(inputPopup.lastItem)
            }
        } else {
            inputPopup.selectItem(at: 0)
        }
        inputPopup.isEnabled = preferences.capturesMicrophone
            && snapshot.nativeMicrophoneCaptureSupported

        if !snapshot.nativeMicrophoneCaptureSupported {
            permissionLabel.stringValue =
                "Native microphone capture requires macOS 15 or newer."
            permissionLabel.textColor = .systemOrange
            privacyButton.isHidden = true
        } else if preferences.capturesMicrophone && !snapshot.microphoneAuthorized {
            permissionLabel.stringValue =
                "Microphone access is off. Until it is restored, meetings record without your voice."
            permissionLabel.textColor = .systemOrange
            privacyButton.isHidden = false
        } else if preferences.capturesMicrophone && !selectedDeviceIsAvailable {
            permissionLabel.stringValue =
                "The selected microphone is unavailable. Choose another input or System Default."
            permissionLabel.textColor = .systemRed
            privacyButton.isHidden = true
        } else if !preferences.capturesSystemAudio && !preferences.capturesMicrophone {
            permissionLabel.stringValue =
                "Audio is disabled. Meeting recordings will contain video only."
            permissionLabel.textColor = .systemRed
            privacyButton.isHidden = true
        } else {
            permissionLabel.stringValue = preferences.capturesMicrophone
                ? "Microphone access is ready."
                : "Microphone capture is disabled by your selection."
            permissionLabel.textColor = .secondaryLabelColor
            privacyButton.isHidden = true
        }
        recordingLabel.stringValue = snapshot.isRecording
            ? "Recording now"
            : ""
        recordingLabel.textColor = snapshot.isRecording ? .systemOrange : .secondaryLabelColor

        let calendar = calendarSettings()
        calendarButton.state = calendar.enabled ? .on : .off
        rebuildCalendarList(calendar)
        switch calendar.authorization {
        case .denied, .restricted:
            calendarStatusLabel.stringValue =
                "Calendar read access is unavailable. Enable Full Calendar Access in System Settings to use context."
            calendarStatusLabel.textColor = .systemOrange
        default:
            if calendar.hasReadAccess {
                let availableIDs = Set(calendar.calendars.map(\.id))
                let selectedCount = calendar.selection.resolvedIDs(
                    availableCalendarIDs: availableIDs
                ).count
                let unavailableSelectedCount = calendar.selection.explicitCalendarIDs.map {
                    Set($0).subtracting(availableIDs).count
                } ?? 0
                if calendar.enabled {
                    calendarStatusLabel.stringValue = unavailableSelectedCount > 0
                        ? "Reading \(selectedCount) of \(calendar.calendars.count) calendars locally; \(unavailableSelectedCount) saved selection is temporarily unavailable."
                        : "Reading \(selectedCount) of \(calendar.calendars.count) calendars locally; all-day and canceled events are ignored."
                } else {
                    calendarStatusLabel.stringValue =
                        "Calendar access is available but context is disabled."
                }
            } else {
                calendarStatusLabel.stringValue =
                    "Enabling this asks macOS for Full Calendar Access."
            }
            calendarStatusLabel.textColor = .secondaryLabelColor
        }
    }

    func setActive(_ active: Bool) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard active else { return }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    @objc private func toggleManualRecording() { toggleMeeting(); refresh() }
    @objc private func transcriptionLanguageChanged() {
        updateTranscriptionLanguage(LibreReverseTranscriptionLanguage.supported[languagePopup.indexOfSelectedItem].code)
    }

    @objc private func policyChanged() {
        let value: LibreReverseMeetingStartPolicy = switch policyPopup.indexOfSelectedItem {
        case 1: .automatic
        case 2: .disabled
        default: .ask
        }
        updatePolicy(value)
    }

    @objc private func audioSelectionChanged() {
        let selectedID = (inputPopup.selectedItem?.representedObject as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        updateAudioSettings(.init(
            capturesSystemAudio: systemAudioButton.state == .on,
            capturesMicrophone: microphoneButton.state == .on,
            microphoneDeviceID: selectedID
        ))
        refresh()
    }

    @objc private func openPrivacy() {
        openMicrophonePrivacy()
    }

    @objc private func calendarSelectionChanged() {
        updateCalendarEnabled(calendarButton.state == .on)
        refresh()
    }

    private func rebuildCalendarList(
        _ snapshot: LibreReverseMeetingCalendarSettingsSnapshot
    ) {
        calendarListStack.arrangedSubviews.forEach { view in
            calendarListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let availableIDs = Set(snapshot.calendars.map(\.id))
        let selectedIDs = snapshot.selection.resolvedIDs(
            availableCalendarIDs: availableIDs
        )
        for calendar in snapshot.calendars {
            let button = NSButton(
                checkboxWithTitle: calendar.title,
                target: self,
                action: #selector(calendarItemChanged(_:))
            )
            button.identifier = NSUserInterfaceItemIdentifier(calendar.id)
            button.state = selectedIDs.contains(calendar.id) ? .on : .off
            button.isEnabled = snapshot.enabled && snapshot.hasReadAccess
            button.setAccessibilityIdentifier("meetings.calendar.item.\(calendar.id)")
            calendarListStack.addArrangedSubview(button)
        }
        calendarScrollView.isHidden = snapshot.calendars.isEmpty
        selectAllCalendarsButton.isHidden = snapshot.calendars.isEmpty
        selectAllCalendarsButton.isEnabled = snapshot.enabled
            && snapshot.hasReadAccess
            && selectedIDs != availableIDs
    }

    @objc private func calendarItemChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        updateCalendar(id, sender.state == .on)
        refresh()
    }

    @objc private func selectAllCalendarsClicked() {
        selectAllCalendars()
        refresh()
    }
}

@MainActor
final class LibreReverseAISettingsViewController: NSViewController {
    private let profilePopup = NSPopUpButton()
    private let providerPopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let modelField = NSTextField()
    private let routingField = NSTextField()
    private let fallbacks = NSButton(checkboxWithTitle: "Allow other providers if preferred providers are unavailable", target: nil, action: nil)
    private var profiles = LibreReverseAIProfiles.load()
    private var selectedID = LibreReverseAIProfiles.selected().id
    private let apiKey: () throws -> String?
    private let updateAPIKey: (String?) throws -> Void
    private let keyControls = NSStackView()
    private let keyField = NSSecureTextField(frame: .zero)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save API key", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove key", target: nil, action: nil)

    init(
        apiKey: @escaping () throws -> String?,
        updateAPIKey: @escaping (String?) throws -> Void
    ) {
        self.apiKey = apiKey
        self.updateAPIKey = updateAPIKey
        #if DEBUG
        if let root = LibreReverseDevelopmentEnvironment.values["LIBREREVERSE_SETTINGS_FIXTURE_ROOT"],
           root.hasPrefix("/private/tmp/"),
           let selected = LibreReverseDevelopmentEnvironment.values["LIBREREVERSE_AI_SETTINGS_PROFILE_FIXTURE"] {
            profiles = [.local, .openAI, .deepSeek]
            selectedID = profiles.first { $0.id == selected }?.id ?? "local"
        }
        #endif
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView(frame: .zero)
        let title = NSTextField(labelWithString: "AI")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString:
            "One profile for search, answers and meeting summaries."
        )
        detail.font = .systemFont(ofSize: 14)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3

        let privacy = NSTextField(wrappingLabelWithString:
            "Your key is stored in LibreReverse's encrypted database. Only your question and the relevant, redacted text excerpts are sent when you use Ask. Screenshots, video, and audio remain local. OpenRouter routing excludes providers that collect prompt data. Provider retention policies still apply."
        )
        privacy.font = .systemFont(ofSize: 13)
        privacy.textColor = .secondaryLabelColor
        privacy.maximumNumberOfLines = 5

        keyField.placeholderString = "API key for this profile"
        keyField.setAccessibilityLabel("API key for this profile")
        keyField.setAccessibilityIdentifier("settings.ai.api-key")
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.heightAnchor.constraint(equalToConstant: 18).isActive = true
        saveButton.target = self
        saveButton.action = #selector(save)
        removeButton.target = self
        removeButton.action = #selector(remove)
        let controls = keyControls
        [settingsFieldContainer(keyField), saveButton, removeButton].forEach { controls.addArrangedSubview($0) }
        controls.orientation = .horizontal
        controls.spacing = 10

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("settings.ai.status")
        let examples = NSTextField(wrappingLabelWithString:
            "Try: “What did I promise in yesterday's customer call?”, “When did I first discuss the launch?”, or “Draft a follow-up from this morning's meeting.”"
        )
        examples.font = .systemFont(ofSize: 13)
        examples.maximumNumberOfLines = 4

        providerPopup.setAccessibilityIdentifier("settings.ai.provider")
        profilePopup.setAccessibilityIdentifier("settings.ai.profile")
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.addItems(withTitles: LibreReverseAIProfile.Provider.allCases.map(\.rawValue))
        profilePopup.target = self
        profilePopup.action = #selector(selectProfile)
        nameField.placeholderString = "Profile name"
        modelField.placeholderString = "Model ID"
        routingField.placeholderString = "Preferred OpenRouter providers, separated by commas (optional)"
        let add = NSButton(title: "Add profile", target: self, action: #selector(addProfile))
        let saveProfileButton = NSButton(title: "Save profile", target: self, action: #selector(saveProfile))
        let delete = NSButton(title: "Remove profile", target: self, action: #selector(removeProfile))
        let profileRow = NSStackView(views: [profilePopup, add, delete])
        profileRow.spacing = 8
        func fieldRow(_ title: String, _ field: NSTextField) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12)
            label.widthAnchor.constraint(equalToConstant: 70).isActive = true
            let row = NSStackView(views: [label, settingsFieldContainer(field)])
            row.spacing = 10
            row.alignment = .centerY
            return row
        }
        let nameRow = fieldRow("Name", nameField)
        let modelRow = fieldRow("Model", modelField)
        let routingRow = fieldRow("Routing", routingField)
        let providerLabel = NSTextField(labelWithString: "Provider")
        providerLabel.font = .systemFont(ofSize: 12)
        providerLabel.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let providerRow = NSStackView(views: [providerLabel, providerPopup])
        providerRow.spacing = 10
        let form = NSStackView(views: [profileRow, nameRow, providerRow, modelRow, routingRow, fallbacks, saveProfileButton])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        for row in [nameRow, modelRow, routingRow] {
            row.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        }
        reloadProfiles()
        let privacyRow = NSStackView(views: [NSTextField(labelWithString: "Privacy and data sharing"), LibreReverseSettingsInfoButton(privacy.stringValue, identifier: "settings.ai.privacy-help")])
        privacyRow.spacing = 8
        let stack = NSStackView(views: [title, detail, form, controls, statusLabel, privacyRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(26, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        form.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -36),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),


        ])
        view = root
        refresh()
    }

    private func reloadProfiles() {
        profilePopup.removeAllItems()
        profilePopup.addItems(withTitles: profiles.map(\.name))
        let index = profiles.firstIndex { $0.id == selectedID } ?? 0
        profilePopup.selectItem(at: index)
        let profile = profiles[index]
        selectedID = profile.id
        nameField.stringValue = profile.name
        modelField.stringValue = profile.model
        routingField.stringValue = profile.preferredProviders.joined(separator: ", ")
        providerPopup.selectItem(withTitle: profile.provider.rawValue)
        fallbacks.state = profile.allowFallbacks ? .on : .off
        keyField.stringValue = ""
        updateProviderVisibility()
    }

    @objc private func providerChanged() { updateProviderVisibility() }
    private func updateProviderVisibility() {
        let provider = LibreReverseAIProfile.Provider(rawValue: providerPopup.titleOfSelectedItem ?? "") ?? .local
        let local = provider == .local
        modelField.superview?.superview?.isHidden = local
        routingField.superview?.superview?.isHidden = provider != .openRouter
        fallbacks.isHidden = provider != .openRouter
        keyControls.isHidden = local
    }

    @objc private func selectProfile() {
        guard profiles.indices.contains(profilePopup.indexOfSelectedItem) else { return }
        selectedID = profiles[profilePopup.indexOfSelectedItem].id
        do { try LibreReverseAIProfiles.save(profiles, selected: selectedID) }
        catch { statusLabel.stringValue = error.localizedDescription; return }
        reloadProfiles()
        refresh()
    }

    @objc private func addProfile() {
        var profile = LibreReverseAIProfile.deepSeek
        profile.id = UUID().uuidString
        profile.name = "OpenRouter \(profiles.count)"
        profiles.append(profile)
        selectedID = profile.id
        persistProfiles()
    }

    @objc private func saveProfile() {
        guard let index = profiles.firstIndex(where: { $0.id == selectedID }) else { return }
        profiles[index].name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[index].model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[index].provider = LibreReverseAIProfile.Provider(rawValue: providerPopup.titleOfSelectedItem ?? "") ?? .openRouter
        profiles[index].preferredProviders = routingField.stringValue.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        profiles[index].allowFallbacks = fallbacks.state == .on
        persistProfiles()
    }

    @objc private func removeProfile() {
        guard profiles.count > 1, selectedID != "local" else { return }
        do { try updateAPIKey(nil) } catch { statusLabel.stringValue = error.localizedDescription; return }
        profiles.removeAll { $0.id == selectedID }
        selectedID = profiles[0].id
        persistProfiles()
    }

    private func persistProfiles() {
        do {
            try LibreReverseAIProfiles.save(profiles, selected: selectedID)
            reloadProfiles()
            refresh()
        } catch { statusLabel.stringValue = error.localizedDescription }
    }

    private func refresh() {
        do {
            updateProviderVisibility()
            let local = profiles.first { $0.id == selectedID }?.provider == .local
            keyField.isEnabled = !local
            saveButton.isEnabled = !local
            let hasAPIKey = !(try apiKey() ?? "").isEmpty
            statusLabel.stringValue = local ? "Search and summaries use Apple Intelligence on this Mac." : hasAPIKey
                ? "API key saved. The saved key is hidden."
                : "No API key saved."
            removeButton.isEnabled = hasAPIKey && !local
        } catch {
            statusLabel.stringValue = error.localizedDescription
            removeButton.isEnabled = false
        }
    }

    @objc private func save() {
        let value = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { NSSound.beep(); return }
        do {
            try updateAPIKey(value)
            keyField.stringValue = ""
            refresh()
        } catch { statusLabel.stringValue = error.localizedDescription }
    }

    @objc private func remove() {
        do {
            try updateAPIKey(nil)
            keyField.stringValue = ""
            refresh()
        } catch { statusLabel.stringValue = error.localizedDescription }
    }
}

private final class LibreReverseShortcutRecorderButton: NSButton {
    var onCapture: ((LibreReverseShortcutBinding?) -> Void)?
    var onValidationError: ((String) -> Void)?
    private var binding: LibreReverseShortcutBinding?
    private var isRecordingShortcut = false

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        alignment = .center
    }

    required init?(coder: NSCoder) { nil }

    func display(_ binding: LibreReverseShortcutBinding?) {
        self.binding = binding
        guard !isRecordingShortcut else { return }
        title = binding?.displayName ?? "Record Shortcut"
        toolTip = binding == nil
            ? "Click, then type a shortcut"
            : "Click to replace \(binding!.displayName)"
        setAccessibilityValue(binding?.displayName ?? "Not assigned")
    }

    @objc private func beginRecording() {
        isRecordingShortcut = true
        title = "Type shortcut…"
        window?.makeFirstResponder(self)
        setAccessibilityValue("Recording shortcut")
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            isRecordingShortcut = false
            display(binding)
        }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        guard isRecordingShortcut else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            isRecordingShortcut = false
            display(binding)
            window?.makeFirstResponder(nil)
            return
        }
        if event.keyCode == 51,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            isRecordingShortcut = false
            onCapture?(nil)
            window?.makeFirstResponder(nil)
            return
        }
        guard let captured = LibreReverseShortcutBinding.from(event: event) else {
            onValidationError?(
                "Shortcuts must include Command, Option, or Control."
            )
            NSSound.beep()
            return
        }
        isRecordingShortcut = false
        onCapture?(captured)
        window?.makeFirstResponder(nil)
    }
}

@MainActor
final class LibreReverseShortcutsSettingsViewController: NSViewController {
    private let settings: () -> LibreReverseShortcutSettings
    private let updateSettings: (LibreReverseShortcutSettings) throws -> Void
    private let rows = NSStackView()
    private let scrollButton = NSButton(
        checkboxWithTitle: "Use Command + Shift + Scroll to open LibreReverse",
        target: nil,
        action: nil
    )
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var recorders: [LibreReverseShortcutAction: LibreReverseShortcutRecorderButton] = [:]

    init(
        settings: @escaping () -> LibreReverseShortcutSettings,
        updateSettings: @escaping (LibreReverseShortcutSettings) throws -> Void
    ) {
        self.settings = settings
        self.updateSettings = updateSettings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: "Keyboard shortcuts")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let explanation = NSTextField(
            wrappingLabelWithString:
                "Choose global shortcuts that work even when LibreReverse is in the background. Click a field and type a new shortcut; press Delete to clear it."
        )
        explanation.textColor = .secondaryLabelColor
        explanation.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        for action in LibreReverseShortcutAction.allCases {
            rows.addArrangedSubview(makeRow(for: action))
        }

        scrollButton.target = self
        scrollButton.action = #selector(scrollChanged)
        scrollButton.setAccessibilityIdentifier("shortcuts.scrollToRewind")
        let keycaps = NSStackView(views: [
            keycap("⌘  Command"),
            keycap("⇧  Shift"),
            NSTextField(labelWithString: "+ scroll on your trackpad"),
        ])
        keycaps.orientation = .horizontal
        keycaps.alignment = .centerY
        keycaps.spacing = 10
        let scrollNote = NSTextField(
            wrappingLabelWithString:
                "Command + Shift + scroll: open the timeline. Shift + scroll: move faster. Shift + drag: select text."
        )
        scrollNote.textColor = .secondaryLabelColor
        scrollNote.font = .systemFont(ofSize: 12)

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12, weight: .medium)
        errorLabel.isHidden = true
        errorLabel.setAccessibilityIdentifier("shortcuts.error")

        let shortcutCard = makeCard(views: [rows])
        let scrollHeading = NSTextField(labelWithString: "Scroll to LibreReverse")
        scrollHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        scrollHeading.textColor = .secondaryLabelColor
        let scrollCard = makeCard(views: [
            scrollHeading, scrollButton, keycaps, scrollNote,
        ])
        let page = NSStackView(views: [
            title, explanation, shortcutCard, scrollCard, errorLabel,
        ])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 14
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        explanation.translatesAutoresizingMaskIntoConstraints = false
        explanation.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        shortcutCard.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        scrollCard.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        errorLabel.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        scrollNote.translatesAutoresizingMaskIntoConstraints = false
        scrollNote.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -40).isActive = true
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 34),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -34),
            page.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24),
        ])
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        let current = settings()
        for action in LibreReverseShortcutAction.allCases {
            recorders[action]?.display(current.binding(for: action))
        }
        scrollButton.state = current.scrollToRewindEnabled ? .on : .off
    }

    private func makeCard(views: [NSView]) -> NSBox {
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 8
        card.borderWidth = 0.5
        card.borderColor = NSColor.white.withAlphaComponent(0.08)
        card.fillColor = NSColor(calibratedWhite: 0.145, alpha: 1)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.contentView!.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.contentView!.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.contentView!.bottomAnchor),
        ])
        return card
    }

    private func makeRow(for action: LibreReverseShortcutAction) -> NSView {
        let label = NSTextField(labelWithString: action.title + ":")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let recorder = LibreReverseShortcutRecorderButton()
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.widthAnchor.constraint(equalToConstant: 150).isActive = true
        recorder.setAccessibilityLabel(action.title + " shortcut")
        recorder.setAccessibilityIdentifier("shortcuts.\(action.rawValue).recorder")
        recorder.onCapture = { [weak self] binding in
            self?.change(action: action, binding: binding)
        }
        recorder.onValidationError = { [weak self] message in
            self?.showError(message)
        }
        recorders[action] = recorder

        let clear = NSButton(
            image: NSImage(
                systemSymbolName: "xmark.circle.fill",
                accessibilityDescription: "Clear"
            ) ?? NSImage(),
            target: self,
            action: #selector(clearBinding(_:))
        )
        clear.bezelStyle = .inline
        clear.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        clear.toolTip = "Clear \(action.title) shortcut"
        clear.setAccessibilityLabel("Clear \(action.title) shortcut")

        let restore = NSButton(
            title: "Restore Default",
            target: self,
            action: #selector(restoreDefault(_:))
        )
        restore.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        restore.isHidden = action == .toggleCapture
        restore.setAccessibilityLabel("Restore default \(action.title) shortcut")

        let row = NSStackView(views: [label, recorder, clear, restore])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func keycap(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.alignment = .center
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 7
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .windowBackgroundColor
        label.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor, constant: -7),
        ])
        return box
    }

    private func change(
        action: LibreReverseShortcutAction,
        binding: LibreReverseShortcutBinding?
    ) {
        var candidate = settings()
        candidate.setBinding(binding, for: action)
        do {
            try updateSettings(candidate)
            errorLabel.isHidden = true
            refresh()
        } catch {
            showError(error.localizedDescription)
            refresh()
        }
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    @objc private func clearBinding(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let action = LibreReverseShortcutAction(rawValue: raw) else { return }
        change(action: action, binding: nil)
    }

    @objc private func restoreDefault(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let action = LibreReverseShortcutAction(rawValue: raw) else { return }
        change(
            action: action,
            binding: LibreReverseShortcutSettings.defaults.binding(for: action)
        )
    }

    @objc private func scrollChanged() {
        var candidate = settings()
        candidate.scrollToRewindEnabled = scrollButton.state == .on
        do {
            try updateSettings(candidate)
            errorLabel.isHidden = true
        } catch {
            showError(error.localizedDescription)
            refresh()
        }
    }
}

@MainActor
final class LibreReverseStorageSettingsViewController: NSViewController {
    private let manager: GoogleDriveConnectionManager
    private let connectionValidated: (GoogleDriveConnectionIdentity) async throws -> Void
    private let connectionAuthorized: (GoogleDriveConnectionManager.PendingAuthorization) async throws -> Void
    private let connectionDisconnected: (ArchiveBackendKind) async throws -> Void
    private let archiveConnectionSettings: () async throws -> LibreReverseArchiveConnectionSettings
    private let connectS3: (S3ArchiveConfiguration) async throws -> Void
    private let archiveSnapshot: () async throws -> LibreReverseArchiveSettingsSnapshot?
    private let updateArchivePolicy: (LibreReverseArchivePolicy) throws -> Void
    private let retryArchive: () -> Void
    private let storageUsage: () async -> LibreReverseStorageUsageSnapshot
    private let deleteAllData: () async throws -> Void
    private let titleLabel = NSTextField(labelWithString: "Storage")
    private let providerPopup = NSPopUpButton()
    private let s3Form = NSStackView()
    private let editConnectionButton = NSButton(title: "Edit connection…", target: nil, action: nil)
    private var editsConnection = false
    private let endpointField = NSTextField()
    private let bucketField = NSTextField()
    private let regionField = NSTextField(string: "us-east-1")
    private let accessKeyField = NSTextField()
    private let secretKeyField = NSSecureTextField()
    private let sessionTokenField = NSSecureTextField()
    private let sessionTokenToggle = NSButton(checkboxWithTitle: "Use a session token", target: nil, action: nil)
    private var selection = LibreReverseArchiveSettingsSelection()
    private var connectionSettings = LibreReverseArchiveConnectionSettings(activeKind: nil, s3Configuration: nil)
    private var hasLoadedConnectionSettings = false
    private var providerName: String { selection.provider == .googleDrive ? "Google Drive" : "S3" }
    private let explanationLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let syncProgress = NSProgressIndicator()
    private let syncActivityIndicator = NSProgressIndicator()
    private let syncStateLabel = NSTextField(labelWithString: "Backup")
    private let syncSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let syncNoteLabel = NSTextField(wrappingLabelWithString: "")
    private let syncFailureLabel = NSTextField(wrappingLabelWithString: "")
    private let localRetentionPopup = NSPopUpButton()
    private let retentionRow = NSStackView()
    private let retryButton = NSButton(title: "Retry Backup", target: nil, action: nil)
    private let primaryButton = NSButton(title: "Connect Google Drive", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    private let usageLabel = NSTextField(wrappingLabelWithString: "Calculating local storage…")
    private let archiveUsageLabel = NSTextField(wrappingLabelWithString: "")
    private let growthLabel = NSTextField(wrappingLabelWithString: "")
    private let projectionLabel = NSTextField(wrappingLabelWithString: "")
    private let deleteAllButton = NSButton(title: "Delete All Data…", target: nil, action: nil)
    private var shuttingDown = false
    private var operationTask: Task<Void, Never>?
    private var archiveStatusTask: Task<Void, Never>?
    private var statusTimer: Timer?
    private var latestArchiveSnapshot: LibreReverseArchiveSettingsSnapshot?
    private var etaEstimator = LibreReverseTransferETAEstimator()
    private var configurationStatus = GoogleDriveConfigurationStatus(
        source: nil,
        hasSavedAuthorization: false
    )
    private var identity: GoogleDriveConnectionIdentity?
    private var isBusy = false
    private var errorMessage: String?

    init(
        manager: GoogleDriveConnectionManager,
        connectionValidated: @escaping (GoogleDriveConnectionIdentity) async throws -> Void,
        connectionAuthorized: @escaping (GoogleDriveConnectionManager.PendingAuthorization) async throws -> Void,
        connectionDisconnected: @escaping (ArchiveBackendKind) async throws -> Void,
        archiveConnectionSettings: @escaping () async throws -> LibreReverseArchiveConnectionSettings,
        connectS3: @escaping (S3ArchiveConfiguration) async throws -> Void,
        archiveSnapshot: @escaping () async throws -> LibreReverseArchiveSettingsSnapshot?,
        updateArchivePolicy: @escaping (LibreReverseArchivePolicy) throws -> Void,
        retryArchive: @escaping () -> Void,
        storageUsage: @escaping () async -> LibreReverseStorageUsageSnapshot,
        deleteAllData: @escaping () async throws -> Void
    ) {
        self.manager = manager
        self.connectionValidated = connectionValidated
        self.connectionAuthorized = connectionAuthorized
        self.connectionDisconnected = connectionDisconnected
        self.archiveConnectionSettings = archiveConnectionSettings
        self.connectS3 = connectS3
        self.archiveSnapshot = archiveSnapshot
        self.updateArchivePolicy = updateArchivePolicy
        self.retryArchive = retryArchive
        self.storageUsage = storageUsage
        self.deleteAllData = deleteAllData
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    private func sectionHeading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeCard(views: [NSView]) -> NSBox {
        let card = NSBox()
        card.boxType = .custom
        card.borderWidth = 0
        card.fillColor = .clear
        card.contentViewMargins = .zero
        let rule = NSBox()
        rule.boxType = .separator
        let stack = NSStackView(views: views + [rule])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(18, after: views.last!)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.contentView!.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.contentView!.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.contentView!.bottomAnchor),
            rule.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return card
    }

    override func loadView() {
        view = NSView()
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        explanationLabel.stringValue = "Back up recordings and encrypted history to your cloud storage."
        explanationLabel.font = .systemFont(ofSize: 11)
        explanationLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        progress.style = .spinning
        progress.controlSize = .small
        progress.isHidden = true
        syncProgress.style = .bar
        syncProgress.isIndeterminate = false
        syncProgress.minValue = 0
        syncProgress.maxValue = 1
        syncProgress.doubleValue = 0
        syncProgress.isHidden = true
        syncProgress.setAccessibilityIdentifier("storage.sync.progress")
        syncActivityIndicator.style = .spinning
        syncActivityIndicator.controlSize = .small
        syncActivityIndicator.isDisplayedWhenStopped = false
        syncActivityIndicator.isHidden = true
        syncActivityIndicator.setAccessibilityIdentifier("storage.sync.activity")
        syncStateLabel.font = .systemFont(ofSize: 12, weight: .regular)
        syncStateLabel.setAccessibilityIdentifier("storage.sync.state")
        syncSummaryLabel.textColor = .secondaryLabelColor
        syncSummaryLabel.setAccessibilityIdentifier("storage.sync.summary")
        syncFailureLabel.font = .systemFont(ofSize: 12)
        syncFailureLabel.textColor = .secondaryLabelColor
        syncFailureLabel.isSelectable = true
        syncFailureLabel.setAccessibilityIdentifier("storage.sync.failures")
        syncFailureLabel.isHidden = true
        syncNoteLabel.textColor = .secondaryLabelColor
        syncNoteLabel.font = .systemFont(ofSize: 12)
        syncNoteLabel.toolTip = "Most recent recording or history file successfully backed up to your archive."
        localRetentionPopup.addItems(withTitles: ["Keep all history on this Mac", "Keep 7 days on this Mac", "Keep 30 days on this Mac", "Keep 90 days on this Mac"])
        localRetentionPopup.setAccessibilityIdentifier("storage.policy.localRetention")
        localRetentionPopup.target = self
        localRetentionPopup.action = #selector(retentionSelectionChanged)
        retryButton.target = self
        retryButton.action = #selector(retrySync)
        retryButton.setAccessibilityIdentifier("storage.sync.retry")
        archiveUsageLabel.setAccessibilityIdentifier("storage.archive.usage")
        growthLabel.setAccessibilityIdentifier("storage.archive.monthlyEstimate")
        growthLabel.font = .systemFont(ofSize: 12)
        growthLabel.textColor = .secondaryLabelColor
        usageLabel.font = .systemFont(ofSize: 12, weight: .regular)
        usageLabel.setAccessibilityIdentifier("storage.local.usage")
        projectionLabel.textColor = .secondaryLabelColor
        projectionLabel.setAccessibilityIdentifier("storage.local.projection")
        deleteAllButton.target = self
        deleteAllButton.action = #selector(confirmDeleteAllData)
        deleteAllButton.contentTintColor = .systemRed
        deleteAllButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        deleteAllButton.imagePosition = .imageLeading
        deleteAllButton.setAccessibilityIdentifier("storage.deleteAll")

        retentionRow.addArrangedSubview(NSTextField(labelWithString: "History kept locally:"))
        retentionRow.addArrangedSubview(localRetentionPopup)
        retentionRow.orientation = .horizontal
        retentionRow.spacing = 8
        primaryButton.target = self
        primaryButton.action = #selector(connect)
        primaryButton.keyEquivalent = "\r"
        primaryButton.setAccessibilityIdentifier("storage.googleDrive.connect")
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnect)
        disconnectButton.setAccessibilityIdentifier("storage.googleDrive.disconnect")
        let buttonRow = NSStackView(views: [primaryButton, disconnectButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10

        let disclosure = NSTextField(wrappingLabelWithString: "Recordings are uploaded over TLS and are not client-side encrypted. History databases retain SQLCipher encryption. Switching copies recordings and history available on this Mac. Remote-only items stay with the previous provider; keep access to that archive.")
        disclosure.textColor = .tertiaryLabelColor
        disclosure.font = .systemFont(ofSize: 11)

        editConnectionButton.target = self
        editConnectionButton.action = #selector(toggleConnectionDetails)
        editConnectionButton.setAccessibilityIdentifier("storage.connection.edit")
        providerPopup.addItems(withTitles: ["Google Drive", "S3-compatible storage"])
        providerPopup.target = self
        providerPopup.action = #selector(providerSelectionChanged)
        providerPopup.setAccessibilityIdentifier("storage.provider")
        s3Form.orientation = .vertical
        s3Form.alignment = .leading
        s3Form.spacing = 8
        let fields: [(String, NSTextField, String, String)] = [
            ("Endpoint", endpointField, "https://s3.example.com", "endpoint"),
            ("Bucket", bucketField, "my-recordings", "bucket"),
            ("Region", regionField, "us-east-1", "region"),
            ("Access key", accessKeyField, "Access key ID", "accessKey"),
            ("Secret key", secretKeyField, "Secret access key", "secretKey"),
            ("Session token", sessionTokenField, "Optional", "sessionToken"),
        ]
        for (title, field, placeholder, identifier) in fields {
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 84).isActive = true
            field.placeholderString = placeholder
            field.setAccessibilityLabel(title)
            field.setAccessibilityIdentifier("storage.s3.\(identifier)")
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            let row = NSStackView(views: [label, settingsFieldContainer(field)])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            s3Form.addArrangedSubview(row)
        }
        sessionTokenToggle.target = self
        sessionTokenToggle.action = #selector(sessionTokenChanged)
        sessionTokenToggle.setAccessibilityIdentifier("storage.s3.useSessionToken")
        s3Form.insertArrangedSubview(sessionTokenToggle, at: 5)
        let s3Hint = NSTextField(wrappingLabelWithString: "Credentials are saved securely.")
        s3Hint.toolTip = "Use a bucket you control. Credentials are saved in the encrypted library. The connection is tested before becoming active. Existing archive settings stay active until verification succeeds."
        s3Hint.font = .systemFont(ofSize: 11)
        s3Hint.textColor = .secondaryLabelColor
        s3Form.addArrangedSubview(s3Hint)
        let connectionHeading = sectionHeading("Cloud storage provider")
        let backupHeading = sectionHeading("Backup")
        let localHeading = sectionHeading("Local history")
        let syncStateRow = NSStackView(views: [syncActivityIndicator, syncStateLabel])
        syncStateRow.orientation = .horizontal
        syncStateRow.alignment = .centerY
        syncStateRow.spacing = 7
        let connectionCard = makeCard(views: [
            connectionHeading, providerPopup, statusLabel, detailLabel, editConnectionButton, s3Form, progress, buttonRow,
        ])
        let backupCard = makeCard(views: [
            backupHeading, syncStateRow, archiveUsageLabel, growthLabel, syncSummaryLabel, syncProgress,
            syncNoteLabel, syncFailureLabel, retryButton,
        ])
        let localCard = makeCard(views: [
            localHeading, usageLabel, retentionRow, projectionLabel,
            deleteAllButton,
        ])
        let page = NSStackView(views: [
            titleLabel, explanationLabel, connectionCard, backupCard, localCard,
            NSStackView(views: [NSTextField(labelWithString: "About archiving"), LibreReverseSettingsInfoButton(disclosure.stringValue, identifier: "storage.archive.help")]),
        ])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 14
        page.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = LibreReverseStorageDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        view.addSubview(scroll)
        document.addSubview(page)
        s3Hint.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        for fullWidthView in [explanationLabel, statusLabel, detailLabel, syncSummaryLabel, syncNoteLabel, syncFailureLabel, usageLabel, archiveUsageLabel, growthLabel, projectionLabel] {
            fullWidthView.translatesAutoresizingMaskIntoConstraints = false
            fullWidthView.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        }
        for card in [connectionCard, backupCard, localCard] {
            card.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            page.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 30),
            page.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -30),
            page.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
        render()
    }

    /// Close admission synchronously and return every current owner so the app
    /// can await provider and credential writes before releasing its lock.
    func beginShutdown() -> [Task<Void, Never>] {
        shuttingDown = true
        statusTimer?.invalidate()
        statusTimer = nil
        let tasks = [operationTask, archiveStatusTask].compactMap { $0 }
        for task in tasks { task.cancel() }
        return tasks
    }

    deinit {
        operationTask?.cancel()
        archiveStatusTask?.cancel()
        statusTimer?.invalidate()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        beginStatusPolling()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func invalidateArchiveStatus() {
        selection.invalidate()
        archiveStatusTask?.cancel()
        archiveStatusTask = nil
        latestArchiveSnapshot = nil
        etaEstimator = LibreReverseTransferETAEstimator()
    }

    @objc private func providerSelectionChanged() {
        guard !isBusy else { return }
        selection.select(providerPopup.indexOfSelectedItem == 0 ? .googleDrive : .s3Compatible)
        invalidateArchiveStatus()
        errorMessage = nil
        render()
        requestArchiveSnapshot(syncPolicyControls: true)
    }

    @objc private func sessionTokenChanged() { render() }

    #if DEBUG
    /// Isolated native-window tests supply explicit synthetic state; never connects a provider.
    func renderConnectedPreview(settings: LibreReverseArchiveConnectionSettings,
                                archive: LibreReverseArchiveSettingsSnapshot,
                                usage: LibreReverseStorageUsageSnapshot) {
        _ = view
        applyConnectionSettings(settings, initial: true)
        hasLoadedConnectionSettings = true
        latestArchiveSnapshot = archive
        renderUsage(usage)
        render()
    }
    #endif

    private func applyConnectionSettings(_ settings: LibreReverseArchiveConnectionSettings, initial: Bool) {
        connectionSettings = settings
        if initial {
            selection.select(settings.activeKind ?? .googleDrive)
            providerPopup.selectItem(at: selection.provider == .googleDrive ? 0 : 1)
        }
        if initial, let s3 = settings.s3Configuration {
            endpointField.stringValue = s3.endpoint.absoluteString
            bucketField.stringValue = s3.bucket
            regionField.stringValue = s3.region
            accessKeyField.stringValue = s3.accessKey
            sessionTokenToggle.state = s3.sessionToken == nil ? .off : .on
        }
        secretKeyField.placeholderString = settings.s3Configuration == nil ? "Secret access key" : "Saved — leave blank to keep"
        sessionTokenField.placeholderString = settings.s3Configuration?.sessionToken == nil ? "Optional" : "Saved — leave blank to keep"
    }

    func refresh() {
        guard !shuttingDown, operationTask == nil else { return }
        errorMessage = nil
        isBusy = true
        invalidateArchiveStatus()
        render()
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { operationTask = nil }
            let usage = await storageUsage()
            guard !Task.isCancelled else { return }
            renderUsage(usage)
            do {
                let settings = try await archiveConnectionSettings()
                applyConnectionSettings(settings, initial: !hasLoadedConnectionSettings)
                hasLoadedConnectionSettings = true
                configurationStatus = try await manager.configurationStatus()
                identity = try await manager.savedConnectionIdentity()
                // Viewing Storage must not reactivate a saved Drive account while S3 is active.
                if settings.activeKind == .googleDrive && configurationStatus.hasSavedAuthorization {
                    render(statusOverride: "Verifying Google Drive connection…")
                    identity = try await manager.restore()
                    configurationStatus = try await manager.configurationStatus()
                }
            } catch { errorMessage = error.localizedDescription }
            isBusy = false
            await loadArchiveSnapshot(syncPolicyControls: true)
            render()
        }
    }

    @objc private func connect() {
        guard !shuttingDown, operationTask == nil else { return }
        let provider = selection.provider
        isBusy = true
        errorMessage = nil
        invalidateArchiveStatus()
        render(statusOverride: provider == .googleDrive ? "Waiting for Google permission…" : "Testing S3 connection…")
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { operationTask = nil }
            do {
                if provider == .googleDrive {
                    if connectionSettings.activeKind != .googleDrive,
                       configurationStatus.hasSavedAuthorization,
                       let restored = try? await manager.restore() {
                        try await connectionValidated(restored)
                        identity = restored
                    } else {
                        try Task.checkCancellation()
                        let pending = try await manager.authorize { url in
                            guard NSWorkspace.shared.open(url) else { throw GoogleDriveConnectionError.unableToOpenBrowser }
                        }
                        try await connectionAuthorized(pending)
                        identity = pending.identity
                    }
                    configurationStatus = try await manager.configurationStatus()
                } else {
                    let configuration = try LibreReverseS3SettingsDraft(
                        endpoint: endpointField.stringValue, bucket: bucketField.stringValue,
                        region: regionField.stringValue, accessKey: accessKeyField.stringValue,
                        secretKey: secretKeyField.stringValue, sessionToken: sessionTokenField.stringValue,
                        usesSessionToken: sessionTokenToggle.state == .on
                    ).configuration(saved: connectionSettings.s3Configuration)
                    try await connectS3(configuration)
                    secretKeyField.stringValue = ""
                    sessionTokenField.stringValue = ""
                }
                applyConnectionSettings(try await archiveConnectionSettings(), initial: false)
            } catch is CancellationError { errorMessage = nil }
            catch { errorMessage = error.localizedDescription }
            isBusy = false
            await loadArchiveSnapshot(syncPolicyControls: true)
            render()
        }
    }

    @objc private func disconnect() {
        guard !shuttingDown, operationTask == nil, connectionSettings.activeKind == selection.provider else { return }
        let provider = selection.provider
        let alert = NSAlert()
        alert.messageText = "Disconnect \(providerName)?"
        alert.informativeText = "Archiving will stop. Existing remote files are not deleted."
        alert.addButton(withTitle: "Disconnect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isBusy = true
        errorMessage = nil
        invalidateArchiveStatus()
        render(statusOverride: "Disconnecting \(providerName)…")
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { operationTask = nil }
            do {
                // Parent drains transfers/readers before revoking credentials.
                try await connectionDisconnected(provider)
                applyConnectionSettings(try await archiveConnectionSettings(), initial: false)
                if provider == .googleDrive {
                    identity = nil
                    configurationStatus = try await manager.configurationStatus()
                }
            } catch { errorMessage = error.localizedDescription }
            isBusy = false
            await loadArchiveSnapshot(syncPolicyControls: true)
            render()
        }
    }

    @objc private func toggleConnectionDetails() { editsConnection.toggle(); render() }

    private func render(statusOverride: String? = nil) {
        guard isViewLoaded else { return }
        progress.isHidden = !isBusy
        if isBusy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        providerPopup.isEnabled = !isBusy
        let activeS3 = selection.provider == .s3Compatible && connectionSettings.activeKind == .s3Compatible
        s3Form.isHidden = selection.provider != .s3Compatible || (activeS3 && !editsConnection)
        editConnectionButton.isHidden = !activeS3
        editConnectionButton.title = editsConnection ? "Hide connection details" : "Edit connection…"
        primaryButton.isHidden = activeS3 && !editsConnection
        for field in [endpointField, bucketField, regionField, accessKeyField, secretKeyField, sessionTokenField] { field.isEnabled = !isBusy }
        sessionTokenToggle.isEnabled = !isBusy
        sessionTokenField.isEnabled = !isBusy && sessionTokenToggle.state == .on
        let active = connectionSettings.activeKind == selection.provider
        disconnectButton.isEnabled = !isBusy && active
        disconnectButton.isHidden = !active
        primaryButton.isEnabled = !isBusy && (selection.provider == .s3Compatible || configurationStatus.source != nil)
        primaryButton.setAccessibilityIdentifier(selection.provider == .googleDrive ? "storage.googleDrive.connect" : "storage.s3.connect")
        disconnectButton.setAccessibilityIdentifier(selection.provider == .googleDrive ? "storage.googleDrive.disconnect" : "storage.s3.disconnect")
        primaryButton.title = selection.provider == .googleDrive
            ? (active ? "Reconnect" : "Connect")
            : (active ? "Test & Save" : "Connect")

        if let statusOverride {
            statusLabel.stringValue = statusOverride
            detailLabel.stringValue = ""
        } else if let errorMessage {
            statusLabel.stringValue = "Needs attention"
            detailLabel.stringValue = errorMessage
        } else if selection.provider == .googleDrive && configurationStatus.source == nil
                    && (!active || connectionSettings.isOperational == false) {
            statusLabel.stringValue = "Google Drive is unavailable in this build"
            detailLabel.stringValue = active
                ? "Your saved archive is retained, but this build cannot reconnect. Use a build with Google Drive enabled."
                : "Use S3-compatible storage or a build with Google Drive enabled."
        } else if active && connectionSettings.isOperational == false {
            statusLabel.stringValue = "Archive needs reconnecting"
            detailLabel.stringValue = "Your archive settings are saved, but this app has no active connection. Reconnect to resume backups and downloads."
        } else if selection.provider == .s3Compatible {
            statusLabel.stringValue = active ? "Connected" : ""
            detailLabel.stringValue = active ? connectionSettings.s3Configuration?.displayName ?? "" : ""
        } else if active, let identity {
            statusLabel.stringValue = "Connected as \(identity.emailAddress)"
            var detail = "The LibreReverse folder is ready in Google Drive."
            if let usage = identity.storageUsage, let limit = identity.storageLimit { detail += " Drive usage: \(bytes(usage)) of \(bytes(limit))." }
            detailLabel.stringValue = detail
        } else if active {
            statusLabel.stringValue = "Connected to Google Drive"
            detailLabel.stringValue = "Your archive is active."
        } else if configurationStatus.source == nil {
            statusLabel.stringValue = "Google Drive is unavailable in this build"
            detailLabel.stringValue = "Use S3-compatible storage or a build with Google Drive enabled."
        } else {
            statusLabel.stringValue = "Ready to connect Google Drive"
            detailLabel.stringValue = connectionSettings.activeKind == .s3Compatible ? "Your S3 archive stays active until Google Drive connects successfully." : "Sign in with Google to choose your archive account."
        }
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        detailLabel.isHidden = detailLabel.stringValue.isEmpty
        renderArchiveSnapshot(syncPolicyControls: true)
    }

    private func beginStatusPolling() {
        guard !shuttingDown, statusTimer == nil else { return }
        requestArchiveSnapshot(syncPolicyControls: false)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.requestArchiveSnapshot(syncPolicyControls: false)
            }
        }
    }

    private func renderArchiveSnapshot(syncPolicyControls: Bool) {
        let archive = latestArchiveSnapshot.flatMap { $0.providerKind == selection.provider && connectionSettings.activeKind == selection.provider ? $0 : nil }
        syncFailureLabel.isHidden = true
        syncFailureLabel.stringValue = ""
        syncSummaryLabel.isHidden = archive == nil
        syncProgress.isHidden = true
        syncActivityIndicator.stopAnimation(nil)
        syncActivityIndicator.isHidden = true
        retentionRow.isHidden = false
        localRetentionPopup.isEnabled = archive != nil && !isBusy
        retryButton.isHidden = true
        archiveUsageLabel.isHidden = archive == nil
        growthLabel.isHidden = archive == nil
        if let archive {
            let archivedBytes = archive.status.verifiedBytes + archive.shardStatus.verifiedBytes
            archiveUsageLabel.stringValue = "Archive storage: \(bytes(archivedBytes))"
            if let days = latestUsage?.recordedDays, days >= 7, archivedBytes > 0, archive.status.historicalPendingObjects == 0, archive.shardStatus.queuedObjects == 0 {
                let monthly = Double(archivedBytes) / Double(days) * 30
                growthLabel.stringValue = "Estimated/month: \(bytes(Int64(monthly)))"
                growthLabel.toolTip = "This archive’s verified video and index bytes divided by the library history span (\(days) days), scaled to 30 days. Remote-only history is included using coarse shard periods. Other providers and repeated upload attempts are excluded. Initial backup, deletions, and changing activity affect this estimate; it is not measured monthly growth."
            } else {
                growthLabel.stringValue = "Estimated/month: collecting history"
            }
            let videoTransferred = min(
                archive.status.totalBytes,
                archive.status.verifiedBytes + archive.status.activeTransferredBytes
            )
            let shardTransferred = min(
                archive.shardStatus.totalBytes,
                archive.shardStatus.verifiedBytes + archive.shardStatus.activeTransferredBytes
            )
            let transferred = videoTransferred + shardTransferred
            let totalBytes = archive.status.totalBytes + archive.shardStatus.totalBytes
            let pending = archive.status.queuedObjects + Int64(archive.shardStatus.queuedObjects)
            let failed = archive.status.failedObjects + Int64(archive.shardStatus.failedObjects)
            let shardPending = archive.shardStatus.totalObjects - archive.shardStatus.verifiedObjects
            let historicalPending = archive.status.historicalPendingObjects + Int64(shardPending)
            let isSaving = failed == 0 && (
                historicalPending > 0 || pending > 0
                    || archive.status.latestObjectState != .verified
            )
            if isSaving {
                syncActivityIndicator.isHidden = false
                syncActivityIndicator.startAnimation(nil)
            }
            syncFailureLabel.stringValue = LibreReverseArchiveFailurePresentation.text(
                summaries: archive.failureSummaries, totalFailed: failed)
            syncFailureLabel.isHidden = failed == 0
            retryButton.isHidden = failed == 0
            if failed > 0 {
                syncStateLabel.stringValue = "Backup needs attention"
                syncStateLabel.textColor = .systemRed
            } else if historicalPending > 0 {
                syncStateLabel.stringValue = "Backing up existing recordings…"
                syncStateLabel.textColor = .labelColor
            } else if archive.status.latestObjectState != .verified {
                syncStateLabel.stringValue = "Backing up to \(providerName)…"
                syncStateLabel.textColor = .labelColor
            } else {
                syncStateLabel.stringValue = "Backed up to \(providerName)"
                syncStateLabel.textColor = .systemGreen
            }
            var activity: [String] = []
            if pending > 0 { activity.append("\(pending) pending") }
            if failed > 0 { activity.append("\(failed) need attention") }
            if failed == 0, let eta = etaEstimator.estimate(transferred: transferred, total: totalBytes) {
                activity.append("~\(duration(eta)) left")
            }
            if archive.status.rehydrationObjects > 0 { activity.append("\(archive.status.rehydrationObjects) restoring") }
            syncSummaryLabel.stringValue = activity.joined(separator: " · ")
            syncSummaryLabel.isHidden = activity.isEmpty
            syncSummaryLabel.toolTip = "Restoring \(bytes(archive.status.rehydrationBytes)) for local retention. \(bytes(archive.residencyForecast.bytesWaitingForVerification)) awaits verification or integrity checking; \(bytes(archive.residencyForecast.bytesSafelyEvictable)) is verified and eligible for local removal. Recording continues locally; current segments are checkpointed at least every 5 minutes."
            let checkpoint = [archive.status.latestVerifiedAt, archive.shardStatus.latestVerifiedAt]
                .compactMap { $0 }.max()
            let checkpointText = checkpoint.map { "Last backup: \(relativeCheckpoint($0))" }
                ?? "Waiting for the first backup"
            syncNoteLabel.stringValue = checkpointText
            syncProgress.isHidden = historicalPending == 0
            syncProgress.doubleValue = totalBytes > 0
                ? min(1, Double(transferred) / Double(totalBytes))
                : 0
            if syncPolicyControls && !isBusy { renderPolicy(archive.policy) }
        } else {
            syncStateLabel.stringValue = "Not connected — recordings stay on this Mac"
            syncStateLabel.textColor = .secondaryLabelColor
            syncNoteLabel.stringValue = ""
        }
        if connectionSettings.activeKind == selection.provider && connectionSettings.isOperational == false {
            syncStateLabel.stringValue = "Archive needs reconnecting — recordings stay on this Mac"
            syncStateLabel.textColor = .systemOrange
            syncProgress.isHidden = true
            syncSummaryLabel.isHidden = true
            syncActivityIndicator.stopAnimation(nil)
            syncActivityIndicator.isHidden = true
        }
    }

    private func relativeCheckpoint(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        }
        let hours = Int(seconds / 3_600)
        if hours < 24 {
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "on \(formatter.string(from: date))"
    }

    private func requestArchiveSnapshot(syncPolicyControls: Bool) {
        guard !shuttingDown, archiveStatusTask == nil, !isBusy else { return }
        let generation = selection.generation
        archiveStatusTask = Task { [weak self] in
            guard let self else { return }
            await loadArchiveSnapshot(syncPolicyControls: syncPolicyControls)
            if selection.generation == generation { archiveStatusTask = nil }
        }
    }

    private func loadArchiveSnapshot(syncPolicyControls: Bool) async {
        guard !shuttingDown, !Task.isCancelled else { return }
        let generation = selection.generation
        let provider = selection.provider
        let snapshot = try? await archiveSnapshot()
        guard !Task.isCancelled, selection.accepts(generation: generation, provider: provider) else { return }
        latestArchiveSnapshot = snapshot.flatMap { $0.providerKind == provider ? $0 : nil }
        renderArchiveSnapshot(syncPolicyControls: syncPolicyControls)
    }

    private func renderPolicy(_ policy: LibreReverseArchivePolicy) {
        switch policy.requiredLocalSeconds {
        case nil: localRetentionPopup.selectItem(at: 0)
        case let value? where value <= 7 * 86_400: localRetentionPopup.selectItem(at: 1)
        case let value? where value <= 30 * 86_400: localRetentionPopup.selectItem(at: 2)
        default: localRetentionPopup.selectItem(at: 3)
        }
        renderProjection()
    }

    private var latestUsage: LibreReverseStorageUsageSnapshot?

    private func renderUsage(_ usage: LibreReverseStorageUsageSnapshot) {
        latestUsage = usage
        let history: String
        if usage.recordedDays == 1 {
            history = " (1 day of history)"
        } else if usage.recordedDays > 1 {
            history = " (\(usage.recordedDays) days of history)"
        } else {
            history = ""
        }
        usageLabel.stringValue = "On this Mac: \(bytes(usage.localBytes))"
        usageLabel.toolTip = "Local allocated storage\(history). Includes recordings and library files."
        renderProjection()
    }

    @objc private func retentionSelectionChanged() {
        guard !shuttingDown else { return }
        renderProjection()
        applySelectedPolicy()
    }

    private func renderProjection() {
        let selectedDays: Int? = switch localRetentionPopup.indexOfSelectedItem {
        case 0: nil
        case 1: 7
        case 2: 30
        default: 90
        }
        if let selectedDays {
            projectionLabel.stringValue = "Local copies are removed after backup; recordings stay safely in your archive."
            projectionLabel.toolTip = "Verified recordings older than \(selectedDays) days are eligible for removal. Actual space freed depends on completed uploads and recordings currently in use."
        } else {
            projectionLabel.stringValue = "Keep all recordings on this Mac."
            projectionLabel.toolTip = "Archiving adds a remote copy without removing local recordings."
        }
    }

    @objc private func confirmDeleteAllData() {
        guard !shuttingDown, operationTask == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Permanently delete all LibreReverse data?"
        alert.informativeText = connectionSettings.activeKind == nil
            ? "This permanently deletes every local recording, transcript, summary, and search index. LibreReverse will quit to complete the reset. This cannot be undone."
            : "This permanently deletes every recording, transcript, summary, and search index from this Mac and the connected archive. LibreReverse will quit to complete the reset. This cannot be undone."
        if connectionSettings.activeKind == .s3Compatible {
            alert.informativeText += " Versioned S3 buckets may retain earlier object versions. Remove those versions through your storage provider to erase them permanently."
        }
        alert.addButton(withTitle: "Delete All Data")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        operationTask = Task { [weak self] in
            guard let self else { return }
            isBusy = true
            errorMessage = nil
            deleteAllButton.isEnabled = false
            render(statusOverride: connectionSettings.activeKind == nil
                ? "Finalizing capture and preparing local reset…"
                : "Finalizing capture and deleting the connected archive…")
            do {
                try await deleteAllData()
            } catch {
                errorMessage = error.localizedDescription
                isBusy = false
                deleteAllButton.isEnabled = true
                operationTask = nil
                render()
            }
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(1, Int(seconds / 60))
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours < 24 { return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min" }
        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0 ? "\(days) days" : "\(days) days \(remainingHours) hr"
    }

    private func applySelectedPolicy() {
        guard latestArchiveSnapshot != nil, !isBusy else { return }
        do {
            let requiredLocal: TimeInterval? = switch localRetentionPopup.indexOfSelectedItem {
            case 0: nil
            case 1: 7 * 86_400
            case 2: 30 * 86_400
            default: 90 * 86_400
            }
            try updateArchivePolicy(.init(
                coverageMode: .allHistory,
                coverageValue: nil,
                continuousArchive: true,
                requiredLocalSeconds: requiredLocal,
                rehydratedCacheBytes: LibreReverseArchivePolicy.defaultRehydratedCacheBytes
            ))
            errorMessage = nil
            retryArchive()
            requestArchiveSnapshot(syncPolicyControls: true)
            render()
        } catch {
            errorMessage = error.localizedDescription
            render()
        }
    }

    @objc private func retrySync() {
        guard !shuttingDown else { return }
        retryArchive()
        refresh()
    }

    private func bytes(_ value: Int64) -> String {
        if value == 0 { return "0 bytes" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

#endif
