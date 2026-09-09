import Foundation
import XCTest

@testable import LibreReverseCore

final class MeetingDetectionTests: XCTestCase {
    func testConfirmedMeetExitOverridesAudioButLiveRoomAndTransientMissesWin() {
        let now = Date(timeIntervalSince1970: 1000)
        let observation = LibreReverseMeetingWindowObservation(
            windowID: 1, processIdentifier: 42, bundleIdentifier: "com.google.Chrome",
            title: "Meet – abc-defg-hij", url: URL(string: "https://meet.google.com/abc-defg-hij"),
            accessibilityLabels: ["Rejoin"], browserCallIsActive: false)
        let ended = LibreReverseMeetingDetector.explicitlyEndedCandidates(from: [observation])
        XCTAssertEqual(ended.count, 1)
        XCTAssertTrue(LibreReverseMeetingDetector.candidates(from: [observation]).isEmpty)
        let candidate = ended[0]
        var coordinator = LibreReverseMeetingLifecycleCoordinator(configuration: .init(
            startPolicy: .automatic, startObservationThreshold: 1))
        XCTAssertEqual(coordinator.observe([candidate], at: now), .startCapture(candidate))
        coordinator.captureDidStart(at: now)
        // A still-active copy of the room overrides a stale post-call tab.
        XCTAssertEqual(coordinator.observe([candidate], at: now,
            explicitlyEndedCandidates: ended), .none)
        XCTAssertEqual(coordinator.observe([], at: now, outputVoiceActivity: true,
            explicitlyEndedCandidates: ended), .none)
        // An uncertain read must break the sequence of positive exit evidence.
        XCTAssertEqual(coordinator.observe([], at: now, outputVoiceActivity: true), .none)
        XCTAssertEqual(coordinator.observe([], at: now.addingTimeInterval(5), outputVoiceActivity: true,
            explicitlyEndedCandidates: ended), .none)
        XCTAssertEqual(coordinator.observe([], at: now.addingTimeInterval(10), outputVoiceActivity: true,
            explicitlyEndedCandidates: ended), .stopCapture(.meetingWindowClosed))
    }

    func testMeetExitEvidenceRequiresARealRejoinButton() {
        XCTAssertEqual(MeetingProviderCatalog.callEvidence(label: "Rejoin", role: "AXButton", provider: .googleMeet), ["Rejoin"])
        for role in ["AXStaticText", "AXTextField", "AXLink"] {
            XCTAssertTrue(MeetingProviderCatalog.callEvidence(label: "Rejoin", role: role, provider: .googleMeet).isEmpty)
        }
        XCTAssertTrue(MeetingProviderCatalog.callEvidence(label: "Please Rejoin", role: "AXButton", provider: .googleMeet).isEmpty)
        XCTAssertTrue(MeetingProviderCatalog.callEvidence(label: "Rejoin", role: "AXButton", provider: .zoomWeb).isEmpty)
    }

    func testGoogleMeetLobbyDoesNotStartButMutedJoinedCallDoes() {
        func observation(active: Bool) -> LibreReverseMeetingWindowObservation {
            .init(windowID: 12, processIdentifier: 42, bundleIdentifier: "com.google.Chrome",
                title: "Meet – abc-defg-hij", url: URL(string: "https://meet.google.com/abc-defg-hij"),
                usesMicrophoneInput: false, browserCallIsActive: active)
        }
        XCTAssertNil(LibreReverseMeetingDetector.candidate(from: observation(active: false)))
        XCTAssertEqual(LibreReverseMeetingDetector.candidate(from: observation(active: true))?.provider, .googleMeet)
    }

    func testProviderPersistenceUsesLegacySpellingsAndReadsPortAliases() {
        let expected: [(LibreReverseMeetingProvider, String)] = [
            (.zoom, "zoom"),
            (.zoomWeb, "zoom"),
            (.microsoftTeams, "teams"),
            (.microsoftTeamsV2, "teams2"),
            (.microsoftTeamsWeb, "microsoftTeams"),
            (.slackHuddle, "slack"),
            (.webex, "webex"),
            (.googleMeet, "googleMeet"),
            (.manual, "manual"),
            (.calendar, "calendar"),
        ]
        for (provider, persisted) in expected {
            XCTAssertEqual(provider.legacyPersistenceValue, persisted)
            XCTAssertNotNil(LibreReverseMeetingProvider(persistedValue: persisted))
        }
        XCTAssertEqual(
            LibreReverseMeetingProvider(persistedValue: "slackHuddle"),
            .slackHuddle
        )
        XCTAssertEqual(
            LibreReverseMeetingProvider(persistedValue: "microsoftTeamsV2"),
            .microsoftTeamsV2
        )
        XCTAssertNil(LibreReverseMeetingProvider(persistedValue: "unknown-provider"))
    }

    func testMeetingContextUpdateNormalizesNamesWithoutReordering() {
        let context = LibreReverseMeetingContextUpdate(
            participantText: " Ada, Grace;Ada\n\n Lin ",
            calendarTitle: "  Product calendar  "
        )
        XCTAssertEqual(context.participants, ["Ada", "Grace", "Lin"])
        XCTAssertEqual(context.participantText, "Ada, Grace, Lin")
        XCTAssertEqual(context.calendarTitle, "Product calendar")
    }

    func testDenseMeetingHandoffDrainsSparseCaptureAndExcludesLateAdmission() async {
        let handoff = LibreReverseMeetingCaptureHandoff()
        let initialAdmission = await handoff.beginSparseCapture()
        XCTAssertTrue(initialAdmission)

        let transition = Task { await handoff.beginMeetingCapture() }
        while await !handoff.meetingOwnsCapture {
            await Task.yield()
        }
        let admissionDuringTransition = await handoff.beginSparseCapture()
        let initialInFlight = await handoff.sparseCapturesInFlight
        XCTAssertFalse(admissionDuringTransition)
        XCTAssertEqual(initialInFlight, 1)

        await handoff.finishSparseCapture()
        let meetingAcquired = await transition.value
        XCTAssertTrue(meetingAcquired)
        let drainedInFlight = await handoff.sparseCapturesInFlight
        let admissionDuringMeeting = await handoff.beginSparseCapture()
        XCTAssertEqual(drainedInFlight, 0)
        XCTAssertFalse(admissionDuringMeeting)

        await handoff.finishMeetingCapture()
        let admissionAfterMeeting = await handoff.beginSparseCapture()
        XCTAssertTrue(admissionAfterMeeting)
        await handoff.finishSparseCapture()
    }

    func testDenseMeetingHandoffCancellationReopensSparseAdmission() async {
        let handoff = LibreReverseMeetingCaptureHandoff()
        let initialSparseAdmission = await handoff.beginSparseCapture()
        XCTAssertTrue(initialSparseAdmission)
        let transition = Task { await handoff.beginMeetingCapture() }
        while await !handoff.meetingOwnsCapture {
            await Task.yield()
        }

        transition.cancel()
        let meetingAcquired = await transition.value
        let meetingOwnsCapture = await handoff.meetingOwnsCapture
        let sparseAdmissionAfterCancellation = await handoff.beginSparseCapture()
        XCTAssertFalse(meetingAcquired)
        XCTAssertFalse(meetingOwnsCapture)
        XCTAssertTrue(sparseAdmissionAfterCancellation)
        await handoff.finishSparseCapture()
        await handoff.finishSparseCapture()
    }

    func testDenseMeetingHandoffRejectsConcurrentMeetingOwner() async {
        let handoff = LibreReverseMeetingCaptureHandoff()
        let firstMeetingAdmission = await handoff.beginMeetingCapture()
        let secondMeetingAdmission = await handoff.beginMeetingCapture()
        let sparseAdmissionDuringMeeting = await handoff.beginSparseCapture()
        XCTAssertTrue(firstMeetingAdmission)
        XCTAssertFalse(secondMeetingAdmission)
        XCTAssertFalse(sparseAdmissionDuringMeeting)
        await handoff.finishMeetingCapture()
        let sparseAdmissionAfterMeeting = await handoff.beginSparseCapture()
        XCTAssertTrue(sparseAdmissionAfterMeeting)
        await handoff.finishSparseCapture()
    }

