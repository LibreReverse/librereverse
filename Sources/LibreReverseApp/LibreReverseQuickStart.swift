#if os(macOS)
import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import LibreReverseCore

@MainActor
final class LibreReversePermissionsController {
    private(set) var state: PermissionGrantContract.PublishedState
    private let readState: () -> PermissionGrantContract.PublishedState

    init(readState: @escaping () -> PermissionGrantContract.PublishedState = {
        .init(accessibility: AXIsProcessTrusted(),
              screenCapture: CGPreflightScreenCaptureAccess(),
              microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    }) {
        self.readState = readState
        state = readState()
    }

    var accessibility: Bool { state.accessibility }
    var screenCapture: Bool { state.screenCapture }
    var microphone: Bool { state.microphone }

    func updatePermissions() {
        // Publish a complete snapshot before consumers render or start capture.
        // Passive checks never capture a window or request optional access.
        state = readState()
    }
}

@MainActor
final class LibreReverseQuickStartWindowController: NSWindowController, NSWindowDelegate {
    private let permissions: LibreReversePermissionsController
    private let startCapture: () -> Void
    private let recordingStatus: () -> PermissionGrantContract.RecordingStatus
    private let defaults: UserDefaults
    private var progress: PermissionGrantContract.SetupProgress
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var requestedScreen = false
    private var requestedAccessibility = false
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let screenRow = PermissionRow(title: "Screen Recording", detail: "Required · Saves your screen so you can search and replay it.")
    private let accessibilityRow = PermissionRow(title: "Accessibility", detail: "Required · Adds the active app, window title, and web address to your history.")
    private let microphoneRow = PermissionRow(title: "Microphone", detail: "Optional · Adds your voice to meeting recordings and transcripts. Screen history works without it. Meeting system audio uses Screen Recording access.")
    private let restartButton = NSButton(title: "Restart LibreReverse", target: nil, action: nil)

    static let completionDefaultsKey = "LibreReverse.setup.completed"
    static let showInDockDefaultsKey = LibreReverseCaptureSettingsPreferences.showInDockKey

    init(
        permissions: LibreReversePermissionsController,
        startWhenReady: Bool = true,
        defaults: UserDefaults = .standard,
        recordingStatus: @escaping () -> PermissionGrantContract.RecordingStatus = { .waiting },
        startCapture: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.startCapture = startCapture
        self.recordingStatus = recordingStatus
        self.defaults = defaults
        progress = .init(startWhenReady: startWhenReady)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set up LibreReverse"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.115, alpha: 1)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.center()
        super.init(window: window)
        window.delegate = self
        installContent()
    }

    required init?(coder: NSCoder) { nil }

    func open() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        startObserving()
    }

    /// Also called after returning from System Settings and native prompts.
    func refresh() {
        permissions.updatePermissions()
        if progress.shouldStart(permissions: permissions.state) {
            defaults.set(true, forKey: Self.completionDefaultsKey)
            startCapture()
        }
        screenRow.update(granted: permissions.screenCapture, actionTitle: requestedScreen ? "Open Settings" : "Allow")
        accessibilityRow.update(granted: permissions.accessibility, actionTitle: requestedAccessibility ? "Open Settings" : "Allow")
        microphoneRow.update(granted: permissions.microphone, actionTitle: "Allow")
        let status = recordingStatus()
        statusLabel.textColor = .secondaryLabelColor
        if !permissions.state.allRequiredPermissionsGranted {
            statusLabel.stringValue = "Recording starts when both required permissions are allowed. You can leave this window open while you enable access in System Settings."
        } else {
            switch status {
            case .recording:
                statusLabel.stringValue = "✓ Recording is on. You can configure optional microphone access now or later in Settings."
                statusLabel.textColor = .systemBlue
            case .starting:
                statusLabel.stringValue = "Permissions are ready. Starting recording…"
            case .paused:
                statusLabel.stringValue = "Permissions are ready. Recording is paused; resume it from the menu bar when you’re ready."
            case .failed(let message):
                statusLabel.stringValue = "Permissions are ready, but recording could not start: \(message)"
                statusLabel.textColor = .systemRed
            case .waiting:
                statusLabel.stringValue = "Permissions are ready. Waiting for recording to start…"
            }
        }
        if requestedScreen && !permissions.screenCapture {
            statusLabel.stringValue += " If macOS asks you to quit and reopen after enabling access, use Restart LibreReverse below."
        }
        restartButton.isHidden = !(requestedScreen && !permissions.screenCapture)
        if window?.isVisible != true && !progress.startPending { stopObserving() }
    }

