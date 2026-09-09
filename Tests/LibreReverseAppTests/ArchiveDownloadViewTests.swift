#if os(macOS)
import AppKit
import XCTest
@testable import LibreReverseApp

final class ArchiveDownloadEstimateTests: XCTestCase {
    func testWaitEstimateNeedsTransferEvidenceAndOnlyDescribesCurrentStep() {
        var estimate = LibreReverseDownloadEstimate()
        XCTAssertEqual(estimate.status(now: 0), "Estimating time remaining…")
        estimate.update(completed: 0, total: 10_000_000, now: 0)
        estimate.update(completed: 1_000_000, total: 10_000_000, now: 10)
        XCTAssertEqual(estimate.fraction, 0.1)
        XCTAssertEqual(estimate.status(now: 10), "10% · About 2 min for this step")
        XCTAssertEqual(estimate.status(now: 26), "10% · Waiting for download…")
    }

    func testCompletionWaitsForInstallationAndRetryDiscardsOldThroughput() {
        var estimate = LibreReverseDownloadEstimate()
        estimate.update(completed: 0, total: 10_000_000, now: 0)
        estimate.update(completed: 10_000_000, total: 10_000_000, now: 10)
        XCTAssertEqual(estimate.status(now: 30), "Finishing up…")
        estimate.update(completed: 0, total: 10_000_000, now: 31)
        XCTAssertEqual(estimate.status(now: 31), "0% · Estimating time remaining…")
        estimate.update(completed: 500_000, total: 1_000_000, now: 35)
        XCTAssertEqual(estimate.status(now: 35), "50% · Estimating time remaining…")
    }

    func testUnknownAndInvalidTotalsNeverInventAPercentOrWait() {
        var estimate = LibreReverseDownloadEstimate()
        estimate.update(completed: -4, total: 0, now: 0)
        XCTAssertNil(estimate.fraction)
        XCTAssertEqual(estimate.status(now: 100), "Estimating time remaining…")
    }
}

@MainActor
final class ArchiveDownloadViewTests: XCTestCase {
    func testDownloadStagesResetProgressAndKeepActionsCentered() throws {
        let view = LibreReverseArchiveDownloadView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        let now = ProcessInfo.processInfo.systemUptime
        view.appearance = NSAppearance(named: .darkAqua)
        view.detailLabel.stringValue = "Download recordings for September 4, 9–10 AM to view them here. The first download takes a little longer."
        view.layoutSubtreeIfNeeded()
        let buttonFrame = view.downloadButton.convert(view.downloadButton.bounds, to: view)
        XCTAssertEqual(buttonFrame.midX, view.bounds.midX, accuracy: 1)
        XCTAssertEqual(buttonFrame.height, 36, accuracy: 1)
        XCTAssertFalse(view.downloadButton.isHidden)
        try snapshot(view, name: "archive-ready")

        view.titleLabel.stringValue = "Preparing your history…"
        view.detailLabel.stringValue = "This first step takes a little longer. Then we’ll get your recording."
        view.updateTransfer(id: "history:1", completed: 0, total: 10_000_000, now: now - 120)
        view.updateTransfer(id: "history:1", completed: 4_000_000, total: 10_000_000, now: now)
        XCTAssertTrue(view.downloadButton.isHidden)
        XCTAssertNotNil(view.progress.fraction)
        XCTAssertEqual(try XCTUnwrap(view.progress.fraction), 0.4, accuracy: 0.001)
        XCTAssertEqual(view.statusLabel.stringValue, "40% · About 3 min for this step")
        try snapshot(view, name: "archive-preparing")

        view.titleLabel.stringValue = "Downloading recording…"
        view.detailLabel.stringValue = "Your recording will open as soon as it’s ready."
        view.beginTransfer(id: "video:1")
        XCTAssertNil(view.progress.fraction)
        XCTAssertEqual(view.statusLabel.stringValue, "Estimating time remaining…")
        view.updateTransfer(id: "video:1", completed: 0, total: 10_000_000, now: now - 6)
        view.updateTransfer(id: "video:1", completed: 7_000_000, total: 10_000_000, now: now)
        try snapshot(view, name: "archive-recording")
        view.widthAnchor.constraint(equalToConstant: 360).isActive = true
        window.setContentSize(NSSize(width: 360, height: 480))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.bounds.width, 360, accuracy: 1)
        let progressFrame = view.progress.convert(view.progress.bounds, to: view)
        XCTAssertGreaterThanOrEqual(progressFrame.minX, 24)
        XCTAssertLessThanOrEqual(progressFrame.maxX, view.bounds.width - 24)
        XCTAssertFalse(view.hasAmbiguousLayout)
        try snapshot(view, name: "archive-narrow")

        view.setDownloading(false)
        XCTAssertFalse(view.downloadButton.isHidden)
        XCTAssertTrue(view.progress.isHiddenOrHasHiddenAncestor)
    }

    func testArchiveWaitingAndRecoveryStatesKeepLongCopyAndActionsInsideTheWindow() throws {
        let view = LibreReverseArchiveDownloadView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let states: [(String, String, String, String?, String?)] = [
            ("checking", "Checking download…", "Checking whether this recording is ready.", nil, "One moment…"),
            ("queued", "Download queued", "Your download is saved and will continue automatically.", nil, "No need to keep this window open."),
            ("retrying", "Waiting to resume…", "Your download is saved and will continue automatically.", nil, "No need to keep this window open."),
            ("nearby", "Downloading nearby recordings…", "This recording is in your saved download and will open when ready.", nil, "The download is continuing in the background."),
            ("disconnected", "Archive needs reconnecting", "Your download is saved. Reconnect your archive in Storage settings to continue.", "Reconnect & retry", nil),
            ("missing", "Not in this archive", "This history may be stored with another provider. Switch archives in Storage settings to restore it.", "Open Storage settings", nil),
            ("save-failed", "Couldn’t save this download", "Free some space, then try again.", "Try Again", nil),
            ("connect", "This recording is archived", "Connect an archive in Storage settings to restore this recording.", "Connect archive", nil),
        ]
        for (name, title, detail, action, waiting) in states {
            view.titleLabel.stringValue = title
            view.detailLabel.stringValue = detail
            view.setDownloading(false)
            if let waiting { view.showWaiting(waiting) }
            if let action { view.downloadButton.title = action }
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.downloadButton.isHidden, action == nil)
            for control in [view.titleLabel, view.detailLabel, view.downloadButton, view.statusLabel] where !control.isHiddenOrHasHiddenAncestor {
                let frame = control.convert(control.bounds, to: view)
                XCTAssertTrue(view.bounds.contains(frame), "\(name): visible copy/action must remain inside the viewer")
                XCTAssertGreaterThan(frame.width, 0)
            }
            try snapshot(view, name: "archive-" + name)
        }
    }

    private func snapshot(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["LIBREREVERSE_ARCHIVE_PREVIEW_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["LIBREREVERSE_NATIVE_WINDOW_PREVIEWS"] == "1",
           let window = view.window {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.center()
            window.orderFrontRegardless()
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), root.appendingPathComponent(name + ".png").path]
            try capture.run()
            capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
            window.orderOut(nil)
            return
        }
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent(name + ".png"))
    }
}
#endif
