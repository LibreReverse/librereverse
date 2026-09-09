#if os(macOS)
import AppKit
import LibreReverseCore

struct LibreReverseTranscriptionLanguage: Equatable, Sendable {
    let code: String?
    let name: String

    static let supported: [Self] = [
        .init(code: nil, name: "Detect automatically"),
        .init(code: "af", name: "Afrikaans"), .init(code: "ar", name: "Arabic"),
        .init(code: "hy", name: "Armenian"), .init(code: "az", name: "Azerbaijani"),
        .init(code: "be", name: "Belarusian"), .init(code: "bs", name: "Bosnian"),
        .init(code: "bg", name: "Bulgarian"), .init(code: "ca", name: "Catalan"),
        .init(code: "zh", name: "Chinese"), .init(code: "hr", name: "Croatian"),
        .init(code: "cs", name: "Czech"), .init(code: "da", name: "Danish"),
        .init(code: "nl", name: "Dutch"), .init(code: "en", name: "English"),
        .init(code: "et", name: "Estonian"), .init(code: "fi", name: "Finnish"),
        .init(code: "fr", name: "French"), .init(code: "gl", name: "Galician"),
        .init(code: "de", name: "German"), .init(code: "el", name: "Greek"),
        .init(code: "he", name: "Hebrew"), .init(code: "hi", name: "Hindi"),
        .init(code: "hu", name: "Hungarian"), .init(code: "is", name: "Icelandic"),
        .init(code: "id", name: "Indonesian"), .init(code: "it", name: "Italian"),
        .init(code: "ja", name: "Japanese"), .init(code: "kn", name: "Kannada"),
        .init(code: "kk", name: "Kazakh"), .init(code: "ko", name: "Korean"),
        .init(code: "lv", name: "Latvian"), .init(code: "lt", name: "Lithuanian"),
        .init(code: "mk", name: "Macedonian"), .init(code: "ms", name: "Malay"),
        .init(code: "mi", name: "Maori"), .init(code: "mr", name: "Marathi"),
        .init(code: "ne", name: "Nepali"), .init(code: "no", name: "Norwegian"),
        .init(code: "fa", name: "Persian"), .init(code: "pl", name: "Polish"),
        .init(code: "pt", name: "Portuguese"), .init(code: "ro", name: "Romanian"),
        .init(code: "ru", name: "Russian"), .init(code: "sr", name: "Serbian"),
        .init(code: "sk", name: "Slovak"), .init(code: "sl", name: "Slovenian"),
        .init(code: "es", name: "Spanish"), .init(code: "sw", name: "Swahili"),
        .init(code: "sv", name: "Swedish"), .init(code: "tl", name: "Tagalog"),
        .init(code: "ta", name: "Tamil"), .init(code: "th", name: "Thai"),
        .init(code: "tr", name: "Turkish"), .init(code: "uk", name: "Ukrainian"),
        .init(code: "ur", name: "Urdu"), .init(code: "vi", name: "Vietnamese"),
        .init(code: "cy", name: "Welsh"),
    ]

    static func normalizedCode(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        return supported.contains(where: { $0.code == value }) ? value : "en"
    }
}

@MainActor
final class LibreReverseAudioSettingsViewController: NSViewController {
    private let toggleMeeting: () -> Void
    private let meetingButton = NSButton(title: "Start Meeting Recording", target: nil, action: nil)
    private let snapshot: () -> LibreReverseMeetingAudioSettingsSnapshot
    private let updatePreferences: (LibreReverseMeetingAudioPreferences) -> Void
    private let updateTranscriptionLanguage: (String?) -> Void
    private let openMicrophonePrivacy: () -> Void
    private let sourcePopup = NSPopUpButton()
    private let microphonePopup = NSPopUpButton()
    private let languagePopup = NSPopUpButton()
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    private let recordingLabel = NSTextField(wrappingLabelWithString: "")
    private let privacyButton = NSButton(title: "Open Microphone Privacy", target: nil, action: nil)
    private var refreshTimer: Timer?

