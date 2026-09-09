#if os(macOS)
import AppKit
import Foundation
import LibreReverseCore
import UniformTypeIdentifiers

enum LibreReverseOCRLanguageMode: String, CaseIterable, Equatable {
    case standard
    case additional

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .additional: return "Additional Language Support"
        }
    }
}

struct LibreReverseGeneralSettingsSnapshot: Equatable {
    var launchAtLogin: Bool
    var remindWhenPaused: Bool
    var showInDock: Bool
}

struct LibreReverseExcludedApplication: Equatable, Identifiable {
    let bundleIdentifier: String
    let name: String
    let applicationURL: URL?
    let isRunningProcess: Bool
    let isInstalledApplication: Bool

    var id: String { bundleIdentifier }
    var icon: NSImage {
        guard let applicationURL else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }
}

struct LibreReverseScreenSettingsSnapshot: Equatable {
    var omittedBundleIdentifiers: Set<String>
    var excludePrivateWindows: Bool
    var ocrLanguageMode: LibreReverseOCRLanguageMode
    var showRunningProcesses: Bool
    var applications: [LibreReverseExcludedApplication]
}

enum LibreReverseCaptureSettingsPreferences {
    static let launchAtLoginKey = "LibreReverse.launchAtLogin"
    static let remindWhenPausedKey = "LibreReverse.remindWhenPaused"
    static let showInDockKey = "LibreReverse.showInDock"
    static let omittedApplicationsKey = "LibreReverse.omittedAppBundleIdentifiers"
    static let excludePrivateWindowsKey = "LibreReverse.excludeIncognito"
    static let ocrLanguageModeKey = "LibreReverse.ocrLanguageMode"
    static let showRunningProcessesKey = "LibreReverse.showRunningProcesses"

    static func remindWhenPaused(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: remindWhenPausedKey) == nil
            ? true : defaults.bool(forKey: remindWhenPausedKey)
    }

    static func excludePrivateWindows(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: excludePrivateWindowsKey) == nil
            ? CapturePrivacySettings.defaultExcludeIncognito(
                preferredLanguages: Locale.preferredLanguages
            )
            : defaults.bool(forKey: excludePrivateWindowsKey)
    }

    static func ocrLanguageMode(_ defaults: UserDefaults = .standard)
        -> LibreReverseOCRLanguageMode
    {
        defaults.string(forKey: ocrLanguageModeKey)
            .flatMap(LibreReverseOCRLanguageMode.init(rawValue:)) ?? .standard
    }

    static func privacySettings(
        _ defaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> CapturePrivacySettings {
        let excludePrivateWindows = defaults.object(forKey: excludePrivateWindowsKey) == nil
            ? CapturePrivacySettings.defaultExcludeIncognito(
                preferredLanguages: preferredLanguages
            )
            : defaults.bool(forKey: excludePrivateWindowsKey)
        return .init(
            omittedAppBundleIdentifiers: Set(
                defaults.stringArray(forKey: omittedApplicationsKey) ?? []
            ),
            excludeIncognito: excludePrivateWindows
        )
    }
}

enum LibreReversePausedReminderContract {
    static let identifier = "local.librereverse.capture-paused"
    static let delay: TimeInterval = 3_600
    static let title = "LibreReverse is paused"
    static let body = "Screen history has not been recorded for one hour. Resume capture from the menu bar when you are ready."
}

enum LibreReverseApplicationCatalog {
    static func applications(
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared
    ) -> [LibreReverseExcludedApplication] {
        var values: [String: LibreReverseExcludedApplication] = [:]
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url),
                    let identifier = bundle.bundleIdentifier,
                    !identifier.isEmpty
                else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                values[identifier] = .init(
                    bundleIdentifier: identifier,
                    name: name,
                    applicationURL: url,
                    isRunningProcess: false,
                    isInstalledApplication: true
                )
            }
        }
        for application in workspace.runningApplications {
            guard let identifier = application.bundleIdentifier,
                identifier != Bundle.main.bundleIdentifier
            else { continue }
            let existing = values[identifier]
            values[identifier] = .init(
                bundleIdentifier: identifier,
                name: application.localizedName ?? existing?.name ?? identifier,
                applicationURL: application.bundleURL ?? existing?.applicationURL,
                isRunningProcess: true,
                isInstalledApplication: existing?.isInstalledApplication == true
            )
        }
        return values.values.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame
                ? $0.bundleIdentifier < $1.bundleIdentifier
                : comparison == .orderedAscending
        }
    }
}

