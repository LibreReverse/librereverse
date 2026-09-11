#if os(macOS)
import AppKit
import AVFoundation
import AVKit
import CoreGraphics
import Combine
import Darwin
import Foundation
import os
import LibreReverseCore
import ServiceManagement
import UniformTypeIdentifiers
@preconcurrency import UserNotifications
import VideoToolbox

private enum LibreReverseDataResetError: LocalizedError {
  case archiveConnectionRequired
  case restartRequired(String)

  var errorDescription: String? {
    switch self {
    case .archiveConnectionRequired:
      "Reconnect your archive before deleting all data so the complete archive can be removed safely."
    case .restartRequired(let detail):
      "Data reset failed: \(detail) Quit and reopen LibreReverse before recording. Local data has been retained."
    }
  }
}

private enum LibreReverseTimelineInvocationSource {
    case lastSearch
    case blankSearchFromScroll
}

private enum LibreReverseMeetingConfigurationError: LocalizedError {
    case selectedMicrophoneUnavailable
    case insufficientStorage(availableBytes: Int64, requiredBytes: Int64)
    case captureJournalMismatch

    var errorDescription: String? {
        switch self {
        case .selectedMicrophoneUnavailable:
            "The selected meeting microphone is no longer available. Choose another input in LibreReverse Settings, or use System Default."
        case .insufficientStorage(let availableBytes, let requiredBytes):
            "Meeting recording needs at least \(ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)) free. Only \(ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)) is available. Free space or finish archiving, then try again."
        case .captureJournalMismatch:
            "LibreReverse could not safely rename this active meeting because its recovery journal no longer matches the recording. The recording was not changed."
        }
    }
}

private struct LibreReverseCaptureSnapshot: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let windowIDs: [CGWindowID]
    let context: LibreReverseCaptureContext?
    let displayBounds: CGRect
    let frontWindowBounds: CGRect?
}

private struct LibreReverseMeetingDetectionProbeSummary: Codable {
    let schemaVersion: Int
    let startedAt: Date
    let finishedAt: Date
    let pollCount: Int
    let collectionFailureCount: Int
    let providerCandidateCounts: [String: Int]
    let screenRecordingAuthorized: Bool
    let accessibilityAuthorized: Bool
    let lifecycleStartPolicy: LibreReverseMeetingStartPolicy
    let simulatesCaptureAcknowledgements: Bool
}

@MainActor
func runLibreReverseApplication() {
    let application = NSApplication.shared
    let delegate = LibreReverseAppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}

