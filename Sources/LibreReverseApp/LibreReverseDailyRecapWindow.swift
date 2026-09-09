#if os(macOS)
import AppKit
import LibreReverseCore
import SwiftUI

@MainActor final class LibreReverseDailyRecapWindowController: NSWindowController, NSWindowDelegate {
    private static var openingContentSize: NSSize {
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        return NSSize(width: min(520, max(360, available.width - 40)),
            height: min(800, max(560, available.height - 64)))
    }
    private let model: LibreReverseDailyRecapViewModel
    private let libraryConfiguration: LibreReverseLibraryConfiguration?
    private let openTimeline: (LibreReverseDailyRecapMeeting) -> Void
    private var meetingDetailsWindow: LibreReverseMeetingDetailsWindowController?

    init(
        libraryConfiguration: LibreReverseLibraryConfiguration,
        calendarEvents: @escaping (DateInterval) -> [LibreReverseMeetingCalendarEvent] = { _ in [] },
        openTimeline: @escaping (LibreReverseDailyRecapMeeting) -> Void = { _ in }
    ) {
        self.libraryConfiguration = libraryConfiguration
        self.openTimeline = openTimeline
        let database = LibraryDatabaseConfiguration(
            databaseURL: libraryConfiguration.databaseURL,
            keyFileURL: libraryConfiguration.keyFileURL, mediaRoot: libraryConfiguration.mediaRoot)
        model = LibreReverseDailyRecapViewModel(
            session: LibraryDatabaseSession(configuration: database),
            calendarEvents: calendarEvents)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.openingContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable ],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.title = "Daily Recap"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1)
        window.minSize = NSSize(width: 360, height: 560)
        window.setFrameAutosaveName("LibreReverse.DailyRecap")
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.contentViewController = NSHostingController(
            rootView: LibreReverseDailyRecapView(
                model: model,
                pinChanged: { [weak self] pinned in
                    self?.window?.level = pinned ? .floating : .normal
                },
                openDetails: { [weak self] meeting in self?.presentDetails(for: meeting) },
                openTimeline: openTimeline))
        // NSHostingController initially negotiates the SwiftUI view down to
        // its 360×560 minimum. Reassert the opening size after host
        // installation while retaining that smaller value as the resize floor.
        window.setContentSize(Self.openingContentSize)
        model.reload()
    }

    init(fixtureRecap: LibreReverseDailyRecap) {
        libraryConfiguration = nil
        openTimeline = { _ in }
        model = LibreReverseDailyRecapViewModel(fixtureRecap: fixtureRecap)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.openingContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable ],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.title = "Daily Recap"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1)
        window.minSize = NSSize(width: 360, height: 560)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.contentViewController = NSHostingController(
            rootView: LibreReverseDailyRecapView(
                model: model,
                pinChanged: { [weak self] pinned in
                    self?.window?.level = pinned ? .floating : .normal
                },
                openDetails: { [weak self] meeting in
                    self?.presentFixtureDetails(for: meeting)
                },
                openTimeline: { _ in }))
        window.setContentSize(Self.openingContentSize)
        model.reload()
    }

    required init?(coder: NSCoder) { nil }

    func beginShutdown() -> [Task<Void, Never>] { model.beginShutdown() }

    func present() {
        guard !model.shuttingDown else { return }
        showWindow(nil)
        if let window, let screen = window.screen ?? NSScreen.main {
            let available = screen.visibleFrame.insetBy(dx: 10, dy: 10)
            var frame = window.frame
            frame.size.width = min(frame.width, available.width)
            frame.size.height = min(frame.height, available.height)
            frame.origin.x = min(max(frame.minX, available.minX), available.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, available.minY), available.maxY - frame.height)
            window.setFrame(frame, display: false)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.reload()
    }

    func windowWillClose(_ notification: Notification) { model.cancel() }

    func presentFirstFixtureMeetingDetails() -> Int? {
        guard libraryConfiguration == nil,
            let meeting = model.recap?.recordedMeetings.first
        else { return nil }
        presentFixtureDetails(for: meeting)
        return meetingDetailsWindow?.window?.windowNumber
    }

    private func presentDetails(for meeting: LibreReverseDailyRecapMeeting) {
        guard meeting.segmentID != nil, let libraryConfiguration else { return }
        meetingDetailsWindow = LibreReverseMeetingDetailsWindowController(
            libraryConfiguration: libraryConfiguration,
            meeting: meeting,
            openTimeline: { [weak self] meeting in
                self?.openTimeline(meeting)
            }
        )
        meetingDetailsWindow?.present()
    }

    private func presentFixtureDetails(for meeting: LibreReverseDailyRecapMeeting) {
        guard let segmentID = meeting.segmentID else { return }
        let transcriptText = """
            Maya: The new meeting capture is stable across the validation runs, including system audio and microphone input.

            Theo: Great. The next step is connecting the recap cards to the exact meeting moment in the timeline.

            Sam: I’ll verify archived transcripts still open after their media has moved to Google Drive.
            """
        let transcript = LibreReverseMeetingTranscript(
            segmentID: segmentID,
            title: meeting.title,
            text: transcriptText,
            startDate: meeting.startDate,
            endDate: meeting.endDate,
            words: [],
            metadata: .init(
                calendarTitle: meeting.calendarTitle,
                participants: meeting.participants
            ),
            processingState: .complete
        )
        meetingDetailsWindow = LibreReverseMeetingDetailsWindowController(
            fixtureMeeting: meeting,
            summary: """
                The team confirmed that dense meeting video, system audio, and microphone audio remain synchronized through finalization. Timeline navigation and archived transcript restoration are the final integration checks.

                Next steps
                • Open recorded meetings at their exact timeline moment.
                • Verify transcript access before and after Google Drive archival.
                • Complete the long-running production soak.
                """,
            transcript: transcript
        )
        meetingDetailsWindow?.present()
    }
}