@MainActor
final class LibreReverseGeneralSettingsViewController: NSViewController {
    private let showSetup: () -> Void
    private let snapshot: () -> LibreReverseGeneralSettingsSnapshot
    private let updateLaunchAtLogin: (Bool) throws -> Void
    private let updateRemindWhenPaused: (Bool) -> Void
    private let updateShowInDock: (Bool) -> Void
    private let launchButton = NSSwitch()
    private let reminderButton = NSSwitch()
    private let dockButton = NSSwitch()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init(
        snapshot: @escaping () -> LibreReverseGeneralSettingsSnapshot,
        updateLaunchAtLogin: @escaping (Bool) throws -> Void,
        updateRemindWhenPaused: @escaping (Bool) -> Void,
        updateShowInDock: @escaping (Bool) -> Void,
        showSetup: @escaping () -> Void = {}
    ) {
        self.showSetup = showSetup
        self.snapshot = snapshot
        self.updateLaunchAtLogin = updateLaunchAtLogin
        self.updateRemindWhenPaused = updateRemindWhenPaused
        self.updateShowInDock = updateShowInDock
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: "General")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = true
        launchButton.target = self
        launchButton.action = #selector(launchChanged)
        reminderButton.target = self
        reminderButton.action = #selector(reminderChanged)
        dockButton.target = self
        dockButton.action = #selector(dockChanged)
        let rows: [(String, NSSwitch, String)] = [
            ("Open at login", launchButton, "Launch LibreReverse when you sign in."),
            ("Remind when paused", reminderButton,
             "After screen capture is paused for one hour, send one local reminder. Meeting recording is unaffected."),
            ("Show in Dock", dockButton, "The menu-bar icon remains available when the Dock icon is hidden."),
        ]
        let stack = NSStackView(views: [title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setCustomSpacing(24, after: title)
        for (text, control, help) in rows {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13)
            label.toolTip = help
            control.controlSize = .small
            control.setAccessibilityLabel(text)
            control.setAccessibilityHelp(help)
            control.toolTip = help
            let row = NSStackView(views: [label, NSView(), control])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.heightAnchor.constraint(equalToConstant: 56).isActive = true
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            let rule = separator()
            stack.addArrangedSubview(rule)
            rule.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let setupButton = NSButton(title: "Review setup and permissions…", target: self, action: #selector(openSetup))
        setupButton.isBordered = false
        setupButton.alignment = .left
        setupButton.font = .systemFont(ofSize: 13)
        setupButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        setupButton.imagePosition = .imageTrailing
        setupButton.contentTintColor = .labelColor
        stack.addArrangedSubview(setupButton)
        setupButton.heightAnchor.constraint(equalToConstant: 56).isActive = true
        stack.addArrangedSubview(statusLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -30),
        ])
        refresh()
    }

    @objc private func openSetup() { showSetup() }

    func refresh() {
        let value = snapshot()
        launchButton.state = value.launchAtLogin ? .on : .off
        reminderButton.state = value.remindWhenPaused ? .on : .off
        dockButton.state = value.showInDock ? .on : .off
    }

    @objc private func launchChanged() {
        do {
            try updateLaunchAtLogin(launchButton.state == .on)
            statusLabel.isHidden = true
        } catch {
            launchButton.state = launchButton.state == .on ? .off : .on
            statusLabel.stringValue = "Launch at login could not be changed: \(error.localizedDescription)"
            statusLabel.isHidden = false
        }
    }

    @objc private func reminderChanged() {
        updateRemindWhenPaused(reminderButton.state == .on)
    }

    @objc private func dockChanged() { updateShowInDock(dockButton.state == .on) }
}