    func testCandidateTitleEditPreservesDurableIdentityAndCalendarEvidence() {
        let original = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 42,
            processIdentifier: 99,
            bundleIdentifier: "com.google.Chrome",
            title: "Google Meet",
            url: URL(string: "https://meet.google.com/abc-defg-hij"),
            calendarEventID: "event-1",
            calendarID: "calendar-1",
            calendarSeriesID: "series-1",
            calendarTitle: "Work",
            calendarParticipants: ["Ada", "Grace"]
        )
        let edited = original.updatingTitle("  Design review  ")
        XCTAssertEqual(edited.identity, original.identity)
        XCTAssertEqual(edited.title, "Design review")
        XCTAssertEqual(edited.url, original.url)
        XCTAssertEqual(edited.calendarEventID, "event-1")
        XCTAssertEqual(edited.calendarID, "calendar-1")
        XCTAssertEqual(edited.calendarSeriesID, "series-1")
        XCTAssertEqual(edited.calendarParticipants, ["Ada", "Grace"])
        XCTAssertNil(edited.updatingTitle("  \n ").title)
    }

    func testBrowserCandidateIdentityBindsReusedWindowToCanonicalMeetingRoom() {
        let firstRoom = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 42,
            processIdentifier: 99,
            bundleIdentifier: "com.google.Chrome",
            url: URL(string: "https://meet.google.com/abc-defg-hij?authuser=0")
        )
        let sameRoom = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 42,
            processIdentifier: 99,
            bundleIdentifier: "com.google.Chrome",
            url: URL(string: "https://meet.google.com/abc-defg-hij?authuser=1")
        )
        let differentRoom = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 42,
            processIdentifier: 99,
            bundleIdentifier: "com.google.Chrome",
            url: URL(string: "https://meet.google.com/xyz-wxyz-xyz")
        )

        XCTAssertEqual(firstRoom.identity, sameRoom.identity)
        XCTAssertNotEqual(firstRoom.identity, differentRoom.identity)
    }

    func testCandidateIdentityBindsWindowServerIDToOwningProcess() {
        let original = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 42,
            processIdentifier: 99,
            bundleIdentifier: "us.zoom.xos"
        )
        let recycledWindowID = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 42,
            processIdentifier: 100,
            bundleIdentifier: "us.zoom.xos"
        )
        let legacyJournalCandidate = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 42,
            bundleIdentifier: "us.zoom.xos"
        )

        XCTAssertNotEqual(original.identity, recycledWindowID.identity)
        XCTAssertNotEqual(original.identity, legacyJournalCandidate.identity)
    }

    func testCandidateArbitrationIsOrderIndependentForDuplicateCallSurfaces() {
        let zoomPrimary = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 40,
            processIdentifier: 900,
            bundleIdentifier: "us.zoom.xos"
        )
        let zoomShare = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 41,
            processIdentifier: 900,
            bundleIdentifier: "us.zoom.xos"
        )
        XCTAssertEqual(
            LibreReverseMeetingCandidateArbitration.selectUnambiguous([
                zoomShare, zoomPrimary,
            ]),
            zoomPrimary
        )
        XCTAssertEqual(
            LibreReverseMeetingCandidateArbitration.selectUnambiguous([
                zoomPrimary, zoomShare,
            ]),
            zoomPrimary
        )

        let meetChrome = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 60,
            processIdentifier: 901,
            bundleIdentifier: "com.google.Chrome",
            url: URL(string: "https://meet.google.com/abc-defg-hij?authuser=0")
        )
        let meetArc = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 50,
            processIdentifier: 902,
            bundleIdentifier: "company.thebrowser.Browser",
            url: URL(string: "https://meet.google.com/abc-defg-hij?authuser=1")
        )
        XCTAssertEqual(
            LibreReverseMeetingCandidateArbitration.selectUnambiguous([
                meetChrome, meetArc,
            ]),
            meetArc
        )
    }

    func testCandidateArbitrationFailsClosedForDifferentRoomsProvidersAndProcesses() {
        let firstRoom = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 1,
            processIdentifier: 10,
            bundleIdentifier: "com.google.Chrome",
            url: URL(string: "https://meet.google.com/abc-defg-hij")
        )
        let secondRoom = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 2,
            processIdentifier: 10,
            bundleIdentifier: "com.google.Chrome",
            url: URL(string: "https://meet.google.com/xyz-abcd-efg")
        )
        let zoom = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 3,
            processIdentifier: 11,
            bundleIdentifier: "us.zoom.xos"
        )
        let restartedZoom = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 4,
            processIdentifier: 12,
            bundleIdentifier: "us.zoom.xos"
        )

        XCTAssertNil(
            LibreReverseMeetingCandidateArbitration.selectUnambiguous([
                firstRoom, secondRoom,
            ])
        )
        XCTAssertNil(
            LibreReverseMeetingCandidateArbitration.selectUnambiguous([firstRoom, zoom])
        )
        XCTAssertNil(
            LibreReverseMeetingCandidateArbitration.selectUnambiguous([
                zoom, restartedZoom,
            ])
        )
    }

    func testLifecycleWaitsOutAmbiguityAndPreservesAnEstablishedLogicalMeeting() {
        let zoomPrimary = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 20,
            processIdentifier: 200,
            bundleIdentifier: "us.zoom.xos"
        )
        let zoomShare = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 21,
            processIdentifier: 200,
            bundleIdentifier: "us.zoom.xos"
        )
        let unrelated = LibreReverseMeetingCandidate(
            provider: .slackHuddle,
            source: .windowDetection,
            windowID: 30,
            processIdentifier: 300,
            bundleIdentifier: "com.tinyspeck.slackmacgap"
        )
        var lifecycle = LibreReverseMeetingLifecycleCoordinator(
            configuration: .init(
                startPolicy: .automatic,
                startObservationThreshold: 2
            )
        )

        XCTAssertEqual(lifecycle.observe([unrelated, zoomPrimary]), .none)
        XCTAssertEqual(lifecycle.state, .idle)
        XCTAssertEqual(lifecycle.observe([zoomShare, zoomPrimary]), .none)
        XCTAssertEqual(lifecycle.observe([zoomPrimary, zoomShare]), .startCapture(zoomPrimary))
        let startedAt = Date(timeIntervalSince1970: 100)
        lifecycle.captureDidStart(at: startedAt)
        XCTAssertEqual(lifecycle.observe([unrelated, zoomShare]), .none)
        XCTAssertEqual(lifecycle.state, .recording(zoomPrimary, startedAt: startedAt))
    }

    func testIgnoreTrackerSuppressesEverySurfaceOfTheSameLogicalMeeting() {
        let ignored = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 70,
            processIdentifier: 700,
            bundleIdentifier: "us.zoom.xos"
        )
        let sibling = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 71,
            processIdentifier: 700,
            bundleIdentifier: "us.zoom.xos"
        )
        let otherProcess = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 72,
            processIdentifier: 701,
            bundleIdentifier: "us.zoom.xos"
        )
        var tracker = LibreReverseMeetingIgnoreTracker()
        tracker.ignore(ignored)
        let remaining = tracker.candidatesExcludingIgnoredMeeting(
            [sibling, otherProcess],
            at: Date(timeIntervalSince1970: 1),
            configuration: .init()
        )
        XCTAssertEqual(remaining, [otherProcess])
    }

    func testMeetingRecordingPresentationDisclosesTitleAudioRouteAndElapsedTime() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let candidate = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            title: "  Weekly review  "
        )
        let presentation = LibreReverseMeetingRecordingPresentation(
            candidate: candidate,
            selection: .init(
                capturesSystemAudio: true,
                capturesMicrophone: true,
                microphoneDeviceID: "mic-1"
            ),
            microphoneName: "Studio Display Microphone",
            startedAt: startedAt
        )
        XCTAssertEqual(presentation.title, "Weekly review")
        XCTAssertEqual(
            presentation.audioDescription,
            "System audio + microphone · Studio Display Microphone"
        )
        XCTAssertEqual(
            presentation.elapsedDescription(at: startedAt.addingTimeInterval(65)),
            "1:05"
        )
        XCTAssertEqual(
            presentation.elapsedDescription(at: startedAt.addingTimeInterval(3_661)),
            "1:01:01"
        )
    }

    func testMeetingRecordingPresentationMakesEveryAudioModeExplicit() {
        let candidate = LibreReverseMeetingCandidate(
            provider: .manual,
            source: .manual,
            title: "   "
        )
        let modes: [(Bool, Bool, String)] = [
            (true, false, "System audio only"),
            (false, true, "Microphone only"),
            (false, false, "Video only"),
        ]
        for (system, microphone, expected) in modes {
            let presentation = LibreReverseMeetingRecordingPresentation(
                candidate: candidate,
                selection: .init(
                    capturesSystemAudio: system,
                    capturesMicrophone: microphone,
                    microphoneDeviceID: nil
                ),
                startedAt: .distantPast
            )
            XCTAssertEqual(presentation.title, "Ad hoc meeting")
            XCTAssertEqual(presentation.audioDescription, expected)
        }
    }

    func testRecoveredBrowserMeetingURLsAndYouTubeBoundary() {
        let cases: [(String, LibreReverseMeetingProvider?)] = [
            ("https://meet.google.com/abc-defg-hij", .googleMeet),
            ("https://meet.google.com/", nil),
            ("https://teams.microsoft.com/l/meetup-join/19%3ameeting", .microsoftTeamsWeb),
            ("https://teams.microsoft.com/v2/", nil),
            ("https://teams.live.com/_#/modern-calling/", .microsoftTeamsWeb),
            ("https://app.slack.com/huddle/T123/C456", .slackHuddle),
            ("https://app.slack.com/client/T123/C456", nil),
            ("https://acme.zoom.us/j/123456789", .zoomWeb),
            ("https://zoom.us/", nil),
            ("https://www.youtube.com/watch?v=meeting-demo", nil),
            ("https://youtu.be/example", nil),
        ]
        for (rawURL, expected) in cases {
            XCTAssertEqual(
                LibreReverseMeetingDetector.browserProvider(for: URL(string: rawURL)!),
                expected,
                rawURL
            )
        }
    }

    func testBrowserTitleCannotTurnOrdinaryVideoIntoMeeting() {
        let observation = LibreReverseMeetingWindowObservation(
            windowID: 1,
            processIdentifier: 10,
            bundleIdentifier: "com.google.Chrome",
            title: "Weekly meeting recording - YouTube",
            url: URL(string: "https://www.youtube.com/watch?v=abc")
        )
        XCTAssertNil(LibreReverseMeetingDetector.candidate(from: observation))
    }

    func testBrowserPopOutRequiresExactMeetTitleAndSameProcessMicrophoneInput() {
        XCTAssertEqual(
            LibreReverseMeetingDetector.browserPopOutBundleIdentifiers,
            [
                "com.google.Chrome",
                "com.google.Chrome.dev",
                "com.google.Chrome.beta",
                "company.thebrowser.Browser",
            ]
        )
        for title in [
            "abc-defg-hij",
            "Meet - abc-defg-hij",
            "Google Meet | abc-defg-hij",
            "abc-defg-hij — Google Meet",
        ] {
            let observation = LibreReverseMeetingWindowObservation(
                windowID: 2,
                processIdentifier: 20,
                bundleIdentifier: "com.google.Chrome",
                title: title,
                usesMicrophoneInput: true
            )
            XCTAssertEqual(
                LibreReverseMeetingDetector.candidate(from: observation)?.provider,
                .googleMeet,
                title
            )
            XCTAssertEqual(
                LibreReverseMeetingDetector.candidate(from: observation)?.url?.absoluteString,
                "https://meet.google.com/abc-defg-hij",
                title
            )
        }

        for title in [
            "abc-defg-hij notes",
            "Planning abc-defg-hij",
            "Meetings - abc-defg-hij",
            "abc-def-hij",
        ] {
            let observation = LibreReverseMeetingWindowObservation(
                windowID: 3,
                processIdentifier: 30,
                bundleIdentifier: "company.thebrowser.Browser",
                title: title,
                usesMicrophoneInput: true
            )
            XCTAssertNil(LibreReverseMeetingDetector.candidate(from: observation), title)
        }

        let noMicrophone = LibreReverseMeetingWindowObservation(
            windowID: 4,
            processIdentifier: 40,
            bundleIdentifier: "company.thebrowser.Browser",
            title: "abc-defg-hij"
        )
        XCTAssertNil(LibreReverseMeetingDetector.candidate(from: noMicrophone))

        let unsupportedBrowser = LibreReverseMeetingWindowObservation(
            windowID: 5,
            processIdentifier: 50,
            bundleIdentifier: "com.apple.Safari",
            title: "abc-defg-hij",
            usesMicrophoneInput: true
        )
        XCTAssertNil(LibreReverseMeetingDetector.candidate(from: unsupportedBrowser))
    }

    func testBrowserPopOutIdentityBindsWindowToExactMeetCode() {
        func candidate(_ code: String) -> LibreReverseMeetingCandidate {
            LibreReverseMeetingDetector.candidate(
                from: LibreReverseMeetingWindowObservation(
                    windowID: 6,
                    processIdentifier: 60,
                    bundleIdentifier: "com.google.Chrome",
                    title: code,
                    usesMicrophoneInput: true
                ))!
        }

        let first = candidate("abc-defg-hij")
        let same = candidate("Meet - ABC-DEFG-HIJ")
        let next = candidate("xyz-abcd-efg")
        XCTAssertEqual(first.identity, same.identity)
        XCTAssertNotEqual(first.identity, next.identity)

        let continuation = LibreReverseRecoveredMeetingContinuation(
            candidate: first,
            captureFinishedAt: Date(timeIntervalSince1970: 100),
            recoveredAt: Date(timeIntervalSince1970: 101)
        )!
        XCTAssertEqual(
            continuation.decision(
                liveCandidates: [next],
                at: Date(timeIntervalSince1970: 102)
            ),
            .waiting
        )
        XCTAssertEqual(
            continuation.decision(
                liveCandidates: [same],
                at: Date(timeIntervalSince1970: 102)
            ),
            .resume(first)
        )
    }

    func testKnownNonMeetingBrowserURLOverridesPopOutTitleAndMicrophoneEvidence() {
        let observation = LibreReverseMeetingWindowObservation(
            windowID: 5,
            processIdentifier: 50,
            bundleIdentifier: "com.google.Chrome",
            title: "abc-defg-hij",
            url: URL(string: "https://www.youtube.com/watch?v=abc"),
            usesMicrophoneInput: true
        )
        XCTAssertNil(LibreReverseMeetingDetector.candidate(from: observation))
    }

    func testSlackBrowserAndNativeCandidatesUseTheirSurfaceSpecificGraceClass() {
        let browserObservation = LibreReverseMeetingWindowObservation(
            windowID: 1,
            processIdentifier: 10,
            bundleIdentifier: "com.apple.Safari",
            title: "Huddle",
            url: URL(string: "https://app.slack.com/huddle/T123/C456")
        )
        let browserCandidate = LibreReverseMeetingDetector.candidate(
            from: browserObservation
        )
        let nativeCandidate = LibreReverseMeetingDetector.candidate(
            from: observation(
                bundle: "com.tinyspeck.slackmacgap",
                title: "Huddle"
            ))

        XCTAssertEqual(browserCandidate?.provider, .slackHuddle)
        XCTAssertTrue(browserCandidate?.isBrowserMeeting == true)
        XCTAssertEqual(nativeCandidate?.provider, .slackHuddle)
        XCTAssertFalse(nativeCandidate?.isBrowserMeeting == true)
    }

    func testLiveProbeEvidenceRedactsMeetingContentAndKeepsDecisionSignals() throws {
        let secretTitle = "Project Nightingale acquisition review"
        let secretCode = "abc-defg-hij"
        let meeting = LibreReverseMeetingWindowObservation(
            windowID: 41,
            processIdentifier: 900,
            bundleIdentifier: "com.google.Chrome",
            title: secretTitle,
            url: URL(string: "https://meet.google.com/\(secretCode)?authuser=private")!,
            accessibilityLabels: ["untrusted private label"],
            usesMicrophoneInput: true
        )
        let youtube = LibreReverseMeetingWindowObservation(
            windowID: 42,
            processIdentifier: 901,
            bundleIdentifier: "com.apple.Safari",
            title: "Private video title",
            url: URL(string: "https://www.youtube.com/watch?v=private")
        )
        let unrelated = LibreReverseMeetingWindowObservation(
            windowID: 43,
            processIdentifier: 902,
            bundleIdentifier: "com.example.secret-app",
            title: "Confidential document"
        )
        let observations = [meeting, youtube, unrelated]
        let record = LibreReverseMeetingDetectionProbeRecord(
            recordedAt: Date(timeIntervalSince1970: 100),
            pollIndex: 7,
            observations: observations,
            candidates: LibreReverseMeetingDetector.candidates(from: observations)
        )

        XCTAssertEqual(record.observations.count, 2)
        XCTAssertEqual(record.observations.map(\.urlKind), [.googleMeet, .youtube])
        XCTAssertEqual(record.candidates.map(\.provider), [.googleMeet])
        XCTAssertFalse(record.candidates[0].usedURLlessMicrophoneFallback)
        XCTAssertEqual(record.admissionCandidate?.provider, .googleMeet)
        XCTAssertEqual(record.candidates[0].logicalMeetingToken.count, 64)
        XCTAssertEqual(
            record.admissionCandidate?.logicalMeetingToken,
            record.candidates[0].logicalMeetingToken
        )
        XCTAssertFalse(record.candidateSetAmbiguous)
        XCTAssertEqual(record.observations[0].accessibilityMarkers, [])
        XCTAssertTrue(record.observations[0].usesMicrophoneInput)

        let encoded = try JSONEncoder().encode(record)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains(secretTitle))
        XCTAssertFalse(json.contains(secretCode))
        XCTAssertFalse(json.contains("authuser"))
        XCTAssertFalse(json.contains("untrusted private label"))
        XCTAssertFalse(json.contains("com.example.secret-app"))
        XCTAssertTrue(json.contains("googleMeet"))
        XCTAssertTrue(json.contains("youtube"))
    }

    func testLiveProbeBindsPopOutFallbackEvidenceToTheCandidateWindow() {
        let popOut = LibreReverseMeetingWindowObservation(
            windowID: 51,
            processIdentifier: 951,
            bundleIdentifier: "com.google.Chrome",
            title: "abc-defg-hij",
            usesMicrophoneInput: true
        )
        let popOutRecord = LibreReverseMeetingDetectionProbeRecord(
            recordedAt: .distantPast,
            pollIndex: 0,
            observations: [popOut],
            candidates: LibreReverseMeetingDetector.candidates(from: [popOut])
        )
        XCTAssertEqual(popOutRecord.candidates.count, 1)
        XCTAssertTrue(popOutRecord.candidates[0].usedURLlessMicrophoneFallback)
        XCTAssertTrue(popOutRecord.admissionCandidate?.usedURLlessMicrophoneFallback == true)

        let urlMeeting = LibreReverseMeetingWindowObservation(
            windowID: 52,
            processIdentifier: 952,
            bundleIdentifier: "com.google.Chrome",
            title: "Private URL meeting",
            url: URL(string: "https://meet.google.com/xyz-abcd-efg")
        )
        let unrelatedMicrophone = LibreReverseMeetingWindowObservation(
            windowID: 53,
            processIdentifier: 953,
            bundleIdentifier: "company.thebrowser.Browser",
            title: "Private ordinary page",
            usesMicrophoneInput: true
        )
        let mixed = [urlMeeting, unrelatedMicrophone]
        let mixedRecord = LibreReverseMeetingDetectionProbeRecord(
            recordedAt: .distantPast,
            pollIndex: 1,
            observations: mixed,
            candidates: LibreReverseMeetingDetector.candidates(from: mixed)
        )
        XCTAssertEqual(mixedRecord.candidates.count, 1)
        XCTAssertFalse(mixedRecord.candidates[0].usedURLlessMicrophoneFallback)
        XCTAssertFalse(
            mixedRecord.admissionCandidate?.usedURLlessMicrophoneFallback == true
        )
    }

    func testLiveProbeReportsArbitratedAdmissionAndGenuineAmbiguity() {
        let zoomPrimary = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 80,
            processIdentifier: 800,
            bundleIdentifier: "us.zoom.xos"
        )
        let zoomShare = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 81,
            processIdentifier: 800,
            bundleIdentifier: "us.zoom.xos"
        )
        let duplicateRecord = LibreReverseMeetingDetectionProbeRecord(
            recordedAt: .distantPast,
            pollIndex: 2,
            observations: [],
            candidates: [zoomShare, zoomPrimary]
        )
        XCTAssertEqual(duplicateRecord.candidates.count, 2)
        XCTAssertEqual(duplicateRecord.admissionCandidate?.windowID, 80)
        XCTAssertEqual(
            Set(duplicateRecord.candidates.map(\.logicalMeetingToken)).count,
            1
        )
        XCTAssertFalse(duplicateRecord.candidateSetAmbiguous)

        let slack = LibreReverseMeetingCandidate(
            provider: .slackHuddle,
            source: .windowDetection,
            windowID: 90,
            processIdentifier: 900,
            bundleIdentifier: "com.tinyspeck.slackmacgap"
        )
        let ambiguousRecord = LibreReverseMeetingDetectionProbeRecord(
            recordedAt: .distantPast,
            pollIndex: 3,
            observations: [],
            candidates: [zoomPrimary, slack]
        )
        XCTAssertEqual(ambiguousRecord.candidates.count, 2)
        XCTAssertNil(ambiguousRecord.admissionCandidate)
        XCTAssertTrue(ambiguousRecord.candidateSetAmbiguous)
        XCTAssertEqual(
            Set(ambiguousRecord.candidates.map(\.logicalMeetingToken)).count,
            2
        )
    }

    func testLiveProbeOpaqueIdentityTracksLogicalMeetingOnlyWithinOneRun() {
        let secret = Data(repeating: 0x5A, count: 32)
        let otherSecret = Data(repeating: 0xA5, count: 32)
        let firstSurface = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 101,
            processIdentifier: 1_001,
            bundleIdentifier: "com.google.Chrome",
            url: URL(string: "https://meet.google.com/abc-defg-hij")
        )
        let siblingSurface = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 102,
            processIdentifier: 1_001,
            bundleIdentifier: "company.thebrowser.Browser",
            url: URL(string: "https://meet.google.com/abc-defg-hij?authuser=1")
        )
        let nextRoom = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 101,
            processIdentifier: 1_001,
            bundleIdentifier: "com.google.Chrome",
            url: URL(string: "https://meet.google.com/xyz-abcd-efg")
        )

        func token(
            _ candidate: LibreReverseMeetingCandidate,
            secret: Data
        ) -> String {
            LibreReverseMeetingDetectionProbeRecord(
                recordedAt: .distantPast,
                pollIndex: 0,
                observations: [],
                candidates: [candidate],
                identitySecret: secret
            ).admissionCandidate!.logicalMeetingToken
        }

        let firstToken = token(firstSurface, secret: secret)
        XCTAssertEqual(firstToken, token(siblingSurface, secret: secret))
        XCTAssertNotEqual(firstToken, token(nextRoom, secret: secret))
        XCTAssertNotEqual(firstToken, token(firstSurface, secret: otherSecret))
        XCTAssertEqual(firstToken.count, 64)
        XCTAssertTrue(firstToken.allSatisfy(\.isHexDigit))
    }

    func testLiveProbeDryRunReplaysProductionLifecycleWithPureAcknowledgements() {
        let secret = Data(repeating: 0x33, count: 32)
        let zoom = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 201,
            processIdentifier: 2_001,
            bundleIdentifier: "us.zoom.xos"
        )
        var ask = LibreReverseMeetingLifecycleCoordinator(
            configuration: .init(startPolicy: .ask)
        )

        let firstCommand = ask.observe([zoom], at: Date(timeIntervalSince1970: 1))
        let first = LibreReverseMeetingDetectionProbeRecord(
            recordedAt: Date(timeIntervalSince1970: 1),
            pollIndex: 0,
            observations: [],
            candidates: [zoom],
            identitySecret: secret,
            dryRunLifecycleState: ask.state,
            dryRunLifecycleCommand: firstCommand
        )
        XCTAssertEqual(first.dryRunLifecycleState, .candidate)
        XCTAssertEqual(first.dryRunLifecycleCommand, .none)
        XCTAssertEqual(
            first.dryRunLifecycleMeetingToken,
            first.admissionCandidate?.logicalMeetingToken
        )

        let promptCommand = ask.observe([zoom], at: Date(timeIntervalSince1970: 2))
        let prompt = LibreReverseMeetingDetectionProbeRecord(
            recordedAt: Date(timeIntervalSince1970: 2),
            pollIndex: 1,
            observations: [],
            candidates: [zoom],
            identitySecret: secret,
            dryRunLifecycleState: ask.state,
            dryRunLifecycleCommand: promptCommand
        )
        XCTAssertEqual(prompt.dryRunLifecycleState, .prompt)
        XCTAssertEqual(prompt.dryRunLifecycleCommand, .presentPrompt)
        XCTAssertEqual(
            prompt.dryRunLifecycleMeetingToken,
            first.dryRunLifecycleMeetingToken
        )

        _ = ask.observe([], at: Date(timeIntervalSince1970: 3))
        let dismissCommand = ask.observe([], at: Date(timeIntervalSince1970: 4))
        let dismissed = LibreReverseMeetingDetectionProbeRecord(
            recordedAt: Date(timeIntervalSince1970: 4),
            pollIndex: 3,
            observations: [],
            candidates: [],
            identitySecret: secret,
            dryRunLifecycleState: ask.state,
            dryRunLifecycleCommand: dismissCommand
        )
        XCTAssertEqual(dismissed.dryRunLifecycleState, .idle)
        XCTAssertEqual(dismissed.dryRunLifecycleCommand, .dismissPrompt)
        XCTAssertNil(dismissed.dryRunLifecycleMeetingToken)

        var automatic = LibreReverseMeetingProbeLifecycleSimulator(
            configuration: .init(
                startPolicy: .automatic,
                endObservationThreshold: 2,
                nativeEndGrace: 2
            ),
            simulatesCaptureAcknowledgements: true
        )
        _ = automatic.step(
            candidates: [zoom],
            at: Date(timeIntervalSince1970: 5)
        )
        let startStep = automatic.step(
            candidates: [zoom],
            at: Date(timeIntervalSince1970: 6)
        )
        let starting = LibreReverseMeetingDetectionProbeRecord(
            recordedAt: Date(timeIntervalSince1970: 6),
            pollIndex: 1,
            observations: [],
            candidates: [zoom],
            identitySecret: secret,
            dryRunLifecycleState: startStep.state,
            dryRunLifecycleCommand: startStep.command
        )
        XCTAssertEqual(starting.dryRunLifecycleState, .starting)
        XCTAssertEqual(starting.dryRunLifecycleCommand, .startCapture)
        XCTAssertNotEqual(starting.dryRunLifecycleState, .recording)

        let recording = automatic.step(
            candidates: [zoom],
            at: Date(timeIntervalSince1970: 7)
        )
        XCTAssertEqual(recording.state, .recording(zoom, startedAt: Date(timeIntervalSince1970: 6)))
        XCTAssertEqual(recording.command, .none)

        let ending = automatic.step(
            candidates: [],
            at: Date(timeIntervalSince1970: 8)
        )
        guard case .ending = ending.state else {
            return XCTFail("expected simulated recording to enter ending grace")
        }
        let stopping = automatic.step(
            candidates: [],
            at: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(stopping.command, .stopCapture(.meetingWindowClosed))
        guard case .stopping = stopping.state else {
            return XCTFail("expected simulated capture stop boundary")
        }

        // The simulator acknowledged and reset only its private reducer; the
        // next observation starts a fresh stabilization cycle.
        let restarted = automatic.step(
            candidates: [zoom],
            at: Date(timeIntervalSince1970: 11)
        )
        XCTAssertEqual(restarted.state, .candidate(zoom, observations: 1))
        XCTAssertEqual(restarted.command, .none)
    }

    func testLiveProbeKeepsOnlyCanonicalAccessibilityMarkers() {
        let observation = LibreReverseMeetingWindowObservation(
            windowID: 9,
            processIdentifier: 99,
            bundleIdentifier: "us.zoom.xos",
            title: "Private meeting title",
            accessibilityLabels: ["Leave Meeting", "Participant Alice Example"]
        )
        let record = LibreReverseMeetingDetectionProbeRecord(
            recordedAt: .distantPast,
            pollIndex: 0,
            observations: [observation],
            candidates: LibreReverseMeetingDetector.candidates(from: [observation])
        )

        XCTAssertEqual(record.observations.first?.accessibilityMarkers, ["Leave Meeting"])
        XCTAssertEqual(record.candidates.first?.provider, .zoom)
    }

    func testNativeProvidersRequireRecoveredMeetingEvidence() {
        XCTAssertEqual(
            LibreReverseMeetingDetector.candidate(
                from: observation(
                    bundle: "us.zoom.xos", title: "Zoom Meeting"
                ))?.provider,
            .zoom
        )
        XCTAssertNil(
            LibreReverseMeetingDetector.candidate(
                from: observation(
                    bundle: "us.zoom.xos", title: "Zoom Workplace"
                )))
        XCTAssertNil(
            LibreReverseMeetingDetector.candidate(
                from: observation(
                    bundle: "us.zoom.xos",
                    title: "Zoom Workplace",
                    labels: ["Meeting controls"]
                )))
        XCTAssertNil(
            LibreReverseMeetingDetector.candidate(
                from: observation(
                    bundle: "us.zoom.xos", title: "Meeting notes"
                )))
        XCTAssertEqual(
            LibreReverseMeetingDetector.candidate(
                from: observation(
                    bundle: "us.zoom.xos",
                    title: "Quarterly review",
                    labels: ["Leave Meeting"]
                ))?.provider,
            .zoom
        )
        XCTAssertEqual(
            LibreReverseMeetingDetector.candidate(
                from: observation(
                    bundle: "us.zoom.xos",
                    title: "Quarterly review",
                    labels: ["You are screen sharing"]
                ))?.provider,
            .zoom
        )
        XCTAssertEqual(
            LibreReverseMeetingDetector.candidate(
                from: observation(
                    bundle: "com.tinyspeck.slackmacgap", title: "Huddle"
                ))?.provider,
            .slackHuddle
        )
        XCTAssertEqual(
            LibreReverseMeetingDetector.candidate(
                from: observation(
                    bundle: "com.tinyspeck.slackmacgap",
                    title: "general | Slack",
                    labels: ["Leave Huddle"]
                ))?.provider,
            .slackHuddle
        )
        XCTAssertNil(
            LibreReverseMeetingDetector.candidate(
                from: observation(
                    bundle: "com.tinyspeck.slackmacgap", title: "general | Slack"
                )))
        XCTAssertNil(
            LibreReverseMeetingDetector.candidate(
                from: observation(
                    bundle: "com.tinyspeck.slackmacgap",
                    title: "Huddle notes | Slack",
                    labels: ["Huddles"]
                )))
        XCTAssertEqual(
            LibreReverseMeetingDetector.candidate(
                from: observation(
                    bundle: "com.webex.meetingmanager", title: "Design review"
                ))?.provider,
            .webex
        )
    }

    func testZoomMenuBarScanIsNarrowAndUsesOnlyLiveCallMarkers() {
        XCTAssertEqual(
            LibreReverseMeetingDetector.menuBarScanBundleIdentifiers,
            ["us.zoom.xos"]
        )
        XCTAssertTrue(
            LibreReverseMeetingDetector.zoomActiveCallMarkers.contains("Leave Meeting")
        )
        XCTAssertTrue(
            LibreReverseMeetingDetector.zoomActiveCallMarkers.contains("Stop Share")
        )
        XCTAssertFalse(
            LibreReverseMeetingDetector.zoomActiveCallMarkers.contains("Start Meeting")
        )
        XCTAssertFalse(
            LibreReverseMeetingDetector.canonicalAccessibilityMarkers.contains(
                "Meeting controls"
            )
        )
    }

    func testTeamsMainWindowsAreExcludedAndCallMarkerIsRequired() {
        XCTAssertNil(
            LibreReverseMeetingDetector.candidate(
                from: observation(
                    bundle: "com.microsoft.teams2",
                    title: "Calendar | Microsoft Teams"
                )))
        XCTAssertNil(
            LibreReverseMeetingDetector.candidate(
                from: observation(
                    bundle: "com.microsoft.teams2",
                    title: "Design review"
                )))
        XCTAssertEqual(
            LibreReverseMeetingDetector.candidate(
                from: observation(
                    bundle: "com.microsoft.teams2",
                    title: "Design review",
                    labels: ["Microsoft Teams Call in progress"]
                ))?.provider,
            .microsoftTeamsV2
        )
    }

    func testAskLifecycleDebouncesAndDoesNotPublishBeforeCaptureFinishes() {
        let candidate = LibreReverseMeetingDetector.candidate(
            from: observation(
                bundle: "us.zoom.xos", title: "Zoom Meeting"
            ))!
        var coordinator = LibreReverseMeetingLifecycleCoordinator(
            configuration: .init(
                startPolicy: .ask,
                endPolicy: .detected,
                startObservationThreshold: 2,
                endObservationThreshold: 2,
                nativeEndGrace: 0,
                browserEndGrace: 0
            ))
        XCTAssertEqual(coordinator.observe([candidate]), .none)
        XCTAssertEqual(coordinator.observe([candidate]), .presentPrompt(candidate))
        XCTAssertEqual(coordinator.acceptPrompt(), .startCapture(candidate))
        let start = Date(timeIntervalSince1970: 100)
        coordinator.captureDidStart(at: start)
        XCTAssertEqual(coordinator.state, .recording(candidate, startedAt: start))
        XCTAssertEqual(coordinator.observe([]), .none)
        XCTAssertEqual(coordinator.observe([]), .stopCapture(.meetingWindowClosed))
        coordinator.captureDidFinish(segmentID: 42)
        XCTAssertEqual(coordinator.state, .completed(candidate, segmentID: 42))
    }

    func testAskPromptSurvivesOneTransientMissAndDismissesAfterConfirmedLoss() {
        let candidate = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 44
        )
        var lifecycle = LibreReverseMeetingLifecycleCoordinator(
            configuration: .init(
                startPolicy: .ask,
                startObservationThreshold: 1,
                promptDismissObservationThreshold: 2
            ))

        XCTAssertEqual(lifecycle.observe([candidate]), .presentPrompt(candidate))
        XCTAssertEqual(lifecycle.observe([]), .none)
        XCTAssertEqual(lifecycle.state, .prompt(candidate))
        XCTAssertEqual(lifecycle.observe([candidate]), .none)
        XCTAssertEqual(lifecycle.observe([]), .none)
        XCTAssertEqual(lifecycle.observe([]), .dismissPrompt)
        XCTAssertEqual(lifecycle.state, .idle)
    }

    func testIgnoredBrowserMeetingSurvivesTabSwitchAndAllowsDifferentRoomImmediately() {
        let start = Date(timeIntervalSince1970: 1_000)
        let ignored = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 44,
            processIdentifier: 9,
            bundleIdentifier: "com.google.Chrome",
            url: URL(string: "https://meet.google.com/abc-defg-hij?authuser=0")
        )
        let differentRoom = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 44,
            processIdentifier: 9,
            bundleIdentifier: "com.google.Chrome",
            url: URL(string: "https://meet.google.com/xyz-wxyz-xyz")
        )
        let configuration = LibreReverseMeetingLifecycleConfiguration(
            endObservationThreshold: 2,
            nativeEndGrace: 30,
            browserEndGrace: 300
        )
        var tracker = LibreReverseMeetingIgnoreTracker()
        tracker.ignore(ignored)

        XCTAssertEqual(
            tracker.candidatesExcludingIgnoredMeeting(
                [ignored, differentRoom],
                at: start,
                configuration: configuration
            ),
            [differentRoom]
        )
        XCTAssertEqual(
            tracker.candidatesExcludingIgnoredMeeting(
                [differentRoom],
                at: start.addingTimeInterval(1),
                configuration: configuration
            ),
            [differentRoom]
        )
        XCTAssertEqual(
            tracker.candidatesExcludingIgnoredMeeting(
                [ignored, differentRoom],
                at: start.addingTimeInterval(200),
                configuration: configuration
            ),
            [differentRoom]
        )
        XCTAssertEqual(tracker.ignoredCandidate, ignored)

        _ = tracker.candidatesExcludingIgnoredMeeting(
            [differentRoom],
            at: start.addingTimeInterval(201),
            configuration: configuration
        )
        _ = tracker.candidatesExcludingIgnoredMeeting(
            [differentRoom],
            at: start.addingTimeInterval(501),
            configuration: configuration
        )
        XCTAssertNil(tracker.ignoredCandidate)
        XCTAssertEqual(
            tracker.candidatesExcludingIgnoredMeeting(
                [ignored],
                at: start.addingTimeInterval(502),
                configuration: configuration
            ),
            [ignored]
        )
    }

    func testIgnoredNativeMeetingRequiresConfirmedGraceBeforePromptingAgain() {
        let start = Date(timeIntervalSince1970: 2_000)
        let ignored = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 44,
            processIdentifier: 9,
            bundleIdentifier: "us.zoom.xos"
        )
        let configuration = LibreReverseMeetingLifecycleConfiguration(
            endObservationThreshold: 2,
            nativeEndGrace: 30,
            browserEndGrace: 300
        )
        var tracker = LibreReverseMeetingIgnoreTracker()
        tracker.ignore(ignored)

        _ = tracker.candidatesExcludingIgnoredMeeting(
            [],
            at: start,
            configuration: configuration
        )
        _ = tracker.candidatesExcludingIgnoredMeeting(
            [],
            at: start.addingTimeInterval(29),
            configuration: configuration
        )
        XCTAssertEqual(tracker.ignoredCandidate, ignored)
        _ = tracker.candidatesExcludingIgnoredMeeting(
            [],
            at: start.addingTimeInterval(30),
            configuration: configuration
        )
        XCTAssertNil(tracker.ignoredCandidate)
    }

    func testUserStopDuringDeviceRestartCannotAutoReopenTheSameMeeting() throws {
        let stopped = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 44,
            processIdentifier: 9,
            bundleIdentifier: "com.google.Chrome",
            url: URL(string: "https://meet.google.com/abc-defg-hij")
        )
        let differentRoom = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 44,
            processIdentifier: 9,
            bundleIdentifier: "com.google.Chrome",
            url: URL(string: "https://meet.google.com/xyz-wxyz-xyz")
        )
        let configuration = LibreReverseMeetingLifecycleConfiguration(
            startPolicy: .automatic,
            startObservationThreshold: 1
        )
        var restart = LibreReverseMeetingRestartIntentTracker()
        restart.schedule(stopped)
        var ignored = LibreReverseMeetingIgnoreTracker()
        ignored.ignore(try XCTUnwrap(restart.cancelForUserStop()))
        var lifecycle = LibreReverseMeetingLifecycleCoordinator(configuration: configuration)
        let now = Date(timeIntervalSince1970: 1_000)

        let sameMeeting = ignored.candidatesExcludingIgnoredMeeting(
            [stopped],
            at: now,
            configuration: configuration
        )
        XCTAssertTrue(sameMeeting.isEmpty)
        XCTAssertEqual(lifecycle.observe(sameMeeting, at: now), .none)

        let nextMeeting = ignored.candidatesExcludingIgnoredMeeting(
            [stopped, differentRoom],
            at: now.addingTimeInterval(1),
            configuration: configuration
        )
        XCTAssertEqual(nextMeeting, [differentRoom])
        XCTAssertEqual(
            lifecycle.observe(nextMeeting, at: now.addingTimeInterval(1)),
            .startCapture(differentRoom)
        )
    }

    func testCancelledRestartPredecessorCannotConsumeReplacementIntent() {
        let first = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 1,
            processIdentifier: 10,
            bundleIdentifier: "us.zoom.xos"
        )
        let replacement = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 2,
            processIdentifier: 11,
            bundleIdentifier: "us.zoom.xos"
        )
        var restart = LibreReverseMeetingRestartIntentTracker()
        restart.schedule(first)
        restart.schedule(replacement)

        XCTAssertFalse(restart.consume(first))
        XCTAssertEqual(restart.candidate, replacement)
        XCTAssertTrue(restart.consume(replacement))
        XCTAssertNil(restart.candidate)
    }

    func testAutomaticAndManualStartAreIdempotent() {
        let candidate = LibreReverseMeetingDetector.candidate(
            from: observation(
                bundle: "com.webex.meetingmanager", title: "Webex"
            ))!
        var automatic = LibreReverseMeetingLifecycleCoordinator(
            configuration: .init(
                startPolicy: .automatic,
                startObservationThreshold: 1
            ))
        XCTAssertEqual(automatic.observe([candidate]), .startCapture(candidate))
        XCTAssertEqual(automatic.observe([candidate]), .none)

        var manual = LibreReverseMeetingLifecycleCoordinator()
        let command = manual.startManual(title: "Ad hoc")
        guard case .startCapture = command else {
            return XCTFail("manual start should request capture")
        }
        XCTAssertEqual(manual.startManual(), .none)
    }

    func testMeetingPolicyChangeCannotResetLifecycleAcrossOwnedCaptureBoundary() {
        XCTAssertTrue(
            LibreReverseMeetingPolicyTransition.canResetLifecycle(
                hasActiveSession: false,
                hasOperationInFlight: false,
                hasPendingRestart: false
            )
        )
        for ownedBoundary in [
            (true, false, false),
            (false, true, false),
            (false, false, true),
            (true, true, true),
        ] {
            XCTAssertFalse(
                LibreReverseMeetingPolicyTransition.canResetLifecycle(
                    hasActiveSession: ownedBoundary.0,
                    hasOperationInFlight: ownedBoundary.1,
                    hasPendingRestart: ownedBoundary.2
                )
            )
        }
    }

    func testMeetingStartAdmissionRejectsEveryOwnedOrTerminatingBoundary() {
        XCTAssertTrue(
            LibreReverseMeetingStartAdmission.canBegin(
                terminating: false,
                hasActiveSession: false,
                hasOperationInFlight: false,
                systemCaptureSuspended: false
            )
        )
        for rejected in [
            (true, false, false, false),
            (false, true, false, false),
            (false, false, true, false),
            (false, false, false, true),
            (true, true, true, true),
        ] {
            XCTAssertFalse(
                LibreReverseMeetingStartAdmission.canBegin(
                    terminating: rejected.0,
                    hasActiveSession: rejected.1,
                    hasOperationInFlight: rejected.2,
                    systemCaptureSuspended: rejected.3
                )
            )
        }
    }

    func testSystemBoundaryRetainsStopAcrossStartingRaceAndBlocksAdmission() {
        var boundary = LibreReverseMeetingSystemBoundaryTracker()
        boundary.suspend(.sessionInactive, ownsCaptureBoundary: true)

        XCTAssertTrue(boundary.captureIsSuspended)
        XCTAssertEqual(boundary.pendingStopReason, .systemSessionInactive)
        XCTAssertNil(
            boundary.consumePendingStop(
                hasActiveSession: true,
                hasOperationInFlight: true
            )
        )
        XCTAssertEqual(boundary.pendingStopReason, .systemSessionInactive)

        // Becoming active reopens future admission but cannot erase the stop
        // owed by the capture that crossed the inactive-session boundary.
        boundary.resume(.sessionInactive)
        XCTAssertFalse(boundary.captureIsSuspended)
        XCTAssertEqual(
            boundary.consumePendingStop(
                hasActiveSession: true,
                hasOperationInFlight: false
            ),
            .systemSessionInactive
        )
        XCTAssertNil(boundary.pendingStopReason)
    }

    func testSystemBoundaryClearsOrphanedStopButSleepSupersedesLock() {
        var boundary = LibreReverseMeetingSystemBoundaryTracker()
        boundary.suspend(.sessionInactive, ownsCaptureBoundary: true)
        boundary.suspend(.sleep, ownsCaptureBoundary: true)
        XCTAssertEqual(boundary.pendingStopReason, .systemSleep)
        boundary.resume(.sleep)
        XCTAssertTrue(
            boundary.captureIsSuspended,
            "waking to a locked session must keep capture admission closed"
        )
        XCTAssertNil(
            boundary.consumePendingStop(
                hasActiveSession: false,
                hasOperationInFlight: false
            )
        )
        XCTAssertNil(boundary.pendingStopReason)

        boundary.resume(.sessionInactive)
        XCTAssertFalse(boundary.captureIsSuspended)
        boundary.suspend(.sessionInactive, ownsCaptureBoundary: false)
        XCTAssertNil(boundary.pendingStopReason)
    }

    func testCompletedBoundaryCannotStopTheNextMeetingAfterUnlock() {
        var boundary = LibreReverseMeetingSystemBoundaryTracker()
        boundary.suspend(.sessionInactive, ownsCaptureBoundary: true)
        boundary.captureBoundaryDidEnd()
        boundary.resume(.sessionInactive)

        XCTAssertFalse(boundary.captureIsSuspended)
        XCTAssertNil(boundary.pendingStopReason)
        XCTAssertNil(
            boundary.consumePendingStop(
                hasActiveSession: true,
                hasOperationInFlight: false
            )
        )
    }

    func testManualRecordingNeverEndsFromMissingDetectorOrSilence() {
        let start = Date(timeIntervalSince1970: 500)
        var lifecycle = LibreReverseMeetingLifecycleCoordinator(
            configuration: .init(
                endPolicy: .detected,
                endObservationThreshold: 1,
                nativeEndGrace: 0,
                browserEndGrace: 0
            ))
        guard case .startCapture(let candidate) = lifecycle.startManual(title: "Interview")
        else { return XCTFail("manual meeting did not start") }
        lifecycle.captureDidStart(at: start)

        for minute in 1...120 {
            XCTAssertEqual(
                lifecycle.observe(
                    [],
                    at: start.addingTimeInterval(TimeInterval(minute * 60)),
                    outputVoiceActivity: false
                ),
                .none
            )
        }
        XCTAssertEqual(lifecycle.state, .recording(candidate, startedAt: start))
        XCTAssertEqual(lifecycle.requestStop(.userRequested), .stopCapture(.userRequested))
    }

    func testDisabledDetectionStillAllowsExplicitManualRecording() {
        var lifecycle = LibreReverseMeetingLifecycleCoordinator(
            configuration: .init(
                startPolicy: .disabled,
                startObservationThreshold: 1
            ))
        let candidate = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 7
        )
        XCTAssertEqual(lifecycle.observe([candidate]), .none)
        XCTAssertEqual(
            lifecycle.startManual(title: "Manual only"),
            .startCapture(
                .init(
                    provider: .manual,
                    source: .manual,
                    title: "Manual only"
                ))
        )
    }

    func testFailedCaptureCanNeverBecomeCompleted() {
        struct Failure: LocalizedError { var errorDescription: String? { "writer failed" } }
        var coordinator = LibreReverseMeetingLifecycleCoordinator()
        _ = coordinator.startManual()
        coordinator.captureDidFail(Failure())
        guard case .failed(_, let message) = coordinator.state else {
            return XCTFail("expected failed lifecycle")
        }
        XCTAssertEqual(message, "writer failed")
        coordinator.captureDidFinish(segmentID: 99)
        guard case .failed = coordinator.state else {
            return XCTFail("a failed writer must not become completed")
        }
    }

    func testSystemSleepRequestsOneOrderlyStop() {
        var lifecycle = LibreReverseMeetingLifecycleCoordinator()
        guard case .startCapture = lifecycle.startManual(title: "Sleep boundary") else {
            return XCTFail("manual meeting did not start")
        }
        lifecycle.captureDidStart(at: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(lifecycle.requestStop(.systemSleep), .stopCapture(.systemSleep))
        XCTAssertEqual(lifecycle.requestStop(.systemSleep), .none)
    }

    func testInactiveSystemSessionRequestsOneOrderlyStop() {
        var lifecycle = LibreReverseMeetingLifecycleCoordinator()
        guard case .startCapture = lifecycle.startManual(title: "Lock boundary") else {
            return XCTFail("manual meeting did not start")
        }
        lifecycle.captureDidStart(at: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(
            lifecycle.requestStop(.systemSessionInactive),
            .stopCapture(.systemSessionInactive)
        )
        XCTAssertEqual(lifecycle.requestStop(.systemSessionInactive), .none)
    }

    func testStoragePressureRequestsOneOrderlyStopAndNeverResumesImplicitly() {
        var lifecycle = LibreReverseMeetingLifecycleCoordinator()
        guard case .startCapture = lifecycle.startManual(title: "Storage boundary") else {
            return XCTFail("manual meeting did not start")
        }
        lifecycle.captureDidStart(at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(
            lifecycle.requestStop(.storagePressure),
            .stopCapture(.storagePressure)
        )
        XCTAssertEqual(lifecycle.requestStop(.storagePressure), .none)
        lifecycle.captureDidFinish(segmentID: 1)
        guard case .completed = lifecycle.state else {
            return XCTFail("the finalized segment must remain completed")
        }
    }

    func testMeetingStorageGuardUsesMeasuredRateSafetyMarginAndFloor() {
        let gib: Int64 = 1_073_741_824
        let guardrail = LibreReverseMeetingCaptureStorageGuard()
        XCTAssertEqual(guardrail.requiredFreeBytes(), 2 * gib)
        XCTAssertTrue(guardrail.hasCapacity(availableBytes: 2 * gib))
        XCTAssertFalse(guardrail.hasCapacity(availableBytes: 2 * gib - 1))
        XCTAssertEqual(
            guardrail.requiredFreeBytes(plannedDuration: 7_200),
            75_497_472_000
        )
        XCTAssertFalse(
            guardrail.hasCapacity(
                availableBytes: 70 * gib,
                plannedDuration: 7_200
            ))
    }

    func testAudioRouteChangeSplitsAndResumesWithoutReprompting() {
        let candidate = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 9
        )
        var lifecycle = LibreReverseMeetingLifecycleCoordinator(
            configuration: .init(
                startPolicy: .ask,
                startObservationThreshold: 1
            ))
        XCTAssertEqual(lifecycle.observe([candidate]), .presentPrompt(candidate))
        XCTAssertEqual(lifecycle.acceptPrompt(), .startCapture(candidate))
        lifecycle.captureDidStart(at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(
            lifecycle.requestStop(.audioDeviceChanged),
            .stopCapture(.audioDeviceChanged)
        )
        lifecycle.captureDidFinish(segmentID: 1)
        lifecycle.reset()
        XCTAssertEqual(
            lifecycle.resumeAfterCaptureBoundary(candidate),
            .startCapture(candidate)
        )

        lifecycle.captureDidStart(at: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(
            lifecycle.requestStop(.microphonePermissionChanged),
            .stopCapture(.microphonePermissionChanged)
        )
        lifecycle.captureDidFinish(segmentID: 3)
        lifecycle.reset()
        XCTAssertEqual(
            lifecycle.resumeAfterCaptureBoundary(candidate),
            .startCapture(candidate)
        )

        lifecycle.captureDidStart(at: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(
            lifecycle.requestStop(.audioSourceChanged),
            .stopCapture(.audioSourceChanged)
        )
        lifecycle.captureDidFinish(segmentID: 2)
        lifecycle.reset()
        XCTAssertEqual(
            lifecycle.resumeAfterCaptureBoundary(candidate),
            .startCapture(candidate)
        )
    }

    func testRecoveredHardExitResumesOnlyTheSameLiveProviderWindow() throws {
        let finished = Date(timeIntervalSince1970: 10_000)
        let recovered = finished.addingTimeInterval(5)
        let recorded = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 91,
            processIdentifier: 100,
            bundleIdentifier: "us.zoom.xos",
            title: "User-edited planning review"
        )
        let continuation = try XCTUnwrap(
            LibreReverseRecoveredMeetingContinuation(
                candidate: recorded,
                captureFinishedAt: finished,
                recoveredAt: recovered
            )
        )
        let unrelated = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 92,
            processIdentifier: 100,
            bundleIdentifier: "us.zoom.xos",
            title: "Different call"
        )
        XCTAssertEqual(
            continuation.decision(liveCandidates: [unrelated], at: recovered),
            .waiting
        )
        let restartedProviderWithRecycledWindowID = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 91,
            processIdentifier: 101,
            bundleIdentifier: "us.zoom.xos",
            title: "New call after provider restart"
        )
        XCTAssertEqual(
            continuation.decision(
                liveCandidates: [restartedProviderWithRecycledWindowID],
                at: recovered
            ),
            .waiting
        )
        let sameLiveWindow = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 91,
            processIdentifier: 100,
            bundleIdentifier: "us.zoom.xos",
            title: "Provider title changed after restart"
        )
        XCTAssertEqual(
            continuation.decision(liveCandidates: [sameLiveWindow], at: recovered),
            .resume(recorded)
        )
    }

    func testRecoveredHardExitDoesNotTransferBrowserConsentToAnotherRoom() throws {
        let finished = Date(timeIntervalSince1970: 15_000)
        let recovered = finished.addingTimeInterval(5)
        let recorded = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 91,
            processIdentifier: 100,
            bundleIdentifier: "com.google.Chrome",
            url: URL(string: "https://meet.google.com/abc-defg-hij?authuser=0")
        )
        let continuation = try XCTUnwrap(
            LibreReverseRecoveredMeetingContinuation(
                candidate: recorded,
                captureFinishedAt: finished,
                recoveredAt: recovered
            )
        )
        let sameRoom = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 91,
            processIdentifier: 100,
            bundleIdentifier: "com.google.Chrome",
            url: URL(string: "https://meet.google.com/abc-defg-hij?authuser=1")
        )
        let differentRoom = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 91,
            processIdentifier: 100,
            bundleIdentifier: "com.google.Chrome",
            url: URL(string: "https://meet.google.com/xyz-wxyz-xyz")
        )

        XCTAssertEqual(
            continuation.decision(liveCandidates: [sameRoom], at: recovered),
            .resume(recorded)
        )
        XCTAssertEqual(
            continuation.decision(liveCandidates: [differentRoom], at: recovered),
            .waiting
        )
    }

    func testRecoveredHardExitContinuationIsBoundedAndNeverResumesManualCapture() {
        let finished = Date(timeIntervalSince1970: 20_000)
        let provider = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 7
        )
        XCTAssertNil(
            LibreReverseRecoveredMeetingContinuation(
                candidate: provider,
                captureFinishedAt: finished,
                recoveredAt: finished.addingTimeInterval(601)
            )
        )
        XCTAssertNil(
            LibreReverseRecoveredMeetingContinuation(
                candidate: .init(provider: .manual, source: .manual),
                captureFinishedAt: finished,
                recoveredAt: finished.addingTimeInterval(1)
            )
        )
        let continuation = LibreReverseRecoveredMeetingContinuation(
            candidate: provider,
            captureFinishedAt: finished,
            recoveredAt: finished.addingTimeInterval(10)
        )
        XCTAssertEqual(
            continuation?.decision(
                liveCandidates: [provider],
                at: finished.addingTimeInterval(601)
            ),
            .expired
        )
    }

    func testMeetingRecoveryRetryBackoffIsBoundedAndNormalizesConfiguration() {
        let policy = LibreReverseMeetingRecoveryRetryPolicy(
            initialDelay: 0.5,
            maximumDelay: 5
        )
        XCTAssertEqual(policy.delay(afterFailureCount: 0), 0.5)
        XCTAssertEqual(policy.delay(afterFailureCount: 1), 0.5)
        XCTAssertEqual(policy.delay(afterFailureCount: 2), 1)
        XCTAssertEqual(policy.delay(afterFailureCount: 4), 4)
        XCTAssertEqual(policy.delay(afterFailureCount: 5), 5)
        XCTAssertEqual(policy.delay(afterFailureCount: 1_000), 5)

        let normalized = LibreReverseMeetingRecoveryRetryPolicy(
            initialDelay: 0,
            maximumDelay: -1
        )
        XCTAssertEqual(normalized.initialDelay, 0.001)
        XCTAssertEqual(normalized.maximumDelay, 0.001)
    }

    func testRecoveredContinuationStoreSurvivesRelaunchAndRetiresInvalidState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "meeting-continuation-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibreReverseRecoveredMeetingContinuationStore(root: root)
        let olderCandidate = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 40,
            title: "Earlier recovered call"
        )
        let newerCandidate = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 41,
            title: "Latest recovered call"
        )
        let older = try XCTUnwrap(
            LibreReverseRecoveredMeetingContinuationRecord(
                publicationXID: "older-xid",
                candidate: olderCandidate,
                captureFinishedAt: Date(timeIntervalSince1970: 100),
                createdAt: Date(timeIntervalSince1970: 101)
            ))
        let newer = try XCTUnwrap(
            LibreReverseRecoveredMeetingContinuationRecord(
                publicationXID: "newer-xid",
                candidate: newerCandidate,
                captureFinishedAt: Date(timeIntervalSince1970: 200),
                createdAt: Date(timeIntervalSince1970: 201)
            ))
        try store.persist(newer)
        try store.persist(older)

        let relaunched = LibreReverseRecoveredMeetingContinuationStore(root: root)
        XCTAssertEqual(
            try relaunched.load(at: Date(timeIntervalSince1970: 202))?.candidate,
            newerCandidate
        )
        XCTAssertNil(try relaunched.load(at: Date(timeIntervalSince1970: 801)))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    LibreReverseRecoveredMeetingContinuationStore.fileName
                ).path
            ))

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: root.appendingPathComponent(
                LibreReverseRecoveredMeetingContinuationStore.fileName
            ))
        XCTAssertNil(try relaunched.load(at: Date(timeIntervalSince1970: 202)))
        XCTAssertNil(
            LibreReverseRecoveredMeetingContinuationRecord(
                publicationXID: "manual-xid",
                candidate: .init(provider: .manual, source: .manual),
                captureFinishedAt: Date(timeIntervalSince1970: 200),
                createdAt: Date(timeIntervalSince1970: 201)
            ))
    }

    func testMeetingStartupRetainsOnlyPostRecordingStaging() {
        XCTAssertFalse(
            LibreReverseMeetingStartupFailurePolicy.retainsStaging(
                captureReachedRecording: false
            ))
        XCTAssertTrue(
            LibreReverseMeetingStartupFailurePolicy.retainsStaging(
                captureReachedRecording: true
            ))
    }

    func testAudioRouteSnapshotRestartsOnlyWhenSelectedInputChanges() {
        let baseline = LibreReverseMeetingAudioRouteSnapshot(
            defaultInputDeviceID: "built-in",
            defaultInputRouteName: "MacBook Microphone",
            availableInputDeviceIDs: ["built-in", "headset"]
        )
        XCTAssertFalse(
            LibreReverseMeetingAudioRouteSnapshot(
                defaultInputDeviceID: "built-in",
                defaultInputRouteName: "MacBook Microphone",
                availableInputDeviceIDs: ["built-in", "headset", "display"]
            ).requiresCaptureRestart(from: baseline, requestedDeviceID: nil))
        XCTAssertTrue(
            LibreReverseMeetingAudioRouteSnapshot(
                defaultInputDeviceID: "headset",
                defaultInputRouteName: "Bluetooth Headset",
                availableInputDeviceIDs: ["built-in", "headset"]
            ).requiresCaptureRestart(from: baseline, requestedDeviceID: nil))
        XCTAssertTrue(
            LibreReverseMeetingAudioRouteSnapshot(
                defaultInputDeviceID: "built-in",
                defaultInputRouteName: "Bluetooth Headset",
                availableInputDeviceIDs: ["built-in", "headset"]
            ).requiresCaptureRestart(from: baseline, requestedDeviceID: nil))
        XCTAssertFalse(
            LibreReverseMeetingAudioRouteSnapshot(
                defaultInputDeviceID: "headset",
                availableInputDeviceIDs: ["built-in", "headset"]
            ).requiresCaptureRestart(from: baseline, requestedDeviceID: "built-in"))
        XCTAssertTrue(
            LibreReverseMeetingAudioRouteSnapshot(
                defaultInputDeviceID: "headset",
                availableInputDeviceIDs: ["headset"]
            ).requiresCaptureRestart(from: baseline, requestedDeviceID: "built-in"))
    }

    func testAudioRouteChangeRequiresConsecutiveMismatchAndResetsAfterRecovery() {
        let baseline = LibreReverseMeetingAudioRouteSnapshot(
            defaultInputDeviceID: "built-in",
            defaultInputRouteName: "MacBook Microphone",
            availableInputDeviceIDs: ["built-in", "headset"]
        )
        let transientDropout = LibreReverseMeetingAudioRouteSnapshot(
            defaultInputDeviceID: nil,
            availableInputDeviceIDs: []
        )
        var tracker = LibreReverseMeetingAudioRouteChangeTracker(observationThreshold: 2)

        XCTAssertFalse(
            tracker.observe(transientDropout, baseline: baseline, requestedDeviceID: nil)
        )
        XCTAssertEqual(tracker.mismatchObservationCount, 1)
        XCTAssertFalse(tracker.observe(baseline, baseline: baseline, requestedDeviceID: nil))
        XCTAssertEqual(tracker.mismatchObservationCount, 0)
        XCTAssertFalse(
            tracker.observe(transientDropout, baseline: baseline, requestedDeviceID: nil)
        )
        XCTAssertTrue(
            tracker.observe(transientDropout, baseline: baseline, requestedDeviceID: nil)
        )
        tracker.reset()
        XCTAssertEqual(tracker.mismatchObservationCount, 0)
    }

    func testMeetingAudioPreferencesResolvePermissionAndPlatformAtCaptureBoundary() {
        let defaults = LibreReverseMeetingAudioPreferences()
        XCTAssertEqual(
            defaults.effectiveCaptureSelection(
                microphoneAuthorized: true,
                nativeMicrophoneCaptureSupported: true
            ),
            .init(
                capturesSystemAudio: true,
                capturesMicrophone: true,
                microphoneDeviceID: nil
            )
        )
        XCTAssertEqual(
            LibreReverseMeetingAudioPreferences(
                capturesSystemAudio: true,
                capturesMicrophone: true,
                microphoneDeviceID: "usb-mic"
            ).effectiveCaptureSelection(
                microphoneAuthorized: false,
                nativeMicrophoneCaptureSupported: true
            ),
            .init(
                capturesSystemAudio: true,
                capturesMicrophone: false,
                microphoneDeviceID: nil
            )
        )
        XCTAssertEqual(
            LibreReverseMeetingAudioPreferences(
                capturesSystemAudio: false,
                capturesMicrophone: true,
                microphoneDeviceID: "usb-mic"
            ).effectiveCaptureSelection(
                microphoneAuthorized: true,
                nativeMicrophoneCaptureSupported: false
            ),
            .init(
                capturesSystemAudio: false,
                capturesMicrophone: false,
                microphoneDeviceID: nil
            )
        )
        XCTAssertNil(
            LibreReverseMeetingAudioPreferences(
                capturesSystemAudio: false,
                capturesMicrophone: false,
                microphoneDeviceID: "must-not-survive"
            ).microphoneDeviceID)

        let activeCombined = LibreReverseMeetingAudioCaptureSelection(
            capturesSystemAudio: true,
            capturesMicrophone: true,
            microphoneDeviceID: "usb-mic"
        )
        XCTAssertFalse(activeCombined.requiresCaptureRestart(from: activeCombined))
        XCTAssertTrue(
            LibreReverseMeetingAudioCaptureSelection(
                capturesSystemAudio: true,
                capturesMicrophone: false,
                microphoneDeviceID: nil
            ).requiresCaptureRestart(from: activeCombined))
        XCTAssertTrue(
            LibreReverseMeetingAudioCaptureSelection(
                capturesSystemAudio: true,
                capturesMicrophone: true,
                microphoneDeviceID: nil
            ).requiresCaptureRestart(from: activeCombined))

        let explicitPreferences = LibreReverseMeetingAudioPreferences(
            capturesSystemAudio: true,
            capturesMicrophone: true,
            microphoneDeviceID: "usb-mic"
        )
        XCTAssertEqual(
            explicitPreferences.runtimeDecision(
                from: activeCombined,
                microphoneAuthorized: true,
                nativeMicrophoneCaptureSupported: true,
                availableMicrophoneDeviceIDs: ["usb-mic"]
            ), .unchanged)
        XCTAssertEqual(
            explicitPreferences.runtimeDecision(
                from: activeCombined,
                microphoneAuthorized: false,
                nativeMicrophoneCaptureSupported: true,
                availableMicrophoneDeviceIDs: ["usb-mic"]
            ),
            .restart(
                .init(
                    capturesSystemAudio: true,
                    capturesMicrophone: false,
                    microphoneDeviceID: nil
                )))
        let activeWithoutMicrophone = LibreReverseMeetingAudioCaptureSelection(
            capturesSystemAudio: true,
            capturesMicrophone: false,
            microphoneDeviceID: nil
        )
        XCTAssertEqual(
            explicitPreferences.runtimeDecision(
                from: activeWithoutMicrophone,
                microphoneAuthorized: true,
                nativeMicrophoneCaptureSupported: true,
                availableMicrophoneDeviceIDs: ["usb-mic"]
            ), .restart(activeCombined))
        XCTAssertEqual(
            explicitPreferences.runtimeDecision(
                from: activeWithoutMicrophone,
                microphoneAuthorized: true,
                nativeMicrophoneCaptureSupported: true,
                availableMicrophoneDeviceIDs: []
            ), .selectedMicrophoneUnavailable("usb-mic"))
    }

    func testOutputAudioCanSustainButNeverStartAMeeting() {
        let start = Date(timeIntervalSince1970: 1_000)
        var coordinator = LibreReverseMeetingLifecycleCoordinator(
            configuration: .init(
                startPolicy: .automatic,
                startObservationThreshold: 1
            ))
        XCTAssertEqual(
            coordinator.observe([], at: start, outputVoiceActivity: true),
            .none,
            "music or video audio alone must never start a meeting"
        )

        let candidate = LibreReverseMeetingDetector.candidate(
            from: observation(
                bundle: "us.zoom.xos", title: "Zoom Meeting"
            ))!
        XCTAssertEqual(coordinator.observe([candidate], at: start), .startCapture(candidate))
        coordinator.captureDidStart(at: start)
        XCTAssertEqual(
            coordinator.observe(
                [],
                at: start.addingTimeInterval(120),
                outputVoiceActivity: true
            ),
            .none
        )
        XCTAssertEqual(coordinator.state, .recording(candidate, startedAt: start))
    }

    func testHiddenNativeMeetingWindowsMergeWithoutBypassingPrivacyOrBrowserURLRules() {
        let visibleZoom = observation(
            bundle: "us.zoom.xos",
            title: "Zoom Meeting"
        )
        let hiddenTeams = LibreReverseMeetingWindowObservation(
            windowID: 22,
            processIdentifier: 202,
            bundleIdentifier: "com.microsoft.teams2",
            title: "Call",
            accessibilityLabels: ["Microsoft Teams Call in progress"]
        )
        let hiddenSlack = LibreReverseMeetingWindowObservation(
            windowID: 23,
            processIdentifier: 203,
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            title: "Huddle",
            accessibilityLabels: ["Leave Huddle"]
        )
        let hiddenBrowser = LibreReverseMeetingWindowObservation(
            windowID: 24,
            processIdentifier: 204,
            bundleIdentifier: "com.google.Chrome",
            title: "Meet",
            url: URL(string: "https://meet.google.com/abc-defg-hij")
        )
        let duplicateVisible = LibreReverseMeetingWindowObservation(
            windowID: visibleZoom.windowID,
            processIdentifier: visibleZoom.processIdentifier,
            bundleIdentifier: visibleZoom.bundleIdentifier,
            title: "stale hidden title"
        )

        let merged = LibreReverseMeetingDetector.mergingHiddenNativeObservations(
            visible: [visibleZoom],
            inventory: [
                .init(observation: duplicateVisible, ownerName: "zoom.us"),
                .init(observation: hiddenTeams, ownerName: "Microsoft Teams"),
                .init(observation: hiddenSlack, ownerName: "Slack"),
                .init(observation: hiddenBrowser, ownerName: "Google Chrome"),
            ],
            ownBundleIdentifier: "local.librereverse",
            omittedBundleIdentifiers: ["com.tinyspeck.slackmacgap"],
            omittedOwnerNames: []
        )

        XCTAssertEqual(merged, [visibleZoom, hiddenTeams])
        XCTAssertEqual(
            LibreReverseMeetingDetector.candidates(from: merged).map(\.provider),
            [.zoom, .microsoftTeamsV2]
        )
    }

    func testHiddenNativeMeetingWindowsRejectStaleTitlesButAcceptDedicatedWebexProcess() {
        let staleZoom = LibreReverseMeetingWindowObservation(
            windowID: 41,
            processIdentifier: 401,
            bundleIdentifier: "us.zoom.xos",
            title: "Zoom Meeting"
        )
        let staleSlack = LibreReverseMeetingWindowObservation(
            windowID: 42,
            processIdentifier: 402,
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            title: "Huddle"
        )
        let liveZoom = LibreReverseMeetingWindowObservation(
            windowID: 43,
            processIdentifier: 403,
            bundleIdentifier: "us.zoom.xos",
            title: "Zoom Meeting",
            accessibilityLabels: ["Leave Meeting"]
        )
        let webex = LibreReverseMeetingWindowObservation(
            windowID: 44,
            processIdentifier: 404,
            bundleIdentifier: "com.webex.meetingmanager",
            title: ""
        )
        let inventory = [staleZoom, staleSlack, liveZoom, webex].map {
            LibreReverseMeetingWindowInventoryItem(observation: $0, ownerName: "Allowed")
        }

        XCTAssertEqual(
            LibreReverseMeetingDetector.mergingHiddenNativeObservations(
                visible: [],
                inventory: inventory,
                ownBundleIdentifier: "local.librereverse",
                omittedBundleIdentifiers: [],
                omittedOwnerNames: []
            ),
            [liveZoom, webex]
        )
    }

    func testHiddenNativePrivacyFilterRunsBeforeAccessibilityEvidenceBoundary() {
        let zoom = LibreReverseMeetingWindowInventoryItem(
            observation: observation(bundle: "us.zoom.xos", title: "Zoom Meeting"),
            ownerName: "Zoom"
        )
        let teams = LibreReverseMeetingWindowInventoryItem(
            observation: LibreReverseMeetingWindowObservation(
                windowID: 52,
                processIdentifier: 502,
                bundleIdentifier: "com.microsoft.teams2",
                title: "Call"
            ),
            ownerName: "Microsoft Teams"
        )
        XCTAssertEqual(
            LibreReverseMeetingDetector.privacyEligibleHiddenNativeInventory(
                [zoom, teams],
                ownBundleIdentifier: "local.librereverse",
                omittedBundleIdentifiers: ["us.zoom.xos"],
                omittedOwnerNames: []
            ),
            [teams]
        )
        XCTAssertTrue(
            LibreReverseMeetingDetector.privacyEligibleHiddenNativeInventory(
                [zoom, teams],
                ownBundleIdentifier: "com.microsoft.teams2",
                omittedBundleIdentifiers: [],
                omittedOwnerNames: ["Zoom"]
            ).isEmpty
        )
    }

    func testHiddenNativeMeetingWindowMergeHonorsOwnerAndSelfExclusions() {
        let webex = LibreReverseMeetingWindowObservation(
            windowID: 31,
            processIdentifier: 301,
            bundleIdentifier: "com.webex.meetingmanager",
            title: "Meeting"
        )
        let zoom = LibreReverseMeetingWindowObservation(
            windowID: 32,
            processIdentifier: 302,
            bundleIdentifier: "us.zoom.xos",
            title: "Zoom Meeting"
        )
        XCTAssertTrue(
            LibreReverseMeetingDetector.mergingHiddenNativeObservations(
                visible: [],
                inventory: [
                    .init(observation: webex, ownerName: "Webex"),
                    .init(observation: zoom, ownerName: "Zoom"),
                ],
                ownBundleIdentifier: "com.webex.meetingmanager",
                omittedBundleIdentifiers: [],
                omittedOwnerNames: ["Zoom"]
            ).isEmpty
        )
    }

    func testBrowserTabSwitchUsesLongGraceAndReentryHysteresis() {
        let start = Date(timeIntervalSince1970: 2_000)
        let observation = LibreReverseMeetingWindowObservation(
            windowID: 8,
            processIdentifier: 12,
            bundleIdentifier: "com.google.Chrome",
            title: "Meet",
            url: URL(string: "https://meet.google.com/abc-defg-hij")
        )
        let candidate = LibreReverseMeetingDetector.candidate(from: observation)!
        var coordinator = LibreReverseMeetingLifecycleCoordinator(
            configuration: .init(
                startPolicy: .automatic,
                startObservationThreshold: 1,
                endObservationThreshold: 1,
                reentryObservationThreshold: 2,
                nativeEndGrace: 30,
                browserEndGrace: 300
            ))
        _ = coordinator.observe([candidate], at: start)
        coordinator.captureDidStart(at: start)
        XCTAssertEqual(coordinator.observe([], at: start.addingTimeInterval(1)), .none)
        guard case .ending = coordinator.state else { return XCTFail("expected grace state") }
        XCTAssertEqual(coordinator.observe([candidate], at: start.addingTimeInterval(10)), .none)
        guard case .ending = coordinator.state else {
            return XCTFail("one transient toolbar scan must not exit ending")
        }
        XCTAssertEqual(coordinator.observe([candidate], at: start.addingTimeInterval(15)), .none)
        XCTAssertEqual(coordinator.state, .recording(candidate, startedAt: start))

        XCTAssertEqual(coordinator.observe([], at: start.addingTimeInterval(20)), .none)
        XCTAssertEqual(coordinator.observe([], at: start.addingTimeInterval(319)), .none)
        XCTAssertEqual(
            coordinator.observe([], at: start.addingTimeInterval(320)),
            .stopCapture(.meetingWindowClosed)
        )
    }

    func testBrowserRoomChangeDoesNotInheritActiveRecordingLifecycle() {
        let start = Date(timeIntervalSince1970: 3_000)
        let firstRoom = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 8,
            processIdentifier: 12,
            bundleIdentifier: "com.google.Chrome",
            url: URL(string: "https://meet.google.com/abc-defg-hij")
        )
        let differentRoom = LibreReverseMeetingCandidate(
            provider: .googleMeet,
            source: .windowDetection,
            windowID: 8,
            processIdentifier: 12,
            bundleIdentifier: "com.google.Chrome",
            url: URL(string: "https://meet.google.com/xyz-wxyz-xyz")
        )
        var coordinator = LibreReverseMeetingLifecycleCoordinator(
            configuration: .init(
                startPolicy: .automatic,
                startObservationThreshold: 1,
                endObservationThreshold: 1,
                nativeEndGrace: 0,
                browserEndGrace: 0
            )
        )

        XCTAssertEqual(coordinator.observe([firstRoom], at: start), .startCapture(firstRoom))
        coordinator.captureDidStart(at: start)
        XCTAssertEqual(
            coordinator.observe([differentRoom], at: start.addingTimeInterval(1)),
            .stopCapture(.meetingWindowClosed)
        )
    }

    func testProviderRestartDoesNotInheritActiveRecordingLifecycle() {
        let start = Date(timeIntervalSince1970: 4_000)
        let original = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 8,
            processIdentifier: 12,
            bundleIdentifier: "us.zoom.xos"
        )
        let restarted = LibreReverseMeetingCandidate(
            provider: .zoom,
            source: .windowDetection,
            windowID: 8,
            processIdentifier: 13,
            bundleIdentifier: "us.zoom.xos"
        )
        var coordinator = LibreReverseMeetingLifecycleCoordinator(
            configuration: .init(
                startPolicy: .automatic,
                startObservationThreshold: 1,
                endObservationThreshold: 1,
                nativeEndGrace: 0,
                browserEndGrace: 0
            )
        )

        XCTAssertEqual(coordinator.observe([original], at: start), .startCapture(original))
        coordinator.captureDidStart(at: start)
        XCTAssertEqual(
            coordinator.observe([restarted], at: start.addingTimeInterval(1)),
            .stopCapture(.meetingWindowClosed)
        )
    }

    private func observation(
        bundle: String,
        title: String,
        labels: [String] = []
    ) -> LibreReverseMeetingWindowObservation {
        LibreReverseMeetingWindowObservation(
            windowID: 7,
            processIdentifier: 11,
            bundleIdentifier: bundle,
            title: title,
            accessibilityLabels: labels
        )
    }
}