@MainActor final class LibreReverseDailyRecapViewModel: ObservableObject {
    @Published private(set) var selectedDay: Date
    @Published private(set) var recap: LibreReverseDailyRecap?
    @Published private(set) var isLoading = false
    @Published private(set) var errorDescription: String?
    @Published var showPercentages: Bool {
        didSet {
            UserDefaults.standard.set(showPercentages, forKey: Self.showPercentagesDefaultsKey)
        }
    }
    @Published var isPinned = false

    private static let showPercentagesDefaultsKey = "LibreReverse.recapShowPercentages"
    private let session: LibraryDatabaseSession?
    private let calendar: Calendar
    private let calendarEvents: (DateInterval) -> [LibreReverseMeetingCalendarEvent]
    private let fixtureRecap: LibreReverseDailyRecap?
    typealias EvidenceLoader = (DateInterval) async throws -> ([TimelineSegment], [LibreReverseDailyRecapMeeting])
    private let evidenceLoader: EvidenceLoader?
    private var loadTask: Task<Void, Never>?
    private var loadOwners: [UUID: Task<Void, Never>] = [:]
    private var loadID: UUID?
    private var shutdownTask: Task<Void, Never>?
    private(set) var shuttingDown = false

    init(
        session: LibraryDatabaseSession,
        day: Date = Date(),
        calendar: Calendar = .current,
        calendarEvents: @escaping (DateInterval) -> [LibreReverseMeetingCalendarEvent] = { _ in [] },
        evidenceLoader: EvidenceLoader? = nil
    ) {
        self.session = session
        self.evidenceLoader = evidenceLoader
        self.calendar = calendar
        self.calendarEvents = calendarEvents
        fixtureRecap = nil
        selectedDay = calendar.startOfDay(for: day)
        showPercentages = UserDefaults.standard.bool(forKey: Self.showPercentagesDefaultsKey)
    }

    init(fixtureRecap: LibreReverseDailyRecap, calendar: Calendar = .current) {
        session = nil
        evidenceLoader = nil
        self.calendar = calendar
        calendarEvents = { _ in [] }
        self.fixtureRecap = fixtureRecap
        selectedDay = calendar.startOfDay(for: fixtureRecap.day)
        showPercentages = false
    }