    init(
        snapshot: @escaping () -> LibreReverseMeetingAudioSettingsSnapshot,
        updatePreferences: @escaping (LibreReverseMeetingAudioPreferences) -> Void,
        updateTranscriptionLanguage: @escaping (String?) -> Void,
        openMicrophonePrivacy: @escaping () -> Void,
        toggleMeeting: @escaping () -> Void = {}
    ) {
        self.toggleMeeting = toggleMeeting
        self.snapshot = snapshot
        self.updatePreferences = updatePreferences
        self.updateTranscriptionLanguage = updateTranscriptionLanguage
        self.openMicrophonePrivacy = openMicrophonePrivacy
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }
    deinit { refreshTimer?.invalidate() }

    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: "Record a meeting")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString:
            "Start a meeting from here or the menu bar. Use the Start / Stop Meeting shortcut in Settings → Shortcuts. Recordings and transcription stay on this Mac."
        )
        explanation.textColor = .secondaryLabelColor

        sourcePopup.addItems(withTitles: [
            "Microphone and speaker audio", "Microphone only", "Speaker only", "Audio disabled",
        ])
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        sourcePopup.setAccessibilityIdentifier("audio.captureSource")
        microphonePopup.target = self
        microphonePopup.action = #selector(microphoneChanged)
        microphonePopup.setAccessibilityIdentifier("audio.microphone")
        languagePopup.addItems(withTitles: LibreReverseTranscriptionLanguage.supported.map(\.name))
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.setAccessibilityIdentifier("audio.transcriptionLanguage")
        privacyButton.target = self
        privacyButton.action = #selector(openPrivacy)
        privacyButton.bezelStyle = .rounded
        privacyButton.controlSize = .small
        permissionLabel.font = .systemFont(ofSize: 12)
        recordingLabel.font = .systemFont(ofSize: 12, weight: .medium)

        let sourceHelp = NSTextField(wrappingLabelWithString:
            "Use Microphone only when listening through speakers, Speaker only when your own voice must be omitted, or both when wearing headphones. Use Start / Stop Meeting to control manual recording."
        )
        sourceHelp.textColor = .secondaryLabelColor
        sourceHelp.font = .systemFont(ofSize: 12)
        let limitationTitle = NSTextField(labelWithString: "Speaker and Bluetooth limitations")
        limitationTitle.font = .systemFont(ofSize: 13, weight: .regular)
        let limitations = NSTextField(wrappingLabelWithString:
            "Speaker capture can suppress macOS notifications and DRM-protected video. Enable notifications while mirroring in System Settings if needed. Bluetooth switches to lower-quality duplex audio while its microphone is active; choosing the Mac microphone avoids that downgrade. Echo, duplicate text, silence, or a one-sided call usually means the selected source or microphone route is wrong."
        )
        limitations.textColor = .secondaryLabelColor
        limitations.font = .systemFont(ofSize: 12)
        let languageHelp = NSTextField(wrappingLabelWithString:
            "Choose a specific language for best accuracy. Detect automatically supports multilingual meetings but is slower and substantially less accurate. Language changes apply to queued and future local transcription."
        )
        languageHelp.textColor = .secondaryLabelColor
        languageHelp.font = .systemFont(ofSize: 12)
        let sourceSeparator = audioSettingsSeparator()
        let limitationSeparator = audioSettingsSeparator()

        meetingButton.target = self
        meetingButton.action = #selector(toggleRecording)
        meetingButton.bezelStyle = .rounded
        let stack = NSStackView(views: [
            title, explanation, meetingButton,
            audioSettingsRow("Audio capture source:", sourcePopup), sourceHelp,
            audioSettingsRow("Microphone input:", microphonePopup),
            permissionLabel, privacyButton, recordingLabel,
            sourceSeparator,
            audioSettingsRow("Transcription language:", languagePopup), languageHelp,
            limitationSeparator, limitationTitle, limitations,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 42),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -42),
            sourcePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            microphonePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            languagePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            sourceSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            limitationSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        refresh()
    }

    func setActive(_ active: Bool) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard active else { return }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    @objc private func toggleRecording() { toggleMeeting(); refresh() }

    func refresh() {
        guard isViewLoaded else { return }
        let value = snapshot()
        let preferences = value.preferences
        let sourceIndex = switch (
            preferences.capturesMicrophone, preferences.capturesSystemAudio
        ) {
        case (true, true): 0
        case (true, false): 1
        case (false, true): 2
        case (false, false): 3
        }
        sourcePopup.selectItem(at: sourceIndex)
        microphonePopup.removeAllItems()
        let defaultName = value.inputDevices.first(where: \.isDefault)?.name
            ?? "Current system input"
        microphonePopup.addItem(withTitle: "System Default — \(defaultName)")
        microphonePopup.lastItem?.representedObject = ""
        if !value.inputDevices.isEmpty { microphonePopup.menu?.addItem(.separator()) }
        for device in value.inputDevices {
            microphonePopup.addItem(withTitle: device.name + (device.isDefault ? " (current)" : ""))
            microphonePopup.lastItem?.representedObject = device.id
        }
        if let selectedID = preferences.microphoneDeviceID {
            if let item = microphonePopup.itemArray.first(where: {
                ($0.representedObject as? String) == selectedID
            }) {
                microphonePopup.select(item)
            } else {
                microphonePopup.menu?.addItem(.separator())
                microphonePopup.addItem(withTitle: "Unavailable — \(selectedID)")
                microphonePopup.lastItem?.representedObject = selectedID
                microphonePopup.select(microphonePopup.lastItem)
            }
        } else {
            microphonePopup.selectItem(at: 0)
        }
        microphonePopup.isEnabled = preferences.capturesMicrophone
            && value.nativeMicrophoneCaptureSupported

        let selectedLanguage = LibreReverseTranscriptionLanguage.supported.firstIndex {
            $0.code == value.transcriptionLanguageCode
        } ?? 0
        languagePopup.selectItem(at: selectedLanguage)
        languagePopup.isEnabled = value.transcriptionBackendAvailable

        let selectedDeviceAvailable = preferences.microphoneDeviceID.map { selectedID in
            value.inputDevices.contains(where: { $0.id == selectedID })
        } ?? true
        if !value.nativeMicrophoneCaptureSupported {
            permissionLabel.stringValue = "Microphone capture requires macOS 15 or newer; speaker audio remains available."
            permissionLabel.textColor = .systemOrange
            privacyButton.isHidden = true
        } else if preferences.capturesMicrophone && !value.microphoneAuthorized {
            permissionLabel.stringValue = "Microphone access is off. Recordings continue without your voice until access is restored."
            permissionLabel.textColor = .systemOrange
            privacyButton.isHidden = false
        } else if preferences.capturesMicrophone && !selectedDeviceAvailable {
            permissionLabel.stringValue = "The selected microphone is unavailable. Choose another input or System Default."
            permissionLabel.textColor = .systemRed
            privacyButton.isHidden = true
        } else if !value.transcriptionBackendAvailable {
            permissionLabel.stringValue = "The local transcription runtime is not installed; audio remains recordable and retryable."
            permissionLabel.textColor = .systemOrange
            privacyButton.isHidden = true
        } else {
            permissionLabel.stringValue = preferences.capturesMicrophone
                ? "Microphone access and the selected local transcription runtime are ready."
                : "Microphone capture is disabled by your source selection."
            permissionLabel.textColor = .secondaryLabelColor
            privacyButton.isHidden = true
        }
        meetingButton.title = value.isRecording ? "Stop Meeting Recording" : "Start Meeting Recording"
        recordingLabel.stringValue = value.isRecording
            ? "A meeting is recording. Source changes finalize the current file safely and resume the same meeting."
            : "Source changes apply to the next manual or meeting recording."
        recordingLabel.textColor = value.isRecording ? .systemOrange : .secondaryLabelColor
    }

    @objc private func sourceChanged() {
        let current = snapshot().preferences
        let selection: (Bool, Bool) = switch sourcePopup.indexOfSelectedItem {
        case 1: (true, false)
        case 2: (false, true)
        case 3: (false, false)
        default: (true, true)
        }
        updatePreferences(.init(
            capturesSystemAudio: selection.1,
            capturesMicrophone: selection.0,
            microphoneDeviceID: selection.0 ? current.microphoneDeviceID : nil
        ))
        refresh()
    }

    @objc private func microphoneChanged() {
        let current = snapshot().preferences
        let identifier = (microphonePopup.selectedItem?.representedObject as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        updatePreferences(.init(
            capturesSystemAudio: current.capturesSystemAudio,
            capturesMicrophone: current.capturesMicrophone,
            microphoneDeviceID: identifier
        ))
        refresh()
    }

    @objc private func languageChanged() {
        guard LibreReverseTranscriptionLanguage.supported.indices.contains(
            languagePopup.indexOfSelectedItem
        ) else { return }
        updateTranscriptionLanguage(
            LibreReverseTranscriptionLanguage.supported[languagePopup.indexOfSelectedItem].code
        )
        refresh()
    }

    @objc private func openPrivacy() { openMicrophonePrivacy() }
}

private func audioSettingsRow(_ title: String, _ control: NSView) -> NSView {
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 13, weight: .regular)
    label.alignment = .left
    label.widthAnchor.constraint(equalToConstant: 170).isActive = true
    let row = NSStackView(views: [label, control])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 12
    return row
}

private func audioSettingsSeparator() -> NSView {
    let separator = NSBox()
    separator.boxType = .separator
    separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return separator
}
#endif