@MainActor
private final class LibreReverseAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let meetingStartPolicyDefaultsKey = "LibreReverse.meetingStartPolicy"
    private static let meetingSystemAudioDefaultsKey = "LibreReverse.meetingSystemAudio"
    private static let meetingMicrophoneDefaultsKey = "LibreReverse.meetingMicrophone"
    private static let meetingMicrophoneDeviceDefaultsKey =
        "LibreReverse.meetingMicrophoneDeviceID"
    private static let meetingTranscriptionLanguageDefaultsKey =
        "LibreReverse.meetingTranscriptionLanguage"
    private static let meetingCalendarEnabledDefaultsKey =
        "LibreReverse.meetingCalendarEnabled"
    private static let meetingCalendarIDsDefaultsKey =
        "LibreReverse.meetingCalendarIDs"
    private var shouldPauseMeetingWaveformBackfill: Bool {
        NSApp.isActive || productMeetingSession != nil || meetingValidationSession != nil
    }

    private func scheduleMeetingWaveformBackfill() {
        guard !terminating, meetingWaveformBackfillTask == nil else { return }
        let configuration = libraryConfiguration
        let shouldPause: @Sendable () async -> Bool = { [weak self] in
            await self?.shouldPauseMeetingWaveformBackfill ?? false
        }
        meetingWaveformBackfillTask = Task.detached(priority: .utility) {
            do {
                // Read legacy media into a separate index; never rewrite recordings.
                try await Task.sleep(for: .seconds(30))
                _ = try await MeetingWaveformBackfill.run(
                    configuration: configuration, shouldPause: shouldPause
                )
            } catch {
                // Per-file failures are checkpointed and retried on next launch.
            }
        }
    }

    private var statusItem: NSStatusItem!
    private var lastRecordingErrorOperation: String?
    private var meetingSaveWarning: String?
    private var recordingDisabledReason: String? = "LibreReverse is starting"
    private var menuBarFixtureSnapshot: LibreReverseMenuBarSnapshot?
    private var recordingTask: Task<Void, Never>?
    private var captureTimer: DispatchSourceTimer?
    private var recordingSession: ScreenRecordingSession?
    private var meetingValidationSession: HighFidelityMeetingCaptureSession?
    private var meetingValidationTask: Task<Void, Never>?
    private var meetingWaveformBackfillTask: Task<Void, Never>?
    private var productMeetingSession: HighFidelityMeetingCaptureSession?
    private var meetingNativeRecordingFinished = false
    private var productMeetingCandidate: LibreReverseMeetingCandidate?
    private var productMeetingStagingURL: URL?
    private var productMeetingPublicationXID: String?
    private var productMeetingCapturesMicrophone = false
    private var productMeetingMicrophoneDeviceID: String?
    private var productMeetingAudioSelection: LibreReverseMeetingAudioCaptureSelection?
    private var productMeetingAudioRouteSnapshot: LibreReverseMeetingAudioRouteSnapshot?
    private var meetingAudioRouteChangeTracker = LibreReverseMeetingAudioRouteChangeTracker()
    private var meetingSystemBoundary = LibreReverseMeetingSystemBoundaryTracker()
    private var productMeetingStartedAt: Date?
    private var meetingRestartTask: Task<Void, Never>?
    private var meetingRestartIntent = LibreReverseMeetingRestartIntentTracker()
    private var meetingTranscriber: (any MeetingTranscriber)?
    private var meetingTranscriptionTask: Task<Void, Never>?
    private lazy var meetingSummaryScheduler = MeetingSummaryScheduler(
      configuration: libraryConfiguration
    ) { [weak self] _ in
      self?.timelineWindow?.meetingTranscriptionStateDidChange()
    }
    private var meetingTranscriptionSchedulerState =
        LibreReverseMeetingTranscriptionSchedulerState()
    private var meetingDetectionTimer: DispatchSourceTimer?
    private var meetingDetectionProbeTimer: DispatchSourceTimer?
    private var meetingDetectionProbeTask: Task<Void, Never>?
    private var meetingDetectionProbeHandle: FileHandle?
    private var meetingDetectionProbeStart: Date?
    private var meetingDetectionProbePollCount = 0
    private var meetingDetectionProbeFailureCount = 0
    private var meetingDetectionProbeProviderCounts: [String: Int] = [:]
    private var meetingDetectionProbeIdentitySecret: Data?
    private var meetingDetectionProbeLifecycle = LibreReverseMeetingProbeLifecycleSimulator()
    private var meetingOperationTask: Task<Void, Never>?
    private var meetingLifecycle = LibreReverseMeetingLifecycleCoordinator()
    private var meetingCaptureRecoveryInProgress = true
    private var meetingCaptureRecoveryTask: Task<Void, Never>?
    private var pendingRecoveredMeetingContinuation: LibreReverseRecoveredMeetingContinuation?
    private var lastMeetingVoiceBufferCount = 0
    private var meetingIgnoreTracker = LibreReverseMeetingIgnoreTracker()
    private let meetingCalendarSource = LibreReverseCalendarMeetingSource()
    private lazy var meetingStorageGuard: LibreReverseMeetingCaptureStorageGuard = {
        let diagnosticFloor =
            LibreReverseDevelopmentEnvironment.values[
                "LIBREREVERSE_MEETING_MINIMUM_FREE_BYTES"
            ].flatMap(Int64.init) ?? 0
        // Diagnostics may raise the floor to exercise refusal/finalization on
        // a healthy volume, but can never lower the production safety reserve.
        return LibreReverseMeetingCaptureStorageGuard(
            minimumFreeBytes: max(
                LibreReverseMeetingCaptureStorageGuard.defaultMinimumFreeBytes,
                diagnosticFloor
            ))
    }()
    private var captureShardBoundary: Date?
    private let screenshotAdmission = ScreenshotCaptureGate()
    private let meetingCaptureHandoff = LibreReverseMeetingCaptureHandoff()
    private var globalHotKeys: LibreReverseGlobalHotKeyRegistrar?
    private var scrollToRewind: LibreReverseScrollToRewindController?
    private var timelineWindow: LibreReverseTimelineWindowController?
    private var dailyRecapWindow: LibreReverseDailyRecapWindowController?
    private var askWindow: LibreReverseAskWindowController?
    private var searchFixtureWindow: LibreReverseSearchFixtureWindowController?
    private var pinnedTranscriptFixtureWindow: LibreReversePinnedTranscriptWindowController?
    private var settingsWindow: LibreReverseSettingsWindowController?
    private var quickStartWindow: LibreReverseQuickStartWindowController?
    /// Resolve Bundle/environment credentials after NSApplication launch. An
    /// eager delegate-field default was observed producing nil before the app
    /// bundle's custom Info.plist keys became visible under direct diagnostics.
    private lazy var googleDriveConnectionManager = GoogleDriveConnectionManager(
        bundledConfiguration: GoogleOAuthClientConfiguration.bundled(),
        credentialStore: GoogleDriveEncryptedDatabaseStore(
            configuration: libraryConfiguration
        )
    )
    private var archiveCoordinator: LibreReverseArchiveCoordinator?
    private var shardArchiveCoordinator: LibreReverseShardArchiveCoordinator?
    private var archiveBackend: (any ArchiveBackend)?
    private var archiveTransitionInProgress = false
    private var archiveConnectionGeneration: UInt64 = 0
    private var archiveMediaResolver: LibreReverseLocalMediaResolver?
    private var archiveShardResolver: LibreReverseShardResolver?
    private var archiveRestoreTask: Task<Void, Never>?
    private var archiveConnectionRetryTask: Task<Void, Never>?
    private lazy var archiveDownloads = LibreReverseArchiveDownloadCoordinator(
        library: libraryConfiguration,
        onChange: { [weak self] status in
            await self?.timelineWindow?.archiveDownloadDidChange(status)
        }
    )
    private var archiveResidencyManager: LibreReverseMediaResidencyManager?
    private var archiveShardResidencyManager: LibreReverseShardResidencyManager?
    private var archiveWorkTask: Task<Void, Never>?
    private var meetingDeletionRecoveryTask: Task<Void, Never>?
    private var meetingDeletionRecoveryTaskState = LibreReverseMeetingMaintenanceTaskState()
    private var meetingTitleUpdateRecoveryTask: Task<Void, Never>?
    private var meetingTitleUpdateRecoveryTaskState = LibreReverseMeetingMaintenanceTaskState()
    private var archiveRetryTask: Task<Void, Never>?
    private var archiveMenuStatusTask: Task<Void, Never>?
    private var archiveMenuStatusGeneration: UInt64 = 0
    private var updateCheckTask: Task<Void, Never>?
    private var updateDownloadTask: Task<Void, Never>?
    private var updateCheckTimer: DispatchSourceTimer?
    private var updateCheckInProgress = false
    private var updateDownloadInProgress = false
    private var availableUpdate: LibreReverseUpdateManifest?
    private var updateCheckError: String?
    private var archiveWorkPending = false
    private var archiveRoundTripDiagnosticCompleted = false
    private var shortcutFixtureSettings = LibreReverseShortcutSettings.defaults
    private var askFixtureAPIKey: String?
    private var captureSettingsFixtureGeneral = LibreReverseGeneralSettingsSnapshot(
      launchAtLogin: false,
      remindWhenPaused: true,
      showInDock: false
    )
    private var captureSettingsFixtureScreen = LibreReverseScreenSettingsSnapshot(
      omittedBundleIdentifiers: ["com.example.PrivateNotes"],
      excludePrivateWindows: true,
      ocrLanguageMode: .standard,
      showRunningProcesses: false,
      applications: [
        .init(
          bundleIdentifier: "com.apple.Safari",
          name: "Safari",
          applicationURL: URL(fileURLWithPath: "/Applications/Safari.app"),
          isRunningProcess: false,
          isInstalledApplication: true
        ),
        .init(
          bundleIdentifier: "com.example.PrivateNotes",
          name: "Private Notes",
          applicationURL: nil,
          isRunningProcess: true,
          isInstalledApplication: false
        ),
      ]
    )
    private var audioSettingsFixturePreferences = LibreReverseMeetingAudioPreferences(
      capturesSystemAudio: true,
      capturesMicrophone: true,
      microphoneDeviceID: "fixture-studio-mic"
    )
    private var audioSettingsFixtureLanguage: String? = "en"
    private lazy var ocrCoordinator: LibreReverseOCRCoordinator = {
      let coordinator = LibreReverseOCRCoordinator(configuration: libraryConfiguration)
      coordinator.updateAdditionalLanguageSupport(
        LibreReverseCaptureSettingsPreferences.ocrLanguageMode() == .additional
      )
      return coordinator
    }()
    private let permissionsController = LibreReversePermissionsController()
    private var paused = false
    private var latestLiveCapture:
      (
        frame: CapturedScreenFrame,
        date: Date,
        admittedFrame: LibreReverseAdmittedFrame?
    )?
    private var starShortcutTask: Task<Void, Never>?
    private let foregroundContextProvider = LibreReverseForegroundContextProvider()
    private let uiMutationLifetime = LibreReverseUIMutationLifetime()
    private var terminating = false
    private var terminationReplySent = false
    private var installationLock: LibreReverseInstallationLock?
    private var startupReady = false
    private var startupTask: Task<Void, Never>?
    private var pendingStartupMoment: Date?
    private var pendingStartupReopen = false
    private var dataResetRequiresRestart = false

    private var isLibraryUIValidationMode: Bool {
      LibreReverseDevelopmentEnvironment.values["LIBREREVERSE_LIBRARY_UI_VALIDATION"] == "1"
    }

    private lazy var libraryConfiguration = LibreReverseLibraryConfiguration(
        databaseURL: dataDirectory.appendingPathComponent("Library/library.sqlite3"),
        keyFileURL: dataDirectory.appendingPathComponent("Secrets/library-db-key"),
        mediaRoot: dataDirectory.appendingPathComponent("Library/Media", isDirectory: true)
    )

    private lazy var dataDirectory: URL = {
      if let fixture = LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_SETTINGS_FIXTURE_ROOT"
      ], !fixture.isEmpty {
        return URL(fileURLWithPath: fixture, isDirectory: true)
      }
      return FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      )[0].appendingPathComponent("LibreReverse", isDirectory: true)
    }()

    private var pendingDataResetURL: URL {
      dataDirectory.appendingPathComponent("delete-all-data.pending")
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
      // URL-scheme events can arrive before `applicationDidFinishLaunching`
      // and the delegate callback is not consistently invoked for an already
      // running accessory application. Register the canonical GetURL Apple
      // event explicitly so both cold and warm moment links share
      // the same routing path.
      NSAppleEventManager.shared().setEventHandler(
        self,
        andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
        forEventClass: AEEventClass(kInternetEventClass),
        andEventID: AEEventID(kAEGetURL)
      )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
      #if DEBUG
      if let fixture = LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_MENU_BAR_FIXTURE"
      ] {
        // Deterministic menu-only validation. It opens no library, permissions,
        // capture, audio hardware, calendar, transcription, archive, or updater.
        configureStatusItem()
        menuBarFixtureSnapshot = menuBarFixtureSnapshot(named: fixture)
        refreshStatusMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
          self?.statusItem.button?.performClick(nil)
        }
        return
      }
      if LibreReverseDevelopmentEnvironment.values["LIBREREVERSE_ARCHIVE_MAX_OBJECTS"] != nil {
            let environmentHasID = getenv("LIBREREVERSE_GOOGLE_CLIENT_ID") != nil
        let bundleHasID =
          Bundle.main.infoDictionary?["LibreReverseGoogleOAuthClientID"] != nil
            let resolved = GoogleOAuthClientConfiguration.bundled() != nil
        let message =
          "ARCHIVE_DIAGNOSTIC oauth env=\(environmentHasID) bundle=\(bundleHasID) resolved=\(resolved)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
      if let probeOutput = LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_MEETING_DETECTION_PROBE_OUTPUT"
      ], !probeOutput.isEmpty {
        // This content-redacted diagnostic owns no library or capture
        // state and can run alongside the normal product instance.
        configureStatusItem()
        startMeetingDetectionProbe(
          outputDirectory: URL(fileURLWithPath: probeOutput, isDirectory: true)
        )
        return
      }
      if let validationOutput = LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_MEETING_VALIDATION_OUTPUT"
      ], !validationOutput.isEmpty {
        // This diagnostic process owns no library state and may run beside
        // the normal product instance while a browser fixture is playing.
        configureStatusItem()
        startMeetingValidationMode(
          outputDirectory: URL(fileURLWithPath: validationOutput, isDirectory: true)
        )
        return
      }
      if let output = LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_SHORTCUT_REGISTRATION_PROBE"
      ], !output.isEmpty {
        // Carbon-only signed probe: no library, window, screen/audio capture,
        // calendar, transcription, archive, or event monitor is opened.
        let registrar = LibreReverseGlobalHotKeyRegistrar()
        do {
          try registrar.start(settings: .defaults) { action in
            try? (action.rawValue + "\n").write(
              toFile: output,
              atomically: true,
              encoding: .utf8
            )
          }
          globalHotKeys = registrar
        } catch {
          try? ("error: \(error.localizedDescription)\n").write(
            toFile: output,
            atomically: true,
            encoding: .utf8
          )
        }
        return
      }
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_MEETING_SETTINGS_FIXTURE"
      ] != nil {
        // This settings-only process owns no capture or library state and
        // must remain runnable beside the user's production recorder.
        configureStatusItem()
        presentSettings(section: .meetings)
        if let output = LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_MEETING_SETTINGS_FIXTURE_WINDOW_ID"
        ], let windowNumber = settingsWindow?.window?.windowNumber {
          try? String(windowNumber).write(
            toFile: output,
            atomically: true,
            encoding: .utf8
          )
        }
        return
      }
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_AUDIO_SETTINGS_FIXTURE"
      ] != nil {
        // Audio-settings validation uses deterministic devices and never opens
        // capture, audio hardware, permissions, transcription, or the library.
        configureStatusItem()
        presentSettings(section: .audio)
        if let output = LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_AUDIO_SETTINGS_FIXTURE_WINDOW_ID"
        ], let windowNumber = settingsWindow?.window?.windowNumber {
          try? String(windowNumber).write(
            toFile: output,
            atomically: true,
            encoding: .utf8
          )
        }
        return
      }
      if let captureSettingsFixture = LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_CAPTURE_SETTINGS_FIXTURE"
      ] {
        // General/Screen visual validation uses in-memory preferences and no
        // capture, library, login-item mutation, notifications, or app scan.
        configureStatusItem()
        presentSettings(section: captureSettingsFixture == "screen" ? .screen : .general)
        if let output = LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_CAPTURE_SETTINGS_FIXTURE_WINDOW_ID"
        ], let windowNumber = settingsWindow?.window?.windowNumber {
          try? String(windowNumber).write(
            toFile: output,
            atomically: true,
            encoding: .utf8
          )
        }
        return
      }
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_STORAGE_SETTINGS_FIXTURE"
      ] != nil {
        // The caller redirects Application Support to a temporary root. This
        // opens the production Storage controller but no capture, calendar,
        // transcription, scheduler, or user library.
        configureStatusItem()
        do {
          try LibreReverseLibraryStore.initialize(libraryConfiguration)
        } catch {
          showRecordingError(error)
          return
        }
        presentSettings(section: .storage)
        if let output = LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_STORAGE_SETTINGS_FIXTURE_WINDOW_ID"
        ], let windowNumber = settingsWindow?.window?.windowNumber {
          try? String(windowNumber).write(
            toFile: output,
            atomically: true,
            encoding: .utf8
          )
        }
        return
      }
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_SHORTCUTS_SETTINGS_FIXTURE"
      ] != nil {
        // Uses an in-memory settings model and returns before capture,
        // library initialization, hot-key registration, or event monitors.
        configureStatusItem()
        presentSettings(section: .shortcuts)
        if let output = LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_SHORTCUTS_SETTINGS_FIXTURE_WINDOW_ID"
        ], let windowNumber = settingsWindow?.window?.windowNumber {
          try? String(windowNumber).write(
            toFile: output,
            atomically: true,
            encoding: .utf8
          )
        }
        return
      }
      if let fixture = LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_ASK_UI_FIXTURE"
      ] {
        // Deterministic Ask UI validation: no library, credentials, network,
        // capture, hot keys, calendar, transcription, or archive resources.
        configureStatusItem()
        askFixtureAPIKey = fixture == "setup" ? nil : "fixture-key"
        askWindow = LibreReverseAskWindowController(
          answerHandler: { _, _ in
            if fixture == "chat" {
              try await Task.sleep(for: .seconds(2))
              return .init(text: "The follow-up was to test **screen sharing** before Friday. [1]", citations: [
                .init(instant: Date(timeIntervalSince1970: 1_777_124_400), title: "Weekly product review",
                      excerpt: "Test screen sharing before Friday.", source: "Transcript")])
            }
            if fixture == "loading" { try await Task.sleep(for: .seconds(60)) }
            throw NSError(domain: "LibreReverse.UIFixture", code: 1,
              userInfo: [NSLocalizedDescriptionKey: "The AI profile could not be reached. Try again."])
          },
          loadAPIKey: { [weak self] in self?.askFixtureAPIKey },
          openAISettings: { },
          openMoment: { _ in }
        )
        askWindow?.present()
        if fixture == "answer" || fixture == "chat" {
          let instant = Date(timeIntervalSince1970: 1_777_124_400)
          askWindow?.presentFixture(
            question: "What were the main decisions from the product review?",
            answer: .init(
              text: "The team agreed to keep meeting capture local, finish transcript compatibility, and validate the polished timeline before expanding the rollout. [1] [2]",
              citations: [
                .init(
                  instant: instant,
                  title: "Weekly product review",
                  excerpt: "Keep meeting capture local and preserve transcript compatibility.",
                  source: "Transcript"
                ),
                .init(
                  instant: instant.addingTimeInterval(420),
                  title: "LibreReverse timeline",
                  excerpt: "Validate the polished timeline before expanding the rollout.",
                  source: "Screen text"
                ),
              ]
            )
          )
        }
        if fixture == "chat" {
          askWindow?.appendFixture(question: "Who owns the follow-up work?", answer: .init(
            text: "**Alex** will test screen sharing, and **Morgan** will review transcription accuracy. [1]\n\nThe rollout stays limited until both checks pass.",
            citations: [.init(instant: Date(timeIntervalSince1970: 1_777_124_400),
              title: "Weekly product review", excerpt: "Alex: screen sharing. Morgan: transcription accuracy.", source: "Transcript")]))
        }
        if fixture == "loading" || fixture == "error" {
          askWindow?.prefill(question: "What did we decide in the product review?")
          askWindow?.submitFixtureRequest()
        }
        if let output = LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_ASK_UI_FIXTURE_WINDOW_ID"
        ], let windowNumber = askWindow?.window?.windowNumber {
          try? String(windowNumber).write(toFile: output, atomically: true, encoding: .utf8)
        }
        return
      }
      if let rawState = LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_SEARCH_UI_FIXTURE"
      ], let state = LibreReverseSearchFixtureWindowController.State(rawValue: rawState) {
        // Production Search views with in-memory content only. No library,
        // permissions, capture, audio, calendar, archive, or updater opens.
        configureStatusItem()
        searchFixtureWindow = LibreReverseSearchFixtureWindowController(state: state)
        searchFixtureWindow?.present()
        if let output = LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_SEARCH_UI_FIXTURE_WINDOW_ID"
        ], let windowNumber = searchFixtureWindow?.window?.windowNumber {
          try? String(windowNumber).write(
            toFile: output,
            atomically: true,
            encoding: .utf8
          )
        }
        return
      }
      if let fixture = LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_DAILY_RECAP_UI_FIXTURE"
      ] {
        // This deterministic UI-only process opens no library, calendar,
        // screen-capture, audio-capture, or transcription resources.
        configureStatusItem()
        dailyRecapWindow = LibreReverseDailyRecapWindowController(
          fixtureRecap: fixture == "empty"
            ? LibreReverseDailyRecapFixture.empty()
            : LibreReverseDailyRecapFixture.make()
        )
        dailyRecapWindow?.present()
        if let output = LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_DAILY_RECAP_UI_FIXTURE_WINDOW_ID"
        ], let windowNumber = dailyRecapWindow?.window?.windowNumber {
          try? String(windowNumber).write(
            toFile: output,
            atomically: true,
            encoding: .utf8
          )
        }
        if let output = LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_DAILY_RECAP_UI_FIXTURE_DETAILS_WINDOW_ID"
        ], let windowNumber = dailyRecapWindow?.presentFirstFixtureMeetingDetails() {
          try? String(windowNumber).write(
            toFile: output,
            atomically: true,
            encoding: .utf8
          )
        }
        return
      }
      if let transcriptFixture = LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_PINNED_TRANSCRIPT_UI_FIXTURE"
      ] {
        // A standalone transcript window for signed visual/accessibility QA.
        // It deliberately opens no library, screen/audio capture, calendar,
        // transcription, or archive resources.
        configureStatusItem()
        let transcriptView = LibreReverseMeetingTranscriptView(frame: .zero)
        transcriptView.onTogglePlayback = {}
        transcriptView.onTogglePin = {}
        transcriptView.onWordSeek = { _, _ in }
        transcriptView.onRename = { _, title in title }
        transcriptView.onUpdateContext = { _, names, calendar in
          .init(participants: names, calendarTitle: calendar)
        }
        transcriptView.onDelete = { _ in }
        transcriptView.onRetryPlayback = { _ in }
        let start = Date(timeIntervalSince1970: 1_777_124_400)
        let text =
          "We captured every frame and both audio sources. The restored transcript stays synchronized with playback."
        transcriptView.present(
          .init(
            segmentID: 9_001,
            title: "Weekly product review",
            text: text,
            startDate: start,
            endDate: start.addingTimeInterval(1_458),
            words: [
              .init(
                id: 1, speechSource: "others", text: "captured",
                startSeconds: 2, durationSeconds: 1, fullTextUTF16Offset: 3),
              .init(
                id: 2, speechSource: "me", text: "restored",
                startSeconds: 8, durationSeconds: 1, fullTextUTF16Offset: 52),
              .init(
                id: 3, speechSource: "others", text: "synchronized",
                startSeconds: 10, durationSeconds: 1, fullTextUTF16Offset: 78),
            ],
            metadata: .init(
              provider: .googleMeet,
              calendarTitle: "Product",
              participants: ["Maya", "Jordan", "Sam"]
            ),
            processingState: .complete
          ),
          at: start.addingTimeInterval(8.4)
        )
        transcriptView.setPlaybackAvailable(transcriptFixture != "unavailable")
        if transcriptFixture == "playing" { transcriptView.setPlaybackActive(true) }
        if transcriptFixture == "failed" {
          transcriptView.presentPlaybackNotice(.failedToPrepare, segmentID: 9_001)
        }
        transcriptView.setPinned(true)
        let controller = LibreReversePinnedTranscriptWindowController(
          transcriptView: transcriptView
        )
        pinnedTranscriptFixtureWindow = controller
        if transcriptFixture.hasPrefix("recording-") {
          let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 110))
          let status = LibreReverseMeetingRecordingView(frame: .zero)
          status.onStop = {}
          status.onRenameRequested = {}
          host.addSubview(status)
          NSLayoutConstraint.activate([
            status.widthAnchor.constraint(equalToConstant: 360),
            status.heightAnchor.constraint(equalToConstant: 58),
            status.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: host.centerYAnchor),
          ])
          status.present(.init(candidate: .init(provider: .googleMeet, source: .windowDetection,
            title: "Weekly product review"), selection: .init(capturesSystemAudio: true,
            capturesMicrophone: true, microphoneDeviceID: nil), startedAt: Date().addingTimeInterval(-754)))
          if transcriptFixture == "recording-finishing" { status.setFinishing() }
          controller.window?.title = "Meeting recording"
          controller.window?.minSize = NSSize(width: 400, height: 142)
          controller.window?.contentView = host
          controller.window?.setContentSize(host.frame.size)
        }
        controller.present()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
          transcriptView.presentFixtureAction(transcriptFixture)
        }
        if let output = LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_PINNED_TRANSCRIPT_UI_FIXTURE_WINDOW_ID"
        ], let windowNumber = controller.window?.windowNumber {
          try? String(windowNumber).write(
            toFile: output,
            atomically: true,
            encoding: .utf8
          )
        }
        return
      }
      if let mediaPath = LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_MEETING_PLAYBACK_UI_FIXTURE_MEDIA"
      ], let fixtureRootPath = LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_MEETING_PLAYBACK_UI_FIXTURE_ROOT"
      ], let screen = NSScreen.main {
        // Full production timeline/player/pin validation against caller-owned
        // A/V media in an isolated temporary library. No capture, transcription,
        // calendar, credentials, archive scheduler, or user library is opened.
        configureStatusItem()
        let root = URL(fileURLWithPath: fixtureRootPath, isDirectory: true)
        let fixtureLibrary = LibreReverseLibraryConfiguration(
          databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
          keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
          mediaRoot: root.appendingPathComponent("Library/Media", isDirectory: true)
        )
        do {
          try LibreReverseLibraryStore.initialize(fixtureLibrary)
          let sourceURL = URL(fileURLWithPath: mediaPath)
          let actionsFixture = LibreReverseDevelopmentEnvironment.values[
            "LIBREREVERSE_TIMELINE_ACTIONS_UI_FIXTURE"
          ] == "1"
          let remoteOnly = LibreReverseDevelopmentEnvironment.values[
            "LIBREREVERSE_MEETING_PLAYBACK_UI_FIXTURE_MODE"
          ] == "remote"
          let actionsSeed = actionsFixture && !remoteOnly
            ? try seedTimelineActionsFixture(
                sourceURL: sourceURL,
                library: fixtureLibrary
              )
            : nil
          let playbackURL = actionsSeed?.mediaURL ?? (remoteOnly
            ? fixtureLibrary.mediaRoot.appendingPathComponent(
                "fixture/remote-only-meeting.mp4")
            : sourceURL)
          let resolver = remoteOnly
            ? LibreReverseMeetingPlaybackFixtureResolver(
                sourceURL: sourceURL,
                destinationURL: playbackURL
              )
            : nil
          let controller = LibreReverseTimelineWindowController(
            dataDirectory: root,
            libraryConfiguration: fixtureLibrary,
            transcriptionQueue: LibreReverseMeetingTranscriptionQueue(
              root: root.appendingPathComponent("TranscriptionQueue", isDirectory: true)
            ),
            mediaResolver: resolver
          )
          timelineWindow = controller
          controller.present(
            on: screen,
            startAtLiveEdge: false,
            forwardingGlobalScrollEvent: nil
          )
          controller.presentMeetingPlaybackValidationFixture(
            mediaURL: playbackURL,
            remoteOnly: remoteOnly,
            statusURL: LibreReverseDevelopmentEnvironment.values[
              "LIBREREVERSE_MEETING_PLAYBACK_UI_FIXTURE_STATUS"
            ].map(URL.init(fileURLWithPath:)),
            actionsSeed: actionsSeed
          )
          if let output = LibreReverseDevelopmentEnvironment.values[
            "LIBREREVERSE_MEETING_PLAYBACK_UI_FIXTURE_WINDOW_ID"
          ], let windowNumber = controller.window?.windowNumber {
            try? String(windowNumber).write(
              toFile: output,
              atomically: true,
              encoding: .utf8
            )
          }
        } catch {
          showRecordingError(error)
        }
        return
      }
      if isLibraryUIValidationMode {
        // Signed validation against the user's actual library. The historical
        // session opens SQLCipher with SQLITE_OPEN_READONLY. This branch skips
        // schema initialization, permissions, capture, meeting
        // recovery, transcription, calendar, archive/updater work, and every
        // product mutation callback.
        NSApp.setActivationPolicy(.regular)
        guard FileManager.default.fileExists(atPath: libraryConfiguration.databaseURL.path),
          FileManager.default.fileExists(atPath: libraryConfiguration.keyFileURL.path),
          let mainScreen = NSScreen.main
        else {
          FileHandle.standardError.write(Data(
            "LibreReverse's existing library or main display is unavailable.\n".utf8
          ))
          NSApp.terminate(nil)
          return
        }
        let controller = LibreReverseTimelineWindowController(
          dataDirectory: dataDirectory,
          libraryConfiguration: libraryConfiguration,
          transcriptionQueue: meetingTranscriptionQueue,
          allowsLibraryMutations: false
        )
        timelineWindow = controller
        configureGlobalHotKeys()
        controller.present(
          on: mainScreen,
          startAtLiveEdge: false,
          forwardingGlobalScrollEvent: nil
        )
        if LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_LIBRARY_UI_VALIDATION_ARCHIVED_HISTORY"
        ] == "1" {
          let statusURL = LibreReverseDevelopmentEnvironment.values[
            "LIBREREVERSE_LIBRARY_UI_VALIDATION_STATUS"
          ].map(URL.init(fileURLWithPath:))
          Task { [weak self, weak controller] in
            guard let self, let controller else { return }
            let hasDestination = (try? LibreReverseArchiveStore.activeDestination(
              configuration: self.libraryConfiguration
            )) != nil
            let hasSavedAuthorization = (try? await self.googleDriveConnectionManager
              .configurationStatus().hasSavedAuthorization) == true
            let authorizationIsUsable: Bool
            do {
              try await self.googleDriveConnectionManager.validateSavedAuthorizationToken()
              authorizationIsUsable = true
            } catch {
              authorizationIsUsable = false
            }
            if hasDestination && hasSavedAuthorization && !authorizationIsUsable {
              controller.setArchiveConnectionNeedsReconnect()
            } else {
              controller.setArchiveConnectionAvailableForValidation(
                hasDestination && hasSavedAuthorization && authorizationIsUsable
              )
            }
            controller.presentArchivedHistoryValidation(statusURL: statusURL)
          }
        } else if let query = LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_LIBRARY_UI_VALIDATION_QUERY"
        ], !query.isEmpty {
          let facet = LibreReverseDevelopmentEnvironment.values[
            "LIBREREVERSE_LIBRARY_UI_VALIDATION_FACET"
          ] ?? "ocr"
          let statusURL = LibreReverseDevelopmentEnvironment.values[
            "LIBREREVERSE_LIBRARY_UI_VALIDATION_STATUS"
          ].map(URL.init(fileURLWithPath:))
          let selectsFirstResult = LibreReverseDevelopmentEnvironment.values[
            "LIBREREVERSE_LIBRARY_UI_VALIDATION_SELECT_FIRST"
          ] == "1"
          if LibreReverseDevelopmentEnvironment.values[
            "LIBREREVERSE_LIBRARY_UI_VALIDATION_RESTORE_DRIVE_SHARD"
          ] == "1" {
            guard let fixtureRoot = LibreReverseDevelopmentEnvironment.values[
              "LIBREREVERSE_SETTINGS_FIXTURE_ROOT"
            ], fixtureRoot.hasPrefix("/private/tmp/") || fixtureRoot.hasPrefix("/tmp/")
            else {
              FileHandle.standardError.write(Data(
                "Drive-shard validation requires an explicit temporary library root.\n".utf8
              ))
              NSApp.terminate(nil)
              return
            }
            do {
              guard let destination = try LibreReverseArchiveStore.googleDriveDestination(
                configuration: libraryConfiguration
              ), let rootFolderID = destination.remoteRoot
              else {
                throw LibreReverseShardArchiveError.shardUnavailable(-1)
              }
              let records = try LibreReverseShardStore.records(
                configuration: libraryConfiguration
              )
              guard let shard = records.first(where: {
                  $0.state == .sealedLocal && ($0.byteCount ?? 0) > 0
                }) ?? records
                  .filter({ $0.state == .remoteOnly && ($0.byteCount ?? 0) > 0 })
                  .min(by: { ($0.byteCount ?? .max) < ($1.byteCount ?? .max) })
              else {
                throw LibreReverseShardArchiveError.shardUnavailable(-1)
              }
              let backend = GoogleDriveArchiveBackend(
                connection: googleDriveConnectionManager,
                rootFolderID: rootFolderID
              )
              let resolver = LibreReverseShardResolver(
                destinationID: destination.id,
                library: libraryConfiguration,
                backend: backend
              )
              controller.setShardResolver(resolver)
              controller.presentDriveShardSearchValidation(
                query: query,
                facet: facet,
                statusURL: statusURL,
                selectsFirstResult: selectsFirstResult,
                resolver: resolver,
                shardOrdinal: shard.interval.ordinal,
                shardInterval: DateInterval(
                  start: shard.interval.start,
                  end: shard.interval.end
                ),
                expectedBytes: shard.byteCount ?? 0
              )
            } catch {
              FileHandle.standardError.write(Data(
                "Drive-shard validation setup failed: \(error.localizedDescription)\n".utf8
              ))
              NSApp.terminate(nil)
            }
          } else {
            controller.presentLibrarySearchValidation(
              query: query,
              facet: facet,
              statusURL: statusURL,
              selectsFirstResult: selectsFirstResult
            )
          }
        }
        return
      }
      #endif
        do {
            installationLock = try LibreReverseInstallationLock(directory: dataDirectory)
        } catch {
            let alert = LibreReverseApplicationAlerts.make(.libraryError(error.localizedDescription))
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(
          UserDefaults.standard.bool(
            forKey: LibreReverseCaptureSettingsPreferences.showInDockKey
          ) ? .regular : .accessory
        )
        do {
          try applyPendingDataResetIfNeeded()
        } catch {
          configureStatusItem()
          showRecordingError(error)
          return
        }
        let configuration = libraryConfiguration
        startupTask = Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try LibreReverseLibraryStore.initialize(configuration)
                    try LibreReverseArchiveStore.recoverInterruptedResidency(configuration: configuration)
                }.value
                guard let self, !Task.isCancelled, !self.terminating else { return }
                self.startupReady = true
                self.startupTask = nil
                self.configureStatusItem()
                self.configureUpdateChecks()
                self.configureGlobalHotKeys()
                self.configureScrollToRewind()
                self.resetMeetingLifecycle()
                self.configureMeetingTranscription()
                self.scheduleMeetingSummaries()
                self.resumePendingMeetingTitleUpdates()
                self.startMeetingCaptureRecovery()
                self.installMeetingSystemBoundaryObservers()
                self.startAfterPermissionCheck()
                self.restoreArchiveDestination()
                self.scheduleMeetingWaveformBackfill()
                if let moment = self.pendingStartupMoment {
                    self.pendingStartupMoment = nil
                    self.openTimelineWithSource(.lastSearch)
                    self.timelineWindow?.navigateToMoment(moment)
                } else if self.pendingStartupReopen {
                    self.openTimeline()
                }
                self.pendingStartupReopen = false
      #if DEBUG
      if let fixture = LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_MEETING_UI_FIXTURE"
      ] {
        openTimeline()
        timelineWindow?.presentMeetingUIValidationFixture(fixture)
        if let output = LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_MEETING_UI_FIXTURE_WINDOW_ID"
        ], let windowNumber = timelineWindow?.window?.windowNumber {
          try? String(windowNumber).write(
            toFile: output,
            atomically: true,
            encoding: .utf8
          )
        }
        return
      }
      #endif
            } catch {
                guard let self else { return }
                self.startupTask = nil
                self.configureStatusItem()
                self.showRecordingError(error, operation: "libraryStartup")
            }
        }


    }

    private func seedTimelineActionsFixture(
      sourceURL: URL,
      library: LibreReverseLibraryConfiguration
    ) throws -> LibreReverseTimelineActionsFixtureSeed {
      let start = Date(timeIntervalSince1970: 1_777_124_400)
      let requestedDate = start.addingTimeInterval(1)
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_MEETING_STABILITY_UI_FIXTURE"
      ] == "1" {
        // Exercise the real database-backed audio route, including stationary
        // refreshes, instead of presenting an audio overlay over a screen segment.
        let xid = XID.string(timestamp: UInt32(start.timeIntervalSince1970),
          machineIdentifier: [0x10, 0x20, 0x30], processIdentifier: 0x4050,
          counter: 0x0060_7081)
        let relativePath = VideoStorage.relativePath(xid: xid, date: start)
        let mediaURL = library.mediaRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
          at: mediaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: mediaURL)
        let meeting = try LibreReverseLibraryStore.publishMeeting(
          .init(
            startDate: start, endDate: start.addingTimeInterval(8),
            windowName: "Weekly product review",
            browserURL: "https://meet.google.com/abc-defg-hij",
            relativeMediaPath: relativePath, xid: xid,
            width: 1_920, height: 1_080, frameRate: 15,
            audioStartTime: start, duration: 8,
            transcriptText: "We captured every frame and both audio sources. The restored transcript stays synchronized with playback.",
            transcriptWords: [
              .init(speechSource: "others", word: "captured", timeOffset: 1,
                fullTextOffset: 3, duration: 1),
              .init(speechSource: "me", word: "restored", timeOffset: 3,
                fullTextOffset: 52, duration: 1),
              .init(speechSource: "others", word: "synchronized", timeOffset: 5,
                fullTextOffset: 78, duration: 1),
            ],
            event: .init(title: "Weekly product review",
              participants: "[\"Maya\",\"Jordan\",\"Sam\"]",
              detailsJSON: "{\"provider\":\"googleMeet\",\"calendarTitle\":\"Product\"}")),
          configuration: library)
        return .init(start: start, end: start.addingTimeInterval(8),
          requestedDate: requestedDate, frameID: meeting.frameID,
          segmentID: meeting.segmentID, videoID: meeting.videoID, mediaURL: mediaURL)
      }
      let context = LibreReverseCaptureContext(
        bundleID: "com.google.Chrome",
        windowName: "Timeline actions fixture",
        browserURL: "https://meet.google.com/abc-defg-hij"
      )
      var admitted: [LibreReverseAdmittedFrame] = []
      for frameIndex in 0...30 {
        admitted.append(
          try LibreReverseLibraryStore.admitFrame(
            createdAt: start.addingTimeInterval(Double(frameIndex) / 30),
            imageFileName: "timeline-actions-\(frameIndex).png",
            context: context,
            configuration: library
          )
        )
      }
      let selected = admitted[30]
      guard let segmentID = selected.segmentID else {
        throw LibreReverseLibraryStoreError.sqlite(
          "timeline actions fixture did not create a segment"
        )
      }
      let xid = XID.string(
        timestamp: UInt32(start.timeIntervalSince1970),
        machineIdentifier: [0x10, 0x20, 0x30],
        processIdentifier: 0x4050,
        counter: 0x0060_7080
      )
      let relativePath = VideoStorage.relativePath(xid: xid, date: start)
      let mediaURL = library.mediaRoot.appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(
        at: mediaURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.copyItem(at: sourceURL, to: mediaURL)
      let videoID = try LibreReverseLibraryStore.commitRecordedChunk(
        .init(
          relativeMediaPath: relativePath,
          xid: xid,
          width: 1_920,
          height: 1_080,
          frameRate: 30,
          frames: admitted.enumerated().map {
            .init(frameID: $0.element.id, videoFrameIndex: $0.offset)
          }
        ),
        configuration: library
      )
      return .init(
        start: start,
        end: start.addingTimeInterval(8),
        requestedDate: requestedDate,
        frameID: selected.id,
        segmentID: segmentID,
        videoID: videoID,
        mediaURL: mediaURL
      )
    }

    func application(_ application: NSApplication, open urls: [URL]) {
      routeTimelineDeepLink(urls)
    }

    @objc private func handleGetURLEvent(
      _ event: NSAppleEventDescriptor,
      withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
      guard let value = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
        let url = URL(string: value)
      else { return }
      routeTimelineDeepLink([url])
    }

    private func routeTimelineDeepLink(_ urls: [URL]) {
      guard let date = urls.lazy.compactMap(MomentDeepLink.date(from:)).first
      else { return }
      guard startupReady else {
          pendingStartupMoment = date
          return
      }
      openTimelineWithSource(.lastSearch)
      timelineWindow?.navigateToMoment(date)
    }

    private func startAfterPermissionCheck() {
        // A launch-only diagnostic hook for repeatable UI lifecycle traces.
        // Production bundles never set it.
        if LibreReverseDevelopmentEnvironment.values["LIBREREVERSE_UI_TEST"] == "1" {
            return
        }
        permissionsController.updatePermissions()
        if permissionsController.state.allRequiredPermissionsGranted {
            UserDefaults.standard.set(true, forKey: LibreReverseQuickStartWindowController.completionDefaultsKey)
            startRecording()
            return
        }
        recordingDisabledReason = "required permissions are missing"
        updateStatusItem(.waiting, toolTip: "Allow recording permissions in LibreReverse setup")
        refreshStatusMenu()
        openQuickStart()
    }

    private var setupRecordingStatus: PermissionGrantContract.RecordingStatus {
        if recordingDisabledReason == "LibreReverse is starting" { return .starting }
        if let reason = recordingDisabledReason, reason != "required permissions are missing" {
            return .failed(reason)
        }
        if paused { return .paused }
        if captureTimer != nil { return .recording }
        if recordingTask != nil { return .starting }
        return .waiting
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      if isLibraryUIValidationMode {
        globalHotKeys?.stop()
        globalHotKeys = nil
        timelineWindow?.window?.orderOut(nil)
        timelineWindow = nil
        return .terminateNow
      }
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_MENU_BAR_FIXTURE"
      ] != nil {
        statusItem?.menu = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        self.statusItem = nil
        return .terminateNow
      }
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_ASK_UI_FIXTURE"
      ] != nil {
        askWindow?.close()
        askWindow = nil
        return .terminateNow
      }
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_SEARCH_UI_FIXTURE"
      ] != nil {
        searchFixtureWindow?.close()
        searchFixtureWindow = nil
        return .terminateNow
      }
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_AUDIO_SETTINGS_FIXTURE"
      ] != nil {
        settingsWindow?.close()
        settingsWindow = nil
        return .terminateNow
      }
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_CAPTURE_SETTINGS_FIXTURE"
      ] != nil {
        settingsWindow?.close()
        settingsWindow = nil
        return .terminateNow
      }
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_DAILY_RECAP_UI_FIXTURE"
      ] != nil {
        dailyRecapWindow?.close()
        dailyRecapWindow = nil
        return .terminateNow
      }
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_SHORTCUT_REGISTRATION_PROBE"
      ] != nil {
        globalHotKeys?.stop()
        globalHotKeys = nil
        return .terminateNow
      }
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_STORAGE_SETTINGS_FIXTURE"
      ] != nil {
        settingsWindow?.close()
        settingsWindow = nil
        return .terminateNow
      }
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_SHORTCUTS_SETTINGS_FIXTURE"
      ] != nil {
        settingsWindow?.close()
        settingsWindow = nil
        return .terminateNow
      }
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_PINNED_TRANSCRIPT_UI_FIXTURE"
      ] != nil {
        pinnedTranscriptFixtureWindow?.closeWithoutCallback()
        pinnedTranscriptFixtureWindow = nil
        return .terminateNow
      }
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_MEETING_PLAYBACK_UI_FIXTURE_MEDIA"
      ] != nil {
        timelineWindow?.window?.orderOut(nil)
        timelineWindow = nil
        return .terminateNow
      }
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_MEETING_DETECTION_PROBE_OUTPUT"
      ] != nil {
        meetingDetectionProbeTimer?.cancel()
        meetingDetectionProbeTimer = nil
        meetingDetectionProbeTask?.cancel()
        meetingDetectionProbeTask = nil
        try? meetingDetectionProbeHandle?.close()
        meetingDetectionProbeHandle = nil
        return .terminateNow
      }
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_MEETING_VALIDATION_OUTPUT"
      ] != nil {
        guard meetingValidationSession != nil else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        meetingValidationTask?.cancel()
      meetingWaveformBackfillTask?.cancel()
      meetingWaveformBackfillTask = nil
        Task {
          if let meetingValidationSession,
            meetingValidationSession.state == .recording
              || meetingValidationSession.state == .failed
          {
            _ = try? await meetingValidationSession.stop(
              finalizationReason: "applicationTermination"
            )
          }
          self.meetingValidationSession = nil
          completeTermination(sender)
        }
        return .terminateLater
      }
        guard !terminating else { return .terminateLater }
        guard startupReady else {
            guard let pendingStartup = startupTask else { return .terminateNow }
            terminating = true
            Task {
                await pendingStartup.value
                completeTermination(sender)
            }
            return .terminateLater
        }
        terminating = true
        archiveConnectionGeneration &+= 1
        captureTimer?.cancel()
        captureTimer = nil
        meetingDetectionTimer?.cancel()
        meetingDetectionTimer = nil
        updateCheckTimer?.cancel()
        updateCheckTimer = nil
        meetingRestartIntent.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // Capture handles before clearing them. Cancellation is a request; the
        // installation lock stays held until these owners have actually exited.
        timelineWindow?.closeMutationAdmission()
        let uiMutationTasks = uiMutationLifetime.beginShutdown()
        let settingsTasks = settingsWindow?.beginShutdown() ?? []
        let askTasks = askWindow?.beginShutdown() ?? []
        let recapTasks = dailyRecapWindow?.beginShutdown() ?? []
        let backgroundTasks = [
            archiveRestoreTask, archiveConnectionRetryTask, archiveRetryTask,
            archiveMenuStatusTask, updateCheckTask, updateDownloadTask,
            meetingCaptureRecoveryTask, meetingWaveformBackfillTask,
            meetingRestartTask, meetingValidationTask, starShortcutTask,
            settingsCatalogTask,
        ].compactMap { $0 } + settingsTasks + askTasks + recapTasks + uiMutationTasks
        for task in backgroundTasks { task.cancel() }
        archiveConnectionRetryTask = nil
        archiveRetryTask = nil
        meetingRestartTask = nil
        recordingTask?.cancel()
        meetingSummaryScheduler.cancel()
        Task {
            await LibreReverseShutdownBoundary.complete(
                backgroundTasks: backgroundTasks,
                stopBackground: {
                    // Retire resolvers before awaiting their callers. Provider
                    // transitions already use this same durable drain boundary.
                    await self.drainArchiveDestination()
                    await self.meetingSummaryScheduler.stop()
                },
                finishCapture: {
                    await self.screenshotAdmission.stopAndDrain()
                    await self.recordingTask?.value
                    await self.meetingOperationTask?.value
                    if self.productMeetingSession != nil {
                        await self.stopProductMeeting(reason: .applicationTermination)
                    }
                    if let session = self.meetingValidationSession,
                       session.state == .recording || session.state == .failed {
                        _ = try? await session.stop(finalizationReason: "applicationTermination")
                    }
                    try? await self.recordingSession?.finish()
                    self.recordingSession = nil
                    await self.ocrCoordinator.waitUntilIdle()
                    self.timelineWindow?.window?.orderOut(nil)
                    self.timelineWindow = nil
                    try? self.applyPendingDataResetIfNeeded()
                },
                reply: { self.completeTermination(sender) }
            )
        }
        return .terminateLater
    }

    func applicationWillResignActive(_ notification: Notification) {
        // Explicit dismissal prevents AppKit from automatically restoring a
        // deactivation-hidden timeline when Settings or another app window opens.
        timelineWindow?.dismissForApplicationDeactivation()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard !flag else { return false }
        guard startupReady else {
            pendingStartupReopen = true
            return true
        }
        openTimeline()
        return true
    }

    private func configureStatusItem() {
        // This item is icon-only in every state. A variable-length item can
        // inherit an oversized fitting width from AppKit during menu/window
        // transitions and reserve a large blank span of the menu bar.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusItem(.recording, toolTip: "LibreReverse")

        let menu = NSMenu(title: "LibreReverse")
        menu.delegate = self
        for (groupIndex, group) in LibreReverseMenuBarContract.sectionOrder.enumerated() {
          for id in group {
            let item = NSMenuItem(
              title: "",
              action: action(for: id),
              keyEquivalent: ""
            )
            item.tag = id.rawValue
            item.target = id == .quit ? NSApp : self
            if id == .screenCapture {
              let toggleView = LibreReverseMenuToggleView(
                frame: NSRect(x: 0, y: 0, width: 360, height: 31)
              )
              toggleView.onToggle = { [weak self] in
                guard let self else { return }
                self.toggleRecording()
              }
              item.view = toggleView
            }
            menu.addItem(item)
          }
          if groupIndex < LibreReverseMenuBarContract.sectionOrder.count - 1 {
            let separator = NSMenuItem.separator()
            separator.tag = 190 + groupIndex
            menu.addItem(separator)
          }
        }
        statusItem.menu = menu
        refreshStatusMenu()
    }

    private func action(for id: LibreReverseMenuItemID) -> Selector? {
      switch id {
      case .recordingBanner, .version: nil
      case .search: #selector(openTimeline)
      case .ask: #selector(openAsk)
      case .dailyRecap: #selector(openDailyRecap)
      case .screenCapture: #selector(toggleRecording)
      case .audioCapture: #selector(toggleMeetingRecording)
      case .quickStart: #selector(openQuickStart)
      case .settings: #selector(openSettings)
      case .backup: #selector(openArchiveSettings)
      case .openDataFolder: #selector(openDataFolder)
      case .checkForUpdates: #selector(checkForUpdates)
      case .quit: #selector(NSApplication.terminate(_:))
      }
    }

    private func menuBarSnapshot() -> LibreReverseMenuBarSnapshot {
      if let menuBarFixtureSnapshot { return menuBarFixtureSnapshot }
      let screenAvailable = recordingDisabledReason == nil
        && (recordingSession != nil || captureTimer != nil || paused)
      let version = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
      ) as? String ?? "Development"
      let updateConfiguration = LibreReverseUpdateConfiguration.bundled()
      let updateTitle: String
      let updateEnabled: Bool
      if updateDownloadInProgress {
        updateTitle = "Downloading and Verifying Update…"
        updateEnabled = false
      } else if updateCheckInProgress {
        updateTitle = "Checking for Updates…"
        updateEnabled = false
      } else if let availableUpdate {
        updateTitle = "Update \(availableUpdate.version) Available…"
        updateEnabled = true
      } else if updateCheckError != nil {
        updateTitle = "Update Check Failed — Try Again…"
        updateEnabled = true
      } else if updateConfiguration != nil {
        updateTitle = "Check for Updates…"
        updateEnabled = true
      } else {
        updateTitle = "Updates unavailable in this build"
        updateEnabled = false
      }
      let currentBackupTitle = statusItem?.menu?.item(
        withTag: LibreReverseMenuItemID.backup.rawValue
      )?.title
      return .init(
        recordingDisabledReason: recordingDisabledReason,
        screenCaptureEnabled: screenAvailable && !paused,
        screenCaptureAvailable: screenAvailable,
        audioCaptureEnabled: productMeetingSession != nil || productMeetingStartedAt != nil,
        audioCaptureAvailable: meetingOperationTask == nil,
        backupTitle: currentBackupTitle?.isEmpty == false
          ? currentBackupTitle!
          : "Backup • Not connected",
        versionTitle: "Version \(version)",
        updateTitle: updateTitle,
        updateAvailable: updateEnabled,
        meetingSaveWarning: meetingSaveWarning
      )
    }

    private func menuBarFixtureSnapshot(named name: String) -> LibreReverseMenuBarSnapshot {
      let disabled = name == "disabled"
      let pausedFixture = name == "paused"
      let audio = name == "audio"
      return .init(
        recordingDisabledReason: disabled ? "LibreReverse has been shut down" : nil,
        screenCaptureEnabled: !disabled && !pausedFixture,
        screenCaptureAvailable: !disabled,
        audioCaptureEnabled: audio,
        audioCaptureAvailable: !disabled,
        backupTitle: "Backup • Backed up",
        versionTitle: "Version 0.1",
        updateTitle: "Check for Updates…",
        updateAvailable: true
      )
    }

    private func refreshStatusMenu() {
      guard let menu = statusItem?.menu else { return }
      let presentations = LibreReverseMenuBarContract.presentations(
        snapshot: menuBarSnapshot(),
        shortcuts: menuBarFixtureSnapshot == nil
          ? LibreReverseShortcutPreferences.load()
          : .defaults
      )
      for presentation in presentations {
        guard let item = menu.item(withTag: presentation.id.rawValue) else { continue }
        item.title = presentation.title
        item.isEnabled = presentation.isEnabled
        item.isHidden = presentation.isHidden
        item.state = presentation.isOn.map { $0 ? .on : .off } ?? .off
        item.image = presentation.symbolName.flatMap {
          NSImage(systemSymbolName: $0, accessibilityDescription: presentation.title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
        let shortcut = LibreReverseMenuBarContract.keyEquivalent(
          for: presentation.shortcut
        )
        item.keyEquivalent = shortcut.key
        item.keyEquivalentModifierMask = shortcut.modifiers
        item.setAccessibilityLabel(presentation.title)
        item.setAccessibilityValue(
          presentation.isOn.map { $0 ? "On" : "Off" }
        )
        (item.view as? LibreReverseMenuToggleView)?.update(
          title: presentation.title,
          symbolName: presentation.symbolName,
          isOn: presentation.isOn ?? false,
          isEnabled: presentation.isEnabled,
          shortcut: presentation.shortcut
        )
      }
      // The separator below the optional banner disappears with the banner.
      menu.item(withTag: 190)?.isHidden = menuBarSnapshot().recordingDisabledReason == nil && meetingSaveWarning == nil
    }

    func menuWillOpen(_ menu: NSMenu) {
      refreshStatusMenu()
      if menuBarFixtureSnapshot == nil { updateArchiveMenuStatus() }
    }

    private func updateStatusItem(
        _ state: LibreReverseStatusIconState,
        toolTip: String
    ) {
        guard let button = statusItem?.button else { return }
        button.title = ""
        let resolvedState: LibreReverseStatusIconState
        if state == .error {
            resolvedState = state
        } else if let captureState = productMeetingSession?.state {
            switch captureState {
            case .idle, .starting: resolvedState = .meetingStarting
            case .recording: resolvedState = state == .meetingFinishing ? .meetingFinishing : .meetingRecording
            case .stopping, .completed: resolvedState = .meetingFinishing
            case .failed: resolvedState = .error
            }
        } else {
            resolvedState = state
        }
        button.image = LibreReverseStatusIcon.image(for: resolvedState)
        button.imagePosition = .imageOnly
        button.toolTip = resolvedState == .meetingRecording ? resolvedState.statusDescription : toolTip
        button.setAccessibilityLabel("LibreReverse")
        button.setAccessibilityValue(resolvedState.statusDescription)
    }

    private func configureGlobalHotKeys() {
        let settings = LibreReverseShortcutPreferences.load()
        let registrar = LibreReverseGlobalHotKeyRegistrar()
        do {
            try registrar.start(settings: settings) { [weak self] action in
                self?.performShortcutAction(action)
            }
            globalHotKeys = registrar
        } catch {
            statusItem.button?.toolTip = "LibreReverse shortcut registration failed: \(error)"
        }
    }

    private func performShortcutAction(_ action: LibreReverseShortcutAction) {
      if isLibraryUIValidationMode {
        // Register the real shortcut set so conflicts and Search invocation are
        // exercised, while every non-Search chord is a guaranteed no-op.
        if action == .openTimeline { openTimelineWithSource(.lastSearch) }
        return
      }
      switch action {
      case .toggleCapture:
        // Manual meeting capture is the product's mic/speaker transcription
        // boundary. The ordinary screen-history pause is a distinct command.
        toggleMeetingRecording()
      case .openTimeline:
        openTimelineWithSource(.lastSearch)
      case .dailyRecap:
        openDailyRecap()
      case .starCurrentMoment:
        if let timelineWindow, timelineWindow.window?.isVisible == true {
          timelineWindow.starCurrentMomentFromShortcut()
        } else {
          starLatestRecordedMoment()
        }
      case .askRewind:
        openAsk()
      }
    }

    private func applyShortcutSettings(
      _ settings: LibreReverseShortcutSettings
    ) throws {
      let settings = try settings.validated()
      let previous = LibreReverseShortcutPreferences.load()
      globalHotKeys?.stop()
      let replacement = LibreReverseGlobalHotKeyRegistrar()
      do {
        try replacement.start(settings: settings) { [weak self] action in
          self?.performShortcutAction(action)
        }
      } catch {
        let restored = LibreReverseGlobalHotKeyRegistrar()
        try? restored.start(settings: previous) { [weak self] action in
          self?.performShortcutAction(action)
        }
        globalHotKeys = restored
        throw error
      }
      try LibreReverseShortcutPreferences.save(settings)
      globalHotKeys = replacement
      scrollToRewind?.setEnabled(settings.scrollToRewindEnabled)
      updateScrollToRewindMenuState(settings.scrollToRewindEnabled)
      refreshStatusMenu()
    }

    private func configureScrollToRewind() {
        let controller = LibreReverseScrollToRewindController(
            isTimelineOpen: { [weak self] in
                self?.timelineWindow?.window?.isVisible == true
            },
            openHandler: { [weak self] event, isGlobal in
                self?.openTimelineWithSource(
                    .blankSearchFromScroll,
                    forwardingGlobalScrollEvent: isGlobal ? event : nil
                )
            }
        )
      let enabled = LibreReverseShortcutPreferences.load().scrollToRewindEnabled
        controller.setEnabled(enabled)
        scrollToRewind = controller
        updateScrollToRewindMenuState(enabled)
    }

    private func startRecording() {
        guard !terminating, !dataResetRequiresRestart else { return }
        guard recordingTask == nil, captureTimer == nil else { return }
        do {
            let session = try makeRecordingSession()
            recordingSession = session
            recordingTask = Task { [weak self] in
                _ = await self?.ocrCoordinator.recoverPendingSourceImages()
                _ = try? await session.recoverDeferredFrames()
                _ = await self?.ocrCoordinator.reconcileDurableSourceImages()
                guard let self, !Task.isCancelled, !terminating else { return }
                installCaptureScheduler(session: session)
          installMeetingDetectionScheduler()
        }
      } catch {
        showRecordingError(error)
      }
    }

    /// Explicit developer mode for the first meeting-capture milestone. Launch
    /// the signed app executable with `LIBREREVERSE_MEETING_VALIDATION_OUTPUT` set
    /// to a fresh directory while the deterministic local/YouTube fixture plays.
    /// It bypasses meeting detection and the canonical library by design.
    private func startMeetingValidationMode(outputDirectory: URL) {
      let environment = LibreReverseDevelopmentEnvironment.values
      let duration = max(
        Double(environment["LIBREREVERSE_MEETING_VALIDATION_DURATION"] ?? "30") ?? 30,
        0.25
      )
      let frameRate = max(
        Int(environment["LIBREREVERSE_MEETING_VALIDATION_FPS"] ?? "60") ?? 60,
        1
      )
      let expectedSourceFrameRate = max(
        Int(
          environment[
            "LIBREREVERSE_MEETING_VALIDATION_SOURCE_FPS"
          ] ?? "30") ?? 30,
        1
      )
      let capturesSystemAudio =
        environment[
          "LIBREREVERSE_MEETING_VALIDATION_SYSTEM_AUDIO"
        ] != "0"
      let capturesMicrophone =
        environment[
          "LIBREREVERSE_MEETING_VALIDATION_MICROPHONE"
        ] == "1"
      let microphoneDeviceID = environment[
        "LIBREREVERSE_MEETING_VALIDATION_MICROPHONE_DEVICE_ID"
      ].flatMap { $0.isEmpty ? nil : $0 }
      let rawInterruptionAfter = environment[
        "LIBREREVERSE_MEETING_VALIDATION_INTERRUPT_AFTER"
      ]
      let parsedInterruptionAfter = rawInterruptionAfter.flatMap(Double.init)
      let interruptionAfter = parsedInterruptionAfter.flatMap { value in
        value.isFinite ? max(0.25, min(duration, value)) : nil
      }
      let displayID = CGMainDisplayID()
      let configuration = HighFidelityMeetingCaptureConfiguration(
        outputURL: outputDirectory.appendingPathComponent("capture.mp4"),
        manifestURL: outputDirectory.appendingPathComponent("manifest.json"),
        displayID: displayID,
        frameRate: frameRate,
        expectedSourceFrameRate: expectedSourceFrameRate,
        capturesSystemAudio: capturesSystemAudio,
        capturesMicrophone: capturesMicrophone,
        microphoneDeviceID: microphoneDeviceID,
        requestedDurationSeconds: duration
      )
      do {
        if rawInterruptionAfter != nil,
          parsedInterruptionAfter?.isFinite != true
        {
          throw HighFidelityMeetingCaptureError.invalidRequestedDuration(
            parsedInterruptionAfter ?? .nan
          )
        }
        try FileManager.default.createDirectory(
          at: outputDirectory,
          withIntermediateDirectories: true
        )
        let session = try HighFidelityMeetingCaptureSession(configuration: configuration)
        meetingValidationSession = session
        updateStatusItem(
          .waiting,
          toolTip: "LibreReverse meeting validation is starting"
        )
        meetingValidationTask = Task { [weak self] in
          guard let self else { return }
          do {
            try await session.start()
            updateStatusItem(
              .recording,
              toolTip: "LibreReverse is validating dense meeting A/V capture"
            )
            let captureDuration = interruptionAfter ?? duration
            try await Task.sleep(
              nanoseconds: UInt64(captureDuration * 1_000_000_000)
            )
            if interruptionAfter != nil {
              await session.interruptForValidation(
                reason: "Configured validation interruption"
              )
            }
            let manifest = try await session.stop(
              finalizationReason: interruptionAfter == nil
                ? "configuredDurationElapsed"
                : "injectedInterruption"
            )
            meetingValidationSession = nil
            let message =
              "MEETING_VALIDATION complete video=\(manifest.timestamps.video.sampleBufferCount) audioBuffers=\(manifest.timestamps.audio.sampleBufferCount) manifest=\(configuration.manifestURL.path)\n"
            FileHandle.standardOutput.write(Data(message.utf8))
            NSApp.terminate(nil)
          } catch is CancellationError {
            // `applicationShouldTerminate` owns orderly finalization.
          } catch {
            if !terminating,
              session.state == .recording || session.state == .failed
            {
              _ = try? await session.stop(finalizationReason: "validationError")
            }
            meetingValidationSession = nil
            let message = "MEETING_VALIDATION failed: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            showRecordingError(error)
            if !terminating { NSApp.terminate(nil) }
          }
            }
        } catch {
            showRecordingError(error)
        let message = "MEETING_VALIDATION failed: \(error)\n"
        FileHandle.standardError.write(Data(message.utf8))
        NSApp.terminate(nil)
        }
    }

    private func makeRecordingSession() throws -> ScreenRecordingSession {
        try ScreenRecordingSession(
            outputDirectory: libraryConfiguration.mediaRoot,
            libraryConfiguration: libraryConfiguration,
            onChunkFinalized: { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleArchiveWork() }
            }
        )
    }

    private func installCaptureScheduler(session: ScreenRecordingSession) {
        guard captureTimer == nil else { return }
        // LibreReverse recovery is a pre-start library repair. Once that boundary
        // completes, preserve RecordingController.resume(forceResume:)'s exact
        // ordering: takeScreenshot before constructing the repeating timer.
        enqueueCaptureAttempt(session: session)

        let interval = CaptureContract.productionCaptureIntervalSeconds
        let timer = DispatchSource.makeTimerSource(flags: [], queue: nil)
        // RWCore.DispatchTimer schedules at now + interval, repeats at that
        // interval, and passes exactly zero nanoseconds of leeway.
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .nanoseconds(
                CaptureContract.captureTimerLeewayNanoseconds
            )
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.terminating,
            let session = self.recordingSession
          else { return }
                self.enqueueCaptureAttempt(session: session)
            }
        }
        captureTimer = timer
        timer.resume()
        recordingDisabledReason = nil
        updateStatusItem(.recording, toolTip: "LibreReverse is recording")
        refreshStatusMenu()
    }

    private func installMeetingDetectionScheduler() {
      guard meetingDetectionTimer == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.schedule(deadline: .now() + 1, repeating: 5)
      timer.setEventHandler { [weak self] in
        self?.pollMeetingDetection()
      }
      meetingDetectionTimer = timer
      timer.resume()
    }

    private func startMeetingDetectionProbe(outputDirectory: URL) {
      let environment = LibreReverseDevelopmentEnvironment.values
      let duration = max(
        Double(environment["LIBREREVERSE_MEETING_DETECTION_PROBE_DURATION"] ?? "30")
          ?? 30,
        0.5
      )
      let pollInterval = max(
        Double(
          environment[
            "LIBREREVERSE_MEETING_DETECTION_PROBE_INTERVAL"
          ] ?? "1") ?? 1,
        0.25
      )
      let traceURL = outputDirectory.appendingPathComponent("observations.jsonl")
      do {
        try FileManager.default.createDirectory(
          at: outputDirectory,
          withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: traceURL.path) else {
          throw CocoaError(.fileWriteFileExists)
        }
        guard FileManager.default.createFile(atPath: traceURL.path, contents: nil) else {
          throw CocoaError(.fileWriteUnknown)
        }
        meetingDetectionProbeHandle = try FileHandle(forWritingTo: traceURL)
      } catch {
        let message = "MEETING_DETECTION_PROBE failed to open output: \(error)\n"
        FileHandle.standardError.write(Data(message.utf8))
        NSApp.terminate(nil)
        return
      }

      meetingDetectionProbeStart = Date()
      meetingDetectionProbePollCount = 0
      meetingDetectionProbeFailureCount = 0
      meetingDetectionProbeProviderCounts = [:]
      meetingDetectionProbeIdentitySecret =
        LibreReverseMeetingDetectionProbeRecord.makeEphemeralIdentitySecret()
      let lifecycleStartPolicy =
        LibreReverseMeetingStartPolicy(
          rawValue: environment[
            "LIBREREVERSE_MEETING_DETECTION_PROBE_START_POLICY"
          ] ?? "ask"
        ) ?? .ask
      let simulatesCaptureAcknowledgements =
        environment[
          "LIBREREVERSE_MEETING_DETECTION_PROBE_SIMULATE_CAPTURE_ACKNOWLEDGEMENTS"
        ] == "1"
      meetingDetectionProbeLifecycle = LibreReverseMeetingProbeLifecycleSimulator(
        configuration: .init(startPolicy: lifecycleStartPolicy),
        simulatesCaptureAcknowledgements: simulatesCaptureAcknowledgements
      )
      recordMeetingDetectionProbePoll()
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
      timer.setEventHandler { [weak self] in
        self?.recordMeetingDetectionProbePoll()
      }
      meetingDetectionProbeTimer = timer
      timer.resume()
      updateStatusItem(.waiting, toolTip: "LibreReverse is probing meeting detection")
      meetingDetectionProbeTask = Task { [weak self] in
        do {
          try await Task.sleep(
            nanoseconds: UInt64(duration * 1_000_000_000)
          )
        } catch {
          return
        }
        self?.finishMeetingDetectionProbe(outputDirectory: outputDirectory)
      }
    }

    private func recordMeetingDetectionProbePoll() {
      let now = Date()
      let pollIndex = meetingDetectionProbePollCount
      let record: LibreReverseMeetingDetectionProbeRecord
      do {
        let observations = try currentMeetingObservations()
        let candidates = LibreReverseMeetingDetector.candidates(from: observations)
        for candidate in candidates {
          meetingDetectionProbeProviderCounts[candidate.provider.rawValue, default: 0] +=
            1
        }
        let lifecycleStep = meetingDetectionProbeLifecycle.step(
          candidates: candidates,
          at: now
        )
        record = .init(
          recordedAt: now,
          pollIndex: pollIndex,
          observations: observations,
          candidates: candidates,
          identitySecret: meetingDetectionProbeIdentitySecret,
          dryRunLifecycleState: lifecycleStep.state,
          dryRunLifecycleCommand: lifecycleStep.command
        )
      } catch {
        meetingDetectionProbeFailureCount += 1
        let lifecycleStep = meetingDetectionProbeLifecycle.step(
          candidates: [],
          at: now
        )
        record = .init(
          recordedAt: now,
          pollIndex: pollIndex,
          observations: [],
          candidates: [],
          identitySecret: meetingDetectionProbeIdentitySecret,
          dryRunLifecycleState: lifecycleStep.state,
          dryRunLifecycleCommand: lifecycleStep.command,
          collectionFailed: true
        )
      }
      meetingDetectionProbePollCount += 1
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      guard var data = try? encoder.encode(record) else { return }
      data.append(0x0A)
      try? meetingDetectionProbeHandle?.write(contentsOf: data)
      try? meetingDetectionProbeHandle?.synchronize()
    }

    private func finishMeetingDetectionProbe(outputDirectory: URL) {
      meetingDetectionProbeTimer?.cancel()
      meetingDetectionProbeTimer = nil
      try? meetingDetectionProbeHandle?.synchronize()
      try? meetingDetectionProbeHandle?.close()
      meetingDetectionProbeHandle = nil
      meetingDetectionProbeIdentitySecret = nil
      let summary = LibreReverseMeetingDetectionProbeSummary(
        schemaVersion: 3,
        startedAt: meetingDetectionProbeStart ?? Date(),
        finishedAt: Date(),
        pollCount: meetingDetectionProbePollCount,
        collectionFailureCount: meetingDetectionProbeFailureCount,
        providerCandidateCounts: meetingDetectionProbeProviderCounts,
        screenRecordingAuthorized: CGPreflightScreenCaptureAccess(),
        accessibilityAuthorized: AXIsProcessTrusted(),
        lifecycleStartPolicy: meetingDetectionProbeLifecycle.configuration.startPolicy,
        simulatesCaptureAcknowledgements:
          meetingDetectionProbeLifecycle.simulatesCaptureAcknowledgements
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let summaryURL = outputDirectory.appendingPathComponent("summary.json")
      if let data = try? encoder.encode(summary) {
        try? data.write(to: summaryURL, options: .atomic)
      }
      let message =
        "MEETING_DETECTION_PROBE complete polls=\(summary.pollCount) failures=\(summary.collectionFailureCount) output=\(outputDirectory.path)\n"
      FileHandle.standardOutput.write(Data(message.utf8))
      meetingDetectionProbeTask = nil
      NSApp.terminate(nil)
    }

    private func enqueueCaptureAttempt(
      session: ScreenRecordingSession,
      allowMeetingOperation: Bool = false
    ) {
      guard !paused, !terminating, meetingRestartTask == nil,
        MeetingCaptureFinalizationPolicy.allowsSparseCapture(
          hasMeetingSession: productMeetingSession != nil,
          hasMeetingOperation: meetingOperationTask != nil,
          nativeRecordingFinished: meetingNativeRecordingFinished,
          allowMeetingOperation: allowMeetingOperation)
      else { return }
        Task { [weak self] in
            guard let self else { return }
        guard await meetingCaptureHandoff.beginSparseCapture() else { return }
            switch await screenshotAdmission.beginScreenshot() {
            case .dropped:
          await meetingCaptureHandoff.finishSparseCapture()
                return
            case .admitted:
                break
            }

        guard !paused, !terminating, meetingRestartTask == nil,
          MeetingCaptureFinalizationPolicy.allowsSparseCapture(
            hasMeetingSession: productMeetingSession != nil,
            hasMeetingOperation: meetingOperationTask != nil,
            nativeRecordingFinished: meetingNativeRecordingFinished,
            allowMeetingOperation: allowMeetingOperation)
        else {
          await screenshotAdmission.finishScreenshot()
          await meetingCaptureHandoff.finishSparseCapture()
          return
        }

            do {
                let captureSession = try await recordingSessionForCurrentInterval(
                    session,
                    at: Date()
                )
                let snapshot = try currentCaptureSnapshot()
                let context = snapshot.context
                let frame = try await Self.captureFrame(snapshot)
                let captureDate = Date()
                let ingestResult = try await captureSession.ingestWithAdmission(
                    frame,
                    at: captureDate,
                    context: context
                )
                if lastRecordingErrorOperation == "sparseCapture" {
                    logRecordingEvent("recovered", operation: "sparseCapture")
                    lastRecordingErrorOperation = nil
                    recordingDisabledReason = nil
                    updateStatusItem(.recording, toolTip: "LibreReverse is recording")
                    refreshStatusMenu()
                }
                // RecordingUpdate.screenFrame follows the diff gate, source
                // PNG write, and canonical Frame / Segment creation.
                if ingestResult.decision.admitted {
                    latestLiveCapture = (frame, captureDate, ingestResult.admittedFrame)
                    if let admittedFrame = ingestResult.admittedFrame {
                        ocrCoordinator.enqueue(
                            frameID: admittedFrame.id,
                            imageFileName: admittedFrame.imageFileName,
                            displayBounds: snapshot.displayBounds,
                            frontWindowBounds: snapshot.frontWindowBounds
                        )
                    }
                    // Keep the latest capture for the next opening, but avoid
                    // rebuilding the retained viewer while it is offscreen.
                    if timelineWindow?.window?.isVisible == true {
                        timelineWindow?.showLiveFrame(
                            frame,
                            at: captureDate,
                            admittedFrame: ingestResult.admittedFrame
                        )
                    }
                }
            } catch {
                showRecordingError(error, operation: "sparseCapture")
            }
            await screenshotAdmission.finishScreenshot()
        await meetingCaptureHandoff.finishSparseCapture()
        }
    }

    private func recordingSessionForCurrentInterval(
        _ session: ScreenRecordingSession,
        at date: Date
    ) async throws -> ScreenRecordingSession {
        if session.requiresRecovery {
            // Do not admit new PNGs into a terminal writer. Replay durable
            // source frames first; a failed retry leaves the old session marked
            // for recovery so the next timer tick retries without growing it.
            let replacement = try makeRecordingSession()
            _ = try await replacement.recoverDeferredFrames()
            recordingSession = replacement
            return try await recordingSessionForCurrentInterval(replacement, at: date)
        }
        if captureShardBoundary == nil {
            if let ordinal = try LibreReverseShardStore.activeOrdinal(
                configuration: libraryConfiguration
            ) {
                let epoch = try LibreReverseShardStore.epochStart(
                    configuration: libraryConfiguration
                )
          captureShardBoundary =
            LibreReverseShardInterval(
                    ordinal: ordinal,
                    epochStart: epoch
                ).end
            } else {
                captureShardBoundary = .distantFuture
            }
        }
      guard let boundary = captureShardBoundary, date >= boundary else { return session }
      // Native capture can finish before speech processing and publication.
      // Keep accepting sparse frames in this primary until all publishers drain;
      // the next rollover partitions every elapsed interval by recorded date.
      guard LibreReverseMeetingPersistenceAdmission.canReplacePrimary(
        hasMeetingSession: productMeetingSession != nil,
        hasMeetingOperation: meetingOperationTask != nil,
        captureRecoveryInProgress: meetingCaptureRecoveryInProgress
      ) else { return session }

      // Finalize the current MP4 first so the compact catalog and the shard
      // contain the same complete Frame->Video assignments.
      do {
        try await session.finish(at: date)
      } catch {
        return try await recoverSparseCaptureBacklog(
          at: date,
          error: error
        )
      }
      // Retry durable failures before deciding whether this interval can seal.
      // A drained dispatch queue alone does not mean every frame was indexed.
      _ = await ocrCoordinator.recoverPendingSourceImages()
      await ocrCoordinator.waitUntilIdle()
      await timelineWindow?.prepareForPrimaryReplacement()
      if let archiveWorkTask {
        archiveWorkTask.cancel()
        await archiveWorkTask.value
      }
      let configuration = libraryConfiguration
      let transcriptionQueue = meetingTranscriptionQueue
      let result: LibreReverseShardRolloverResult?
      do {
        result = try await Task.detached(priority: .utility) {
          try LibreReverseShardRollover.performIfNeeded(
            at: date,
            configuration: configuration,
            transcriptionQueue: transcriptionQueue
          )
        }.value
      } catch let rolloverError as LibreReverseShardRolloverError {
        switch rolloverError {
        case .pendingSparseFrameRecovery:
          // This recovery path can also be entered before the reader
          // barrier, so reopen it here rather than inside the shared
          // sparse-backlog helper.
          await timelineWindow?.primaryReplacementDidComplete()
          return try await recoverSparseCaptureBacklog(
            at: date,
            error: rolloverError
          )
        case .pendingMeetingTranscriptions, .unresolvedMeetingTranscriptionJobs:
          // Keep capture live in the monolith while the durable runner
          // finishes meetings that would otherwise be stranded in a
          // sealed shard. A later retry can partition all accumulated
          // frames by timestamp without losing correctness.
          return try await resumeSparseCaptureAfterRolloverFailure(
            at: date,
            retryAfter: rolloverError.retryDelay,
            error: rolloverError,
            wakeTranscription: true
          )
        default:
          return try await resumeSparseCaptureAfterRolloverFailure(
            at: date,
            retryAfter: rolloverError.retryDelay,
            error: rolloverError,
            wakeTranscription: false
          )
        }
      } catch {
        return try await resumeSparseCaptureAfterRolloverFailure(
          at: date,
          retryAfter: 15 * 60,
          error: error,
          wakeTranscription: false
        )
      }

      do {
        let replacement = try makeRecordingSession()
        recordingSession = replacement
        if let result {
          captureShardBoundary = result.primary.activeInterval.end
        } else if let ordinal = try LibreReverseShardStore.activeOrdinal(
          configuration: libraryConfiguration
        ) {
          let epoch = try LibreReverseShardStore.epochStart(
            configuration: libraryConfiguration
          )
          captureShardBoundary =
            LibreReverseShardInterval(
              ordinal: ordinal,
              epochStart: epoch
            ).end
        }
        await timelineWindow?.primaryReplacementDidComplete()
        scheduleArchiveWork()
        return replacement
      } catch {
        await timelineWindow?.primaryReplacementDidComplete()
        scheduleArchiveWork()
        throw error
      }
    }

    /// A failed AVAssetWriter becomes terminal and cannot accept another
    /// sample. A launch-era backlog can also predate the current writer.
    /// Canonical source PNGs and deferred Frame rows remain the recovery
    /// authority in both cases, so move the timer to a fresh session and replay
    /// that backlog before attempting shard maintenance again.
    private func recoverSparseCaptureBacklog(
      at date: Date,
      error: Error
    ) async throws -> ScreenRecordingSession {
      NSLog(
        "Sparse capture recovery required before shard rollover: %@",
        error.localizedDescription
      )
      let recovery = try makeRecordingSession()
      recordingSession = recovery
      captureShardBoundary = date.addingTimeInterval(15 * 60)
      do {
        let recovered = try await recovery.recoverDeferredFrames()
        NSLog("Recovered %d deferred sparse frame(s) after finalization failure", recovered)
        scheduleArchiveWork()
        return recovery
      } catch {
        // The backlog stays durable for a later retry. Never leave the
        // capture timer pointing at the terminal writer that first failed.
        NSLog("Deferred sparse-frame recovery failed: %@", error.localizedDescription)
        let replacement = try makeRecordingSession()
        recordingSession = replacement
        scheduleArchiveWork()
        return replacement
      }
    }

    /// Rollover never makes a failed candidate authoritative before the atomic
    /// swap. If validation fails after that swap, the installed primary is
    /// still the only authoritative filename. Reopening through the ordinary
    /// session factory is therefore the safe recovery path in both cases.
    private func resumeSparseCaptureAfterRolloverFailure(
      at date: Date,
      retryAfter delay: TimeInterval,
      error: Error,
      wakeTranscription: Bool
    ) async throws -> ScreenRecordingSession {
      NSLog("Shard rollover deferred: %@", error.localizedDescription)
      do {
        try LibreReverseLibraryStore.initialize(libraryConfiguration)
        let replacement = try makeRecordingSession()
        recordingSession = replacement
        captureShardBoundary = date.addingTimeInterval(delay)
        if let ordinal = try LibreReverseShardStore.activeOrdinal(
          configuration: libraryConfiguration
        ) {
          let epoch = try LibreReverseShardStore.epochStart(
            configuration: libraryConfiguration
          )
          let active = LibreReverseShardInterval(
            ordinal: ordinal,
            epochStart: epoch
          )
          // A post-swap validation error can still leave a correctly
          // advanced authoritative primary. Avoid needlessly retrying
          // before that primary's real next boundary.
          if active.contains(date) {
            captureShardBoundary = active.end
          }
        }
        await timelineWindow?.primaryReplacementDidComplete()
        if wakeTranscription {
          scheduleMeetingTranscription(restart: true)
        }
        scheduleArchiveWork()
        return replacement
      } catch {
        // Never leave readers parked merely because sparse writer recovery
        // also failed. The outer capture loop reports the recovery error.
        await timelineWindow?.primaryReplacementDidComplete()
        scheduleArchiveWork()
        throw error
      }
    }

    @objc private func toggleRecording() {
      guard startupReady, !dataResetRequiresRestart else { return }
      paused.toggle()
      updateStatusItem(
        paused ? .paused : .recording,
        toolTip: paused ? "LibreReverse recording is paused" : "LibreReverse is recording"
      )
      refreshStatusMenu()
      updatePausedReminderSchedule()
    }

    @objc private func toggleMeetingRecording() {
      guard startupReady, !dataResetRequiresRestart else { return }
      guard meetingOperationTask == nil else { return }
      if meetingRestartTask != nil {
        meetingRestartTask?.cancel()
        meetingRestartTask = nil
        if let candidate = meetingRestartIntent.cancelForUserStop() {
          meetingIgnoreTracker.ignore(candidate)
        }
        resetMeetingLifecycle()
        updateMeetingMenu(recording: false)
        timelineWindow?.clearMeetingRecording()
        Task { @MainActor [weak self] in
          guard let self else { return }
          await meetingCaptureHandoff.finishMeetingCapture()
          if let recordingSession, !paused, !terminating {
            enqueueCaptureAttempt(session: recordingSession)
          }
        }
        return
      }
      if productMeetingSession != nil {
        if let candidate = productMeetingCandidate {
          meetingIgnoreTracker.ignore(candidate)
        }
        let command = meetingLifecycle.requestStop(.userRequested)
        guard command == .stopCapture(.userRequested) else { return }
        meetingOperationTask = Task { [weak self] in
          await self?.stopProductMeeting(reason: .userRequested)
          self?.meetingOperationTask = nil
        }
        return
      }
      guard !meetingCaptureRecoveryInProgress else {
        updateStatusItem(.waiting, toolTip: "LibreReverse is recovering a previous meeting. Try starting again when recovery finishes.")
        return
      }
      let title = "Meeting · " + Date().formatted(date: .abbreviated, time: .shortened)
      guard case .startCapture(let candidate) = meetingLifecycle.startManual(title: title)
      else { return }
      beginProductMeeting(candidate)
    }

    private func promptForMeetingTitle(
      initialTitle: String,
      message: String
    ) -> String? {
      let alert = LibreReverseApplicationAlerts.make(.meetingTitle(initialTitle: initialTitle, message: message))
      guard let field = alert.accessoryView as? NSTextField else { return nil }
      NSApp.activate(ignoringOtherApps: true)
      field.selectText(nil)
      guard alert.runModal() == .alertFirstButtonReturn else { return nil }
      return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func renameActiveMeeting() {
      guard productMeetingSession != nil,
        meetingOperationTask == nil,
        let initialCandidate = productMeetingCandidate,
        let title = promptForMeetingTitle(
          initialTitle: initialCandidate.title ?? "",
          message:
            "The new title will be used in the transcript, search, timeline, and archived meeting."
        )
      else { return }
      // NSAlert runs a nested event loop. Detection, storage pressure, or a
      // menu stop may have finalized the capture while the editor was open,
      // so re-resolve every journal owner before performing a synchronous
      // atomic rewrite on the main actor.
      guard productMeetingSession != nil,
        meetingOperationTask == nil,
        let candidate = productMeetingCandidate,
        candidate.identity == initialCandidate.identity,
        let stagingURL = productMeetingStagingURL,
        let expectedXID = productMeetingPublicationXID
      else { return }
      let updated = candidate.updatingTitle(title)
      guard updated != candidate else { return }
      do {
        let directory = stagingURL.deletingLastPathComponent()
        let journal = try LibreReverseMeetingCaptureJournal.read(from: directory)
        guard journal.publicationXID == expectedXID,
          journal.candidate.identity == candidate.identity
        else {
          throw LibreReverseMeetingConfigurationError.captureJournalMismatch
        }
        try journal.updatingCandidate(updated).write(to: directory)
        productMeetingCandidate = updated
        presentActiveMeetingRecordingIfNeeded()
      } catch {
        showRecordingError(error)
      }
    }

    private func pollMeetingDetection() {
      guard !terminating else { return }
      let diagnosticsEnabled = UserDefaults.standard.bool(forKey: LibreReverseMeetingDetectionDiagnostics.enabledDefaultsKey)
      var diagnosticsPhase = "gated"
      var diagnosticCounters = ["recoveryInProgress": meetingCaptureRecoveryInProgress ? 1 : 0,
                                "hasSession": productMeetingSession != nil ? 1 : 0,
                                "hasOperation": meetingOperationTask != nil ? 1 : 0,
                                "hasIgnoredCandidate": meetingIgnoreTracker.ignoredCandidate != nil ? 1 : 0]
      defer {
        if diagnosticsEnabled {
          try? LibreReverseMeetingDetectionDiagnostics.append(.init(timestamp: Date(),
            phase: diagnosticsPhase, policy: currentMeetingStartPolicy().rawValue,
            lifecycle: LibreReverseMeetingDetectionDiagnostics.lifecycleName(meetingLifecycle.state),
            counters: diagnosticCounters), to: dataDirectory.appendingPathComponent("Logs", isDirectory: true))
        }
      }
      guard !meetingCaptureRecoveryInProgress else { return }
      if handleMeetingStoragePressure() { return }
      if handleMeetingAudioPermissionChange() { return }
      if handleMeetingAudioRouteChange() { return }
      if productMeetingSession?.terminalErrorDescription() != nil,
        meetingOperationTask == nil
      {
        if let candidate = productMeetingCandidate {
          meetingIgnoreTracker.ignore(candidate)
        }
        let command = meetingLifecycle.requestStop(.captureFailure)
        if command == .stopCapture(.captureFailure) {
          meetingOperationTask = Task { [weak self] in
            await self?.stopProductMeeting(reason: .captureFailure)
            self?.meetingOperationTask = nil
          }
        }
        return
      }
      do {
        let observations = try currentMeetingObservations()
        diagnosticsPhase = "observed"
        diagnosticCounters.merge(foregroundContextProvider.lastMeetingDiagnostics) { _, latest in latest }
        let now = Date()
        var candidates = LibreReverseMeetingDetector.candidates(from: observations)
        if UserDefaults.standard.bool(
          forKey: Self.meetingCalendarEnabledDefaultsKey
        ) {
          candidates = LibreReverseMeetingCalendarCorrelation.correlate(
            candidates: candidates,
            events: meetingCalendarSource.events(
              at: now,
              selectedCalendarIDs: currentMeetingCalendarSelection().eventFilter
            ),
            at: now
          )
        }
        diagnosticCounters["candidatesBeforeIgnore"] = candidates.count
        candidates = meetingIgnoreTracker.candidatesExcludingIgnoredMeeting(
          candidates,
          at: now,
          configuration: meetingLifecycle.configuration
        )
        diagnosticCounters["candidatesAfterIgnore"] = candidates.count
        if let continuation = pendingRecoveredMeetingContinuation {
          switch continuation.decision(liveCandidates: candidates, at: now) {
          case .waiting:
            break
          case .expired:
            pendingRecoveredMeetingContinuation = nil
            try? recoveredMeetingContinuationStore.clear()
          case .resume(let recoveredCandidate):
            if case .startCapture(let candidate) =
              meetingLifecycle.resumeAfterCaptureBoundary(recoveredCandidate)
            {
              beginProductMeeting(candidate)
              return
            }
          }
        }
        var endedCandidates = LibreReverseMeetingDetector.explicitlyEndedCandidates(from: observations)
        if let current = productMeetingCandidate,
            !candidates.contains(where: { LibreReverseMeetingCandidateArbitration.areSameLogicalMeeting($0, current) }),
            foregroundContextProvider.browserMeetingHasEnded(current) {
            endedCandidates.append(current)
        }
        let timestampSnapshot = productMeetingSession?.timestampSnapshot()
        // Only output activity can bridge a temporarily hidden call. The
        // microphone stays open during recording and always contains room
        // noise; counting it here makes meeting termination impossible.
        let voiceCount = timestampSnapshot?.nonSilentAudioSampleBufferCount ?? 0
        let recentVoice = voiceCount > lastMeetingVoiceBufferCount
        lastMeetingVoiceBufferCount = voiceCount
        handleMeetingLifecycleCommand(
          meetingLifecycle.observe(
            candidates,
            at: now,
            outputVoiceActivity: recentVoice,
            explicitlyEndedCandidates: endedCandidates
          ))
      } catch {
        diagnosticsPhase = "observationFailed"
        // A transient WindowServer/AX miss is an empty detector tick; the
        // lifecycle grace period owns whether an active recording ends.
        handleMeetingLifecycleCommand(
          meetingLifecycle.observe(
            [],
            at: Date(),
            outputVoiceActivity: false
          ))
      }
    }

    private func currentMeetingObservations() throws
      -> [LibreReverseMeetingWindowObservation]
    {
      let displayID = try WindowCapture.pointerDisplayID()
      guard
        let allRows = CGWindowListCopyWindowInfo(
          [.optionAll, .excludeDesktopElements],
          kCGNullWindowID
        ) as? [[CFString: Any]]
      else { return [] }
      let visibleRows = allRows.filter {
        ($0[kCGWindowIsOnscreen] as? NSNumber)?.boolValue == true
      }
      return foregroundContextProvider.meetingObservations(
        from: visibleRows,
        allRows: allRows,
        displayBounds: CGDisplayBounds(displayID),
        privacySettings: currentCapturePrivacySettings()
      )
    }

    @discardableResult
    private func handleMeetingStoragePressure() -> Bool {
      guard productMeetingSession != nil,
        meetingOperationTask == nil,
        let availableBytes = availableMeetingStorageBytes(),
        !meetingStorageGuard.hasCapacity(availableBytes: availableBytes)
      else { return false }
      guard
        meetingLifecycle.requestStop(.storagePressure)
          == .stopCapture(.storagePressure)
      else { return false }
      if let candidate = productMeetingCandidate {
        meetingIgnoreTracker.ignore(candidate)
      }
      updateStatusItem(
        .waiting,
        toolTip: "LibreReverse is finalizing this meeting before storage runs out"
      )
      meetingOperationTask = Task { [weak self] in
        await self?.stopProductMeeting(reason: .storagePressure)
        self?.meetingOperationTask = nil
      }
      return true
    }

    private func availableMeetingStorageBytes() -> Int64? {
      var probe = dataDirectory
      while !FileManager.default.fileExists(atPath: probe.path),
        probe.path != probe.deletingLastPathComponent().path
      {
        probe.deleteLastPathComponent()
      }
      if let capacity = try? probe.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey
      ]).volumeAvailableCapacityForImportantUsage {
        return capacity
      }
      return
        (try? FileManager.default.attributesOfFileSystem(
          forPath: probe.path
        )[.systemFreeSize] as? NSNumber)?.int64Value
    }

    @discardableResult
    private func handleMeetingAudioPermissionChange() -> Bool {
      guard let activeSelection = productMeetingAudioSelection,
        productMeetingSession != nil,
        meetingOperationTask == nil
      else { return false }
      permissionsController.updatePermissions()
      var preferences = currentMeetingAudioPreferences()
      if let environmentMicrophoneDeviceID = ProcessInfo.processInfo.environment[
        "LIBREREVERSE_MEETING_MICROPHONE_DEVICE_ID"
      ].flatMap({ $0.isEmpty ? nil : $0 }) {
        preferences.microphoneDeviceID = environmentMicrophoneDeviceID
      }
      let decision = preferences.runtimeDecision(
        from: activeSelection,
        microphoneAuthorized: permissionsController.microphone,
        nativeMicrophoneCaptureSupported: nativeMicrophoneCaptureSupported,
        availableMicrophoneDeviceIDs: Set(
          availableMeetingInputDevices().map(\.id)
        )
      )
      switch decision {
      case .unchanged, .selectedMicrophoneUnavailable:
        // Restoring permission must not replace System Default with a
        // missing exact device. Keep the current system-only segment until
        // the user chooses an available input.
        return false
      case .restart:
        break
      }
      guard
        meetingLifecycle.requestStop(.microphonePermissionChanged)
          == .stopCapture(.microphonePermissionChanged)
      else { return false }
      meetingOperationTask = Task { [weak self] in
        await self?.stopProductMeeting(reason: .microphonePermissionChanged)
        self?.meetingOperationTask = nil
      }
      return true
    }

    @discardableResult
    private func handleMeetingAudioRouteChange() -> Bool {
      guard productMeetingCapturesMicrophone,
        let baseline = productMeetingAudioRouteSnapshot,
        productMeetingSession != nil,
        meetingOperationTask == nil
      else { return false }
      let current = currentMeetingAudioRouteSnapshot()
      guard
        meetingAudioRouteChangeTracker.observe(
          current,
          baseline: baseline,
          requestedDeviceID: productMeetingMicrophoneDeviceID
        )
      else { return false }
      guard
        meetingLifecycle.requestStop(.audioDeviceChanged)
          == .stopCapture(.audioDeviceChanged)
      else { return false }
      meetingOperationTask = Task { [weak self] in
        await self?.stopProductMeeting(reason: .audioDeviceChanged)
        self?.meetingOperationTask = nil
      }
      return true
    }

    private func currentMeetingAudioRouteSnapshot() -> LibreReverseMeetingAudioRouteSnapshot {
      let deviceTypes: [AVCaptureDevice.DeviceType] = [.microphone, .external]
      let devices = AVCaptureDevice.DiscoverySession(
        deviceTypes: deviceTypes,
        mediaType: .audio,
        position: .unspecified
      ).devices
      let defaultInput = AVCaptureDevice.default(for: .audio)
      return .init(
        defaultInputDeviceID: defaultInput?.uniqueID,
        defaultInputRouteName: defaultInput?.localizedName,
        availableInputDeviceIDs: Set(devices.map(\.uniqueID))
      )
    }

    private func handleMeetingLifecycleCommand(
      _ command: LibreReverseMeetingLifecycleCommand
    ) {
      switch command {
      case .none:
        break
      case .presentPrompt(let candidate):
        let alert = LibreReverseApplicationAlerts.make(.meetingDetected(candidate.title))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
          case .startCapture(let accepted) = meetingLifecycle.acceptPrompt()
        {
          beginProductMeeting(accepted)
        } else {
          meetingIgnoreTracker.ignore(candidate)
          _ = meetingLifecycle.ignorePrompt()
        }
      case .dismissPrompt:
        break
      case .startCapture(let candidate):
        beginProductMeeting(candidate)
      case .stopCapture(let reason):
        guard meetingOperationTask == nil else { return }
        meetingOperationTask = Task { [weak self] in
          await self?.stopProductMeeting(reason: reason)
          self?.meetingOperationTask = nil
        }
      }
    }

    @discardableResult
    private func beginProductMeeting(_ candidate: LibreReverseMeetingCandidate) -> Bool {
      guard !dataResetRequiresRestart else { return false }
      guard
        LibreReverseMeetingStartAdmission.canBegin(
          terminating: terminating,
          hasActiveSession: productMeetingSession != nil,
          hasOperationInFlight: meetingOperationTask != nil,
          systemCaptureSuspended: meetingSystemBoundary.captureIsSuspended,
          captureRecoveryInProgress: meetingCaptureRecoveryInProgress
        )
      else { return false }
      let resumesRecoveredMeeting =
        pendingRecoveredMeetingContinuation?.candidate.identity == candidate.identity
      meetingOperationTask = Task { [weak self] in
        guard let self else { return }
        guard await meetingCaptureHandoff.beginMeetingCapture() else {
          resetMeetingLifecycle()
          meetingOperationTask = nil
          return
        }
        guard !terminating, !dataResetRequiresRestart, !Task.isCancelled,
          !meetingCaptureRecoveryInProgress else {
          await meetingCaptureHandoff.finishMeetingCapture()
          meetingOperationTask = nil
          return
        }
        let directory =
          dataDirectory
          .appendingPathComponent("Library/MeetingStaging", isDirectory: true)
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
        updateStatusItem(.meetingStarting, toolTip: "LibreReverse is starting meeting recording")
        var captureReachedRecording = false
        do {
          if !resumesRecoveredMeeting {
            try recoveredMeetingContinuationStore.clear()
            pendingRecoveredMeetingContinuation = nil
          }
          if let availableBytes = availableMeetingStorageBytes() {
            let requiredBytes = meetingStorageGuard.requiredFreeBytes()
            guard availableBytes >= requiredBytes else {
              throw LibreReverseMeetingConfigurationError.insufficientStorage(
                availableBytes: availableBytes,
                requiredBytes: requiredBytes
              )
            }
          }
          try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
          )
          let mediaURL = directory.appendingPathComponent("meeting.mp4")
          let manifestURL = directory.appendingPathComponent("manifest.json")
          let publicationXID = XID.generate()
          let publicationJournal = LibreReverseMeetingCaptureJournal(
            publicationXID: publicationXID,
            candidate: candidate
          )
          try publicationJournal.write(to: directory)
          let nativeMicrophoneCaptureSupported: Bool
          nativeMicrophoneCaptureSupported = self.nativeMicrophoneCaptureSupported
          permissionsController.updatePermissions()
          var audioPreferences = currentMeetingAudioPreferences()
          let environmentMicrophoneDeviceID = ProcessInfo.processInfo.environment[
            "LIBREREVERSE_MEETING_MICROPHONE_DEVICE_ID"
          ].flatMap { $0.isEmpty ? nil : $0 }
          if let environmentMicrophoneDeviceID {
            audioPreferences.microphoneDeviceID = environmentMicrophoneDeviceID
          }
          let audioSelection = audioPreferences.effectiveCaptureSelection(
            microphoneAuthorized: permissionsController.microphone,
            nativeMicrophoneCaptureSupported: nativeMicrophoneCaptureSupported
          )
          if audioSelection.capturesMicrophone,
            let selectedDeviceID = audioSelection.microphoneDeviceID,
            !availableMeetingInputDevices().contains(where: {
              $0.id == selectedDeviceID
            })
          {
            throw LibreReverseMeetingConfigurationError
              .selectedMicrophoneUnavailable
          }
          let session = try HighFidelityMeetingCaptureSession(
            configuration: .init(
              outputURL: mediaURL,
              manifestURL: manifestURL,
              displayID: CGMainDisplayID(),
              frameRate: MeetingVideoCompression.frameRate,
              capturesSystemAudio: audioSelection.capturesSystemAudio,
              capturesMicrophone: audioSelection.capturesMicrophone,
              microphoneDeviceID: audioSelection.microphoneDeviceID,
              publicationXID: publicationXID
            ))
          productMeetingCandidate = candidate
          productMeetingStagingURL = mediaURL
          productMeetingPublicationXID = publicationXID
          productMeetingCapturesMicrophone = audioSelection.capturesMicrophone
          productMeetingMicrophoneDeviceID = audioSelection.microphoneDeviceID
          productMeetingAudioSelection = audioSelection
          productMeetingAudioRouteSnapshot =
            audioSelection.capturesMicrophone
            ? currentMeetingAudioRouteSnapshot() : nil
          meetingAudioRouteChangeTracker.reset()
          productMeetingSession = session
          try await session.start()
          captureReachedRecording = true
          guard let recoveryCheckpoint = session.recoveryCheckpoint() else {
            _ = try? await session.stop(
              finalizationReason: "recoveryCheckpointUnavailable"
            )
            throw CocoaError(.coderInvalidValue)
          }
          do {
            try publicationJournal.checkpointed(recoveryCheckpoint)
              .write(to: directory)
          } catch {
            _ = try? await session.stop(
              finalizationReason: "recoveryCheckpointWriteFailed"
            )
            throw error
          }
          do {
            try recoveredMeetingContinuationStore.clear()
            pendingRecoveredMeetingContinuation = nil
          } catch {
            _ = try? await session.stop(
              finalizationReason: "continuationRetirementFailed"
            )
            throw error
          }
          let startedAt = Date()
          productMeetingStartedAt = startedAt
          meetingLifecycle.captureDidStart(at: startedAt)
          lastMeetingVoiceBufferCount = 0
          updateMeetingMenu(recording: true)
          let recordingToolTip: String
          if audioPreferences.capturesMicrophone
            && !audioSelection.capturesMicrophone
          {
            recordingToolTip =
              "LibreReverse is recording this meeting without microphone audio"
          } else if !audioSelection.capturesAnyAudio {
            recordingToolTip =
              "LibreReverse is recording this meeting as video only"
          } else {
            recordingToolTip = "LibreReverse is recording a meeting"
          }
          updateStatusItem(.meetingRecording, toolTip: recordingToolTip)
        } catch {
          if !captureReachedRecording,
            let startedSession = productMeetingSession,
            startedSession.state == .recording || startedSession.state == .failed
          {
            captureReachedRecording = true
          }
          if captureReachedRecording,
            let startedSession = productMeetingSession,
            startedSession.state == .recording || startedSession.state == .failed
          {
            _ = try? await startedSession.stop(
              finalizationReason: "meetingStartupFailed"
            )
          }
          meetingLifecycle.captureDidFail(error)
          meetingIgnoreTracker.ignore(candidate)
          resetMeetingLifecycle()
          productMeetingSession = nil
          productMeetingCandidate = nil
          productMeetingStagingURL = nil
          productMeetingPublicationXID = nil
          productMeetingCapturesMicrophone = false
          productMeetingMicrophoneDeviceID = nil
          productMeetingAudioSelection = nil
          productMeetingAudioRouteSnapshot = nil
          meetingAudioRouteChangeTracker.reset()
          productMeetingStartedAt = nil
          await meetingCaptureHandoff.finishMeetingCapture()
          if !LibreReverseMeetingStartupFailurePolicy.retainsStaging(
            captureReachedRecording: captureReachedRecording
          ) {
            try? FileManager.default.removeItem(at: directory)
          } else {
            startMeetingCaptureRecovery()
          }
          updateMeetingMenu(recording: false)
          timelineWindow?.clearMeetingRecording()
          showRecordingError(error)
        }
        meetingOperationTask = nil
        stopMeetingForPendingSystemBoundaryIfNeeded()
        presentActiveMeetingRecordingIfNeeded()
      }
      return true
    }

    private func stopProductMeeting(reason: LibreReverseMeetingStopReason) async {
      guard let session = productMeetingSession,
        let candidate = productMeetingCandidate,
        let stagingURL = productMeetingStagingURL
      else { return }
      updateStatusItem(.meetingFinishing, toolTip: "LibreReverse is saving your meeting")
      timelineWindow?.meetingCaptureIsFinishing()
      defer { meetingNativeRecordingFinished = false }
      var completedForRestart = false
      // Native stop itself can time out before publication begins. Its durable
      // journal still owns recoverable media, so every failed stop needs replay.
      var publicationNeedsRecovery = true
      do {
        let manifest = try await session.stop(finalizationReason: reason.rawValue) { [weak self] in
          guard let self, !terminating else { return }
          meetingNativeRecordingFinished = true
          await meetingCaptureHandoff.finishMeetingCapture()
          if let recordingSession {
            enqueueCaptureAttempt(session: recordingSession)
          }
        }
        guard manifest.state == .completed else {
          throw LibreReverseMeetingCapturePublicationError.captureNotCompleted(
            manifest.state
          )
        }
        guard let publicationXID = productMeetingPublicationXID else {
          throw LibreReverseMeetingCapturePublicationError.missingPublicationXID
        }
        let published = try LibreReverseMeetingPublicationPipeline.publishAndEnqueue(
          .init(
            stagingMediaURL: stagingURL,
            manifest: manifest,
            candidate: candidate,
            publicationXID: publicationXID
          ),
          configuration: libraryConfiguration,
          transcriptionQueue: meetingTranscriptionQueue
        )
        meetingLifecycle.captureDidFinish(segmentID: published.segmentID)
        scheduleMeetingTranscription(restart: true)
        publicationNeedsRecovery = false
        try? FileManager.default.removeItem(
          at: stagingURL.deletingLastPathComponent()
        )
        scheduleArchiveWork()
        completedForRestart = true
        meetingSaveWarning = nil
      } catch {
        meetingLifecycle.captureDidFail(error)
        meetingIgnoreTracker.ignore(candidate)
        logRecordingEvent("error", operation: "stopProductMeeting", error: error)
        meetingSaveWarning = "Meeting could not be saved. Its files are kept locally."
      }
      productMeetingSession = nil
      meetingSystemBoundary.captureBoundaryDidEnd()
      productMeetingCandidate = nil
      productMeetingStagingURL = nil
      productMeetingPublicationXID = nil
      productMeetingCapturesMicrophone = false
      productMeetingMicrophoneDeviceID = nil
      productMeetingAudioSelection = nil
      productMeetingAudioRouteSnapshot = nil
      meetingAudioRouteChangeTracker.reset()
      productMeetingStartedAt = nil
      lastMeetingVoiceBufferCount = 0
      updateMeetingMenu(recording: false)
      updateStatusItem(
        paused ? .paused : .recording,
        toolTip: paused ? "LibreReverse recording is paused" : "LibreReverse is recording"
      )
      resetMeetingLifecycle()
      refreshStatusMenu()
      if publicationNeedsRecovery {
        startMeetingCaptureRecovery()
      }
      if reason == .storagePressure {
        showRecordingError(
          LibreReverseMeetingConfigurationError.insufficientStorage(
            availableBytes: availableMeetingStorageBytes() ?? 0,
            requiredBytes: meetingStorageGuard.requiredFreeBytes()
          ))
      }
      if reason == .audioDeviceChanged || reason == .audioSourceChanged
        || reason == .microphonePermissionChanged,
        completedForRestart,
        meetingLifecycle.resumeAfterCaptureBoundary(candidate) == .startCapture(candidate)
      {
        scheduleMeetingCaptureRestart(candidate, reason: reason)
      } else {
        await meetingCaptureHandoff.finishMeetingCapture()
        timelineWindow?.clearMeetingRecording()
        if let recordingSession, !paused, !terminating {
          enqueueCaptureAttempt(
            session: recordingSession,
            allowMeetingOperation: true
          )
        }
      }
    }

    private func scheduleMeetingCaptureRestart(
      _ candidate: LibreReverseMeetingCandidate,
      reason: LibreReverseMeetingStopReason = .audioDeviceChanged
    ) {
      meetingRestartTask?.cancel()
      meetingRestartIntent.schedule(candidate)
      let operationToDrain = meetingOperationTask
      let restartToolTip =
        switch reason {
        case .audioSourceChanged:
          "LibreReverse is updating meeting audio sources"
        case .microphonePermissionChanged:
          "LibreReverse is updating microphone permission"
        default:
          "LibreReverse is switching microphone inputs"
        }
      updateMeetingMenu(recording: true)
      updateStatusItem(
        .waiting,
        toolTip: restartToolTip
      )
      timelineWindow?.meetingCaptureIsFinishing(restartToolTip + "…")
      meetingRestartTask = Task { [weak self] in
        await operationToDrain?.value
        // The finalization task itself rejects controls. Delay only after
        // it releases ownership so the visible Stop command has a real
        // cancellation window before the replacement capture begins.
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard !Task.isCancelled, let self else { return }
        guard meetingRestartIntent.consume(candidate) else { return }
        meetingRestartTask = nil
        guard beginProductMeeting(candidate) else {
          resetMeetingLifecycle()
          updateMeetingMenu(recording: false)
          timelineWindow?.clearMeetingRecording()
          await meetingCaptureHandoff.finishMeetingCapture()
          updateStatusItem(
            paused ? .paused : .recording,
            toolTip: paused
              ? "LibreReverse recording is paused" : "LibreReverse is recording"
          )
          if let recordingSession, !paused, !terminating {
            enqueueCaptureAttempt(session: recordingSession)
          }
          return
        }
      }
    }

    /// Replays orderly finalized artifacts and integrity-gated MP4s left by a
    /// hard process exit or a lost recording-output completion callback.
    /// Other failed or malformed artifacts remain untouched for
    /// diagnostics; committed XIDs resolve idempotently if the prior process
    /// exited after SQLite commit.
    private func startMeetingCaptureRecovery() {
      guard !terminating, !dataResetRequiresRestart else { return }
      guard meetingCaptureRecoveryTask == nil else { return }
      meetingCaptureRecoveryInProgress = true
      meetingCaptureRecoveryTask = Task { [weak self] in
        guard let self else { return }
        let retryPolicy = LibreReverseMeetingRecoveryRetryPolicy()
        var failureCount = 0
        while !Task.isCancelled, !terminating {
          do {
            if try await recoverCompletedMeetingCaptures() > 0 {
              scheduleArchiveWork()
            }
            meetingCaptureRecoveryInProgress = false
            meetingCaptureRecoveryTask = nil
            return
          } catch {
            failureCount += 1
            if failureCount == 1 {
              showRecordingError(error)
            }
            let delay = retryPolicy.delay(afterFailureCount: failureCount)
            try? await Task.sleep(
              nanoseconds: UInt64(delay * 1_000_000_000)
            )
          }
        }
        meetingCaptureRecoveryTask = nil
      }
    }

    @discardableResult
    private func recoverCompletedMeetingCaptures() async throws -> Int {
      let root =
        dataDirectory
        .appendingPathComponent("Library/MeetingStaging", isDirectory: true)
      guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
      let directories = try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      var recovered = 0
      var retainedRecoveryFailure = false
      var newestContinuation = pendingRecoveredMeetingContinuation
      let recoveredAt = Date()
      if newestContinuation == nil {
        newestContinuation = try recoveredMeetingContinuationStore.load(at: recoveredAt)
        pendingRecoveredMeetingContinuation = newestContinuation
      }
      for directory in directories {
        guard
          (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
          let journal = try? LibreReverseMeetingCaptureJournal.read(from: directory)
        else { continue }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifest: HighFidelityMeetingCaptureManifest
        let recoveredAfterHardExit: Bool
        if let manifestData = try? Data(contentsOf: manifestURL) {
          guard
            let decoded = try? decoder.decode(
              HighFidelityMeetingCaptureManifest.self,
              from: manifestData
            )
          else { continue }
          if decoded.state == .completed {
            manifest = decoded
          } else if decoded.state == .failed, decoded.streamError == nil,
              decoded.writerError?.hasPrefix("Meeting recording output did not finish within ") == true,
              decoded.timestamps.terminalValidationIssue(
                capturesSystemAudio: decoded.capturesSystemAudio,
                capturesMicrophone: decoded.capturesMicrophone) == nil {
            do {
              let recovered = try await LibreReverseMeetingCrashRecovery.recoverFinalizingManifest(
                journal: journal, directory: directory,
                capturedDuration: decoded.timestamps.video.coveredDurationSeconds,
                timestamps: decoded.timestamps)
              manifest = recovered
              try encoder.encode(recovered).write(to: manifestURL, options: .atomic)
            } catch {
              if Task.isCancelled { throw CancellationError() }
              // Exhausted/structurally rejected artifacts stay intact for later
              // recovery. Do not silently call a failed probe a successful save.
              retainedRecoveryFailure = true
              logRecordingEvent("error", operation: "recoverFinalizingMeeting", error: error)
              meetingSaveWarning = "A previous meeting could not be recovered. Its files are kept locally."
              continue
            }
          } else { continue }
          // A prior recovery attempt may already have materialized this
          // manifest before failing to persist the transcript queue job.
          // Preserve hard-exit continuation semantics across that retry.
          recoveredAfterHardExit =
            decoded.finalizationReason
            == LibreReverseMeetingCrashRecovery.finalizationReason
        } else {
          guard
            let crashRecovered =
              try? await LibreReverseMeetingCrashRecovery
              .recoverManifest(journal: journal, directory: directory)
          else { continue }
          manifest = crashRecovered
          recoveredAfterHardExit = true
          try encoder.encode(crashRecovered).write(
            to: manifestURL,
            options: .atomic
          )
        }
        do {
          _ = try LibreReverseMeetingPublicationPipeline.publishAndEnqueue(
            .init(
              stagingMediaURL: directory.appendingPathComponent("meeting.mp4"),
              manifest: manifest,
              candidate: journal.candidate,
              publicationXID: journal.publicationXID
            ),
            configuration: libraryConfiguration,
            transcriptionQueue: meetingTranscriptionQueue
          )
        } catch {
          if LibreReverseMeetingRecoveryFailureClassifier.disposition(for: error)
            == .reject
          {
            retainedRecoveryFailure = true
            // Structurally invalid artifacts and semantic queue/XID
            // mismatches remain staged for diagnostics; retrying cannot
            // make them valid. Filesystem/database errors still escape
            // to the bounded retry loop.
            continue
          }
          throw error
        }
        scheduleMeetingTranscription(restart: true)
        if recoveredAfterHardExit,
          let record = LibreReverseRecoveredMeetingContinuationRecord(
            publicationXID: journal.publicationXID,
            candidate: journal.candidate,
            captureFinishedAt: manifest.finishedAt,
            createdAt: recoveredAt
          ),
          let continuation = record.continuation(at: recoveredAt),
          newestContinuation.map({ continuation.expiresAt > $0.expiresAt }) ?? true
        {
          try recoveredMeetingContinuationStore.persist(record)
          newestContinuation = continuation
          pendingRecoveredMeetingContinuation = continuation
        }
        try FileManager.default.removeItem(at: directory)
        recovered += 1
      }
      pendingRecoveredMeetingContinuation = newestContinuation
      if recovered > 0 && !retainedRecoveryFailure {
        meetingSaveWarning = nil
        refreshStatusMenu()
      }
      return recovered
    }

    private var meetingTranscriptionQueue: LibreReverseMeetingTranscriptionQueue {
      .init(
        root: dataDirectory.appendingPathComponent(
          "Library/MeetingTranscriptionQueue",
          isDirectory: true
        ))
    }

    private var recoveredMeetingContinuationStore: LibreReverseRecoveredMeetingContinuationStore {
      .init(
        root: dataDirectory.appendingPathComponent(
          "Library/MeetingStaging",
          isDirectory: true
        ))
    }

    private func configureMeetingTranscription() {
      do {
        let repair = try meetingTranscriptionQueue.repairCorruptJobs(
          configuration: libraryConfiguration
        )
        if !repair.recoveredPublicationXIDs.isEmpty
          || !repair.retiredPublicationXIDs.isEmpty
          || !repair.unresolvedFileNames.isEmpty
        {
          NSLog(
            "Meeting transcription queue repair: recovered=%d retired=%d unresolved=%d",
            repair.recoveredPublicationXIDs.count,
            repair.retiredPublicationXIDs.count,
            repair.unresolvedFileNames.count
          )
        }
      } catch {
        NSLog("Meeting transcription queue repair failed: %@", error.localizedDescription)
      }
      let environment = ProcessInfo.processInfo.environment
      let language = environment["LIBREREVERSE_WHISPER_LANGUAGE"]
        ?? currentMeetingTranscriptionLanguage()
      if let resources = Bundle.main.resourceURL {
        let executable = resources.appendingPathComponent("Transcription/whisper-cli")
        let nativeModelName = environment["LIBREREVERSE_WHISPER_CPP_MODEL"] ?? "large-v3-turbo"
        let modelURL =
          resources
          .appendingPathComponent("Transcription/Models", isDirectory: true)
          .appendingPathComponent("ggml-\(nativeModelName).bin")
        if FileManager.default.isExecutableFile(atPath: executable.path),
          FileManager.default.fileExists(atPath: modelURL.path)
        {
          meetingTranscriber = WhisperCPPCLITranscriber(
            configuration: .init(
              executableURL: executable,
              modelURL: modelURL,
              language: language,
              useGPU: environment["LIBREREVERSE_WHISPER_DEVICE"] != "cpu",
              vadModelURL: resources.appendingPathComponent("Transcription/Models/ggml-silero-v6.2.0.bin")
            ))
          scheduleMeetingTranscription(restart: true)
          return
        }
      }
      showRecordingError(LibreReverseAskError.provider(
        "Local transcription is unavailable. Reinstall a complete LibreReverse build with its verified speech models."
      ))
    }

    private func scheduleMeetingTranscription(restart: Bool = false) {
      guard meetingTranscriptionSchedulerState.libraryMutationDepth == 0 else { return }
      guard !archiveTransitionInProgress else { return }
      guard !terminating, !dataResetRequiresRestart else { return }
      guard let transcriber = meetingTranscriber else { return }
      let predecessor = meetingTranscriptionTask
      if restart {
        meetingTranscriptionTask?.cancel()
        meetingTranscriptionTask = nil
      }
      guard meetingTranscriptionTask == nil else { return }
      let queue = meetingTranscriptionQueue
      let configuration = libraryConfiguration
      let resolver = archiveMediaResolver
      guard let generation = meetingTranscriptionSchedulerState.beginRunner() else { return }
      meetingTranscriptionTask = Task { [weak self] in
        defer {
          if self?.meetingTranscriptionSchedulerState.owns(generation) == true {
            self?.meetingTranscriptionTask = nil
          }
        }
        await predecessor?.value
        guard !Task.isCancelled else { return }
        let mediaResolver: LibreReverseMeetingTranscriptionRunner.MediaResolver?
        if let resolver {
          mediaResolver = { videoID, _ in
            try await resolver.resolve(videoID: videoID)
          }
        } else {
          mediaResolver = nil
        }
        let runner = LibreReverseMeetingTranscriptionRunner(
          queue: queue,
          library: configuration,
          transcriber: transcriber,
          mediaResolver: mediaResolver
        )
        while !Task.isCancelled {
          let run = await runner.runReady()
          if run.completed > 0 || run.failed > 0 {
            self?.timelineWindow?.meetingTranscriptionStateDidChange()
          }
          guard let next = try? queue.nextAttemptDate() else { break }
          let delay = max(1, next.timeIntervalSinceNow)
          try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
      }
    }

    private func scheduleMeetingSummaries() {
      guard !terminating, !dataResetRequiresRestart else { return }
      guard meetingTranscriptionSchedulerState.libraryMutationDepth == 0 else { return }
      meetingSummaryScheduler.start()
    }

    private func pauseMeetingTranscriptionForLibraryMutation() async {
      meetingTranscriptionSchedulerState.beginLibraryMutation()
      await meetingSummaryScheduler.stop()
      let runner = meetingTranscriptionTask
      runner?.cancel()
      await runner?.value
      // Admission stays closed until the matching resume, so no task can
      // replace this captured runner while the await yields the main actor.
      meetingTranscriptionTask = nil
    }

    private func resumeMeetingTranscriptionAfterLibraryMutation() {
      meetingTranscriptionSchedulerState.endLibraryMutation()
      scheduleMeetingSummaries()
      scheduleMeetingTranscription(restart: true)
    }

    private func retryMeetingTranscription(segmentID: Int64) throws {
      _ = try meetingTranscriptionQueue.retryNow(segmentID: segmentID)
      scheduleMeetingTranscription(restart: true)
      timelineWindow?.meetingTranscriptionStateDidChange()
    }

    private func updateMeetingMenu(recording: Bool) {
      refreshStatusMenu()
    }

    private func presentActiveMeetingRecordingIfNeeded() {
      guard let candidate = productMeetingCandidate,
        let selection = productMeetingAudioSelection,
        let startedAt = productMeetingStartedAt
      else { return }
      let devices = availableMeetingInputDevices()
      let microphoneName: String?
      if selection.capturesMicrophone {
        if let deviceID = selection.microphoneDeviceID {
          microphoneName = devices.first(where: { $0.id == deviceID })?.name
        } else {
          microphoneName = devices.first(where: { $0.isDefault })?.name
        }
      } else {
        microphoneName = nil
      }
      timelineWindow?.presentMeetingRecording(
        .init(
          candidate: candidate,
          selection: selection,
          microphoneName: microphoneName,
          startedAt: startedAt
        ))
    }

    private func currentMeetingStartPolicy() -> LibreReverseMeetingStartPolicy {
      guard
        let raw = UserDefaults.standard.string(
          forKey: Self.meetingStartPolicyDefaultsKey
        ), let policy = LibreReverseMeetingStartPolicy(rawValue: raw)
      else { return .ask }
      return policy
    }

    private func currentMeetingAudioPreferences() -> LibreReverseMeetingAudioPreferences {
      let defaults = UserDefaults.standard
      let capturesSystemAudio =
        defaults.object(
          forKey: Self.meetingSystemAudioDefaultsKey
        ) == nil || defaults.bool(forKey: Self.meetingSystemAudioDefaultsKey)
      let capturesMicrophone =
        defaults.object(
          forKey: Self.meetingMicrophoneDefaultsKey
        ) == nil || defaults.bool(forKey: Self.meetingMicrophoneDefaultsKey)
      return .init(
        capturesSystemAudio: capturesSystemAudio,
        capturesMicrophone: capturesMicrophone,
        microphoneDeviceID: defaults.string(
          forKey: Self.meetingMicrophoneDeviceDefaultsKey
        )
      )
    }

    private func meetingAudioSettingsSnapshot() -> LibreReverseMeetingAudioSettingsSnapshot {
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_AUDIO_SETTINGS_FIXTURE"
      ] != nil {
        return .init(
          preferences: audioSettingsFixturePreferences,
          microphoneAuthorized: true,
          nativeMicrophoneCaptureSupported: true,
          inputDevices: [
            .init(id: "fixture-mac-mic", name: "MacBook Pro Microphone", isDefault: true),
            .init(id: "fixture-studio-mic", name: "Studio Display Microphone", isDefault: false),
          ],
          isRecording: false,
          transcriptionLanguageCode: audioSettingsFixtureLanguage,
          transcriptionBackendAvailable: true
        )
      }
      permissionsController.updatePermissions()
      return .init(
        preferences: currentMeetingAudioPreferences(),
        microphoneAuthorized: permissionsController.microphone,
        nativeMicrophoneCaptureSupported: true,
        inputDevices: availableMeetingInputDevices(),
        isRecording: productMeetingSession != nil || meetingRestartTask != nil,
        transcriptionLanguageCode: currentMeetingTranscriptionLanguage(),
        transcriptionBackendAvailable: meetingTranscriber != nil
      )
    }

    private func currentMeetingTranscriptionLanguage() -> String? {
      let defaults = UserDefaults.standard
      guard defaults.object(
        forKey: Self.meetingTranscriptionLanguageDefaultsKey
      ) != nil else { return "en" }
      return LibreReverseTranscriptionLanguage.normalizedCode(
        defaults.string(forKey: Self.meetingTranscriptionLanguageDefaultsKey)
      )
    }

    private func updateMeetingTranscriptionLanguage(_ language: String?) {
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_AUDIO_SETTINGS_FIXTURE"
      ] != nil {
        audioSettingsFixtureLanguage = language
        return
      }
      UserDefaults.standard.set(
        language ?? "",
        forKey: Self.meetingTranscriptionLanguageDefaultsKey
      )
      configureMeetingTranscription()
    }

    private func meetingCalendarSettingsSnapshot()
      -> LibreReverseMeetingCalendarSettingsSnapshot
    {
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_MEETING_SETTINGS_FIXTURE"
      ] != nil {
        return .init(
          enabled: true,
          authorization: .notDetermined,
          calendars: [
            ("work", "Work"),
            ("personal", "Personal"),
            ("team", "Product & Design"),
            ("birthdays", "Birthdays"),
            ("holidays", "US Holidays"),
            ("travel", "Travel"),
            ("family", "Family"),
            ("focus", "Focus blocks"),
          ],
          selection: .init(explicitCalendarIDs: [
            "work", "team", "travel", "family", "detached-account",
          ]),
          readAccessOverride: true
        )
      }
      return meetingCalendarSource.snapshot(
        enabled: UserDefaults.standard.bool(
          forKey: Self.meetingCalendarEnabledDefaultsKey
        ),
        selection: currentMeetingCalendarSelection()
      )
    }

    private func currentMeetingCalendarSelection()
      -> LibreReverseMeetingCalendarSelection
    {
      let defaults = UserDefaults.standard
      guard defaults.object(forKey: Self.meetingCalendarIDsDefaultsKey) != nil else {
        return .init()
      }
      return .init(
        explicitCalendarIDs: defaults.stringArray(
          forKey: Self.meetingCalendarIDsDefaultsKey
        ) ?? [])
    }

    private func updateMeetingCalendar(
      id: String,
      enabled: Bool
    ) {
      guard
        LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_MEETING_SETTINGS_FIXTURE"
        ] == nil
      else { return }
      let snapshot = meetingCalendarSettingsSnapshot()
      let updated = snapshot.selection.updating(
        calendarID: id,
        enabled: enabled,
        availableCalendarIDs: Set(snapshot.calendars.map(\.id))
      )
      UserDefaults.standard.set(
        updated.explicitCalendarIDs ?? [],
        forKey: Self.meetingCalendarIDsDefaultsKey
      )
      meetingCalendarSource.invalidate()
    }

    private func selectAllMeetingCalendars() {
      guard
        LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_MEETING_SETTINGS_FIXTURE"
        ] == nil
      else { return }
      UserDefaults.standard.removeObject(forKey: Self.meetingCalendarIDsDefaultsKey)
      meetingCalendarSource.invalidate()
    }

    private func updateMeetingCalendarEnabled(_ enabled: Bool) {
      guard
        LibreReverseDevelopmentEnvironment.values[
          "LIBREREVERSE_MEETING_SETTINGS_FIXTURE"
        ] == nil
      else { return }
      if !enabled {
        UserDefaults.standard.set(false, forKey: Self.meetingCalendarEnabledDefaultsKey)
        meetingCalendarSource.invalidate()
        return
      }
      let snapshot = meetingCalendarSettingsSnapshot()
      if snapshot.hasReadAccess {
        UserDefaults.standard.set(true, forKey: Self.meetingCalendarEnabledDefaultsKey)
        meetingCalendarSource.invalidate()
        return
      }
      meetingCalendarSource.requestReadAccess { [weak self] granted in
        guard let self else { return }
        UserDefaults.standard.set(
          granted,
          forKey: Self.meetingCalendarEnabledDefaultsKey
        )
        meetingCalendarSource.invalidate()
        self.settingsWindow?.refreshMeetings()
      }
    }

    private var nativeMicrophoneCaptureSupported: Bool {
      true
    }

    private func updateMeetingAudioPreferences(
      _ preferences: LibreReverseMeetingAudioPreferences
    ) {
      if LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_AUDIO_SETTINGS_FIXTURE"
      ] != nil {
        audioSettingsFixturePreferences = preferences
        return
      }
      guard preferences != currentMeetingAudioPreferences() else { return }
      let defaults = UserDefaults.standard
      defaults.set(
        preferences.capturesSystemAudio,
        forKey: Self.meetingSystemAudioDefaultsKey
      )
      defaults.set(
        preferences.capturesMicrophone,
        forKey: Self.meetingMicrophoneDefaultsKey
      )
      if let deviceID = preferences.microphoneDeviceID {
        defaults.set(deviceID, forKey: Self.meetingMicrophoneDeviceDefaultsKey)
      } else {
        defaults.removeObject(forKey: Self.meetingMicrophoneDeviceDefaultsKey)
      }
      guard productMeetingSession != nil, meetingOperationTask == nil,
        meetingLifecycle.requestStop(.audioSourceChanged)
          == .stopCapture(.audioSourceChanged)
      else { return }
      meetingOperationTask = Task { [weak self] in
        await self?.stopProductMeeting(reason: .audioSourceChanged)
        self?.meetingOperationTask = nil
      }
    }

    private func availableMeetingInputDevices() -> [LibreReverseMeetingInputDevice] {
      let deviceTypes: [AVCaptureDevice.DeviceType] = [.microphone, .external]
      let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
      return AVCaptureDevice.DiscoverySession(
        deviceTypes: deviceTypes,
        mediaType: .audio,
        position: .unspecified
      ).devices.map {
        LibreReverseMeetingInputDevice(
          id: $0.uniqueID,
          name: $0.localizedName,
          isDefault: $0.uniqueID == defaultID
        )
      }.sorted {
        if $0.isDefault != $1.isDefault { return $0.isDefault }
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
    }

    private func openMicrophonePrivacySettings() {
      guard LibreReverseDevelopmentEnvironment.values[
        "LIBREREVERSE_AUDIO_SETTINGS_FIXTURE"
      ] == nil else { return }
      guard
        let url = URL(
          string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
      else { return }
      NSWorkspace.shared.open(url)
    }

    private func resetMeetingLifecycle() {
      meetingLifecycle = LibreReverseMeetingLifecycleCoordinator(
        configuration: .init(
          startPolicy: currentMeetingStartPolicy()
        ))
    }

    private func installMeetingSystemBoundaryObservers() {
      let center = NSWorkspace.shared.notificationCenter
      center.addObserver(
        self,
        selector: #selector(workspaceWillSleep),
        name: NSWorkspace.willSleepNotification,
        object: nil
      )
      center.addObserver(
        self,
        selector: #selector(workspaceDidWake),
        name: NSWorkspace.didWakeNotification,
        object: nil
      )
      center.addObserver(
        self,
        selector: #selector(workspaceSessionDidResignActive),
        name: NSWorkspace.sessionDidResignActiveNotification,
        object: nil
      )
      center.addObserver(
        self,
        selector: #selector(workspaceSessionDidBecomeActive),
        name: NSWorkspace.sessionDidBecomeActiveNotification,
        object: nil
      )
    }

    @objc private func workspaceWillSleep() {
      suspendMeetingCaptureForSystemBoundary(.sleep)
    }

    @objc private func workspaceDidWake() {
      meetingSystemBoundary.resume(.sleep)
        }

    @objc private func workspaceSessionDidResignActive() {
      suspendMeetingCaptureForSystemBoundary(.sessionInactive)
    }

    @objc private func workspaceSessionDidBecomeActive() {
      meetingSystemBoundary.resume(.sessionInactive)
    }

    private func suspendMeetingCaptureForSystemBoundary(
      _ boundary: LibreReverseMeetingSystemBoundary
    ) {
      meetingSystemBoundary.suspend(
        boundary,
        ownsCaptureBoundary: productMeetingSession != nil
          || meetingOperationTask != nil
          || meetingRestartTask != nil
        )
      stopMeetingForPendingSystemBoundaryIfNeeded()
    }

    private func stopMeetingForPendingSystemBoundaryIfNeeded() {
      guard
        let reason = meetingSystemBoundary.consumePendingStop(
          hasActiveSession: productMeetingSession != nil,
          hasOperationInFlight: meetingOperationTask != nil
        ), meetingLifecycle.requestStop(reason) == .stopCapture(reason)
      else { return }
      meetingOperationTask = Task { [weak self] in
        await self?.stopProductMeeting(reason: reason)
        self?.meetingOperationTask = nil
        self?.stopMeetingForPendingSystemBoundaryIfNeeded()
      }
    }

    @objc private func toggleScrollToRewind() {
        var settings = LibreReverseShortcutPreferences.load()
        settings.scrollToRewindEnabled.toggle()
        try? applyShortcutSettings(settings)
    }

    private func updateScrollToRewindMenuState(_ enabled: Bool) {
        refreshStatusMenu()
    }

    @objc private func openTimeline() {
        openTimelineWithSource(.lastSearch)
    }

    @objc private func openAsk() {
      openTimelineWithSource(.lastSearch)
      ensureAskController()
      if let askWindow { timelineWindow?.presentInlineAsk(askWindow) }
    }

    private func ensureAskController() {
      if askWindow == nil {
        let configuration = libraryConfiguration
        let queue = meetingTranscriptionQueue
        askWindow = LibreReverseAskWindowController(
          answerHandler: { question, apiKey in
            let profile = LibreReverseAIProfiles.selected()
            let provider = LibreReverseAIService.provider(for: profile)
            let selectedKey = try LibreReverseAIService.credential(for: profile, configuration: configuration)
            return try await LibreReverseAskEngine(configuration: configuration, provider: provider, transcriptionQueue: queue)
              .answer(question: question, apiKey: selectedKey)
          },
          loadAPIKey: {
            try LibreReverseAskCredentialStore.load(configuration: configuration)
          },
          openAISettings: { [weak self] in
            self?.presentSettings(section: .ai)
          },
          openMoment: { [weak self] instant in
            self?.openTimelineWithSource(.lastSearch)
            self?.timelineWindow?.navigateToMoment(instant)
          },
          conversationAnswerHandler: { question, _, conversation, viewingInstant, onProgress in
            let profile = LibreReverseAIProfiles.selected()
            let provider = LibreReverseAIService.provider(for: profile)
            let selectedKey = try LibreReverseAIService.credential(for: profile, configuration: configuration)
            return try await LibreReverseAskEngine(configuration: configuration, provider: provider, transcriptionQueue: queue)
              .answer(question: question, conversation: conversation, apiKey: selectedKey, viewingInstant: viewingInstant, onProgress: onProgress)
          },
          chatStore: LibreReverseAskChatStore(configuration: configuration)
        )
      }
    }

    @objc private func openQuickStart() {
      timelineWindow?.dismiss()
      if let quickStartWindow {
        NSApp.setActivationPolicy(.regular)
        quickStartWindow.open()
        return
      }
      NSApp.setActivationPolicy(.regular)
      let controller = LibreReverseQuickStartWindowController(
        permissions: permissionsController,
        startWhenReady: recordingTask == nil && captureTimer == nil && !paused,
        recordingStatus: { [weak self] in self?.setupRecordingStatus ?? .waiting },
        startCapture: { [weak self] in
          guard let self, self.recordingSession == nil else { return }
          self.startRecording()
        }
      )
      quickStartWindow = controller
      controller.open()
    }

    @objc private func checkForUpdates() {
      if let availableUpdate {
        presentAvailableUpdate(availableUpdate)
        return
      }
      guard LibreReverseUpdateConfiguration.bundled() != nil else {
        let alert = LibreReverseApplicationAlerts.make(.updatesUnavailable)
        alert.runModal()
        return
      }
      beginUpdateCheck(manual: true)
    }

    private func configureUpdateChecks() {
      guard LibreReverseUpdateConfiguration.bundled() != nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.schedule(deadline: .now() + 30, repeating: 3_600)
      timer.setEventHandler { [weak self] in
        self?.beginUpdateCheck(manual: false)
      }
      updateCheckTimer = timer
      timer.resume()
    }

    private func beginUpdateCheck(manual: Bool) {
      guard updateCheckTask == nil,
            let configuration = LibreReverseUpdateConfiguration.bundled() else { return }
      let currentBuild = Int(
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
      ) ?? 0
      updateCheckInProgress = true
      updateCheckError = nil
      refreshStatusMenu()
      let checker = LibreReverseUpdateChecker(
        configuration: configuration,
        currentBuild: currentBuild
      )
      updateCheckTask = Task { [weak self] in
        guard let self else { return }
        do {
          let result = try await checker.check()
          guard !Task.isCancelled else { return }
          updateCheckInProgress = false
          updateCheckTask = nil
          switch result {
          case .current:
            availableUpdate = nil
            if manual { presentCurrentVersion() }
          case .available(let manifest):
            availableUpdate = manifest
            if manual { presentAvailableUpdate(manifest) }
          }
          refreshStatusMenu()
        } catch is CancellationError {
          updateCheckInProgress = false
          updateCheckTask = nil
          refreshStatusMenu()
        } catch {
          updateCheckInProgress = false
          updateCheckTask = nil
          updateCheckError = error.localizedDescription
          refreshStatusMenu()
          if manual { presentUpdateError(error) }
        }
      }
    }

    private func presentCurrentVersion() {
      let version = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
      ) as? String ?? "Development"
      let alert = LibreReverseApplicationAlerts.make(.currentVersion(version))
      alert.runModal()
    }

    private func presentAvailableUpdate(_ manifest: LibreReverseUpdateManifest) {
      let alert = LibreReverseApplicationAlerts.make(.availableUpdate(version: manifest.version, releaseNotes: manifest.releaseNotesURL != nil))
      switch alert.runModal() {
      case .alertFirstButtonReturn:
        beginUpdateDownload(manifest)
      case .alertThirdButtonReturn:
        if let releaseNotesURL = manifest.releaseNotesURL {
          NSWorkspace.shared.open(releaseNotesURL)
        }
      default:
        break
      }
    }

    private func beginUpdateDownload(_ manifest: LibreReverseUpdateManifest) {
      guard updateDownloadTask == nil else { return }
      updateDownloadInProgress = true
      refreshStatusMenu()
      let downloader = LibreReverseUpdateDownloader()
      updateDownloadTask = Task { [weak self] in
        guard let self else { return }
        do {
          let verifiedURL = try await downloader.downloadAndVerify(manifest)
          if Task.isCancelled { throw CancellationError() }
          updateDownloadInProgress = false
          updateDownloadTask = nil
          refreshStatusMenu()
          NSWorkspace.shared.activateFileViewerSelecting([verifiedURL])
          let alert = LibreReverseApplicationAlerts.make(.verifiedUpdate)
          alert.runModal()
        } catch is CancellationError {
          updateDownloadInProgress = false
          updateDownloadTask = nil
          refreshStatusMenu()
        } catch {
          updateDownloadInProgress = false
          updateDownloadTask = nil
          refreshStatusMenu()
          presentUpdateError(error)
        }
      }
    }

    private func presentUpdateError(_ error: Error) {
      let alert = LibreReverseApplicationAlerts.make(.updateError(error.localizedDescription))
      alert.runModal()
    }

    @objc private func openDailyRecap() {
      timelineWindow?.dismiss()
      if dailyRecapWindow == nil {
        dailyRecapWindow = LibreReverseDailyRecapWindowController(
          libraryConfiguration: libraryConfiguration,
          calendarEvents: { [weak self] interval in
            guard let self,
              UserDefaults.standard.bool(
                forKey: Self.meetingCalendarEnabledDefaultsKey
              )
            else { return [] }
            return self.meetingCalendarSource.events(
              in: interval,
              selectedCalendarIDs: self.currentMeetingCalendarSelection().eventFilter
            )
          },
          openTimeline: { [weak self] meeting in
            self?.openDailyRecapMeetingInTimeline(meeting)
          }
        )
      }
      dailyRecapWindow?.present()
    }

    private func openDailyRecapMeetingInTimeline(
      _ meeting: LibreReverseDailyRecapMeeting
    ) {
      guard meeting.segmentID != nil else { return }
      openTimelineWithSource(.lastSearch)
      timelineWindow?.navigateToMeeting(meeting)
    }

    private func openTimelineWithSource(
        _ source: LibreReverseTimelineInvocationSource,
        forwardingGlobalScrollEvent event: NSEvent? = nil
    ) {
        if timelineWindow == nil {
            timelineWindow = LibreReverseTimelineWindowController(
                dataDirectory: dataDirectory,
                libraryConfiguration: libraryConfiguration,
          transcriptionQueue: meetingTranscriptionQueue,
                mediaResolver: archiveMediaResolver,
          shardResolver: archiveShardResolver,
          archiveDownloads: archiveDownloads,
          meetingStopHandler: { [weak self] in
            self?.toggleMeetingRecording()
          },
          meetingRenameHandler: { [weak self] in
            self?.renameActiveMeeting()
          },
          meetingTitleUpdateHandler: { [weak self] segmentID, title in
            guard let self else { throw CancellationError() }
            return try await self.renamePublishedMeeting(
              segmentID: segmentID,
              title: title
            )
          },
          meetingContextUpdateHandler: {
            [weak self] segmentID, participants, calendarTitle in
            guard let self else { throw CancellationError() }
            return try await self.updatePublishedMeetingContext(
              segmentID: segmentID,
              participants: participants,
              calendarTitle: calendarTitle
            )
          },
          meetingDeletionHandler: { [weak self] segmentID in
            guard let self else { throw CancellationError() }
            try await self.deleteMeeting(segmentID: segmentID)
          },
          meetingTranscriptionRetryHandler: { [weak self] segmentID in
            guard let self else { throw CancellationError() }
            try self.retryMeetingTranscription(segmentID: segmentID)
          },
          screenCaptureIsPaused: { [weak self] in self?.paused ?? true },
          screenCaptureToggleHandler: { [weak self] in self?.toggleRecording() },
          openSettingsHandler: { [weak self] in self?.openSettings() },
          mutationLifetime: uiMutationLifetime,
          openStorageSettingsHandler: { [weak self] in self?.openArchiveSettings() }
            )
            if let latestLiveCapture {
                timelineWindow?.showLiveFrame(
                    latestLiveCapture.frame,
                    at: latestLiveCapture.date,
                    admittedFrame: latestLiveCapture.admittedFrame
                )
            }
        presentActiveMeetingRecordingIfNeeded()
        }
        // Use the logical frame of NSScreen.main for the explorer. Pointer-display
        // selection belongs to capture and may identify a different display.
        guard let mainScreen = NSScreen.main else {
            // A headless or disconnected desktop has no screen on which to present.
            return
        }
        timelineWindow?.onAskQuestion = { [weak self] question in
            guard let self else { return }
            self.ensureAskController()
            if let askWindow = self.askWindow { self.timelineWindow?.presentInlineAsk(askWindow, query: question) }
        }
        timelineWindow?.present(
            on: mainScreen,
            startAtLiveEdge: true,
            forwardingGlobalScrollEvent: event
        )
    }

    private func starLatestRecordedMoment() {
      guard !terminating, starShortcutTask == nil,
        let admitted = latestLiveCapture?.admittedFrame
      else { return }
      let configuration = libraryConfiguration
      starShortcutTask = Task { @MainActor [weak self] in
        _ = try? await Task.detached(priority: .userInitiated) {
          try LibreReverseLibraryStore.setFrameStarred(
            frameID: admitted.id,
            wallDate: admitted.createdAt,
            isStarred: true,
            configuration: configuration
          )
        }.value
        self?.starShortcutTask = nil
      }
    }

    private func deleteMeeting(segmentID: Int64) async throws {
      try await uiMutationLifetime.perform {
        try await self.performMeetingDeletion(segmentID: segmentID)
      }
    }

    private func performMeetingDeletion(segmentID: Int64) async throws {
      await pauseMeetingTranscriptionForLibraryMutation()
      defer { resumeMeetingTranscriptionAfterLibraryMutation() }
      let destination = try LibreReverseArchiveStore.activeDestination(
        configuration: libraryConfiguration
      )
      let coordinator = LibreReverseMeetingDeletionCoordinator(
        destinationID: destination?.id,
        library: libraryConfiguration,
        backend: archiveBackend,
        shardRestorer: archiveShardResolver,
        transcriptionQueue: meetingTranscriptionQueue
      )
      do {
        try await LibreReverseMeetingLibraryMutationScope.perform {
          await timelineWindow?.prepareForPrimaryReplacement()
        } complete: {
          await timelineWindow?.primaryReplacementDidComplete()
        } operation: {
          if let archiveWorkTask {
            archiveWorkTask.cancel()
            await archiveWorkTask.value
          }
          try await Task.detached(priority: .userInitiated) {
            try await coordinator.delete(segmentID: segmentID)
          }.value
        }
        if let destination {
          scheduleArchiveWork(destinationID: destination.id)
        }
      } catch {
        if let destination {
          scheduleArchiveWork(destinationID: destination.id)
        }
        throw error
      }
    }

    private func renamePublishedMeeting(
      segmentID: Int64,
      title: String
    ) async throws -> String? {
      try await uiMutationLifetime.perform {
        try await self.performMeetingRename(segmentID: segmentID, title: title)
      }
    }

    private func performMeetingRename(segmentID: Int64, title: String) async throws -> String? {
      await pauseMeetingTranscriptionForLibraryMutation()
      defer { resumeMeetingTranscriptionAfterLibraryMutation() }
      let destination = try LibreReverseArchiveStore.activeDestination(
        configuration: libraryConfiguration
      )
      let coordinator = LibreReverseMeetingTitleUpdateCoordinator(
        library: libraryConfiguration,
        shardRestorer: archiveShardResolver
      )
      do {
        let stored = try await LibreReverseMeetingLibraryMutationScope.perform {
          await timelineWindow?.prepareForPrimaryReplacement()
        } complete: {
          await timelineWindow?.primaryReplacementDidComplete()
        } operation: {
          if let archiveWorkTask {
            archiveWorkTask.cancel()
            await archiveWorkTask.value
          }
          return try await Task.detached(priority: .userInitiated) {
            try await coordinator.update(segmentID: segmentID, title: title)
          }.value
        }
        if let destination {
          scheduleArchiveWork(destinationID: destination.id)
        }
        return stored
      } catch {
        if let destination {
          scheduleArchiveWork(destinationID: destination.id)
        }
        throw error
      }
    }

    private func updatePublishedMeetingContext(
      segmentID: Int64,
      participants: [String],
      calendarTitle: String?
    ) async throws -> LibreReverseMeetingContextUpdate {
      try await uiMutationLifetime.perform {
        try await self.performMeetingContextUpdate(segmentID: segmentID,
          participants: participants, calendarTitle: calendarTitle)
      }
    }

    private func performMeetingContextUpdate(segmentID: Int64, participants: [String],
      calendarTitle: String?) async throws -> LibreReverseMeetingContextUpdate {
      let coordinator = LibreReverseMeetingTitleUpdateCoordinator(
        library: libraryConfiguration
      )
      let stored = try await Task.detached(priority: .userInitiated) {
        try await coordinator.updateContext(
          segmentID: segmentID,
          participants: participants,
          calendarTitle: calendarTitle
        )
      }.value
      await timelineWindow?.refreshAfterLibraryMutation()
      return stored
    }

    @objc private func openSettings() {
        presentSettings(section: .general)
    }

    private func presentSettings(section: LibreReverseSettingsWindowController.Section) {
        #if !DEBUG
        guard startupReady else { return }
        #endif
        timelineWindow?.dismiss()
        if settingsWindow == nil {
            settingsWindow = LibreReverseSettingsWindowController(
                googleDriveManager: googleDriveConnectionManager,
                connectionValidated: { [weak self] identity in
                    try await self?.persistArchiveDestination(identity)
                },
                connectionAuthorized: { [weak self] authorization in
                    try await self?.persistArchiveDestination(authorization.identity, authorization: authorization)
                },
                connectionDisconnected: { [weak self] kind in
                    try await self?.disconnectArchiveDestination(kind: kind)
                },
                archiveConnectionSettings: { [weak self] in
                    guard let self else { return .init(activeKind: nil, s3Configuration: nil) }
                    let library = self.libraryConfiguration
                    let operational = await self.archiveDownloads.connectionAvailable
                    return try await Task.detached(priority: .utility) {
                        LibreReverseArchiveConnectionSettings(activeKind: try LibreReverseArchiveStore.activeDestination(configuration: library)?.kind,
                              s3Configuration: try S3ArchiveConfigurationStore(library: library).load()
                                ?? S3ArchiveConfigurationStore.environmentConfiguration(),
                              isOperational: operational)
                    }.value
                },
                connectS3: { [weak self] configuration in
                    try await self?.connectS3Archive(configuration)
                },
                archiveSnapshot: { [weak self] in
                    guard let self else { return nil }
                    let configuration = self.libraryConfiguration
                    let hasActiveRecording = self.recordingSession != nil && !self.paused
                    return try await Task.detached(priority: .utility) {
              guard
                let destination = try LibreReverseArchiveStore.activeDestination(
                            configuration: configuration
                ),
                let policy = try LibreReverseArchiveStore.policy(
                            destinationID: destination.id,
                            configuration: configuration
                )
              else { return nil }
                        return LibreReverseArchiveSettingsSnapshot(
                            providerKind: destination.kind,
                            destinationID: destination.id,
                            policy: policy,
                            status: try LibreReverseArchiveStore.status(
                                destinationID: destination.id,
                                configuration: configuration
                            ),
                            residencyForecast: try LibreReverseArchiveStore.residencyForecast(
                                destinationID: destination.id,
                                configuration: configuration
                            ),
                            shardStatus: try LibreReverseShardArchiveStore.status(
                                destinationID: destination.id,
                                configuration: configuration
                            ),
                            hasActiveRecording: hasActiveRecording,
                            failureSummaries: try LibreReverseArchiveStore.failureSummaries(
                                destinationID: destination.id, configuration: configuration)
                        )
                    }.value
                },
                updateArchivePolicy: { [weak self] policy in
                    guard let self,
                          let destination = try LibreReverseArchiveStore.activeDestination(
                            configuration: self.libraryConfiguration
              )
            else { return }
                    try LibreReverseArchiveStore.updatePolicy(
                        policy,
                        destinationID: destination.id,
                        configuration: self.libraryConfiguration
                    )
                    try LibreReverseArchiveStore.reconcilePolicyStates(
                        destinationID: destination.id,
                        configuration: self.libraryConfiguration
                    )
                    try LibreReverseArchiveStore.reconcileDesiredResidency(
                        destinationID: destination.id,
                        configuration: self.libraryConfiguration
                    )
                    self.scheduleArchiveWork(destinationID: destination.id)
                },
                retryArchive: { [weak self] in
                    guard let self,
                          let destination = try? LibreReverseArchiveStore.activeDestination(
                            configuration: self.libraryConfiguration
              )
            else { return }
                    try? LibreReverseArchiveStore.retryFailedObjects(
                        destinationID: destination.id,
                        configuration: self.libraryConfiguration
                    )
                    try? LibreReverseShardArchiveStore.retryFailed(
                        destinationID: destination.id,
                        configuration: self.libraryConfiguration
                    )
                    self.scheduleArchiveWork(destinationID: destination.id)
                },
                storageUsage: { [weak self] in
                  guard let self else {
                    return .init(localBytes: 0, recordedDays: 0)
                  }
                  let configuration = self.libraryConfiguration
                  return await Task.detached(priority: .utility) {
                    return LibreReverseStorageUsageSnapshot.measure(configuration: configuration)
                  }.value
                },
                deleteAllData: { [weak self] in
                  guard let self else { return }
                  try await self.prepareCompleteDataReset()
                },
                generalSettings: { [weak self] in
                  self?.generalSettingsSnapshot()
                    ?? .init(
                      launchAtLogin: false,
                      remindWhenPaused: true,
                      showInDock: false
                    )
                },
                updateLaunchAtLogin: { [weak self] enabled in
                  try self?.updateLaunchAtLogin(enabled)
                },
                updateRemindWhenPaused: { [weak self] enabled in
                  self?.updateRemindWhenPaused(enabled)
                },
                updateShowInDock: { [weak self] enabled in
                  self?.updateShowInDock(enabled)
                },
                screenSettings: { [weak self] in
                  self?.screenSettingsSnapshot()
                    ?? .init(
                      omittedBundleIdentifiers: [],
                      excludePrivateWindows: true,
                      ocrLanguageMode: .standard,
                      showRunningProcesses: false,
                      applications: []
                    )
                },
                updateOmittedApplications: { [weak self] identifiers in
                  self?.updateOmittedApplications(identifiers)
                },
                updateExcludePrivateWindows: { [weak self] enabled in
                  self?.updateExcludePrivateWindows(enabled)
                },
                updateOCRLanguageMode: { [weak self] mode in
                  self?.updateOCRLanguageMode(mode)
                },
                updateShowRunningProcesses: { [weak self] enabled in
                  self?.updateShowRunningProcesses(enabled)
                },
                shortcutSettings: { [weak self] in
                  guard let self else { return .defaults }
                  if LibreReverseDevelopmentEnvironment.values[
                    "LIBREREVERSE_SHORTCUTS_SETTINGS_FIXTURE"
                  ] != nil {
                    return self.shortcutFixtureSettings
                  }
                  return LibreReverseShortcutPreferences.load()
                },
                updateShortcutSettings: { [weak self] settings in
                  guard let self else { throw CancellationError() }
                  if LibreReverseDevelopmentEnvironment.values[
                    "LIBREREVERSE_SHORTCUTS_SETTINGS_FIXTURE"
                  ] != nil {
                    self.shortcutFixtureSettings = try settings.validated()
                    return
                  }
                  try self.applyShortcutSettings(settings)
                },
                askAPIKey: { [weak self] in
                  guard let self else { return nil }
                  if LibreReverseDevelopmentEnvironment.values[
                    "LIBREREVERSE_ASK_UI_FIXTURE"
                  ] != nil {
                    return self.askFixtureAPIKey
                  }
                  return try LibreReverseAskCredentialStore.load(
                    configuration: self.libraryConfiguration
                  )
                },
                updateAskAPIKey: { [weak self] value in
                  guard let self else { throw CancellationError() }
                  if LibreReverseDevelopmentEnvironment.values[
                    "LIBREREVERSE_ASK_UI_FIXTURE"
                  ] != nil {
                    self.askFixtureAPIKey = value
                    return
                  }
                  try LibreReverseAskCredentialStore.save(
                    value,
                    configuration: self.libraryConfiguration
                  )
                },
          meetingPolicy: { [weak self] in
            self?.currentMeetingStartPolicy() ?? .ask
          },
          updateMeetingPolicy: { [weak self] policy in
            UserDefaults.standard.set(
              policy.rawValue,
              forKey: Self.meetingStartPolicyDefaultsKey
            )
            guard let self,
              LibreReverseMeetingPolicyTransition.canResetLifecycle(
                hasActiveSession: self.productMeetingSession != nil,
                hasOperationInFlight: self.meetingOperationTask != nil,
                hasPendingRestart: self.meetingRestartTask != nil
              )
            else { return }
            self.resetMeetingLifecycle()
          },
          meetingAudioSettings: { [weak self] in
            self?.meetingAudioSettingsSnapshot()
              ?? .init(
                preferences: .init(),
                microphoneAuthorized: false,
                nativeMicrophoneCaptureSupported: false,
                inputDevices: [],
                isRecording: false,
                transcriptionLanguageCode: "en",
                transcriptionBackendAvailable: false
              )
          },
          updateMeetingAudioSettings: { [weak self] preferences in
            self?.updateMeetingAudioPreferences(preferences)
          },
          updateMeetingTranscriptionLanguage: { [weak self] language in
            self?.updateMeetingTranscriptionLanguage(language)
          },
          openMicrophonePrivacy: { [weak self] in
            self?.openMicrophonePrivacySettings()
          },
          meetingCalendarSettings: { [weak self] in
            self?.meetingCalendarSettingsSnapshot()
              ?? .init(
                enabled: false,
                authorization: .notDetermined,
                calendars: [],
                selection: .init(),
                readAccessOverride: nil
              )
          },
          updateMeetingCalendarEnabled: { [weak self] enabled in
            self?.updateMeetingCalendarEnabled(enabled)
          },
          updateMeetingCalendar: { [weak self] id, enabled in
            self?.updateMeetingCalendar(id: id, enabled: enabled)
          },
          selectAllMeetingCalendars: { [weak self] in
            self?.selectAllMeetingCalendars()
          },
                toggleMeeting: { [weak self] in self?.toggleMeetingRecording() },
                showSetup: { [weak self] in self?.openQuickStart() }
            )
        }
        settingsWindow?.open(section: section)
    }

    @objc private func openArchiveSettings() {
        presentSettings(section: .storage)
    }

    private func restoreArchiveDestination() {
        guard !terminating, !dataResetRequiresRestart, !archiveTransitionInProgress else { return }
        guard archiveRestoreTask == nil else { return }
        let generation = archiveConnectionGeneration
        archiveRestoreTask = Task { [weak self] in
            guard let self else { return }
            defer { archiveRestoreTask = nil }
            do {
                guard let destination = try LibreReverseArchiveStore.activeDestination(
                    configuration: libraryConfiguration) else { return }
                switch destination.kind {
                case .googleDrive:
                    guard let identity = try await googleDriveConnectionManager.restore() else {
                        guard !terminating, !Task.isCancelled, generation == archiveConnectionGeneration else { return }
                        await archiveDownloads.pause(needsConnection: true)
                        return
                    }
                    guard !terminating, !Task.isCancelled, generation == archiveConnectionGeneration else { return }
                    try await persistArchiveDestination(identity)
                case .s3Compatible:
                    guard let configuration = try S3ArchiveConfigurationStore(library: libraryConfiguration).load()
                    else { throw ArchiveBackendError.requestFailed(status: 401, message: "S3 credentials are missing. Open Storage settings to reconnect.") }
                    guard configuration.destinationIdentity == destination.remoteRoot else {
                        throw ArchiveBackendError.requestFailed(status: 401, message: "Saved S3 credentials belong to another destination. Reconnect in Storage settings.")
                    }
                    guard !terminating, !Task.isCancelled, generation == archiveConnectionGeneration else { return }
                    try await activateS3Archive(configuration)
                }
            } catch {
                guard !terminating, !Task.isCancelled, generation == archiveConnectionGeneration, !archiveTransitionInProgress else { return }
                let needsConnection = LibreReverseDownloadFailure.needsConnection(error)
                await archiveDownloads.pause(needsConnection: needsConnection)
                if needsConnection {
                    timelineWindow?.setArchiveConnectionNeedsReconnect()
                } else {
                    archiveConnectionRetryTask?.cancel()
                    archiveConnectionRetryTask = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                        self?.restoreArchiveDestination()
                    }
                }
            }
        }
    }

    private func persistArchiveDestination(_ identity: GoogleDriveConnectionIdentity,
        authorization: GoogleDriveConnectionManager.PendingAuthorization? = nil) async throws {
        try beginArchiveTransition()
        defer {
            archiveTransitionInProgress = false
            if archiveBackend == nil {
                archiveConnectionRetryTask?.cancel()
                archiveConnectionRetryTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                    self?.restoreArchiveDestination()
                }
            }
        }
        await drainArchiveDestination()
        try Task.checkCancellation()
        guard !terminating else { throw CancellationError() }
        let destinationID = try LibreReverseArchiveStore.upsertDestination(kind: .googleDrive,
            displayName: "Google Drive — \(identity.emailAddress)",
            remoteRoot: identity.rootFolderID,
            credentials: authorization?.credentialUpdates ?? [:], configuration: libraryConfiguration)
        if let authorization { await googleDriveConnectionManager.acceptPersistedAuthorization(authorization) }
        let backend = GoogleDriveArchiveBackend(connection: googleDriveConnectionManager,
                                              rootFolderID: identity.rootFolderID)
        await installArchiveDestination(destinationID: destinationID, backend: backend)
    }

    private func connectS3Archive(_ configuration: S3ArchiveConfiguration) async throws {
        // Test the candidate before replacing a working provider or saved credentials.
        archiveConnectionGeneration &+= 1
        let generation = archiveConnectionGeneration
        let backend = try S3ArchiveBackend(configuration: configuration,
            libraryID: LibreReverseArchiveStore.libraryUUID(configuration: libraryConfiguration))
        do {
            try await backend.validateConnection()
        } catch {
            // A failed candidate may have superseded startup's pending restore.
            // Resume that saved provider if it had not installed its workers yet.
            if generation == archiveConnectionGeneration, archiveBackend == nil {
                restoreArchiveDestination()
            }
            throw error
        }
        try Task.checkCancellation()
        guard generation == archiveConnectionGeneration else { throw CancellationError() }
        try await activateS3Archive(configuration, backend: backend)
    }

    private func activateS3Archive(_ configuration: S3ArchiveConfiguration,
                                   backend suppliedBackend: S3ArchiveBackend? = nil) async throws {
        let backend = try suppliedBackend ?? S3ArchiveBackend(configuration: configuration,
            libraryID: LibreReverseArchiveStore.libraryUUID(configuration: libraryConfiguration))
        try beginArchiveTransition()
        defer {
            archiveTransitionInProgress = false
            if archiveBackend == nil {
                archiveConnectionRetryTask?.cancel()
                archiveConnectionRetryTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                    self?.restoreArchiveDestination()
                }
            }
        }
        await drainArchiveDestination()
        try Task.checkCancellation()
        guard !terminating else { throw CancellationError() }
        let destinationID = try LibreReverseArchiveStore.upsertDestination(kind: .s3Compatible,
            displayName: "S3 — \(configuration.bucket)", remoteRoot: configuration.destinationIdentity,
            credentials: [S3ArchiveConfigurationStore.credentialAccount: try JSONEncoder().encode(configuration)],
            configuration: libraryConfiguration)
        await installArchiveDestination(destinationID: destinationID, backend: backend)
    }

    private func beginArchiveTransition() throws {
        guard !terminating, !archiveTransitionInProgress, !dataResetRequiresRestart else {
            throw ArchiveBackendError.unsupportedOperation("another storage change is in progress")
        }
        archiveTransitionInProgress = true
        archiveConnectionGeneration &+= 1
        archiveConnectionRetryTask?.cancel()
        archiveConnectionRetryTask = nil
    }

    private func installArchiveDestination(destinationID: Int64, backend: any ArchiveBackend) async {
        guard !terminating, !Task.isCancelled else { return }
        archiveBackend = backend
        archiveCoordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID,
            library: libraryConfiguration,
            backend: backend
        )
        shardArchiveCoordinator = LibreReverseShardArchiveCoordinator(
            destinationID: destinationID,
            library: libraryConfiguration,
            backend: backend
        )
        let resolver = LibreReverseLocalMediaResolver(
            destinationID: destinationID,
            library: libraryConfiguration,
            backend: backend
        )
        archiveMediaResolver = resolver
        let shardResolver = LibreReverseShardResolver(
            destinationID: destinationID,
            library: libraryConfiguration,
            backend: backend
        )
        archiveShardResolver = shardResolver
        let residencyManager = LibreReverseMediaResidencyManager(
            destinationID: destinationID,
            library: libraryConfiguration,
            backend: backend
        )
        archiveResidencyManager = residencyManager
        archiveShardResidencyManager = LibreReverseShardResidencyManager(
            destinationID: destinationID,
            library: libraryConfiguration,
            backend: backend
        )
        timelineWindow?.setMediaResolver(resolver)
        timelineWindow?.setShardResolver(shardResolver)
        let downloadExecutor = LibreReverseArchiveDownloadExecutor(
            library: libraryConfiguration, destinationID: destinationID,
            shards: shardResolver, media: resolver
        )
        try? await archiveDownloads.connect(downloadExecutor)
        guard !terminating, !Task.isCancelled else {
            await drainArchiveDestination()
            return
        }
        updateArchiveMenuStatus()
      resumePendingMeetingDeletions(
        destinationID: destinationID,
        backend: backend,
        shardRestorer: shardResolver
      )
      resumePendingMeetingTitleUpdates(
        destinationID: destinationID,
        shardRestorer: shardResolver
      )
      // Authentication and coordinator setup are sufficient to begin. Do not
      // make the first backup pass depend on unrelated meeting-maintenance
      // recovery tasks discovering that they have no work.
      archiveTransitionInProgress = false
      scheduleMeetingTranscription(restart: true)
      scheduleArchiveWork(destinationID: destinationID)
    }

    private func resumePendingMeetingTitleUpdates(
      destinationID: Int64? = nil,
      shardRestorer: (any LibreReverseMeetingShardRestoring)? = nil
    ) {
      guard !terminating, !dataResetRequiresRestart else { return }
      let predecessor = meetingTitleUpdateRecoveryTask
      predecessor?.cancel()
      let generation = meetingTitleUpdateRecoveryTaskState.beginTask()
      let configuration = libraryConfiguration
      let coordinator = LibreReverseMeetingTitleUpdateCoordinator(
        library: configuration,
        shardRestorer: shardRestorer
      )
      meetingTitleUpdateRecoveryTask = Task { [weak self] in
        await predecessor?.value
        guard let self else { return }
        guard !Task.isCancelled,
          self.meetingTitleUpdateRecoveryTaskState.owns(generation)
        else { return }
        do {
          let pending = try LibreReverseMeetingTitleUpdate.pendingPlans(
            configuration: configuration
          )
          guard !pending.isEmpty else {
            if self.meetingTitleUpdateRecoveryTaskState.owns(generation) {
              self.meetingTitleUpdateRecoveryTask = nil
            }
            return
          }
          _ = try await LibreReverseMeetingLibraryMutationScope.perform {
            await self.timelineWindow?.prepareForPrimaryReplacement()
          } complete: {
            await self.timelineWindow?.primaryReplacementDidComplete()
          } operation: {
            if let archiveWorkTask = self.archiveWorkTask {
              archiveWorkTask.cancel()
              await archiveWorkTask.value
            }
            return try await Task.detached(priority: .utility) {
              try coordinator.resumePendingUpdates()
            }.value
          }
          guard self.meetingTitleUpdateRecoveryTaskState.owns(generation) else {
            return
          }
          self.meetingTitleUpdateRecoveryTask = nil
          if let destinationID {
            self.scheduleArchiveWork(destinationID: destinationID)
          }
        } catch LibreReverseMeetingTitleUpdateError.remoteShardRequiresRestore {
          // A persisted archive connection invokes recovery again with its
          // verified resolver after authentication returns.
          if self.meetingTitleUpdateRecoveryTaskState.owns(generation) {
            self.meetingTitleUpdateRecoveryTask = nil
          }
        } catch {
          guard self.meetingTitleUpdateRecoveryTaskState.owns(generation) else {
            return
          }
          self.meetingTitleUpdateRecoveryTask = nil
          self.updateStatusItem(
            .waiting,
            toolTip:
              "LibreReverse will retry an interrupted meeting title update: \(error.localizedDescription)"
          )
        }
      }
    }

    private func resumePendingMeetingDeletions(
      destinationID: Int64,
      backend: any ArchiveBackend,
      shardRestorer: any LibreReverseMeetingShardRestoring
    ) {
      guard !terminating, !dataResetRequiresRestart else { return }
      let predecessor = meetingDeletionRecoveryTask
      predecessor?.cancel()
      let generation = meetingDeletionRecoveryTaskState.beginTask()
      let configuration = libraryConfiguration
      let coordinator = LibreReverseMeetingDeletionCoordinator(
        destinationID: destinationID,
        library: configuration,
        backend: backend,
        shardRestorer: shardRestorer,
        transcriptionQueue: meetingTranscriptionQueue
      )
      meetingDeletionRecoveryTask = Task { [weak self] in
        await predecessor?.value
        guard let self else { return }
        guard !Task.isCancelled,
          self.meetingDeletionRecoveryTaskState.owns(generation)
        else { return }
        do {
          let pending = try LibreReverseMeetingDeletion.pendingPlans(
            configuration: configuration
          )
          guard !pending.isEmpty else {
            guard self.meetingDeletionRecoveryTaskState.owns(generation) else {
              return
            }
            self.meetingDeletionRecoveryTask = nil
            self.scheduleArchiveWork(destinationID: destinationID)
            return
          }
          do {
            _ = try await LibreReverseMeetingLibraryMutationScope.perform {
              await self.timelineWindow?.prepareForPrimaryReplacement()
            } complete: {
              await self.timelineWindow?.primaryReplacementDidComplete()
            } operation: {
              try await coordinator.resumePendingDeletions()
            }
            guard self.meetingDeletionRecoveryTaskState.owns(generation) else {
              return
            }
            self.meetingDeletionRecoveryTask = nil
            self.scheduleArchiveWork(destinationID: destinationID)
          } catch is CancellationError {
            if self.meetingDeletionRecoveryTaskState.owns(generation) {
              self.meetingDeletionRecoveryTask = nil
            }
          } catch {
            guard self.meetingDeletionRecoveryTaskState.owns(generation) else {
              return
            }
            self.updateStatusItem(
              .waiting,
              toolTip:
                "LibreReverse will retry an interrupted meeting deletion: \(error.localizedDescription)"
            )
            self.scheduleMeetingDeletionRecoveryRetry(
              destinationID: destinationID,
              backend: backend,
              shardRestorer: shardRestorer,
              replacing: generation
            )
          }
        } catch {
          guard self.meetingDeletionRecoveryTaskState.owns(generation) else {
            return
          }
          self.updateStatusItem(
            .waiting,
            toolTip:
              "LibreReverse could not inspect interrupted meeting deletion work: \(error.localizedDescription)"
          )
          self.scheduleMeetingDeletionRecoveryRetry(
            destinationID: destinationID,
            backend: backend,
            shardRestorer: shardRestorer,
            replacing: generation
          )
        }
      }
    }

    private func scheduleMeetingDeletionRecoveryRetry(
      destinationID: Int64,
      backend: any ArchiveBackend,
      shardRestorer: any LibreReverseMeetingShardRestoring,
      replacing completedGeneration: UInt64
    ) {
      guard meetingDeletionRecoveryTaskState.owns(completedGeneration) else { return }
      let predecessor = meetingDeletionRecoveryTask
      let generation = meetingDeletionRecoveryTaskState.beginTask()
      meetingDeletionRecoveryTask = Task { [weak self] in
        await predecessor?.value
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        guard !Task.isCancelled, let self,
          self.meetingDeletionRecoveryTaskState.owns(generation)
        else { return }
        self.resumePendingMeetingDeletions(
          destinationID: destinationID,
          backend: backend,
          shardRestorer: shardRestorer
        )
      }
    }

    private func scheduleArchiveWork(destinationID explicitDestinationID: Int64? = nil) {
      guard !terminating, !dataResetRequiresRestart, !archiveTransitionInProgress else { return }
        archiveRetryTask?.cancel()
        archiveRetryTask = nil
        archiveWorkPending = true
        updateArchiveMenuStatus(force: "Backup • Checking…")
        guard archiveWorkTask == nil, let coordinator = archiveCoordinator else { return }
        archiveWorkTask = Task { [weak self] in
            guard let self else { return }
            let signposter = OSSignposter(subsystem: "local.librereverse", category: .pointsOfInterest)
            let interval = signposter.beginInterval("ArchiveWork", id: signposter.makeSignpostID())
            defer { signposter.endInterval("ArchiveWork", interval) }
            defer {
                self.archiveWorkTask = nil
                self.updateArchiveMenuStatus()
            }
            do {
                if let destinationID = explicitDestinationID {
                    let configuration = self.libraryConfiguration
                    let diagnosticMaximum = LibreReverseDevelopmentEnvironment.values[
                        "LIBREREVERSE_ARCHIVE_MAX_OBJECTS"
                    ].flatMap(Int.init)
                    try await Task.detached(priority: .utility) {
                        try LibreReverseArchiveStore.recoverInterruptedWork(
                            destinationID: destinationID,
                            configuration: configuration
                        )
                        if let diagnosticMaximum {
                            _ = try LibreReverseArchiveStore.reconcileEligibleVideos(
                                destinationID: destinationID,
                                limit: max(1, min(2_000, diagnosticMaximum)),
                                configuration: configuration
                            )
                        } else {
                            var cursor: Int64 = 0
                            while true {
                  let batch =
                    try LibreReverseArchiveStore.reconcileEligibleVideoBatch(
                                    destinationID: destinationID,
                                    afterVideoID: cursor,
                                    limit: 2_000,
                                    configuration: configuration
                                )
                                guard batch.insertedCount > 0,
                    let lastVideoID = batch.lastVideoID
                  else { break }
                                cursor = lastVideoID
                            }
                        }
                    }.value
                }
                repeat {
                    self.archiveWorkPending = false
            let maximum =
              LibreReverseDevelopmentEnvironment.values[
                        "LIBREREVERSE_ARCHIVE_MAX_OBJECTS"
                    ].flatMap(Int.init) ?? .max
                    _ = try await coordinator.runUntilIdle(maxObjects: maximum)
                    if let shardCoordinator = self.shardArchiveCoordinator {
                        _ = try await shardCoordinator.runUntilIdle(maxObjects: maximum)
                    }
                } while self.archiveWorkPending
                if let destination = try LibreReverseArchiveStore.activeDestination(
                    configuration: self.libraryConfiguration
                ) {
                    try LibreReverseArchiveStore.reconcileDesiredResidency(
                        destinationID: destination.id,
                        configuration: self.libraryConfiguration
                    )
                    if let residency = self.archiveResidencyManager {
                        try await residency.recoverInterruptedEvictions()
                    }
                    if let resolver = self.archiveMediaResolver {
                        while true {
                            let videoIDs = try LibreReverseArchiveStore.videosNeedingRehydration(
                                destinationID: destination.id,
                                configuration: self.libraryConfiguration
                            )
                            if videoIDs.isEmpty { break }
                            var failed = false
                            for videoID in videoIDs {
                                do {
                                    _ = try await resolver.resolve(videoID: videoID)
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    // Continue restoring independent videos,
                                    // then leave this pass so transient failures
                                    // can observe a bounded retry delay.
                                    failed = true
                                }
                            }
                            if failed { break }
                        }
                    }
                    if let shardResolver = self.archiveShardResolver {
                        while true {
                let ordinals =
                  try LibreReverseShardArchiveStore
                                .ordinalsNeedingPolicyRehydration(
                                    destinationID: destination.id,
                                    configuration: self.libraryConfiguration
                                )
                            guard let ordinal = ordinals.first else { break }
                            do {
                                _ = try await shardResolver.restore(ordinal: ordinal) { _ in }
                                await self.timelineWindow?.prepareForShardResidencyChange()
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                // A provider failure remains visible through
                                // the existing retry/status path; do not spin.
                                break
                            }
                        }
                    }
                    if let residency = self.archiveResidencyManager,
                       ProcessInfo.processInfo.environment[
                        "LIBREREVERSE_ARCHIVE_DISABLE_EVICTION"
              ] != "1"
            {
                        while try await residency.evictEligible() > 0 {}
                    }
                    if let shardResidency = self.archiveShardResidencyManager,
                       ProcessInfo.processInfo.environment[
                        "LIBREREVERSE_ARCHIVE_DISABLE_EVICTION"
              ] != "1"
            {
                        await self.timelineWindow?.prepareForShardResidencyChange()
                        while try await shardResidency.evictEligible() > 0 {}
                    }
                    try await self.runArchiveRoundTripDiagnosticIfRequested(
                        destinationID: destination.id
                    )
                    self.scheduleArchiveRetry(destinationID: destination.id)
                }
            } catch {
                if error is CancellationError { return }
                // The store persists attempt count and retryAfter before this
                // point. Schedule the earliest retry without requiring a new
                // recording or an open Settings window.
                if let destination = try? LibreReverseArchiveStore.activeDestination(
                    configuration: self.libraryConfiguration
                ) {
                    self.scheduleArchiveRetry(destinationID: destination.id)
                }
            }
        }
    }

    private func drainArchiveDestination() async {
        archiveRetryTask?.cancel()
        archiveRetryTask = nil
        archiveWorkPending = false
        let work = archiveWorkTask
        work?.cancel()
        let deletion = meetingDeletionRecoveryTask
        deletion?.cancel()
        meetingDeletionRecoveryTaskState.invalidate()
        meetingDeletionRecoveryTask = nil
        let titleUpdate = meetingTitleUpdateRecoveryTask
        titleUpdate?.cancel()
        meetingTitleUpdateRecoveryTaskState.invalidate()
        meetingTitleUpdateRecoveryTask = nil
        let transcription = meetingTranscriptionTask
        transcription?.cancel()
        timelineWindow?.setMediaResolver(nil)
        timelineWindow?.setShardResolver(nil)
        // Cancel detached resolver work before waiting for callers that await it.
        await archiveMediaResolver?.stopAcceptingWork()
        await archiveShardResolver?.stopAcceptingWork()
        await archiveDownloads.pause(needsConnection: false)
        await work?.value
        await deletion?.value
        await titleUpdate?.value
        await transcription?.value
        await archiveMediaResolver?.cancelAllAndWait()
        await archiveShardResolver?.cancelAllAndWait()
        archiveWorkTask = nil
        archiveCoordinator = nil
        shardArchiveCoordinator = nil
        archiveBackend = nil
        archiveMediaResolver = nil
        archiveShardResolver = nil
        archiveResidencyManager = nil
        archiveShardResidencyManager = nil
    }

    private func disconnectArchiveDestination(kind: ArchiveBackendKind) async throws {
        try beginArchiveTransition()
        defer { archiveTransitionInProgress = false }
        let active = try LibreReverseArchiveStore.activeDestination(configuration: libraryConfiguration)
        if active?.kind == kind {
            await drainArchiveDestination()
            try Task.checkCancellation()
            guard !terminating else { throw CancellationError() }
            try LibreReverseArchiveStore.disableDestinations(configuration: libraryConfiguration)
            await archiveDownloads.pause(needsConnection: true)
        }
        switch kind {
        case .googleDrive: try await googleDriveConnectionManager.disconnect()
        case .s3Compatible: try S3ArchiveConfigurationStore(library: libraryConfiguration).remove()
        }
        archiveTransitionInProgress = false
        scheduleMeetingTranscription(restart: true)
        updateArchiveMenuStatus()
    }

    private func runArchiveRoundTripDiagnosticIfRequested(
        destinationID: Int64
    ) async throws {
      guard
        LibreReverseDevelopmentEnvironment.values[
            "LIBREREVERSE_ARCHIVE_ROUNDTRIP_VERIFY"
        ] == "1", !archiveRoundTripDiagnosticCompleted,
        let backend = archiveBackend
      else { return }
        archiveRoundTripDiagnosticCompleted = true
      guard
        let object = try LibreReverseArchiveStore.objects(
            destinationID: destinationID,
            states: [.verified],
            limit: 1,
            configuration: libraryConfiguration
        ).first,
              let remote = try LibreReverseArchiveStore.verifiedRemoteMedia(
                videoID: object.videoID,
                destinationID: destinationID,
                configuration: libraryConfiguration
        )
      else {
            throw LibreReverseLocalMediaResolverError.remoteMediaUnavailable(-1)
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-drive-roundtrip-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await backend.download(remote.metadata, to: temporary) { _ in }
        let integrity = try await Task.detached(priority: .utility) {
            try ArchiveIntegrityEngine.hash(file: temporary)
        }.value
        guard integrity == remote.integrity else {
            throw ArchiveBackendError.verificationMismatch
        }
      FileHandle.standardError.write(
        Data(
          "ARCHIVE_DIAGNOSTIC roundtrip=verified video=\(object.videoID) bytes=\(integrity.byteCount)\n"
            .utf8
        ))
    }

    private func scheduleArchiveRetry(destinationID: Int64) {
        guard !terminating, !archiveTransitionInProgress, !dataResetRequiresRestart else { return }
        archiveRetryTask?.cancel()
        let session = LibreReverseLibraryWriteSession(configuration: libraryConfiguration)
        defer { session.close() }
        let uploadRetry = try? LibreReverseArchiveStore.nextRetryDate(
            destinationID: destinationID,
            configuration: libraryConfiguration, session: session
        )
        let evictionRetry: Date? = {
        guard
          (try? LibreReverseArchiveStore.evictionBytesRequired(
                destinationID: destinationID,
                configuration: libraryConfiguration, session: session
          )) ?? 0 > 0
        else { return nil }
            return try? LibreReverseArchiveStore.nextEvictionEligibilityDate(
                destinationID: destinationID,
                configuration: libraryConfiguration, session: session
            )
        }()
        let rehydrationRetry: Date? = {
        guard
          let pending = try? LibreReverseArchiveStore.videosNeedingRehydration(
                destinationID: destinationID,
                limit: 1,
                configuration: libraryConfiguration, session: session
          ), !pending.isEmpty
        else { return nil }
            return Date().addingTimeInterval(30)
        }()
      guard
        let retryAt = [uploadRetry, evictionRetry, rehydrationRetry].compactMap({ $0 })
          .min()
        else { return }
        let nanoseconds = UInt64(
            max(0.25, retryAt.timeIntervalSinceNow) * 1_000_000_000
        )
        archiveRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            self.archiveRetryTask = nil
            self.scheduleArchiveWork(destinationID: destinationID)
        }
    }

    private func updateArchiveMenuStatus(force: String? = nil) {
        guard !terminating, let item = statusItem?.menu?.item(withTag: 102) else { return }
        archiveMenuStatusGeneration &+= 1
        let generation = archiveMenuStatusGeneration
        archiveMenuStatusTask?.cancel()
        archiveMenuStatusTask = nil
        if let force {
            item.title = force
            item.toolTip = nil
            return
        }
        let configuration = libraryConfiguration
        let hasActiveRecording = recordingSession != nil && !paused
        archiveMenuStatusTask = Task { [weak self, weak item] in
            let title = await Task.detached(priority: .utility) {
                let session = LibreReverseLibraryWriteSession(configuration: configuration)
                defer { session.close() }
                do {
            guard
              let destination = try LibreReverseArchiveStore.activeDestination(
                        configuration: configuration, session: session
              )
            else { return "Backup • Not connected" }
                    let status = try LibreReverseArchiveStore.status(
                        destinationID: destination.id,
                        configuration: configuration, session: session
                    )
                    let forecast = try LibreReverseArchiveStore.residencyForecast(
                        destinationID: destination.id,
                        configuration: configuration, session: session
                    )
                    let shard = try LibreReverseShardArchiveStore.status(
                        destinationID: destination.id,
                        configuration: configuration, session: session
                    )
                    if status.failedObjects > 0
                        || shard.failedObjects > 0
              || forecast.bytesWaitingForVerification > 0
            {
                        return "Backup • Needs attention"
                    }
                    if status.rehydrationObjects > 0 {
                        return "Backup • Restoring \(status.rehydrationObjects)"
                    }
            let historicalPending =
              status.historicalPendingObjects
                        + Int64(shard.totalObjects - shard.verifiedObjects)
                    if historicalPending > 0 {
                        let total = status.totalBytes + shard.totalBytes
                        let transferred = min(
                            total,
                            status.verifiedBytes + status.activeTransferredBytes
                                + shard.verifiedBytes + shard.activeTransferredBytes
                        )
              let percent =
                total > 0
                            ? Int((Double(transferred) / Double(total) * 100).rounded(.down))
                            : 0
                        return "Backup • Backing up \(percent)%"
                    }
                    if status.latestObjectState != .verified {
                        return "Backup • Backing up…"
                    }
                    return "Backup • Backed up"
                } catch {
                    return "Backup • Needs attention"
                }
            }.value
            guard let self,
                  self.archiveMenuStatusGeneration == generation,
          !Task.isCancelled
        else { return }
            item?.title = title
            item?.toolTip = title == "Backup • Backed up" && hasActiveRecording
                ? "Recording continues on this Mac. New recordings are backed up automatically."
                : nil
            self.archiveMenuStatusTask = nil
        }
    }

    @objc private func openDataFolder() {
      try? FileManager.default.createDirectory(
        at: dataDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dataDirectory)
    }

    @MainActor
    private func prepareCompleteDataReset() async throws {
      if try LibreReverseArchiveStore.activeDestination(
        configuration: libraryConfiguration
      ) != nil, archiveBackend == nil {
        throw LibreReverseDataResetError.archiveConnectionRequired
      }
      do {
        dataResetRequiresRestart = true
        paused = true
        captureTimer?.cancel()
        captureTimer = nil
        meetingDetectionTimer?.cancel()
        meetingDetectionTimer = nil
        archiveConnectionRetryTask?.cancel()
        archiveRetryTask?.cancel()
        meetingOperationTask?.cancel()
        let waveformBackfill = meetingWaveformBackfillTask
        waveformBackfill?.cancel()
        meetingWaveformBackfillTask = nil
        await waveformBackfill?.value
        let captureRecovery = meetingCaptureRecoveryTask
        captureRecovery?.cancel()
        let deletion = meetingDeletionRecoveryTask
        deletion?.cancel()
        meetingDeletionRecoveryTaskState.invalidate()
        let titleUpdate = meetingTitleUpdateRecoveryTask
        titleUpdate?.cancel()
        meetingTitleUpdateRecoveryTaskState.invalidate()
        let transcription = meetingTranscriptionTask
        transcription?.cancel()
        meetingSummaryScheduler.cancel()
        timelineWindow?.setMediaResolver(nil)
        timelineWindow?.setShardResolver(nil)
        await archiveMediaResolver?.stopAcceptingWork()
        await archiveShardResolver?.stopAcceptingWork()
        await archiveDownloads.pause(needsConnection: false)
        await archiveMediaResolver?.cancelAllAndWait()
        await archiveShardResolver?.cancelAllAndWait()
        await captureRecovery?.value
        await deletion?.value
        await titleUpdate?.value
        await transcription?.value
        await meetingSummaryScheduler.stop()
        archiveConnectionRetryTask?.cancel()
        paused = true
        captureTimer?.cancel()
        captureTimer = nil
        recordingTask?.cancel()
        await recordingTask?.value
        recordingTask = nil
        await screenshotAdmission.stopAndDrain()
        meetingRestartTask?.cancel()
        meetingRestartTask = nil
        meetingRestartIntent.cancel()
        meetingDetectionTimer?.cancel()
        meetingDetectionTimer = nil
        await meetingOperationTask?.value
        if productMeetingSession != nil {
          await stopProductMeeting(reason: .applicationTermination)
        }
        try await recordingSession?.finish()
        recordingSession = nil
        await ocrCoordinator.waitUntilIdle()

        archiveRetryTask?.cancel()
        archiveRetryTask = nil
        archiveWorkTask?.cancel()
        await archiveWorkTask?.value
        archiveWorkTask = nil
        if let drive = archiveBackend {
          try await drive.removeArchiveRoot()
        }
        if let destination = try LibreReverseArchiveStore.activeDestination(configuration: libraryConfiguration) {
            // Reset already stopped all producers and archive workers.
            switch destination.kind {
            case .googleDrive: try await googleDriveConnectionManager.disconnect()
            case .s3Compatible: try S3ArchiveConfigurationStore(library: libraryConfiguration).remove()
            }
        }
        try LibreReverseArchiveStore.disableDestinations(configuration: libraryConfiguration)

        try FileManager.default.createDirectory(
          at: dataDirectory,
          withIntermediateDirectories: true
        )
        try Data("user-authorized\n".utf8).write(
          to: pendingDataResetURL,
          options: .atomic
        )
        NSApp.terminate(nil)
      } catch {
        // Local data is retained. A partially deleted remote archive cannot be
        // treated as ready for recording; require a fresh startup/recovery.
        dataResetRequiresRestart = true
        paused = true
        recordingDisabledReason = "a data reset failed; quit and reopen LibreReverse before recording"
        updateStatusItem(.error, toolTip: "Data reset failed. Quit and reopen LibreReverse before recording.")
        refreshStatusMenu()
        throw LibreReverseDataResetError.restartRequired(error.localizedDescription)
      }
    }

    private func applyPendingDataResetIfNeeded() throws {
      guard FileManager.default.fileExists(atPath: pendingDataResetURL.path) else { return }
      let targets = [
        dataDirectory.appendingPathComponent("Library", isDirectory: true),
        libraryConfiguration.keyFileURL,
      ]
      for target in targets where FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.removeItem(at: target)
      }
      try FileManager.default.removeItem(at: pendingDataResetURL)
    }

    private func logRecordingEvent(_ event: String, operation: String, error: Error? = nil) {
        do {
            try LibreReverseRecordingDiagnostics.append(
                to: dataDirectory.appendingPathComponent("Logs", isDirectory: true),
                event: event, operation: operation, error: error)
        } catch {
            FileHandle.standardError.write(Data("Recording diagnostics could not be saved: \(error)\n".utf8))
        }
    }

    private func showRecordingError(_ error: Error, operation: String = #function) {
        logRecordingEvent("error", operation: operation, error: error)
        FileHandle.standardError.write(Data("Recording error [\(operation)]: \(error)\n".utf8))
        lastRecordingErrorOperation = operation
        recordingDisabledReason = "of a recording error"
        updateStatusItem(.error, toolTip: "LibreReverse recording error: \(error)")
        refreshStatusMenu()
    }

    private func completeTermination(_ application: NSApplication) {
        guard !terminationReplySent else { return }
        terminationReplySent = true
        installationLock = nil
        application.reply(toApplicationShouldTerminate: true)
    }

    private static func captureFrame(
        _ snapshot: LibreReverseCaptureSnapshot
    ) async throws -> CapturedScreenFrame {
        try await WindowCapture.capture(
            displayID: snapshot.displayID,
            windowIDs: snapshot.windowIDs
        )
    }

    private func currentCaptureSnapshot() throws -> LibreReverseCaptureSnapshot {
        let displayID = try WindowCapture.pointerDisplayID()
      guard
        let rows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[CFString: Any]]
      else {
            throw WindowCaptureError.noWindows
        }
        let selection = foregroundContextProvider.selection(
            from: rows,
            displayBounds: CGDisplayBounds(displayID),
            privacySettings: currentCapturePrivacySettings()
        )
        let windowIDs = selection.selectedWindows.map(\.id)
        guard !windowIDs.isEmpty else { throw WindowCaptureError.noWindows }
        let context = selection.captureContext
        return LibreReverseCaptureSnapshot(
            displayID: displayID,
            windowIDs: windowIDs,
            context: context,
            displayBounds: CGDisplayBounds(displayID),
            frontWindowBounds: selection.frontWindow?.bounds
        )
    }

    /// Read a fresh settings snapshot for each capture so privacy changes
    /// apply to the next window update.
    private func currentCapturePrivacySettings() -> CapturePrivacySettings {
        LibreReverseCaptureSettingsPreferences.privacySettings()
    }

    private var isCaptureSettingsFixture: Bool {
      LibreReverseDevelopmentEnvironment.values["LIBREREVERSE_CAPTURE_SETTINGS_FIXTURE"] != nil
    }

    private func generalSettingsSnapshot() -> LibreReverseGeneralSettingsSnapshot {
      if isCaptureSettingsFixture { return captureSettingsFixtureGeneral }
      return .init(
        launchAtLogin: SMAppService.mainApp.status == .enabled,
        remindWhenPaused: LibreReverseCaptureSettingsPreferences.remindWhenPaused(),
        showInDock: UserDefaults.standard.bool(
          forKey: LibreReverseCaptureSettingsPreferences.showInDockKey
        )
      )
    }

    private func updateLaunchAtLogin(_ enabled: Bool) throws {
      if isCaptureSettingsFixture {
        captureSettingsFixtureGeneral.launchAtLogin = enabled
        return
      }
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      UserDefaults.standard.set(
        enabled,
        forKey: LibreReverseCaptureSettingsPreferences.launchAtLoginKey
      )
    }

    private func updateRemindWhenPaused(_ enabled: Bool) {
      if isCaptureSettingsFixture {
        captureSettingsFixtureGeneral.remindWhenPaused = enabled
        return
      }
      UserDefaults.standard.set(
        enabled,
        forKey: LibreReverseCaptureSettingsPreferences.remindWhenPausedKey
      )
      updatePausedReminderSchedule()
    }

    private func updateShowInDock(_ enabled: Bool) {
      if isCaptureSettingsFixture {
        captureSettingsFixtureGeneral.showInDock = enabled
        return
      }
      UserDefaults.standard.set(
        enabled,
        forKey: LibreReverseCaptureSettingsPreferences.showInDockKey
      )
      NSApp.setActivationPolicy(enabled ? .regular : .accessory)
      if enabled { NSApp.activate(ignoringOtherApps: true) }
    }

    private var cachedSettingsApplications: [LibreReverseExcludedApplication] = []
    private var settingsCatalogLoadedAt: Date?
    private var settingsCatalogTask: Task<Void, Never>?

    private func screenSettingsSnapshot() -> LibreReverseScreenSettingsSnapshot {
      if isCaptureSettingsFixture { return captureSettingsFixtureScreen }
      if settingsCatalogTask == nil,
        settingsCatalogLoadedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
        settingsCatalogTask = Task { [weak self] in
          let applications = await Task.detached(priority: .utility) {
            LibreReverseApplicationCatalog.applications()
          }.value
          guard let self else { return }
          self.cachedSettingsApplications = applications
          self.settingsCatalogLoadedAt = Date()
          self.settingsCatalogTask = nil
          self.settingsWindow?.refreshScreenApplications()
        }
      }
      let defaults = UserDefaults.standard
      return .init(
        omittedBundleIdentifiers: Set(
          defaults.stringArray(
            forKey: LibreReverseCaptureSettingsPreferences.omittedApplicationsKey
          ) ?? []
        ),
        excludePrivateWindows: LibreReverseCaptureSettingsPreferences
          .excludePrivateWindows(defaults),
        ocrLanguageMode: LibreReverseCaptureSettingsPreferences.ocrLanguageMode(defaults),
        showRunningProcesses: defaults.bool(
          forKey: LibreReverseCaptureSettingsPreferences.showRunningProcessesKey
        ),
        applications: cachedSettingsApplications
      )
    }

    private func updateOmittedApplications(_ identifiers: Set<String>) {
      if isCaptureSettingsFixture {
        captureSettingsFixtureScreen.omittedBundleIdentifiers = identifiers
        return
      }
      UserDefaults.standard.set(
        identifiers.sorted(),
        forKey: LibreReverseCaptureSettingsPreferences.omittedApplicationsKey
      )
    }

    private func updateExcludePrivateWindows(_ enabled: Bool) {
      if isCaptureSettingsFixture {
        captureSettingsFixtureScreen.excludePrivateWindows = enabled
        return
      }
      UserDefaults.standard.set(
        enabled,
        forKey: LibreReverseCaptureSettingsPreferences.excludePrivateWindowsKey
      )
    }

    private func updateOCRLanguageMode(_ mode: LibreReverseOCRLanguageMode) {
      if isCaptureSettingsFixture {
        captureSettingsFixtureScreen.ocrLanguageMode = mode
        return
      }
      UserDefaults.standard.set(
        mode.rawValue,
        forKey: LibreReverseCaptureSettingsPreferences.ocrLanguageModeKey
      )
      ocrCoordinator.updateAdditionalLanguageSupport(mode == .additional)
    }

    private func updateShowRunningProcesses(_ enabled: Bool) {
      if isCaptureSettingsFixture {
        captureSettingsFixtureScreen.showRunningProcesses = enabled
        return
      }
      UserDefaults.standard.set(
        enabled,
        forKey: LibreReverseCaptureSettingsPreferences.showRunningProcessesKey
      )
    }

    private func updatePausedReminderSchedule() {
      let center = UNUserNotificationCenter.current()
      let identifier = LibreReversePausedReminderContract.identifier
      center.removePendingNotificationRequests(withIdentifiers: [identifier])
      guard paused, LibreReverseCaptureSettingsPreferences.remindWhenPaused() else { return }
      center.requestAuthorization(options: [.alert]) { granted, _ in
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = LibreReversePausedReminderContract.title
        content.body = LibreReversePausedReminderContract.body
        let request = UNNotificationRequest(
          identifier: identifier,
          content: content,
          trigger: UNTimeIntervalNotificationTrigger(
            timeInterval: LibreReversePausedReminderContract.delay,
            repeats: false
          )
        )
        UNUserNotificationCenter.current().add(request)
      }
    }
}

#endif