    var canMoveForward: Bool {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: selectedDay) else {
            return false
        }
        return tomorrow <= calendar.startOfDay(for: Date())
    }

    var isShowingToday: Bool { calendar.isDateInToday(selectedDay) }

    func move(byDays days: Int) {
        guard let date = calendar.date(byAdding: .day, value: days, to: selectedDay) else { return }
        select(date)
    }

    func select(_ date: Date) {
        guard !shuttingDown else { return }
        let normalized = calendar.startOfDay(for: date)
        guard normalized <= calendar.startOfDay(for: Date()) else { return }
        selectedDay = normalized
        reload()
    }

    func moveToToday() { select(Date()) }

    @discardableResult
    func reload() -> Task<Void, Never>? {
        guard !shuttingDown else { return nil }
        if let fixtureRecap {
            cancel()
            recap = fixtureRecap
            isLoading = false
            errorDescription = nil
            return nil
        }
        let day = selectedDay
        let interval = LibreReverseDailyRecapBuilder.dayInterval(containing: day, calendar: calendar)
        cancel()
        isLoading = true
        errorDescription = nil
        guard let session else {
            errorDescription = "Daily Recap does not have a library session."
            isLoading = false
            return nil
        }
        let calendar = self.calendar
        let calendarQueryInterval = upcomingCalendarInterval(for: day, dayInterval: interval)
        let calendarEvents = self.calendarEvents(calendarQueryInterval)
        let loader: EvidenceLoader = evidenceLoader ?? { interval in
            let segments = try await session.timelineSegments(intersecting: interval)
            try Task.checkCancellation()
            let meetings = try await session.dailyRecapRecordedMeetings(intersecting: interval)
            return (segments, meetings)
        }
        let identifier = UUID()
        loadID = identifier
        let task = Task { [weak self, calendar, calendarEvents] in
            defer {
                self?.loadOwners[identifier] = nil
                if self?.loadID == identifier {
                    self?.loadID = nil
                    self?.loadTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                let (segments, recordedMeetings) = try await loader(interval)
                try Task.checkCancellation()
                let names = Self.applicationNames(for: segments)
                let recap = LibreReverseDailyRecapBuilder.build(
                    day: day,
                    segments: segments,
                    applicationNames: names,
                    recordedMeetings: recordedMeetings,
                    calendarEvents: calendarEvents,
                    upcomingInterval: calendarQueryInterval,
                    calendar: calendar)
                guard let self, !self.shuttingDown, self.loadID == identifier, self.selectedDay == day else { return }
                self.recap = recap
                self.isLoading = false
            } catch is CancellationError { return } catch {
                guard let self, !self.shuttingDown, self.loadID == identifier, self.selectedDay == day else { return }
                self.errorDescription = error.localizedDescription
                self.isLoading = false
            }
        }
        loadTask = task
        loadOwners[identifier] = task
        return task
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        loadID = nil
    }

    func beginShutdown() -> [Task<Void, Never>] {
        if let shutdownTask { return [shutdownTask] }
        shuttingDown = true
        cancel()
        let owners = Array(loadOwners.values)
        for owner in owners { owner.cancel() }
        let session = self.session
        let completion = Task {
            for owner in owners { await owner.value }
            await session?.closeConnection()
        }
        shutdownTask = completion
        return owners + [completion]
    }

    private func upcomingCalendarInterval(
        for day: Date,
        dayInterval: DateInterval
    ) -> DateInterval {
        guard calendar.isDateInToday(day),
            let end = calendar.date(byAdding: .day, value: 7, to: dayInterval.start)
        else { return dayInterval }
        return DateInterval(start: dayInterval.start, end: end)
    }

    private static func applicationNames(for segments: [TimelineSegment]) -> [String:
        String]
    {
        var result: [String: String] = [:]
        for bundleID in Set(segments.compactMap(\.bundleID)) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { continue }
            let bundle = Bundle(url: url)
            let name =
                bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle?
                .object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            if !name.isEmpty { result[bundleID] = name }
        }
        return result
    }
}

enum LibreReverseDailyRecapFixture {
    static func empty(anchorDate: Date = Date(), calendar: Calendar = .current)
        -> LibreReverseDailyRecap
    {
        let interval = LibreReverseDailyRecapBuilder.dayInterval(
            containing: anchorDate,
            calendar: calendar
        )
        return LibreReverseDailyRecap(
            day: interval.start,
            interval: interval,
            activeIntervals: [],
            applications: [],
            websites: [],
            totalActiveTime: 0,
            totalApplicationTime: 0,
            totalWebsiteTime: 0
        )
    }

