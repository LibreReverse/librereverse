#if os(macOS)
import AppKit
import LibreReverseCore
import SwiftUI

@MainActor
final class LibreReverseMeetingDetailsWindowController: NSWindowController, NSWindowDelegate {
    private let model: LibreReverseMeetingDetailsViewModel

    init(
        libraryConfiguration: LibreReverseLibraryConfiguration,
        meeting: LibreReverseDailyRecapMeeting,
        openTimeline: @escaping (LibreReverseDailyRecapMeeting) -> Void
    ) {
        let database = LibraryDatabaseConfiguration(
            databaseURL: libraryConfiguration.databaseURL,
            keyFileURL: libraryConfiguration.keyFileURL,
            mediaRoot: libraryConfiguration.mediaRoot
        )
        model = LibreReverseMeetingDetailsViewModel(
            meeting: meeting,
            session: LibraryDatabaseSession(configuration: database)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable ],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.title = meeting.title
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 520, height: 420)
        window.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1)
        window.contentViewController = NSHostingController(
            rootView: LibreReverseMeetingDetailsView(
                model: model,
                close: { [weak window] in window?.performClose(nil) },
                openTimeline: { openTimeline(meeting) }
            )
        )
        window.setContentSize(NSSize(width: 680, height: 640))
    }

    init(
        fixtureMeeting meeting: LibreReverseDailyRecapMeeting,
        summary: String,
        transcript: LibreReverseMeetingTranscript
    ) {
        model = LibreReverseMeetingDetailsViewModel(
            meeting: meeting,
            fixtureSummary: summary,
            fixtureTranscript: transcript
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable ],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.title = meeting.title
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 520, height: 420)
        window.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1)
        window.contentViewController = NSHostingController(
            rootView: LibreReverseMeetingDetailsView(
                model: model,
                close: { [weak window] in window?.performClose(nil) },
                openTimeline: {}
            )
        )
        window.setContentSize(NSSize(width: 680, height: 640))
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.load()
    }

    func windowWillClose(_ notification: Notification) { model.cancel() }
}