    private func startObserving() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    private func stopObserving() {
        timer?.invalidate()
        timer = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    func windowWillClose(_ notification: Notification) {
        // Finishing a grant in System Settings still resumes startup even if
        // the user explicitly closes this window first.
        if !progress.startPending { stopObserving() }
        let showInDock = defaults.bool(forKey: Self.showInDockDefaultsKey)
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    private func installContent() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Set up recording")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        let introduction = NSTextField(wrappingLabelWithString: "LibreReverse saves your screen history on this Mac. Allow the two required permissions to begin. You can pause recording at any time from the menu bar.")
        introduction.font = .systemFont(ofSize: 13)
        introduction.textColor = .secondaryLabelColor
        screenRow.button.target = self
        screenRow.button.action = #selector(requestScreenCapture)
        accessibilityRow.button.target = self
        accessibilityRow.button.action = #selector(requestAccessibility)
        microphoneRow.button.target = self
        microphoneRow.button.action = #selector(requestMicrophone)
        statusLabel.font = .systemFont(ofSize: 12)
        restartButton.target = self
        restartButton.action = #selector(restartApplication)
        restartButton.bezelStyle = .rounded
        restartButton.toolTip = "If macOS asks you to quit and reopen after allowing Screen Recording, restart here. Setup will continue automatically."
        let done = NSButton(title: "Done", target: self, action: #selector(dismissSetup))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [restartButton, NSView(), done])
        footer.spacing = 12
        let stack = NSStackView(views: [title, introduction, screenRow, accessibilityRow, microphoneRow, statusLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        ])
        for view in [introduction, screenRow, accessibilityRow, microphoneRow, statusLabel, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @objc private func requestScreenCapture() {
        if requestedScreen {
            openSettings("Privacy_ScreenCapture")
        } else {
            requestedScreen = true
            if !CGRequestScreenCaptureAccess() { openSettings("Privacy_ScreenCapture") }
        }
        refresh()
    }

    @objc private func requestAccessibility() {
        if requestedAccessibility {
            openSettings("Privacy_Accessibility")
        } else {
            requestedAccessibility = true
            // Register this app with TCC and present macOS's own prompt. Merely
            // opening the pane can leave a first-run app absent from its list.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        refresh()
    }

    @objc private func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        case .denied, .restricted:
            openSettings("Privacy_Microphone")
        default: refresh()
        }
    }

    private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func dismissSetup() { close() }

    @objc private func restartApplication() {
        // Wait for graceful termination and release of the library lock before
        // opening the replacement process. Bundle paths are positional arguments.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$2\"", "librereverse-restart", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do {
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            statusLabel.stringValue = "Could not restart automatically. Quit LibreReverse from its menu, then open it again."
        }
    }
}

@MainActor
private final class PermissionRow: NSStackView {
    let button = NSButton(title: "", target: nil, action: nil)
    private let indicator = NSTextField(labelWithString: "○")
    private let permissionTitle: String

    init(title: String, detail: String) {
        permissionTitle = title
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .top
        spacing = 12
        indicator.font = .systemFont(ofSize: 15, weight: .semibold)
        indicator.alignment = .center
        indicator.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .medium)
        let description = NSTextField(wrappingLabelWithString: detail)
        description.font = .systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.widthAnchor.constraint(equalToConstant: 112).isActive = true
        button.setAccessibilityLabel("Allow \(title)")
        let body = NSStackView(views: [heading, description])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        addArrangedSubview(indicator)
        addArrangedSubview(body)
        addArrangedSubview(button)
        button.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        body.setContentHuggingPriority(.defaultLow, for: .horizontal)
        description.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    func update(granted: Bool, actionTitle: String) {
        indicator.stringValue = granted ? "✓" : "○"
        indicator.textColor = granted ? .systemBlue : .tertiaryLabelColor
        indicator.setAccessibilityLabel(granted ? "Allowed" : "Not allowed")
        button.title = granted ? "Allowed" : actionTitle
        button.setAccessibilityLabel(granted ? "\(permissionTitle), allowed" : "\(actionTitle) \(permissionTitle)")
        button.isEnabled = !granted
    }
}
#endif