    static func make(anchorDate: Date = Date(), calendar: Calendar = .current)
        -> LibreReverseDailyRecap
    {
        let interval = LibreReverseDailyRecapBuilder.dayInterval(
            containing: anchorDate,
            calendar: calendar
        )
        func date(dayOffset: Int = 0, hour: Int, minute: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: interval.start)
                ?? interval.start
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        func recorded(
            id: Int64,
            title: String,
            startHour: Int,
            startMinute: Int,
            endHour: Int,
            endMinute: Int,
            participants: [String]
        ) -> LibreReverseDailyRecapMeeting {
            LibreReverseDailyRecapMeeting(
                kind: .recorded,
                segmentID: id,
                title: title,
                startDate: date(hour: startHour, minute: startMinute),
                endDate: date(hour: endHour, minute: endMinute),
                calendarTitle: "Work",
                participants: participants
            )
        }
        func upcoming(
            id: String,
            title: String,
            dayOffset: Int,
            startHour: Int,
            startMinute: Int = 0,
            duration: TimeInterval,
            calendarTitle: String,
            participants: [String],
            meetingURL: URL? = nil
        ) -> LibreReverseDailyRecapMeeting {
            let start = date(dayOffset: dayOffset, hour: startHour, minute: startMinute)
            return LibreReverseDailyRecapMeeting(
                kind: .calendar,
                calendarEventID: id,
                title: title,
                startDate: start,
                endDate: start.addingTimeInterval(duration),
                calendarTitle: calendarTitle,
                participants: participants,
                meetingURL: meetingURL
            )
        }

        let activeIntervals = [
            DateInterval(start: date(hour: 8, minute: 45), end: date(hour: 11, minute: 20)),
            DateInterval(start: date(hour: 12, minute: 40), end: date(hour: 15, minute: 35)),
            DateInterval(start: date(hour: 16, minute: 10), end: date(hour: 19, minute: 5)),
        ]
        let applications = [
            LibreReverseDailyRecapActivity(
                kind: .application(bundleID: "com.microsoft.VSCode"), title: "Visual Studio Code",
                duration: 4 * 3_600 + 24 * 60),
            LibreReverseDailyRecapActivity(
                kind: .application(bundleID: "com.google.Chrome"), title: "Google Chrome",
                duration: 2 * 3_600 + 43 * 60),
            LibreReverseDailyRecapActivity(
                kind: .application(bundleID: "com.apple.MobileSMS"), title: "Messages",
                duration: 18 * 60),
            LibreReverseDailyRecapActivity(
                kind: .application(bundleID: "net.whatsapp.WhatsApp"), title: "WhatsApp",
                duration: 9 * 60),
        ]
        let websites = [
            LibreReverseDailyRecapActivity(
                kind: .website(host: "claude.ai"), title: "claude.ai", duration: 54 * 60),
            LibreReverseDailyRecapActivity(
                kind: .website(host: "github.com"), title: "github.com", duration: 31 * 60),
            LibreReverseDailyRecapActivity(
                kind: .website(host: "cal.com"), title: "cal.com", duration: 17 * 60),
            LibreReverseDailyRecapActivity(
                kind: .website(host: "dashboard.clerk.com"), title: "dashboard.clerk.com",
                duration: 6 * 60),
        ]
        let recordedMeetings = [
            recorded(
                id: 9_002,
                title: "Daily product sync",
                startHour: 14,
                startMinute: 0,
                endHour: 14,
                endMinute: 42,
                participants: ["Maya", "Theo", "Sam"]),
            recorded(
                id: 9_001,
                title: "Design review",
                startHour: 10,
                startMinute: 30,
                endHour: 11,
                endMinute: 18,
                participants: ["Maya", "Jordan"]),
        ]
        let upcomingMeetings = [
            upcoming(
                id: "fixture-planning",
                title: "Weekly planning",
                dayOffset: 1,
                startHour: 9,
                startMinute: 30,
                duration: 45 * 60,
                calendarTitle: "Product & Design",
                participants: ["Maya", "Theo", "Jordan"],
                meetingURL: URL(string: "https://meet.google.com/fixture-planning")),
            upcoming(
                id: "fixture-customer",
                title: "Customer research debrief",
                dayOffset: 2,
                startHour: 13,
                duration: 60 * 60,
                calendarTitle: "Work",
                participants: ["Maya", "Alex"]),
        ]
        return LibreReverseDailyRecap(
            day: interval.start,
            interval: interval,
            activeIntervals: activeIntervals,
            applications: applications,
            websites: websites,
            recordedMeetings: recordedMeetings,
            upcomingMeetings: upcomingMeetings,
            totalActiveTime: activeIntervals.reduce(0) { $0 + $1.duration },
            totalApplicationTime: applications.reduce(0) { $0 + $1.duration },
            totalWebsiteTime: websites.reduce(0) { $0 + $1.duration },
            totalCalendarEventTime: 2.5 * 3_600
        )
    }
}

