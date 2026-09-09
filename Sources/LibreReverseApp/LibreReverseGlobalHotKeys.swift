#if os(macOS)
import AppKit
import Carbon
import Foundation
import LibreReverseCore

enum LibreReverseShortcutAction: String, Codable, CaseIterable, Sendable {
    case toggleCapture
    case openTimeline
    case askRewind
    case dailyRecap
    case starCurrentMoment

    var carbonIdentifier: UInt32 {
        switch self {
        case .starCurrentMoment: 1
        case .askRewind: 2
        case .dailyRecap: 3
        case .openTimeline: 4
        case .toggleCapture: 5
        }
    }

    static func action(carbonIdentifier: UInt32) -> Self? {
        allCases.first { $0.carbonIdentifier == carbonIdentifier }
    }

    var title: String {
        switch self {
        case .toggleCapture: "Start / Stop Meeting"
        case .openTimeline: "Search LibreReverse"
        case .askRewind: "Ask LibreReverse"
        case .dailyRecap: "Daily Recap"
        case .starCurrentMoment: "Star Moment"
        }
    }
}

struct LibreReverseShortcutBinding: Codable, Equatable, Hashable, Sendable {
    let virtualKeyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    var displayName: String {
        var pieces: [String] = []
        if modifiers & UInt32(controlKey) != 0 { pieces.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { pieces.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { pieces.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { pieces.append("⌘") }
        pieces.append(keyLabel)
        return pieces.joined()
    }

    static func from(event: NSEvent) -> Self? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard modifiers & (UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)) != 0
        else { return nil }
        let label: String
        switch event.keyCode {
        case 36: label = "Return"
        case 48: label = "Tab"
        case 49: label = "Space"
        case 51: label = "Delete"
        case 53: label = "Escape"
        case 123: label = "←"
        case 124: label = "→"
        case 125: label = "↓"
        case 126: label = "↑"
        default:
            guard let characters = event.charactersIgnoringModifiers,
                  let first = characters.first else { return nil }
            label = String(first).uppercased()
        }
        return .init(
            virtualKeyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            keyLabel: label
        )
    }
}

enum LibreReverseShortcutSettingsError: Error, LocalizedError, Equatable {
    case duplicate(LibreReverseShortcutAction, LibreReverseShortcutAction)
    case unsafe(LibreReverseShortcutAction)

    var errorDescription: String? {
        switch self {
        case let .duplicate(first, second):
            "That shortcut is already assigned to \(first.title); choose a different shortcut for \(second.title)."
        case let .unsafe(action):
            "\(action.title) must include Command, Option, or Control."
        }
    }
}

struct LibreReverseShortcutSettings: Codable, Equatable, Sendable {
    var toggleCapture: LibreReverseShortcutBinding?
    var openTimeline: LibreReverseShortcutBinding?
    var askRewind: LibreReverseShortcutBinding?
    var dailyRecap: LibreReverseShortcutBinding?
    var starCurrentMoment: LibreReverseShortcutBinding?
    var scrollToRewindEnabled: Bool

    static let defaults = LibreReverseShortcutSettings(
        toggleCapture: .init(virtualKeyCode: 46, modifiers: UInt32(controlKey | optionKey | cmdKey), keyLabel: "M"),
        openTimeline: .init(
            virtualKeyCode: 49,
            modifiers: GlobalHotKeyContract.commandShiftModifiers,
            keyLabel: "Space"
        ),
        askRewind: .init(
            virtualKeyCode: 44,
            modifiers: GlobalHotKeyContract.commandShiftModifiers,
            keyLabel: "/"
        ),
        dailyRecap: .init(
            virtualKeyCode: 41,
            modifiers: GlobalHotKeyContract.commandShiftModifiers,
            keyLabel: ";"
        ),
        starCurrentMoment: .init(
            virtualKeyCode: 1,
            modifiers: GlobalHotKeyContract.commandShiftModifiers,
            keyLabel: "S"
        ),
        scrollToRewindEnabled: ScrollToRewindInvocation.defaultEnabled
    )

    func binding(for action: LibreReverseShortcutAction) -> LibreReverseShortcutBinding? {
        switch action {
        case .toggleCapture: toggleCapture
        case .openTimeline: openTimeline
        case .askRewind: askRewind
        case .dailyRecap: dailyRecap
        case .starCurrentMoment: starCurrentMoment
        }
    }