@MainActor
final class LibreReverseSettingsInfoButton: NSButton {
    private let detail: String
    private var popover: NSPopover?
    init(_ detail: String, identifier: String? = nil) {
        self.detail = detail
        super.init(frame: .zero)
        bezelStyle = .helpButton
        title = ""
        target = self
        action = #selector(showDetails)
        toolTip = detail
        setAccessibilityLabel("More information")
        if let identifier { setAccessibilityIdentifier(identifier) }
    }
    required init?(coder: NSCoder) { nil }
    @objc private func showDetails() {
        let text = NSTextField(wrappingLabelWithString: detail)
        text.font = .systemFont(ofSize: 12)
        text.translatesAutoresizingMaskIntoConstraints = false
        let controller = NSViewController()
        controller.view = NSView()
        controller.view.addSubview(text)
        NSLayoutConstraint.activate([
            text.widthAnchor.constraint(equalToConstant: 310),
            text.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 14),
            text.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 14),
            text.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -14),
            text.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -14),
        ])
        let panel = NSPopover()
        panel.behavior = .transient
        panel.contentViewController = controller
        panel.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        popover = panel
    }
}

@MainActor
final class LibreReverseScreenSettingsViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate
{
    private let snapshot: () -> LibreReverseScreenSettingsSnapshot
    private let updateOmittedApplications: (Set<String>) -> Void
    private let updateExcludePrivateWindows: (Bool) -> Void
    private let updateOCRLanguageMode: (LibreReverseOCRLanguageMode) -> Void
    private let updateShowRunningProcesses: (Bool) -> Void
    private var state: LibreReverseScreenSettingsSnapshot?
    private var visibleApplications: [LibreReverseExcludedApplication] = []
    private let tableView = NSTableView()
    private let runningButton = NSButton(checkboxWithTitle: "Show Running Processes", target: nil, action: nil)
    private let privateButton = NSButton(
        checkboxWithTitle: "Do not record Incognito and Private windows", target: nil, action: nil)
    private let languagePopup = NSPopUpButton()

    init(
        snapshot: @escaping () -> LibreReverseScreenSettingsSnapshot,
        updateOmittedApplications: @escaping (Set<String>) -> Void,
        updateExcludePrivateWindows: @escaping (Bool) -> Void,
        updateOCRLanguageMode: @escaping (LibreReverseOCRLanguageMode) -> Void,
        updateShowRunningProcesses: @escaping (Bool) -> Void
    ) {
        self.snapshot = snapshot
        self.updateOmittedApplications = updateOmittedApplications
        self.updateExcludePrivateWindows = updateExcludePrivateWindows
        self.updateOCRLanguageMode = updateOCRLanguageMode
        self.updateShowRunningProcesses = updateShowRunningProcesses
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        let privacy = NSTextField(wrappingLabelWithString:
            "Screen"
        )
        privacy.font = .systemFont(ofSize: 22, weight: .semibold)
        let limitation = NSTextField(wrappingLabelWithString:
            "Exclusions apply to future captures. Mission Control, browser extensions, and incognito picture-in-picture can reveal otherwise excluded content. When private-window exclusion is on, recognized browser windows whose privacy cannot be verified are also omitted, including Dia. Detection covers supported browsers only; exclude other browsers explicitly in this list."
        )
        let exclusionDetails = limitation.stringValue
        limitation.stringValue = "Control which apps and private windows are captured."
        limitation.toolTip = exclusionDetails
        limitation.setAccessibilityHelp(exclusionDetails)
        limitation.textColor = .secondaryLabelColor
        limitation.font = .systemFont(ofSize: 12)
        let excludeTitle = NSTextField(labelWithString: "Exclude Apps")
        excludeTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        let excludeHelp = NSTextField(wrappingLabelWithString:
            "Selected apps are excluded from future captures."
        )
        excludeHelp.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 38
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1)
        tableView.setAccessibilityLabel("Applications excluded from screen recording")
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.masksToBounds = true
        scroll.heightAnchor.constraint(equalToConstant: 250).isActive = true