private struct LibreReverseDailyRecapView: View {
    @ObservedObject var model: LibreReverseDailyRecapViewModel
    let pinChanged: (Bool) -> Void
    let openDetails: (LibreReverseDailyRecapMeeting) -> Void
    let openTimeline: (LibreReverseDailyRecapMeeting) -> Void
    @State private var showsDatePicker = false
    @State private var activeHoursExpanded = true
    @State private var applicationsExpanded = true
    @State private var websitesExpanded = true
    @State private var meetingsExpanded = true
    @State private var optionsControlHovered = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            ScrollView {
                LazyVStack(spacing: 16) {
                    if let recap = model.recap {
                        recapContent(recap)
                    } else if model.isLoading {
                        loadingState
                    } else if let error = model.errorDescription {
                        errorState(error)
                    }
                }.padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 24)
            }
        }.frame(minWidth: 360, minHeight: 560).background(Color(white: 0.105)).preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                showsDatePicker.toggle()
            } label: {
                Text(headerTitle).font(
                    .system(size: 20, weight: .medium, design: .default)
                ).lineLimit(1).minimumScaleFactor(0.75).allowsTightening(true).layoutPriority(1)
                    .padding(.horizontal, 0).frame(height: 36)
            }
            .buttonStyle(
                LibreReverseRecapInteractiveButtonStyle(
                    cornerRadius: 7, hoverFill: 0.08, pressedFill: 0.14,
                    focusStroke: 0.72, pressedScale: 0.98))
            .focusable()
            .focusEffectDisabled()
            .accessibilityLabel(Text("Choose recap date"))
            .accessibilityValue(Text("Choose recap date, \(headerTitle)"))
            .popover(
                isPresented: $showsDatePicker, arrowEdge: .top
            ) {
                DatePicker(
                    "Recap date",
                    selection: Binding(get: { model.selectedDay }, set: { model.select($0) }),
                    in: ...Date(), displayedComponents: .date
                ).datePickerStyle(.graphical).labelsHidden().padding(12)
            }
            Spacer(minLength: 4)
            recapButton(symbol: "chevron.left", label: "Previous day") { model.move(byDays: -1) }
            recapButton(symbol: "chevron.right", label: "Next day") { model.move(byDays: 1) }
                .disabled(!model.canMoveForward)
            Menu {
                Button(model.isPinned ? "Unpin Window" : "Pin Window") {
                    model.isPinned.toggle()
                    pinChanged(model.isPinned)
                }
                Button(model.showPercentages ? "Show Durations" : "Show Percentages") {
                    model.showPercentages.toggle()
                }
                Divider()
                Button("Today") { model.moveToToday() }
                Button("Refresh") { model.reload() }
            } label: {
                Image(systemName: "line.3.horizontal").font(.system(size: 15, weight: .regular)).frame(
                    width: 28, height: 28
                ).background(
                    Color.white.opacity(optionsControlHovered ? 0.08 : 0),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                ).overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(optionsControlHovered ? 0.10 : 0), lineWidth: 1)
                ).animation(.easeOut(duration: 0.12), value: optionsControlHovered)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusable()
            .focusEffectDisabled()
            .onHover { optionsControlHovered = $0 }
            .accessibilityLabel(Text("Daily Recap options"))
        }.foregroundStyle(Color.white.opacity(0.9)).padding(.horizontal, 24)
            .padding(.top, 16).padding(.bottom, 16)
    }

    private var headerTitle: String {
        Self.headerFormatter.string(from: model.selectedDay)
    }

    @ViewBuilder private func recapContent(_ recap: LibreReverseDailyRecap) -> some View {
        if isEmpty(recap) {
            emptyRecapState
        } else {
            LibreReverseRecapSection(
                title: "Active Hours",
                subtitle: LibreReverseDailyRecapBuilder.durationLabel(recap.totalActiveTime),
                identifier: "recap.activeHours",
                isExpanded: $activeHoursExpanded
            ) {
                LibreReverseRecapActivityChart(recap: recap).frame(height: 64).padding(
                    .horizontal, 0
                ).padding(.bottom, 12).accessibilityIdentifier("recap.activeHours.chart")
            }

            LibreReverseRecapSection(
                title: "Meetings",
                subtitle: recap.totalCalendarEventTime > 0
                    ? LibreReverseDailyRecapBuilder.durationLabel(recap.totalCalendarEventTime)
                    : nil,
                identifier: "recap.meetings",
                isExpanded: $meetingsExpanded
            ) {
                meetingList(recap)
            }

            LibreReverseRecapSection(
                title: "Apps",
                subtitle: nil,
                identifier: "recap.apps",
                isExpanded: $applicationsExpanded
            ) {
                activityList(
                    recap.applications,
                    total: recap.totalApplicationTime,
                    emptyText: "No app activity")
            }

            LibreReverseRecapSection(
                title: "Websites",
                subtitle: nil,
                identifier: "recap.websites",
                isExpanded: $websitesExpanded
            ) {
                activityList(
                    recap.websites,
                    total: recap.totalWebsiteTime,
                    emptyText: "No website activity")
            }


        }
    }

    private func isEmpty(_ recap: LibreReverseDailyRecap) -> Bool {
        recap.activeIntervals.isEmpty
            && recap.applications.isEmpty
            && recap.websites.isEmpty
            && recap.recordedMeetings.isEmpty
            && recap.upcomingMeetings.isEmpty
    }

    private var emptyRecapState: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.white.opacity(0.32))
                .accessibilityHidden(true)
            Text("No Activity")
                .font(.system(size: 18, weight: .semibold, design: .default))
            Text("Nothing recorded on this day.")
                .font(.system(size: 14, weight: .medium, design: .default))
                .foregroundStyle(Color.white.opacity(0.48))
        }
        .frame(maxWidth: .infinity, minHeight: 520)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recap.empty")
    }

    @ViewBuilder private func meetingList(_ recap: LibreReverseDailyRecap) -> some View {
        if recap.recordedMeetings.isEmpty && recap.upcomingMeetings.isEmpty {
            Text("No meetings for this day")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.44))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 0)
                .padding(.bottom, 16)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if !recap.recordedMeetings.isEmpty {
                    meetingGroupLabel("Recorded meetings")
                    ForEach(Array(recap.recordedMeetings.enumerated()), id: \.element.id) {
                        index, meeting in
                        if index > 0 { recapRowDivider }
                        LibreReverseRecapMeetingRow(
                            meeting: meeting,
                            openDetails: { openDetails(meeting) },
                            openTimeline: { openTimeline(meeting) })
                    }
                }
                if !recap.upcomingMeetings.isEmpty {
                    if !recap.recordedMeetings.isEmpty { recapRowDivider }
                    meetingGroupLabel(
                        model.isShowingToday ? "Upcoming · next 7 days" : "Upcoming meetings")
                        .padding(.top, recap.recordedMeetings.isEmpty ? 0 : 12)
                    ForEach(Array(recap.upcomingMeetings.enumerated()), id: \.element.id) {
                        index, meeting in
                        if index > 0 { recapRowDivider }
                        LibreReverseRecapMeetingRow(
                            meeting: meeting,
                            openDetails: {},
                            openTimeline: {})
                    }
                }
            }
        }
    }

    private func meetingGroupLabel(_ value: String) -> some View {
        Text(value.uppercased())
            .font(.system(size: 10, weight: .bold, design: .default))
            .tracking(0.7)
            .foregroundStyle(Color.white.opacity(0.38))
            .padding(.horizontal, 0)
            .padding(.bottom, 7)
    }

    private var recapRowDivider: some View {
        Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 0)
    }

    private func activityList(
        _ activities: [LibreReverseDailyRecapActivity], total: TimeInterval, emptyText: String
    ) -> some View {
        VStack(spacing: 0) {
            if activities.isEmpty {
                Text(emptyText).font(.system(size: 13, weight: .medium)).foregroundStyle(
                    Color.white.opacity(0.44)
                ).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 0).padding(
                    .bottom, 16)
            } else {
                ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                    if index > 0 {
                        Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 0)
                    }
                    LibreReverseRecapActivityRow(
                        activity: activity, value: activityValue(activity, total: total))
                }
            }
        }
    }

    private func activityValue(_ activity: LibreReverseDailyRecapActivity, total: TimeInterval)
        -> String
    {
        if model.showPercentages, total > 0 {
            return "\(Int((activity.duration / total * 100).rounded()))%"
        }
        return LibreReverseDailyRecapBuilder.durationLabel(activity.duration)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Building your recap…").foregroundStyle(Color.white.opacity(0.62))
        }.frame(maxWidth: .infinity).padding(.top, 80)
    }

    private func errorState(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 26)).foregroundStyle(
                Color.orange)
            Text("Daily Recap is unavailable").font(.headline)
            Text(error).font(.caption).foregroundStyle(Color.white.opacity(0.55))
                .multilineTextAlignment(.center)
            Button("Try Again") { model.reload() }
        }.frame(maxWidth: .infinity).padding(28)
    }

    private func recapButton(symbol: String, label: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).frame(
                width: 28, height: 28
            ).contentShape(Rectangle()).accessibilityHidden(true)
        }
        .buttonStyle(
            LibreReverseRecapInteractiveButtonStyle(
                cornerRadius: 7, hoverFill: 0.09, pressedFill: 0.16,
                focusStroke: 0.72, pressedScale: 0.94))
        .focusable()
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(label))
    }

    private static let headerFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter
    }()
}

private struct LibreReverseRecapInteractiveButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    let restingFill: Double
    let hoverFill: Double
    let pressedFill: Double
    let restingStroke: Double
    let focusStroke: Double
    let pressedScale: CGFloat

    init(
        cornerRadius: CGFloat,
        restingFill: Double = 0,
        hoverFill: Double,
        pressedFill: Double,
        restingStroke: Double = 0,
        focusStroke: Double,
        pressedScale: CGFloat
    ) {
        self.cornerRadius = cornerRadius
        self.restingFill = restingFill
        self.hoverFill = hoverFill
        self.pressedFill = pressedFill
        self.restingStroke = restingStroke
        self.focusStroke = focusStroke
        self.pressedScale = pressedScale
    }

    static let actionCapsule = LibreReverseRecapInteractiveButtonStyle(
        cornerRadius: 5,
        restingFill: 0,
        hoverFill: 0.07,
        pressedFill: 0.12,
        restingStroke: 0,
        focusStroke: 0.78,
        pressedScale: 0.97
    )

    func makeBody(configuration: Configuration) -> some View {
        LibreReverseRecapInteractiveButtonBody(
            configuration: configuration,
            style: self
        )
    }
}

private struct LibreReverseRecapInteractiveButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: LibreReverseRecapInteractiveButtonStyle
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .background(
                Color.white.opacity(fillOpacity),
                in: RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: isFocused ? 1.5 : 1)
            )
            .scaleEffect(configuration.isPressed ? style.pressedScale : 1)
            .opacity(isEnabled ? 1 : 0.34)
            .contentShape(
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
            )
            .onHover { isHovered = $0 }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: isHovered
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: configuration.isPressed
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: isFocused
            )
    }

    private var fillOpacity: Double {
        if configuration.isPressed { return style.pressedFill }
        if isHovered { return style.hoverFill }
        return style.restingFill
    }

    private var strokeColor: Color {
        if isFocused {
            return Color.blue.opacity(style.focusStroke)
        }
        return Color.white.opacity(style.restingStroke)
    }
}