@MainActor
final class LibreReverseMeetingDetailsViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"

        var id: Self { self }
    }

    let meeting: LibreReverseDailyRecapMeeting
    @Published var selectedTab: Tab = .summary
    @Published private(set) var summary: String?
    @Published private(set) var summaryStatus: String?

    var summaryNotice: String {
        if LibreReverseAIProfiles.selected().provider == .local, let reason = LibreReverseMeetingSummarizer.unavailableReason { return reason }
        if summaryStatus == "localQueued" || summaryStatus == "localRetrying" { return "Preparing your summary…" }
        return "Your summary will appear after transcription."
    }
    @Published private(set) var transcript: LibreReverseMeetingTranscript?
    @Published private(set) var isLoading = false
    @Published private(set) var errorDescription: String?

    private let session: LibraryDatabaseSession?
    private let fixtureSummary: String?
    private let fixtureTranscript: LibreReverseMeetingTranscript?
    private var loadTask: Task<Void, Never>?

    init(meeting: LibreReverseDailyRecapMeeting, session: LibraryDatabaseSession) {
        self.meeting = meeting
        self.session = session
        fixtureSummary = nil
        fixtureTranscript = nil
    }

    init(
        meeting: LibreReverseDailyRecapMeeting,
        fixtureSummary: String,
        fixtureTranscript: LibreReverseMeetingTranscript
    ) {
        self.meeting = meeting
        session = nil
        self.fixtureSummary = fixtureSummary
        self.fixtureTranscript = fixtureTranscript
    }

    func load() {
        if let fixtureSummary, let fixtureTranscript {
            selectedTab = .summary
            summary = fixtureSummary
            transcript = fixtureTranscript
            isLoading = false
            errorDescription = nil
            return
        }
        guard let segmentID = meeting.segmentID else { return }
        loadTask?.cancel()
        isLoading = true
        errorDescription = nil
        guard let session else {
            errorDescription = "Meeting details do not have a library session."
            isLoading = false
            return
        }
        let date = meeting.startDate
        loadTask = Task { [weak self, session] in
            do {
              while !Task.isCancelled {
                let summary = try await session.meetingSummary(segmentID: segmentID)
                let transcript = try await session.meetingTranscript(segmentID: segmentID, at: date)
                let summaryStatus = try await session.meetingSummaryStatus(segmentID: segmentID)
                try Task.checkCancellation()
                guard let self else { return }
                self.summary = summary
                self.summaryStatus = summaryStatus
                self.transcript = transcript
                self.isLoading = false
                if summary != nil { return }
                try await Task.sleep(nanoseconds: 3_000_000_000)
              }
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.errorDescription = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }
}

private struct LibreReverseMeetingDetailsView: View {
    @ObservedObject var model: LibreReverseMeetingDetailsViewModel
    let close: () -> Void
    let openTimeline: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("Meeting details", selection: $model.selectedTab) {
                ForEach(LibreReverseMeetingDetailsViewModel.Tab.allCases) { tab in
                    Text(tab.rawValue)
                        .tag(tab)
                        .accessibilityIdentifier(
                            "meetingDetails.tab.\(tab.rawValue.lowercased())"
                        )
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("meetingDetails.tabs")
            .frame(width: 230, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.bottom, 18)
            Divider().overlay(Color.white.opacity(0.07))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(Color.white.opacity(0.07))
            footer
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Color(white: 0.105))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(model.meeting.title)
                .font(.system(size: 22, weight: .semibold, design: .default))
                .lineLimit(2)
            Text(Self.dateFormatter.string(from: model.meeting.startDate))
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundStyle(Color.white.opacity(0.55))
            if let contextLabel {
                Text(contextLabel)
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundStyle(Color.white.opacity(0.42))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 28)
        .padding(.trailing, 28)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var content: some View {
        if model.isLoading {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Loading meeting details…")
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        } else if let error = model.errorDescription {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.orange)
                Text("Meeting details are unavailable").font(.headline)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.50))
                    .multilineTextAlignment(.center)
                Button("Try Again") { model.load() }
                    .accessibilityIdentifier("meetingDetails.retry")
                    .accessibilityLabel(Text("Try loading meeting details again"))
                    .accessibilityValue(Text("Try loading meeting details again"))
            }
            .padding(30)
        } else {
            switch model.selectedTab {
            case .summary:
                selectableDocument(
                    model.summary,
                    emptyTitle: "Meeting summary",
                    emptyDetail: model.summaryNotice
                )
            case .transcript:
                selectableDocument(
                    model.transcript?.text,
                    emptyTitle: model.transcript?.processingState.emptyStateDescription
                        ?? "No transcript available",
                    emptyDetail: "Open in Timeline to load the recording or retry transcription."
                )
            }
        }
    }

    @ViewBuilder private func selectableDocument(
        _ text: String?,
        emptyTitle: String,
        emptyDetail: String
    ) -> some View {
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            ScrollView {
                Text(text)
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundStyle(Color.white.opacity(0.86))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
            }
        } else {
            VStack(spacing: 8) {
                Text(emptyTitle)
                    .font(.system(size: 17, weight: .semibold, design: .default))
                Text(emptyDetail)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundStyle(Color.white.opacity(0.50))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .padding(30)
        }
    }

    private var footer: some View {
        HStack {
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("meetingDetails.close")
                .accessibilityLabel(Text("Close meeting details"))
                .accessibilityValue(Text("Close meeting details"))
            Spacer()
            Button("Open in Timeline", action: openTimeline)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("meetingDetails.openTimeline")
                .accessibilityLabel(Text("Open meeting in timeline"))
                .accessibilityValue(Text("Open meeting in timeline"))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    private var contextLabel: String? {
        var values: [String] = []
        if let calendar = model.meeting.calendarTitle, !calendar.isEmpty {
            values.append(calendar)
        }
        if !model.meeting.participants.isEmpty {
            values.append(
                model.meeting.participants.count == 1
                    ? "1 participant"
                    : "\(model.meeting.participants.count) participants"
            )
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()
}
#endif