        runningButton.target = self
        runningButton.action = #selector(runningChanged)
        privateButton.target = self
        privateButton.action = #selector(privateChanged)
        languagePopup.addItems(withTitles: LibreReverseOCRLanguageMode.allCases.map(\.title))
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        let languageHelp = NSTextField(wrappingLabelWithString:
            "Standard uses faster recognition for English, French, Italian, German, Spanish, and Portuguese. Small or stylized text may be less accurate. Additional Language Support uses more accurate recognition and enables Chinese, Korean, Japanese, Ukrainian, and other supported languages, using more system resources."
        )
        let languageDetails = languageHelp.stringValue
        languageHelp.stringValue = "Standard is faster. Additional languages use more resources."
        languageHelp.toolTip = languageDetails
        languageHelp.setAccessibilityHelp(languageDetails)
        languageHelp.textColor = .secondaryLabelColor
        languageHelp.font = .systemFont(ofSize: 12)
        let exclusionInfo = NSStackView(views: [limitation, LibreReverseSettingsInfoButton(exclusionDetails, identifier: "settings.screen.privacy-help")])
        exclusionInfo.spacing = 8
        let languageInfo = NSStackView(views: [languageHelp, LibreReverseSettingsInfoButton(languageDetails, identifier: "settings.screen.language-help")])
        languageInfo.spacing = 8
        let appsSeparator = separator()
        let privacySeparator = separator()
        let languageSeparator = separator()
        let stack = NSStackView(views: [
            privacy, exclusionInfo, appsSeparator, excludeTitle, excludeHelp, scroll,
            runningButton, privacySeparator, privateButton, languageSeparator,
            labeledRow("Text Recognition:", languagePopup), languageInfo,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 34),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -34),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            appsSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            privacySeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            languageSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        refresh()
    }

    func refresh() {
        let value = snapshot()
        state = value
        runningButton.state = value.showRunningProcesses ? .on : .off
        privateButton.state = value.excludePrivateWindows ? .on : .off
        languagePopup.selectItem(at: LibreReverseOCRLanguageMode.allCases.firstIndex(
            of: value.ocrLanguageMode
        ) ?? 0)
        visibleApplications = value.applications.filter {
            value.showRunningProcesses || $0.isInstalledApplication
                || value.omittedBundleIdentifiers.contains($0.bundleIdentifier)
        }
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleApplications.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard visibleApplications.indices.contains(row), let state else { return nil }
        let application = visibleApplications[row]
        let cell = NSView()
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(applicationChanged(_:)))
        checkbox.tag = row
        checkbox.state = state.omittedBundleIdentifiers.contains(application.bundleIdentifier)
            ? .on : .off
        checkbox.setAccessibilityLabel("Exclude \(application.name)")
        let icon = NSImageView(image: application.icon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: application.name)
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = application.bundleIdentifier
        cell.toolTip = application.bundleIdentifier
        let labels = NSStackView(views: [name])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        for child in [checkbox, icon, labels] {
            child.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(child)
        }
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 7),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 25),
            icon.heightAnchor.constraint(equalToConstant: 25),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            labels.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func applicationChanged(_ sender: NSButton) {
        guard visibleApplications.indices.contains(sender.tag), var state else { return }
        let identifier = visibleApplications[sender.tag].bundleIdentifier
        if sender.state == .on {
            state.omittedBundleIdentifiers.insert(identifier)
        } else {
            state.omittedBundleIdentifiers.remove(identifier)
        }
        self.state = state
        updateOmittedApplications(state.omittedBundleIdentifiers)
    }

    @objc private func runningChanged() {
        updateShowRunningProcesses(runningButton.state == .on)
        refresh()
    }

    @objc private func privateChanged() {
        updateExcludePrivateWindows(privateButton.state == .on)
        refresh()
    }

    @objc private func languageChanged() {
        let index = languagePopup.indexOfSelectedItem
        guard LibreReverseOCRLanguageMode.allCases.indices.contains(index) else { return }
        updateOCRLanguageMode(LibreReverseOCRLanguageMode.allCases[index])
        refresh()
    }
}

private func labeledRow(_ label: String, _ control: NSView) -> NSView {
    let title = NSTextField(labelWithString: label)
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    title.alignment = .right
    title.widthAnchor.constraint(equalToConstant: 145).isActive = true
    let row = NSStackView(views: [title, control])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 12
    return row
}

private func separator() -> NSView {
    let separator = NSBox()
    separator.boxType = .separator
    separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return separator
}
#endif