private struct LibreReverseRecapSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let identifier: String
    @Binding var isExpanded: Bool
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: String,
        subtitle: String?,
        identifier: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.identifier = identifier
        _isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
                }
            } label: {
                HStack(spacing: 7) {
                    Text(title).font(.system(size: 13, weight: .semibold, design: .default))
                    if let subtitle {
                        Text("· \(subtitle)").font(
                            .system(size: 14, weight: .medium, design: .default)
                        ).foregroundStyle(Color.white.opacity(0.52))
                    }
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.45)).rotationEffect(
                            .degrees(isExpanded ? 0 : -90))
                }.contentShape(Rectangle()).padding(.horizontal, 0).padding(.vertical, 10)
            }
            .buttonStyle(
                LibreReverseRecapInteractiveButtonStyle(
                    cornerRadius: 14, hoverFill: 0.045, pressedFill: 0.075,
                    focusStroke: 0.60, pressedScale: 1))
            .focusable()
            .focusEffectDisabled()
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(Text(isExpanded ? "Collapse \(title)" : "Expand \(title)"))
            .accessibilityValue(
                Text("\(title), \(isExpanded ? "expanded" : "collapsed")")
            )
            if isExpanded { content }
        }.overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
        }
    }
}

private struct LibreReverseRecapActivityChart: View {
    let recap: LibreReverseDailyRecap

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    // Each notch is fifteen minutes of this actual day. Its
                    // height is measured active coverage, not activity intensity.
                    let bin: TimeInterval = 15 * 60
                    let count = max(1, Int(ceil(recap.interval.duration / bin)))
                    for index in 0..<count {
                        let start = recap.interval.start.addingTimeInterval(Double(index) * bin)
                        let end = start.addingTimeInterval(bin)
                        let active = recap.activeIntervals.reduce(0.0) { total, interval in
                            total + max(0, min(end, interval.end).timeIntervalSince(max(start, interval.start)))
                        }
                        let fraction = min(1, max(0, active / max(1, bin)))
                        let height = 3 + 8 * fraction
                        let x = min(recap.interval.duration, (Double(index) + 0.5) * bin)
                            * size.width / max(1, recap.interval.duration)
                        let rect = CGRect(x: x - 0.8, y: size.height - 19 - height / 2,
                            width: 1.6, height: height)
                        context.fill(Path(roundedRect: rect, cornerRadius: 0.8),
                            with: .color(fraction > 0 ? .blue.opacity(0.88) : .white.opacity(0.2)))
                    }
                }
                ForEach([3, 6, 9, 12, 15, 18, 21], id: \.self) { hour in
                    let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0,
                        of: recap.interval.start) ?? recap.interval.start
                    let fraction = date.timeIntervalSince(recap.interval.start) / max(1, recap.interval.duration)
                    Text(Self.hourLabel(hour)).font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .position(x: geometry.size.width * fraction, y: 10)
                }
            }
        }
    }

    private static func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 12: "12 PM"
        case 13...23: "\(hour - 12) PM"
        default: "\(hour) AM"
        }
    }
}

