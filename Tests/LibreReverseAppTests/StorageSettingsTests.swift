#if os(macOS)
import XCTest
import AppKit
@testable import LibreReverseCore
@testable import LibreReverseApp

final class StorageSettingsTests: XCTestCase {
    func testHistorySpanUsesDatabaseDatesInsteadOfCopiedFileDates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("copied-video")
        try Data(repeating: 1, count: 4096).write(to: file)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let interval = DateInterval(start: start, duration: 10 * 86400)
        let before = LibreReverseStorageUsageSnapshot.measure(at: root, recordingInterval: interval)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        let after = LibreReverseStorageUsageSnapshot.measure(at: root, recordingInterval: interval)
        XCTAssertEqual(before, after)
        XCTAssertEqual(after.recordedDays, 11)
        XCTAssertGreaterThan(after.localBytes, 0)
    }
    func testHistoryEstimateSpanIncludesArchivedPeriodsWithoutDoubleCountingOverlap() {
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let primary = DateInterval(start: origin.addingTimeInterval(30 * 86400), duration: 86400)
        let remote = DateInterval(start: origin, duration: 30 * 86400)
        let span = LibreReverseStorageUsageSnapshot.coveringHistoryInterval([primary, remote, remote])
        XCTAssertEqual(span?.start, origin)
        XCTAssertEqual(span?.duration, 31 * 86400)
    }

    func testMissingLibraryMeasuresAsEmpty() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(LibreReverseStorageUsageSnapshot.measure(at: missing), .init(localBytes: 0, recordedDays: 0))
    }

    func testArchiveStatusRejectsOldProviderAndSameProviderReplacement() {
        var selection = LibreReverseArchiveSettingsSelection()
        let initial = selection.generation
        selection.select(.s3Compatible)
        XCTAssertFalse(selection.accepts(generation: initial, provider: .googleDrive))
        XCTAssertFalse(selection.accepts(generation: selection.generation, provider: .googleDrive))
        let s3 = selection.generation
        XCTAssertTrue(selection.accepts(generation: s3, provider: .s3Compatible))
        selection.invalidate()
        XCTAssertFalse(selection.accepts(generation: s3, provider: .s3Compatible))
        selection.select(.googleDrive)
        XCTAssertFalse(selection.accepts(generation: initial, provider: .googleDrive))
    }

    func testS3DraftPreservesSavedSecretOnlyForSameEndpointAndAccessKey() throws {
        let saved = try S3ArchiveConfiguration(endpoint: URL(string: "https://objects.example.test")!,
            bucket: "first", accessKey: "fixture-access", secretKey: "fixture-secret", sessionToken: "fixture-token")
        var draft = LibreReverseS3SettingsDraft(endpoint: saved.endpoint.absoluteString,
            bucket: "second", region: "us-east-1", accessKey: saved.accessKey,
            secretKey: "", sessionToken: "", usesSessionToken: true)
        let reused = try draft.configuration(saved: saved)
        XCTAssertEqual(reused.secretKey, saved.secretKey)
        XCTAssertEqual(reused.sessionToken, saved.sessionToken)
        XCTAssertEqual(reused.bucket, "second")
        draft.usesSessionToken = false
        XCTAssertNil(try draft.configuration(saved: saved).sessionToken)
        draft.endpoint = "https://other.example.test"
        XCTAssertThrowsError(try draft.configuration(saved: saved))
        draft.endpoint = saved.endpoint.absoluteString
        draft.accessKey = "different-access"
        XCTAssertThrowsError(try draft.configuration(saved: saved))
        draft.secretKey = "replacement-fixture-secret"
        XCTAssertEqual(try draft.configuration(saved: saved).secretKey, draft.secretKey)
    }

    private final class EmptyDriveCredentials: GoogleDriveCredentialStore, @unchecked Sendable {
        func data(account: String) throws -> Data? { nil }
        func set(_ data: Data, account: String) throws {}
        func remove(account: String) throws {}
    }

    @MainActor
    func testShutdownRetainsBlockedStorageOperationAndClosesAdmission() async throws {
        _ = NSApplication.shared
        let started = expectation(description: "storage operation entered")
        var resume: CheckedContinuation<LibreReverseStorageUsageSnapshot, Never>?
        var calls = 0
        let manager = GoogleDriveConnectionManager(bundledConfiguration: nil,
            credentialStore: EmptyDriveCredentials())
        let controller = LibreReverseStorageSettingsViewController(manager: manager,
            connectionValidated: { _ in }, connectionAuthorized: { _ in },
            connectionDisconnected: { _ in },
            archiveConnectionSettings: { .init(activeKind: nil, s3Configuration: nil) },
            connectS3: { _ in }, archiveSnapshot: { nil },
            updateArchivePolicy: { _ in }, retryArchive: {},
            storageUsage: {
                calls += 1
                return await withCheckedContinuation { continuation in
                    resume = continuation
                    started.fulfill()
                }
            }, deleteAllData: {})
        _ = controller.view
        controller.refresh()
        await fulfillment(of: [started], timeout: 2)
        let owners = controller.beginShutdown()
        XCTAssertEqual(owners.count, 1)
        XCTAssertTrue(try XCTUnwrap(owners.first).isCancelled)
        controller.refresh()
        XCTAssertEqual(calls, 1)
        // Cancellation alone does not complete this suspended dependency. The
        // returned handle remains available until durable work actually exits.
        try XCTUnwrap(resume).resume(returning: .init(localBytes: 0, recordedDays: 0))
        for owner in owners { await owner.value }
        XCTAssertTrue(controller.beginShutdown().isEmpty)
        controller.refresh()
        await Task.yield()
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testStorageProviderControlsUseSecureFieldsAndScrollAtNormalWindowSize() throws {
        _ = NSApplication.shared
        var activationCount = 0
        let manager = GoogleDriveConnectionManager(bundledConfiguration: nil,
            credentialStore: EmptyDriveCredentials())
        let controller = LibreReverseStorageSettingsViewController(manager: manager,
            connectionValidated: { _ in activationCount += 1 },
            connectionAuthorized: { _ in activationCount += 1 },
            connectionDisconnected: { _ in activationCount += 1 },
            archiveConnectionSettings: { .init(activeKind: nil, s3Configuration: nil) },
            connectS3: { _ in activationCount += 1 }, archiveSnapshot: { nil },
            updateArchivePolicy: { _ in }, retryArchive: {},
            storageUsage: { .init(localBytes: 0, recordedDays: 0) }, deleteAllData: {})
        let root = controller.view
        root.frame = NSRect(x: 0, y: 0, width: 760, height: 570)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(root)
        func control<T: NSView>(_ identifier: String, as type: T.Type) throws -> T {
            try XCTUnwrap(views.first { $0.accessibilityIdentifier() == identifier } as? T)
        }
        let provider = try control("storage.provider", as: NSPopUpButton.self)
        XCTAssertEqual(provider.itemTitles, ["Google Drive", "S3-compatible storage"])
        XCTAssertFalse(provider.pullsDown, "Provider selection is a native popup, not an action menu")
        let s3Fields = try ["endpoint", "bucket", "region", "accessKey", "secretKey", "sessionToken"].map {
            try control("storage.s3.\($0)", as: NSTextField.self)
        }
        XCTAssertTrue(s3Fields.allSatisfy(\.isHiddenOrHasHiddenAncestor),
            "Drive selection must hide every S3 configuration field")
        let driveConnect = try control("storage.googleDrive.connect", as: NSButton.self)
        XCTAssertFalse(driveConnect.isHiddenOrHasHiddenAncestor)
        provider.selectItem(at: 1)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(provider.action), to: provider.target, from: provider))
        XCTAssertEqual(activationCount, 0, "Browsing a provider must not change the active destination")
        let secret = try control("storage.s3.secretKey", as: NSSecureTextField.self)
        let token = try control("storage.s3.sessionToken", as: NSSecureTextField.self)
        XCTAssertTrue(secret.stringValue.isEmpty)
        XCTAssertTrue(token.stringValue.isEmpty)
        XCTAssertFalse(token.isEnabled)
        let connect = try control("storage.s3.connect", as: NSButton.self)
        XCTAssertEqual(connect.title, "Connect")
        XCTAssertTrue(connect.isEnabled, "S3 must work in builds without Google OAuth configuration")
        XCTAssertTrue(connect === driveConnect, "Only one selected-provider connection action is presented")
        XCTAssertTrue(s3Fields.allSatisfy { !$0.isHiddenOrHasHiddenAncestor })
        let endpoint = try control("storage.s3.endpoint", as: NSTextField.self)
        endpoint.stringValue = "https://draft.example.test"
        let disconnect = try control("storage.s3.disconnect", as: NSButton.self)
        XCTAssertTrue(disconnect.isHiddenOrHasHiddenAncestor,
            "Browsing an unconnected provider must not expose an active-provider disconnect")
        let retention = try control("storage.policy.localRetention", as: NSPopUpButton.self)
        XCTAssertFalse(retention.isEnabled, "No active provider snapshot means no editable local policy")
        provider.selectItem(at: 0)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(provider.action), to: provider.target, from: provider))
        XCTAssertTrue(s3Fields.allSatisfy(\.isHiddenOrHasHiddenAncestor))
        XCTAssertEqual(driveConnect.accessibilityIdentifier(), "storage.googleDrive.connect")
        XCTAssertEqual(driveConnect.title, "Connect")
        provider.selectItem(at: 1)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(provider.action), to: provider.target, from: provider))
        XCTAssertTrue(s3Fields.allSatisfy { !$0.isHiddenOrHasHiddenAncestor })
        XCTAssertEqual(endpoint.stringValue, "https://draft.example.test",
            "Provider browsing preserves the user's unsaved configuration")
        XCTAssertEqual(activationCount, 0, "A dropdown round trip must not activate or disconnect an archive")
        root.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertTrue(document.isFlipped)
        XCTAssertEqual(document.frame.width, scroll.contentView.bounds.width, accuracy: 1)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height)
        XCTAssertLessThanOrEqual(scroll.frame.maxX, root.bounds.maxX + 1)
        XCTAssertLessThanOrEqual(scroll.frame.maxY, root.bounds.maxY + 1)
    }

    @MainActor
    func testConnectedProvidersShowVerifiedMetricsRetentionAndEstimates() throws {
        _ = NSApplication.shared
        for provider in [ArchiveBackendKind.googleDrive, .s3Compatible] {
        for scenario in ["connected", "progress", "failed", "disconnected"] + (provider == .s3Compatible ? ["editing"] : []) {
            let manager = GoogleDriveConnectionManager(bundledConfiguration: nil, credentialStore: EmptyDriveCredentials())
            var suppliedSnapshot: LibreReverseArchiveSettingsSnapshot?
            let controller = LibreReverseStorageSettingsViewController(manager: manager,
                connectionValidated: { _ in }, connectionAuthorized: { _ in }, connectionDisconnected: { _ in },
                archiveConnectionSettings: { .init(activeKind: nil, s3Configuration: nil) }, connectS3: { _ in },
                archiveSnapshot: { suppliedSnapshot }, updateArchivePolicy: { _ in }, retryArchive: {},
                storageUsage: { .init(localBytes: 0, recordedDays: 0) }, deleteAllData: {})
            let s3 = try S3ArchiveConfiguration(endpoint: URL(string: "https://objects.example.test")!,
                bucket: "librereverse-preview", accessKey: "preview-access", secretKey: "preview-secret")
            let snapshot = LibreReverseArchiveSettingsSnapshot(providerKind: provider, destinationID: 1,
                policy: .init(requiredLocalSeconds: 30 * 86_400),
                status: .init(totalObjects: 120, queuedObjects: scenario == "progress" ? 30 : 0, verifiedObjects: scenario == "progress" ? 90 : scenario == "failed" ? 117 : 120, failedObjects: scenario == "failed" ? 3 : 0,
                    totalBytes: 6_000_000_000, verifiedBytes: scenario == "progress" ? 4_500_000_000 : scenario == "failed" ? 5_850_000_000 : 6_000_000_000, activeTransferredBytes: 0,
                    rehydrationObjects: 0, rehydrationBytes: 0, historicalPendingObjects: scenario == "progress" ? 30 : 0,
                    latestObjectState: scenario == "progress" ? .uploading : scenario == "failed" ? .failed : .verified, latestVerifiedAt: Date().addingTimeInterval(-180)),
                residencyForecast: .init(bytesSelectedForRemoval: 0, bytesSafelyEvictable: 0, bytesWaitingForVerification: 0),
                shardStatus: .init(totalObjects: 2, verifiedObjects: 2, queuedObjects: 0, failedObjects: 0,
                    totalBytes: 20_000_000, verifiedBytes: 20_000_000, activeTransferredBytes: 0,
                    latestVerifiedAt: Date().addingTimeInterval(-120)), hasActiveRecording: true)
            suppliedSnapshot = snapshot
            controller.renderConnectedPreview(settings: .init(activeKind: provider,
                s3Configuration: provider == .s3Compatible ? s3 : nil,
                isOperational: scenario != "disconnected"), archive: snapshot,
                usage: .init(localBytes: 4_000_000_000, recordedDays: 14))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Storage · synthetic connected preview"
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1)
            controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 600, height: 800))
            window.contentMinSize = NSSize(width: 600, height: 800)
            controller.view.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let views = descendants(controller.view)
            if scenario == "editing" {
                let edit = try XCTUnwrap(views.first { $0.accessibilityIdentifier() == "storage.connection.edit" } as? NSButton)
                XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(edit.action), to: edit.target, from: edit))
            }
            let labels = views.compactMap { $0 as? NSTextField }.map(\.stringValue)
            XCTAssertTrue(labels.contains { $0.hasPrefix("Archive storage:") })
            XCTAssertFalse(labels.contains { $0.hasPrefix("Archive storage:") && $0.contains("verified") })
            let backupState = try XCTUnwrap(views.first { $0.accessibilityIdentifier() == "storage.sync.state" } as? NSTextField)
            if scenario == "connected" || scenario == "editing" {
                XCTAssertTrue(backupState.stringValue.hasPrefix("Backed up to "))
            } else if scenario == "progress" {
                XCTAssertEqual(backupState.stringValue, "Backing up existing recordings…")
            } else if scenario == "failed" {
                XCTAssertEqual(backupState.stringValue, "Backup needs attention")
            } else {
                XCTAssertEqual(backupState.stringValue, "Archive needs reconnecting — recordings stay on this Mac")
            }

            if scenario == "disconnected" {
                XCTAssertFalse(labels.contains { $0.hasPrefix("Connected") },
                    "A saved destination must not masquerade as an active connection")
                XCTAssertTrue(labels.contains { $0.hasPrefix("Archive needs reconnecting") })
                if provider == .googleDrive {
                    XCTAssertTrue(labels.contains("Google Drive is unavailable in this build"))
                }
            }
            XCTAssertTrue(labels.contains { $0.hasPrefix("Estimated/month:") })
            XCTAssertTrue(labels.contains { $0.contains("Last backup:") })
            let summary = try XCTUnwrap(views.first { $0.accessibilityIdentifier() == "storage.sync.summary" } as? NSTextField)
            XCTAssertFalse(summary.stringValue.contains("recordings"))
            XCTAssertFalse(summary.stringValue.contains("history periods"))
            XCTAssertTrue(labels.contains("Local copies are removed after backup; recordings stay safely in your archive."))
            if scenario == "connected" || scenario == "editing" { XCTAssertTrue(summary.isHidden) }

            let retention = try XCTUnwrap(views.first { $0.accessibilityIdentifier() == "storage.policy.localRetention" } as? NSPopUpButton)
            XCTAssertTrue(retention.isEnabled)
            XCTAssertEqual(retention.indexOfSelectedItem, 2)
            let connect = try XCTUnwrap(views.first { $0.accessibilityIdentifier() == (provider == .googleDrive ? "storage.googleDrive.connect" : "storage.s3.connect") } as? NSButton)
            XCTAssertFalse(connect.title.contains("Drive"))
            XCTAssertFalse(connect.title.contains("S3"))
            if let output = ProcessInfo.processInfo.environment["LIBREREVERSE_CONNECTED_STORAGE_PREVIEWS"] {
                window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-x", "-o", "-l", String(window.windowNumber), output + "/settings-" + (provider == .googleDrive ? "drive" : "s3") + "-" + scenario + ".png"]
                try task.run(); task.waitUntilExit(); XCTAssertEqual(task.terminationStatus, 0)
                if scenario == "connected" {
                    let disconnect = try XCTUnwrap(views.first { $0.accessibilityIdentifier() == (provider == .googleDrive ? "storage.googleDrive.disconnect" : "storage.s3.disconnect") } as? NSButton)
                    let cancelTimer = Timer(timeInterval: 0.3, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            if let dialog = NSApp.modalWindow {
                                let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                                capture.arguments = ["-x", "-o", "-l", String(dialog.windowNumber), output + "/settings-" + (provider == .googleDrive ? "drive" : "s3") + "-disconnect-confirmation.png"]
                                try? capture.run(); capture.waitUntilExit()
                            }
                            NSApp.stopModal(withCode: .alertSecondButtonReturn)
                        }
                    }
                    RunLoop.main.add(cancelTimer, forMode: .common)
                    RunLoop.main.add(cancelTimer, forMode: RunLoop.Mode("NSModalPanelRunLoopMode"))
                    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(disconnect.action), to: disconnect.target, from: disconnect))
                    let deleteButton = try XCTUnwrap(views.first { $0.accessibilityIdentifier() == "storage.deleteAll" } as? NSButton)
                    let deleteCancelTimer = Timer(timeInterval: 0.3, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            if let dialog = NSApp.modalWindow {
                                let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                                capture.arguments = ["-x", "-o", "-l", String(dialog.windowNumber), output + "/settings-" + (provider == .googleDrive ? "drive" : "s3") + "-delete-confirmation.png"]
                                try? capture.run(); capture.waitUntilExit()
                            }
                            NSApp.stopModal(withCode: .alertSecondButtonReturn)
                        }
                    }
                    RunLoop.main.add(deleteCancelTimer, forMode: .common)
                    RunLoop.main.add(deleteCancelTimer, forMode: RunLoop.Mode("NSModalPanelRunLoopMode"))
                    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(deleteButton.action), to: deleteButton.target, from: deleteButton))
                    let menuTimer = Timer(timeInterval: 0.3, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                            if let menuWindow = windows.first(where: {
                                ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier &&
                                ($0[kCGWindowNumber as String] as? Int) != window.windowNumber
                            }), let number = menuWindow[kCGWindowNumber as String] {
                                let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                                capture.arguments = ["-x", "-o", "-l", String(describing: number), output + "/settings-" + (provider == .googleDrive ? "drive" : "s3") + "-retention-options.png"]
                                try? capture.run(); capture.waitUntilExit()
                            }
                            retention.menu?.cancelTrackingWithoutAnimation()
                        }
                    }
                    RunLoop.main.add(menuTimer, forMode: .common)
                    RunLoop.main.add(menuTimer, forMode: RunLoop.Mode("NSEventTrackingRunLoopMode"))
                    retention.performClick(nil)
                    XCTAssertEqual(retention.indexOfSelectedItem, 2)

                }
            }
            window.orderOut(nil)
        }
        }
    }

}
#endif
