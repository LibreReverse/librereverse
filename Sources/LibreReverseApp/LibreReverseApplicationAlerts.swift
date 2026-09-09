#if os(macOS)
import AppKit

/// Shared production alert construction also lets isolated previews inspect the
/// actual app dialogs without starting a recorder, updater, or library session.
@MainActor
enum LibreReverseApplicationAlerts {
    enum Presentation {
        case updatesUnavailable
        case currentVersion(String)
        case availableUpdate(version: String, releaseNotes: Bool)
        case verifiedUpdate
        case updateError(String)
        case libraryError(String)
        case meetingDetected(String?)
        case meetingTitle(initialTitle: String, message: String)
    }

    static func make(_ presentation: Presentation) -> NSAlert {
        let alert = NSAlert()
        var buttons = ["OK"]
        switch presentation {
        case .updatesUnavailable:
            alert.messageText = "Updates unavailable"
            alert.informativeText = "Automatic updates are available in release builds."
        case .currentVersion(let version):
            alert.messageText = "LibreReverse is up to date"
            alert.informativeText = "Version \(version)"
        case .availableUpdate(let version, let releaseNotes):
            alert.messageText = "LibreReverse \(version) is available"
            alert.informativeText = "Download the signed release, then replace the app in Applications. Your history stays in place."
            buttons = ["Download", "Later"] + (releaseNotes ? ["Release Notes"] : [])
        case .verifiedUpdate:
            alert.messageText = "Update downloaded and verified"
            alert.informativeText = "Quit LibreReverse and replace it in Applications to finish. Your history stays in place."
        case .updateError(let detail):
            alert.messageText = "Couldn’t check for updates"
            alert.informativeText = "Check your connection and try again.\n\n" + detail
            alert.alertStyle = .warning
        case .libraryError(let detail):
            alert.messageText = "Couldn’t open your library"
            alert.informativeText = detail
            alert.alertStyle = .warning
        case .meetingTitle(let initialTitle, let message):
            alert.messageText = "Meeting title"
            alert.informativeText = message
            buttons = ["Save", "Cancel"]
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.stringValue = initialTitle
            field.placeholderString = "Ad hoc meeting"
            field.setAccessibilityLabel("Meeting title")
            alert.accessoryView = field
        case .meetingDetected(let title):
            alert.messageText = "Record this meeting?"
            alert.informativeText = (title.map { "“\($0)”\n" } ?? "") + "Screen and audio will be recorded locally."
            buttons = ["Record", "Not Now"]
        }
        for title in buttons { alert.addButton(withTitle: title) }
        alert.window.appearance = NSAppearance(named: .darkAqua)
        return alert
    }
}
#endif