private struct LibreReverseRecapMeetingRow: View {
    let meeting: LibreReverseDailyRecapMeeting
    let openDetails: () -> Void
    let openTimeline: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    Image(systemName: meeting.kind == .recorded ? "waveform" : "calendar")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.7)))
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(meeting.title)
                    .font(.system(size: 14, weight: .semibold, design: .default))
                    .lineLimit(2)
                Text(Self.timeLabel(meeting))
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(Color.white.opacity(0.50))
                    .monospacedDigit()
                if let context = contextLabel {
                    Text(context)
                        .font(.system(size: 11, weight: .medium, design: .default))
                        .foregroundStyle(Color.white.opacity(0.40))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            actions
                .padding(.top, 1)
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 11)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recap.meeting.\(meeting.id)")
        .accessibilityLabel(Text(meetingAccessibilityLabel))
        .accessibilityValue(Text(meetingAccessibilityLabel))
    }

    @ViewBuilder private var actions: some View {
        if meeting.kind == .recorded {
            VStack(alignment: .trailing, spacing: 2) {
                actionButton("Details", accessibilityTitle: "Open Details", action: openDetails)
                actionButton("Timeline →", accessibilityTitle: "Open in Timeline", action: openTimeline)
            }
        } else if let meetingURL = meeting.meetingURL {
            Link(destination: meetingURL) {
                actionLabel("Join", symbol: "arrow.up.right")
            }
            .buttonStyle(LibreReverseRecapInteractiveButtonStyle.actionCapsule)
            .focusable()
            .focusEffectDisabled()
            .accessibilityLabel(Text("Join \(meeting.title)"))
            .accessibilityValue(Text("Join \(meeting.title)"))
        } else {
            Label("Scheduled", systemImage: "checkmark.circle")
                .font(.system(size: 11, weight: .semibold, design: .default))
                .foregroundStyle(Color.white.opacity(0.44))
        }
    }

    private func actionButton(_ title: String, accessibilityTitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, symbol: nil) }
            .buttonStyle(LibreReverseRecapInteractiveButtonStyle.actionCapsule)
            .focusable()
            .focusEffectDisabled()
            .accessibilityLabel(Text("\(accessibilityTitle): \(meeting.title)"))
            .accessibilityValue(Text("\(accessibilityTitle): \(meeting.title)"))
    }

    private func actionLabel(_ title: String, symbol: String?) -> some View {
        HStack(spacing: 4) {
            Text(title)
            if let symbol { Image(systemName: symbol) }
        }
        .font(.system(size: 11, weight: .semibold, design: .default))
        .foregroundStyle(Color.blue)
        .padding(.horizontal, 3)
        .padding(.vertical, 5)
    }

    private var contextLabel: String? {
        var values: [String] = []
        if let calendar = meeting.calendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !calendar.isEmpty
        {
            values.append(calendar)
        }
        if !meeting.participants.isEmpty {
            values.append(
                meeting.participants.count == 1
                    ? "1 participant"
                    : "\(meeting.participants.count) participants")
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private var meetingAccessibilityLabel: String {
        [meeting.title, Self.timeLabel(meeting), contextLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private static func timeLabel(_ meeting: LibreReverseDailyRecapMeeting) -> String {
        let sameDay = meeting.kind == .recorded && Calendar.current.isDate(meeting.startDate, inSameDayAs: meeting.endDate)
        let start = (sameDay ? timeFormatter : dayAndTimeFormatter).string(from: meeting.startDate)
        let end = timeFormatter.string(from: meeting.endDate)
        return "\(start)–\(end) · \(LibreReverseDailyRecapBuilder.durationLabel(meeting.endDate.timeIntervalSince(meeting.startDate)))"
    }

    private static let dayAndTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d · h:mm a"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}

private struct LibreReverseRecapActivityRow: View {
    let activity: LibreReverseDailyRecapActivity
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 22, height: 22)
            Text(activity.title).font(.system(size: 13, weight: .regular, design: .default))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 13, weight: .regular, design: .default))
                .foregroundStyle(Color.white.opacity(0.52)).monospacedDigit()
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recap.activity.\(activity.id)")
    }

    @ViewBuilder private var icon: some View {
        switch activity.kind {
        case .application(let bundleID):
            if let image = Self.applicationIcon(bundleID: bundleID) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                fallbackIcon(symbol: "app.fill")
            }
        case .website(let host):
            if let image = LibreReverseFaviconResolver.shared.image(for: host) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(3)
                    .background(Color.white.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                domainMonogram(host)
            }
        }
    }

    private func domainMonogram(_ host: String) -> some View {
        let hue = LibreReverseFaviconResolver.hue(for: host)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.58, brightness: 0.72),
                        Color(hue: hue, saturation: 0.72, brightness: 0.48),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Text(LibreReverseFaviconResolver.monogram(for: host))
                    .font(.system(size: 13, weight: .bold, design: .default))
                    .foregroundStyle(.white.opacity(0.92))
            )
            .accessibilityHidden(true)
    }

    private func fallbackIcon(symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.09))
            .overlay(
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(
                    Color.white.opacity(0.68)))
    }

    @MainActor private static var applicationImages: [String: NSImage] = [:]
    @MainActor private static var missingApplications: Set<String> = []
    @MainActor private static func applicationIcon(bundleID: String) -> NSImage? {
        if let image = applicationImages[bundleID] { return image }
        guard !missingApplications.contains(bundleID) else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missingApplications.insert(bundleID)
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        applicationImages[bundleID] = image
        return image
    }
}
#endif