    mutating func setBinding(
        _ binding: LibreReverseShortcutBinding?,
        for action: LibreReverseShortcutAction
    ) {
        switch action {
        case .toggleCapture: toggleCapture = binding
        case .openTimeline: openTimeline = binding
        case .askRewind: askRewind = binding
        case .dailyRecap: dailyRecap = binding
        case .starCurrentMoment: starCurrentMoment = binding
        }
    }

    func validated() throws -> Self {
        var owner: [UInt64: LibreReverseShortcutAction] = [:]
        for action in LibreReverseShortcutAction.allCases {
            guard let binding = binding(for: action) else { continue }
            guard binding.modifiers
                    & (UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)) != 0
            else { throw LibreReverseShortcutSettingsError.unsafe(action) }
            let chord = UInt64(binding.modifiers) << 32
                | UInt64(binding.virtualKeyCode)
            if let first = owner[chord] {
                throw LibreReverseShortcutSettingsError.duplicate(first, action)
            }
            owner[chord] = action
        }
        return self
    }
}

enum LibreReverseShortcutPreferences {
    static let key = "LibreReverse.keyboardShortcuts.v1"

    static func load(from defaults: UserDefaults = .standard) -> LibreReverseShortcutSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(
                LibreReverseShortcutSettings.self,
                from: data
              ),
              (try? decoded.validated()) != nil else {
            return LibreReverseShortcutSettings.defaults
        }
        return decoded
    }

    static func save(
        _ settings: LibreReverseShortcutSettings,
        to defaults: UserDefaults = .standard
    ) throws {
        defaults.set(try JSONEncoder().encode(settings.validated()), forKey: key)
    }
}

enum LibreReverseGlobalHotKeyError: Error, LocalizedError, Equatable {
    case installEventHandler(OSStatus)
    case register(action: LibreReverseShortcutAction, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case let .installEventHandler(status):
            "LibreReverse could not install its shortcut handler (\(status))."
        case let .register(action, status):
            "\(action.title) could not use that shortcut, usually because another app already owns it (\(status))."
        }
    }
}

final class LibreReverseGlobalHotKeyRegistrar {
    typealias ActionHandler = (LibreReverseShortcutAction) -> Void

    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    fileprivate var actionHandler: ActionHandler?

    func start(
        settings: LibreReverseShortcutSettings,
        actionHandler: @escaping ActionHandler
    ) throws {
        stop()
        let settings = try settings.validated()
        self.actionHandler = actionHandler
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installedHandler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            openRewindGlobalHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &installedHandler
        )
        guard handlerStatus == noErr, let installedHandler else {
            self.actionHandler = nil
            throw LibreReverseGlobalHotKeyError.installEventHandler(handlerStatus)
        }
        eventHandler = installedHandler

        for action in LibreReverseShortcutAction.allCases {
            guard let binding = settings.binding(for: action) else { continue }
            var hotKey: EventHotKeyRef?
            let identifier = EventHotKeyID(
                signature: OSType(GlobalHotKeyContract.signature),
                id: action.carbonIdentifier
            )
            let status = RegisterEventHotKey(
                binding.virtualKeyCode,
                binding.modifiers,
                identifier,
                GetApplicationEventTarget(),
                0,
                &hotKey
            )
            guard status == noErr, let hotKey else {
                stop()
                throw LibreReverseGlobalHotKeyError.register(
                    action: action,
                    status: status
                )
            }
            hotKeys.append(hotKey)
        }
    }

    func stop() {
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        hotKeys.removeAll(keepingCapacity: false)
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        actionHandler = nil
    }

    deinit { stop() }
}

private let openRewindGlobalHotKeyHandler: EventHandlerUPP = {
    _, event, userData -> OSStatus in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr,
          identifier.signature == OSType(GlobalHotKeyContract.signature),
          let action = LibreReverseShortcutAction.action(
            carbonIdentifier: identifier.id
          ) else { return OSStatus(eventNotHandledErr) }
    let registrar = Unmanaged<LibreReverseGlobalHotKeyRegistrar>
        .fromOpaque(userData)
        .takeUnretainedValue()
    registrar.actionHandler?(action)
    return noErr
}
#endif
