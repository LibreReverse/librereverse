#if os(macOS)
import AppKit
import Carbon
import Foundation

enum LibreReverseMenuItemID: Int, CaseIterable, Sendable {
    case recordingBanner = 90
    case search = 91
    case ask = 92
    case dailyRecap = 93
    case screenCapture = 100
    case backup = 102
    case audioCapture = 103
    case quickStart = 104
    case settings = 105
    case openDataFolder = 106
    case version = 107
    case checkForUpdates = 108
    case quit = 109
}

struct LibreReverseMenuBarSnapshot: Equatable, Sendable {
    var recordingDisabledReason: String?
    var screenCaptureEnabled: Bool
    var screenCaptureAvailable: Bool
    var audioCaptureEnabled: Bool
    var audioCaptureAvailable: Bool
    var backupTitle: String
    var versionTitle: String
    var updateTitle: String
    var updateAvailable: Bool
    var meetingSaveWarning: String? = nil
}

struct LibreReverseMenuItemPresentation: Equatable, Sendable {
    let id: LibreReverseMenuItemID
    let title: String
    let symbolName: String?
    let isEnabled: Bool
    let isHidden: Bool
    let isOn: Bool?
    let shortcut: LibreReverseShortcutBinding?
}

enum LibreReverseMenuBarContract {
    static let sectionOrder: [[LibreReverseMenuItemID]] = [
        [.recordingBanner, .quickStart],
        [.search, .ask],
        [.dailyRecap],
        [.screenCapture, .audioCapture],
        [.settings, .backup, .openDataFolder],
        [.version, .checkForUpdates],
        [.quit],
    ]

    static func presentations(
        snapshot: LibreReverseMenuBarSnapshot,
        shortcuts: LibreReverseShortcutSettings
    ) -> [LibreReverseMenuItemPresentation] {
        let banner = snapshot.recordingDisabledReason.map {
            "Recording is disabled because \($0)"
        } ?? snapshot.meetingSaveWarning ?? "Recording is available"
        return [
            .init(
                id: .recordingBanner,
                title: banner,
                symbolName: "exclamationmark.triangle",
                isEnabled: false,
                isHidden: snapshot.recordingDisabledReason == nil && snapshot.meetingSaveWarning == nil,
                isOn: nil,
                shortcut: nil
            ),
            .init(
                id: .search,
                title: "Search LibreReverse…",
                symbolName: "magnifyingglass",
                isEnabled: true,
                isHidden: false,
                isOn: nil,
                shortcut: shortcuts.openTimeline
            ),
            .init(
                id: .ask,
                title: "Ask LibreReverse…",
                symbolName: "questionmark.bubble",
                isEnabled: true,
                isHidden: false,
                isOn: nil,
                shortcut: shortcuts.askRewind
            ),
            .init(
                id: .dailyRecap,
                title: "Daily Recap",
                symbolName: "calendar",
                isEnabled: true,
                isHidden: false,
                isOn: nil,
                shortcut: shortcuts.dailyRecap
            ),
            .init(
                id: .screenCapture,
                title: "Screen Capture",
                symbolName: "rectangle.dashed.badge.record",
                isEnabled: snapshot.screenCaptureAvailable,
                isHidden: false,
                isOn: snapshot.screenCaptureEnabled,
                shortcut: nil
            ),
            .init(
                id: .audioCapture,
                title: snapshot.audioCaptureEnabled ? "Stop Meeting Recording" : "Start Meeting Recording",
                symbolName: "waveform",
                isEnabled: snapshot.audioCaptureAvailable,
                isHidden: false,
                isOn: nil,
                shortcut: shortcuts.toggleCapture
            ),
            .init(
                id: .quickStart,
                title: "Finish Recording Setup…",
                symbolName: "checklist",
                isEnabled: true,
                isHidden: snapshot.recordingDisabledReason != "required permissions are missing",
                isOn: nil,
                shortcut: nil
            ),
            .init(
                id: .settings,
                title: "Settings…",
                symbolName: "slider.horizontal.3",
                isEnabled: true,
                isHidden: false,
                isOn: nil,
                shortcut: nil
            ),
            .init(
                id: .backup,
                title: snapshot.backupTitle,
                symbolName: "externaldrive",
                isEnabled: true,
                isHidden: false,
                isOn: nil,
                shortcut: nil
            ),
            .init(
                id: .openDataFolder,
                title: "Open Data Folder",
                symbolName: "folder",
                isEnabled: true,
                isHidden: false,
                isOn: nil,
                shortcut: nil
            ),
            .init(
                id: .version,
                title: snapshot.versionTitle,
                symbolName: nil,
                isEnabled: false,
                isHidden: false,
                isOn: nil,
                shortcut: nil
            ),
            .init(
                id: .checkForUpdates,
                title: snapshot.updateTitle,
                symbolName: "arrow.clockwise",
                isEnabled: snapshot.updateAvailable,
                isHidden: false,
                isOn: nil,
                shortcut: nil
            ),
            .init(
                id: .quit,
                title: "Quit",
                symbolName: nil,
                isEnabled: true,
                isHidden: false,
                isOn: nil,
                shortcut: nil
            ),
        ]
    }

    static func keyEquivalent(
        for binding: LibreReverseShortcutBinding?
    ) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        guard let binding else { return ("", []) }
        let key: String
        switch binding.keyLabel.lowercased() {
        case "space": key = " "
        case "return": key = "\r"
        case "tab": key = "\t"
        case "delete": key = "\u{8}"
        case "escape": key = "\u{1b}"
        default: key = binding.keyLabel.lowercased()
        }
        var modifiers: NSEvent.ModifierFlags = []
        if binding.modifiers & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        if binding.modifiers & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if binding.modifiers & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        if binding.modifiers & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        return (key, modifiers)
    }
}

@MainActor
final class LibreReverseMenuToggleView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()
    private var interactionEnabled = true
    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .menuFont(ofSize: 0)
        shortcutLabel.font = .menuFont(ofSize: 0)
        shortcutLabel.textColor = .tertiaryLabelColor
        iconView.imageScaling = .scaleProportionallyDown
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggleChanged)
        for view in [iconView, titleLabel, shortcutLabel, toggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 31),
            widthAnchor.constraint(equalToConstant: 360),
            // Custom menu views must reserve the same state/checkmark gutter as native rows.
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 23),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -10),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(
        title: String,
        symbolName: String?,
        isOn: Bool,
        isEnabled: Bool,
        shortcut: LibreReverseShortcutBinding?
    ) {
        titleLabel.stringValue = title
        shortcutLabel.stringValue = shortcut?.displayName ?? ""
        iconView.image = symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
        toggle.state = isOn ? .on : .off
        toggle.isEnabled = isEnabled
        interactionEnabled = isEnabled
        titleLabel.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        iconView.contentTintColor = isEnabled ? .labelColor : .disabledControlTextColor
        shortcutLabel.isHidden = shortcut == nil
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        setAccessibilityValue(isOn ? "On" : "Off")
        setAccessibilityEnabled(isEnabled)
    }

    @objc private func toggleChanged() {
        onToggle?()
    }

    override func mouseUp(with event: NSEvent) {
        guard interactionEnabled else { return }
        toggle.state = toggle.state == .on ? .off : .on
        onToggle?()
    }
}
#endif
