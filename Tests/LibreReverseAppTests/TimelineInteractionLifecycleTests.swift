#if os(macOS) && DEBUG
import AppKit
import XCTest
@testable import LibreReverseCore
@testable import LibreReverseApp

@MainActor
final class TimelineInteractionLifecycleTests: XCTestCase {
    func testDeactivationDismissesTimelineBeforeAnotherAppWindowActivates() {
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        controller.window?.hidesOnDeactivate = false
        controller.window?.orderFrontRegardless()
        controller.dismissForApplicationDeactivation()
        XCTAssertTrue(controller.window?.isVisible == true,
            "Isolated validation windows deliberately remain visible across app activation")
        controller.window?.hidesOnDeactivate = true
        controller.dismissForApplicationDeactivation()
        XCTAssertFalse(controller.window?.isVisible == true)
        let auxiliary = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        auxiliary.orderFrontRegardless()
        defer { auxiliary.orderOut(nil) }
        XCTAssertFalse(controller.window?.isVisible == true,
            "Opening an auxiliary window must not restore the explicitly dismissed timeline")
    }

    func testAIChatIsEmbeddedInMainSearchAndToggleRestoresKeywordSearch() throws {
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        let ask = LibreReverseAskWindowController(answerHandler: { _, _ in .init(text: "Synthetic answer", citations: []) },
            loadAPIKey: { "synthetic" }, openAISettings: {}, openMoment: { _ in })
        controller.window?.setContentSize(NSSize(width: 1200, height: 800))
        controller.presentInlineAsk(ask, query: "What was happening here?")
        let content = try XCTUnwrap(controller.window?.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        content.layoutSubtreeIfNeeded()
        let composer = try XCTUnwrap(descendants(content).first { $0.accessibilityIdentifier() == "ask.question" } as? NSTextView)
        XCTAssertEqual(composer.string, "What was happening here?")
        XCTAssertTrue(composer.window === controller.window)
        XCTAssertFalse(ask.window?.isVisible == true, "AI search must not open a second window")
        XCTAssertFalse(composer.isHiddenOrHasHiddenAncestor)
        let toggle = try XCTUnwrap(descendants(content).first { $0.accessibilityIdentifier() == "search.ai-toggle" } as? NSButton)
        XCTAssertEqual(toggle.state, .on)
        let point = composer.convert(NSPoint(x: 5, y: 5), to: nil)
        XCTAssertFalse(controller.interactionTestShouldScrollTimeline(at: point),
            "Scrolling the chat must not scrub and dismiss the timeline")
        for size in [NSSize(width: 1200, height: 800), NSSize(width: 800, height: 700)] {
            controller.window?.setContentSize(size)
            content.layoutSubtreeIfNeeded()
            XCTAssertTrue(content.bounds.contains(composer.convert(composer.bounds, to: content)), "Composer must stay inside the viewer")
        }
        controller.window?.makeFirstResponder(composer)
        toggle.performClick(nil)
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(controller.window?.firstResponder === composer, "Hidden chat must release keyboard focus")
        XCTAssertEqual(toggle.state, .off)
        XCTAssertTrue(composer.isHiddenOrHasHiddenAncestor)
        controller.presentInlineAsk(ask)
        XCTAssertFalse(composer.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(composer.string, "What was happening here?", "Toggling search must preserve the draft")
        if let path = ProcessInfo.processInfo.environment["LIBREREVERSE_INLINE_ASK_PREVIEW"] {
            controller.window?.setContentSize(NSSize(width: 1200, height: 900))
            ask.appendFixture(question: "What were the decisions in this meeting?", answer: .init(
                text: "**Two decisions** came out of the review. [1]\n\n1. Keep meeting capture local.\n2. Test screen sharing before Friday.",
                citations: [.init(instant: Date(timeIntervalSince1970: 1_700_000_000), title: "Product review", excerpt: "Keep capture local and test sharing.", source: "Transcript")]))
            ask.appendFixture(question: "Who is following up?", answer: .init(
                text: "**Alex** will test sharing. **Morgan** will review the transcript. [1]",
                citations: [.init(instant: Date(timeIntervalSince1970: 1_700_000_000), title: "Product review", excerpt: "Alex and Morgan own the follow-up.", source: "Transcript")]))
            content.layoutSubtreeIfNeeded()
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        _ = ask.beginShutdown()
    }

    func testTranscriptDragMovesCardAndClampsItInsideViewer() {
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        controller.window?.setContentSize(NSSize(width: 1200, height: 800))
        let initial = controller.interactionTestTranscriptFrame
        controller.interactionTestDragTranscript(by: NSSize(width: -180, height: 90))
        let moved = controller.interactionTestTranscriptFrame
        XCTAssertEqual(moved.minX, initial.minX - 180, accuracy: 0.5)
        XCTAssertEqual(moved.minY, initial.minY + 90, accuracy: 0.5)
        controller.interactionTestDragTranscript(by: NSSize(width: -9000, height: -9000))
        let clamped = controller.interactionTestTranscriptFrame
        XCTAssertEqual(clamped.minX, 22, accuracy: 0.5)
        XCTAssertEqual(clamped.minY, MemoryExplorerVisualShell.bottomOverlayHeight + 52, accuracy: 0.5, "Dragging down must preserve the native text-selection action below the card")
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        XCTAssertTrue(NSRect(x: 0, y: 0, width: 800, height: 600).contains(controller.interactionTestTranscriptFrame))
    }

    func testOCRSelectionAfterMeetingUsesFrameResolver() async throws {
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        var requests: [(Date, Int64?)] = []
        controller.interactionTestResolver = { date, meetingID in
            requests.append((date, meetingID))
            return nil
        }
        let target = Date(timeIntervalSince1970: 1_700_000_030)
        controller.interactionTestSelectOCR(result(at: target), previousMeetingID: 99)
        await controller.interactionTestDrain()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0, target)
        XCTAssertNil(requests.first?.1, "The previous meeting must not redirect an OCR result")
    }

    func testDragCompletionResolvesFinalPositionWhenEverySampleWasThrottled() async throws {
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        var resolved: [Date] = []
        controller.interactionTestResolver = { date, _ in
            resolved.append(date)
            return nil
        }
        let dates = [10.0, 20.0, 37.0].map { Date(timeIntervalSince1970: 1_700_000_000 + $0) }
        controller.interactionTestDrag(to: dates)
        await controller.interactionTestDrain()
        XCTAssertEqual(resolved, [dates.last!])
    }

    func testCompletedSearchAllowsLaterClickDragAndJumpToNow() async throws {
        for action in ["click", "drag", "now"] {
            let (controller, root) = makeController()
            defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let window = playbackWindow(start: start, meetingID: nil)
            controller.interactionTestPlaybackWindow = { _ in window }
            controller.interactionTestResolver = { _, _ in nil }
            controller.interactionTestStartHistory(window: window, at: start, uptime: 0)
            let searchDate = start.addingTimeInterval(3)
            controller.interactionTestSelectOCR(result(at: searchDate))
            await controller.interactionTestDrain()
            XCTAssertEqual(controller.interactionTestSeekDate, searchDate)
            let pointerDate = start.addingTimeInterval(7)
            switch action {
            case "click": controller.interactionTestClick(to: pointerDate)
            case "drag": controller.interactionTestDrag(to: [pointerDate])
            default: controller.interactionTestJumpToNow()
            }
            await controller.interactionTestDrain()
            XCTAssertEqual(controller.interactionTestSeekDate,
                           action == "now" ? window.validSeekInterval?.end : pointerDate, action)
            XCTAssertEqual(controller.interactionTestIsPinnedToEnd, action == "now", action)
        }
    }

    func testNewClickPreventsPendingSearchMediaFromPublishing() async throws {
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        let searchDate = Date(timeIntervalSince1970: 1_700_000_003)
        let clickDate = searchDate.addingTimeInterval(4)
        let started = expectation(description: "Old search resolver started")
        let returned = expectation(description: "Old resolver returned after new click")
        var resume: CheckedContinuation<HistoricalTimelineMoment?, Never>?
        var prepared: [Date] = []
        controller.interactionTestResolver = { date, _ in
            guard date == searchDate else { return nil }
            let moment = await withCheckedContinuation { continuation in
                resume = continuation
                started.fulfill()
            }
            returned.fulfill()
            return moment
        }
        controller.interactionTestMediaPreparation = { moment in
            prepared.append(moment.wallDate)
            return .init(frameImage: nil, playbackURL: nil, playbackPreparationError: nil)
        }
        controller.interactionTestSelectOCR(result(at: searchDate))
        await fulfillment(of: [started], timeout: 2)
        controller.interactionTestClick(to: clickDate)
        await controller.interactionTestDrain()
        resume?.resume(returning: moment(at: searchDate, root: root))
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(controller.interactionTestSeekDate, clickDate)
        XCTAssertTrue(prepared.isEmpty, "A completed stale search query must not prepare or publish its media")
    }

    func testDisabledSeekUpdatesBlockPointerAndNowWithoutPartialPinning() async throws {
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let window = playbackWindow(start: start, meetingID: nil)
        controller.interactionTestPlaybackWindow = { _ in window }
        controller.interactionTestResolver = { _, _ in nil }
        controller.interactionTestStartHistory(window: window, at: start, uptime: 0)
        let selected = start.addingTimeInterval(3)
        controller.interactionTestSelectOCR(result(at: selected))
        await controller.interactionTestDrain()
        controller.interactionTestSetSeekUpdatesEnabled(false)
        controller.interactionTestClick(to: start.addingTimeInterval(7))
        controller.interactionTestDrag(to: [start.addingTimeInterval(8)])
        controller.interactionTestJumpToNow()
        XCTAssertEqual(controller.interactionTestSeekDate, selected)
        XCTAssertFalse(controller.interactionTestIsPinnedToEnd)
    }

    func testEscapeKeepsPendingPresentationOnlyWhilePinnedTranscriptOwnsIt() async throws {
        for pinned in [false, true] {
            let (controller, root) = makeController()
            defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
            let started = expectation(description: "Media preparation started, pinned=\(pinned)")
            let completed = expectation(description: "Media preparation returned, pinned=\(pinned)")
            var resume: CheckedContinuation<Void, Never>?
            var wasCancelled: Bool?
            let date = Date(timeIntervalSince1970: 1_700_000_040)
            controller.interactionTestResolver = { date, _ in
                self.moment(at: date, root: root)
            }
            controller.interactionTestMediaPreparation = { _ in
                await withCheckedContinuation { continuation in
                    resume = continuation
                    started.fulfill()
                }
                wasCancelled = Task.isCancelled
                completed.fulfill()
                return .init(frameImage: NSImage(size: .init(width: 64, height: 64)),
                             playbackURL: nil, playbackPreparationError: nil)
            }
            if pinned { controller.interactionTestRetainPinnedTranscript() }
            controller.interactionTestSelectOCR(result(at: date))
            await fulfillment(of: [started], timeout: 2)
            controller.interactionTestEscape()
            resume?.resume()
            await fulfillment(of: [completed], timeout: 2)
            await controller.interactionTestDrain()
            XCTAssertEqual(wasCancelled, !pinned)
        }
    }

    func testLiveTrimmingKeepsNextBeltTickContinuous() throws {
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func date(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
        func segment(_ end: Double) -> TimelineSegment {
            .init(startDate: start, endDate: date(end), bundleID: "editor", rawID: 1, rawType: .capturedScreen)
        }
        let window = HistoricalTimelineSegmentWindow(segments: [segment(7200)],
            validSeekInterval: .init(start: start, end: date(7200)),
            playbackFrameDates: stride(from: 0.0, through: 7200, by: 10).map(date))
        controller.interactionTestResolver = { _, _ in nil }
        controller.interactionTestStartHistory(window: window, at: start, uptime: 0)
        XCTAssertEqual(controller.interactionTestAdvanceHistory(at: 1_000_000_000), date(40))
        controller.interactionTestAdmit(.init(id: 722, segmentID: 1, segment: segment(7210),
            createdAt: date(7210), imageFileName: "fixture", context: nil, encodingStatus: "complete"),
            at: 1_000_000_000)
        XCTAssertEqual(controller.interactionTestPresentationInterval?.start, date(10))
        let next = try XCTUnwrap(controller.interactionTestAdvanceHistory(at: 1_100_000_000))
        XCTAssertEqual(next.timeIntervalSince(start), 44, accuracy: 0.00001)
    }

    func testArchiveRestorationRefreshesMeetingGeometryBeforeResolvingMedia() async {
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let old = playbackWindow(start: start, meetingID: nil)
        let restored = playbackWindow(start: start.addingTimeInterval(10_000), meetingID: 42)
        let target = restored.segments[0].startDate.addingTimeInterval(5)
        controller.interactionTestStartHistory(window: old, at: start, uptime: 0)
        controller.interactionTestPlaybackWindow = { _ in restored }
        var meetingIDs: [Int64?] = []
        controller.interactionTestResolver = { _, meetingID in meetingIDs.append(meetingID); return nil }
        await controller.interactionTestRestoreArchive(at: target)
        await controller.interactionTestDrain()
        XCTAssertEqual(controller.interactionTestPresentationInterval?.start, restored.segments[0].startDate)
        XCTAssertEqual(meetingIDs.count, 1)
        XCTAssertEqual(meetingIDs.first!, 42)
    }

    func testSupersededArchiveRestorationCannotReplaceNewSelectionGeometry() async {
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let old = playbackWindow(start: start, meetingID: nil)
        let restored = playbackWindow(start: start.addingTimeInterval(10_000), meetingID: 42)
        let requested = expectation(description: "archive timing requested")
        var resume: CheckedContinuation<Void, Never>?
        controller.interactionTestStartHistory(window: old, at: start, uptime: 0)
        controller.interactionTestResolver = { _, _ in nil }
        controller.interactionTestPlaybackWindow = { _ in
            await withCheckedContinuation { continuation in resume = continuation; requested.fulfill() }
            return restored
        }
        let restore = Task { await controller.interactionTestRestoreArchive(at: restored.segments[0].startDate) }
        await fulfillment(of: [requested], timeout: 2)
        controller.interactionTestDrag(to: [start.addingTimeInterval(5)])
        resume?.resume()
        await restore.value
        XCTAssertEqual(controller.interactionTestPresentationInterval?.start, start)
    }

    func testUnavailableScrollEdgeOffersArchiveDownload() async {
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        let shard = LibreReverseShardInterval(ordinal: 0, epochStart: Date(timeIntervalSince1970: 1_700_000_000))
        let local = playbackWindow(start: shard.end, meetingID: nil)
        controller.interactionTestStartHistory(window: local, at: shard.end, uptime: 0)
        controller.interactionTestPlaybackWindow = { _ in
            .init(segments: local.segments, validSeekInterval: .init(start: shard.start, end: local.segments[0].endDate))
        }
        let ordinal = await controller.interactionTestScrollBeyondEdge(at: shard.end,
            unavailable: .init(ordinal: shard.ordinal, interval: shard))
        XCTAssertEqual(ordinal, shard.ordinal)
    }

    func testNestedReplacementAndMetadataRefreshKeepPresentationClosed() async {
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_700_000_040)
        var preparedCount = 0
        controller.interactionTestResolver = { date, _ in self.moment(at: date, root: root) }
        controller.interactionTestMediaPreparation = { _ in
            preparedCount += 1
            return .init(frameImage: NSImage(size: .init(width: 64, height: 64)),
                playbackURL: nil, playbackPreparationError: nil)
        }
        await controller.prepareForPrimaryReplacement()
        await controller.prepareForPrimaryReplacement()
        await controller.refreshAfterLibraryMutation()
        controller.interactionTestSelectOCR(result(at: date))
        await controller.interactionTestDrain()
        XCTAssertEqual(preparedCount, 0, "Metadata refresh cannot reopen pending replacement")
        await controller.primaryReplacementDidComplete()
        controller.interactionTestSelectOCR(result(at: date))
        await controller.interactionTestDrain()
        XCTAssertEqual(preparedCount, 0, "One completion cannot finish two replacement scopes")
        await controller.primaryReplacementDidComplete()
        controller.interactionTestSelectOCR(result(at: date))
        await controller.interactionTestDrain()
        XCTAssertEqual(preparedCount, 1)
    }

    func testDismissDiscardsStationaryFetchEvenIfItFinishesAfterReopening() async throws {
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        controller.window?.orderFront(nil)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let started = expectation(description: "Stationary fetch started")
        var resume: CheckedContinuation<HistoricalTimelineSegmentWindow, Never>?
        var cancelled = false
        controller.interactionTestTimelineWindow = { _, includesPlaybackTiming in
            XCTAssertFalse(includesPlaybackTiming)
            let result = await withCheckedContinuation { continuation in
                resume = continuation
                started.fulfill()
            }
            cancelled = Task.isCancelled
            return result
        }
        let refresh = Task { await controller.interactionTestRefetchStationaryWindow(around: start) }
        await fulfillment(of: [started], timeout: 2)
        dismissViewer(controller)
        controller.window?.orderFront(nil)
        resume?.resume(returning: playbackWindow(start: start, meetingID: nil))
        await refresh.value
        XCTAssertTrue(cancelled)
        XCTAssertTrue(controller.interactionTestLoadedSegmentIDs.isEmpty,
            "A cancellation-insensitive result from the old visible session must not publish")
    }

    func testPendingFrameStepCannotSeekAfterDismissalOrReopening() async throws {
        for reopen in [false, true] {
            let (controller, root) = makeController()
            defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
            controller.window?.orderFront(nil)
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            controller.interactionTestStartHistory(window: playbackWindow(start: start, meetingID: nil),
                at: start, uptime: 0)
            let started = expectation(description: "Neighbour query started")
            var resume: CheckedContinuation<HistoricalTimelineMoment?, Never>?
            var mediaQueries = 0
            controller.interactionTestNeighbourMoment = { _, _ in
                await withCheckedContinuation { continuation in
                    resume = continuation
                    started.fulfill()
                }
            }
            controller.interactionTestResolver = { _, _ in mediaQueries += 1; return nil }
            let step = Task { await controller.interactionTestStepOneFrame(forward: true) }
            await fulfillment(of: [started], timeout: 2)
            dismissViewer(controller)
            if reopen { controller.window?.orderFront(nil) }
            resume?.resume(returning: moment(at: start.addingTimeInterval(1), root: root))
            await step.value
            await controller.interactionTestDrain()
            XCTAssertEqual(controller.interactionTestSeekDate, start)
            XCTAssertEqual(mediaQueries, 0, "An old frame-step request must not restart decoding")
        }
    }

    func testVisibleFrameStepStillResolvesItsNeighbour() async throws {
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        controller.window?.orderFront(nil)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let window = playbackWindow(start: start, meetingID: nil)
        controller.interactionTestStartHistory(window: window, at: start, uptime: 0)
        controller.interactionTestPlaybackWindow = { _ in window }
        let next = start.addingTimeInterval(1)
        controller.interactionTestNeighbourMoment = { _, _ in self.moment(at: next, root: root) }
        var resolved: [Date] = []
        controller.interactionTestResolver = { date, _ in resolved.append(date); return nil }
        await controller.interactionTestStepOneFrame(forward: true)
        await controller.interactionTestDrain()
        XCTAssertEqual(controller.interactionTestSeekDate, next)
        XCTAssertEqual(resolved, [next])
    }

    func testReopeningFetchesFreshHistoryAfterHiddenAdmissionsWereSkipped() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var storedWindow = playbackWindow(start: start, meetingID: nil)
        var requests: [LibreReverseTimelineReloadRequest] = []
        controller.interactionTestTimelineWindow = { request, includesPlaybackTiming in
            requests.append(request)
            XCTAssertTrue(includesPlaybackTiming)
            return storedWindow
        }
        controller.interactionTestPlaybackWindow = { _ in storedWindow }
        controller.interactionTestResolver = { _, _ in nil }
        controller.present(on: screen, startAtLiveEdge: true, forwardingGlobalScrollEvent: nil)
        await controller.interactionTestDrainReload()
        XCTAssertEqual(controller.interactionTestPresentationInterval, storedWindow.validSeekInterval)
        dismissViewer(controller)
        let oldDate = controller.interactionTestSeekDate
        storedWindow = playbackWindow(start: start.addingTimeInterval(1000), meetingID: nil)
        // Only the backing store changes: continuous hidden admissions are not delivered.
        XCTAssertEqual(controller.interactionTestSeekDate, oldDate)
        controller.present(on: screen, startAtLiveEdge: true, forwardingGlobalScrollEvent: nil)
        await controller.interactionTestDrainReload()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { if case .recent = $0 { return true }; return false })
        XCTAssertEqual(controller.interactionTestPresentationInterval, storedWindow.validSeekInterval)
        XCTAssertEqual(controller.interactionTestSeekDate, storedWindow.validSeekInterval?.end)
    }

    func testScrollingWithinCompleteMeetingRetainsTextWithoutReloadingOrFlashing() async {
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        controller.window?.orderFront(nil)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let window = playbackWindow(start: start, meetingID: 42)
        controller.interactionTestStartHistory(window: window, at: start, uptime: 0)
        let transcript = meetingTranscript(start: start)
        controller.interactionTestPresentTranscript(transcript, at: start)
        var queries = 0
        controller.interactionTestMeetingTranscript = { _, _ in queries += 1; return transcript }
        XCTAssertFalse(controller.interactionTestTranscriptIsHidden)
        for second in [1.0, 2.0, 4.0] {
            controller.interactionTestScrollTranscript(to: start.addingTimeInterval(second))
            XCTAssertTrue(controller.interactionTestTranscriptIsHidden)
            XCTAssertEqual(controller.interactionTestTranscriptSegmentID, 42,
                "Motion hides the floating card without clearing retained text or selection")
        }
        XCTAssertEqual(queries, 0)
        await controller.interactionTestDrainTranscript()
        XCTAssertEqual(queries, 0, "A complete retained transcript should not be queried again on settlement")
        XCTAssertEqual(controller.interactionTestTranscriptSegmentID, 42)
        XCTAssertFalse(controller.interactionTestTranscriptIsHidden)
    }

    func testEnteringMeetingQueriesOnlyTheFinalSettledPosition() async {
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        controller.window?.orderFront(nil)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        controller.interactionTestStartHistory(window: playbackWindow(start: start, meetingID: 42),
            at: start, uptime: 0)
        var queriedDates: [Date] = []
        controller.interactionTestMeetingTranscript = { id, date in
            XCTAssertEqual(id, 42)
            queriedDates.append(date)
            return self.meetingTranscript(start: start)
        }
        for second in [1.0, 3.0, 6.0] {
            controller.interactionTestScrollTranscript(to: start.addingTimeInterval(second))
            XCTAssertTrue(controller.interactionTestTranscriptIsHidden)
        }
        XCTAssertTrue(queriedDates.isEmpty)
        await controller.interactionTestDrainTranscript()
        XCTAssertEqual(queriedDates, [start.addingTimeInterval(6)])
        XCTAssertFalse(controller.interactionTestTranscriptIsHidden)
        controller.interactionTestScrollTranscript(to: start.addingTimeInterval(7))
        await controller.interactionTestDrainTranscript()
        XCTAssertEqual(queriedDates.count, 1, "The same complete meeting is reused across later gestures")
    }

    func testLateTranscriptCannotAppearAfterLeavingMeetingOrDismissingViewer() async {
        for dismiss in [false, true] {
            let (controller, root) = makeController()
            defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
            controller.window?.orderFront(nil)
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            controller.interactionTestStartHistory(window: playbackWindow(start: start, meetingID: 42),
                at: start, uptime: 0)
            let started = expectation(description: "Settled transcript query started")
            var resume: CheckedContinuation<LibreReverseMeetingTranscript?, Never>?
            controller.interactionTestMeetingTranscript = { _, _ in
                await withCheckedContinuation { continuation in resume = continuation; started.fulfill() }
            }
            controller.interactionTestScrollTranscript(to: start.addingTimeInterval(3))
            await fulfillment(of: [started], timeout: 2)
            let pending = controller.interactionTestPendingTranscriptLoad
            if dismiss { dismissViewer(controller) }
            else { controller.interactionTestScrollTranscript(to: start.addingTimeInterval(20)) }
            resume?.resume(returning: meetingTranscript(start: start))
            await pending?.value
            XCTAssertNil(controller.interactionTestTranscriptSegmentID)
            XCTAssertTrue(controller.interactionTestTranscriptIsHidden)
        }
    }

    func testFailedScreenVideoUsesItsOwnStillAndNeverExportsPreviousFrame() async throws {
        for hasFallback in [true, false] {
            let cache = LibreReversePlayerCache(readiness: { _ in false })
            let (controller, root) = makeController(playerCache: cache)
            defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let oldImage = NSImage(size: NSSize(width: 8, height: 8))
            let targetImage = NSImage(size: NSSize(width: 16, height: 16))
            controller.interactionTestResolver = { date, _ in
                if date == start { return self.moment(at: date, root: root) }
                return .init(frameID: 3, wallDate: date, databaseVideoID: nil,
                    chunkURL: root.appendingPathComponent("broken.mp4"),
                    frameImageURL: root.appendingPathComponent("target.png"), mediaTime: 0,
                    videoFrameIndex: 0, videoFrameRate: 30, videoWidth: 16, videoHeight: 16,
                    segmentID: 3, bundleID: nil, segmentStartDate: start, segmentEndDate: date,
                    windowName: nil, browserURL: nil, segmentType: 0, isStarred: false, isPendingImage: false)
            }
            controller.interactionTestMediaPreparation = { moment in
                .init(frameImage: moment.wallDate == start ? oldImage : (hasFallback ? targetImage : nil),
                    playbackURL: moment.chunkURL, playbackPreparationError: nil)
            }
            controller.interactionTestClick(to: start)
            await controller.interactionTestDrain()
            XCTAssertTrue(controller.interactionTestDisplayedImage === oldImage)
            let target = start.addingTimeInterval(1)
            controller.interactionTestClick(to: target)
            await controller.interactionTestDrain()
            XCTAssertEqual(controller.interactionTestSeekDate, target)
            XCTAssertEqual(cache.retainedCount, 0)
            XCTAssertTrue(controller.interactionTestMediaError?.contains("Select this moment again") == true)
            if hasFallback {
                XCTAssertTrue(controller.interactionTestDisplayedImage === targetImage)
                XCTAssertTrue(controller.interactionTestExportImage === targetImage)
            } else {
                XCTAssertNil(controller.interactionTestDisplayedImage)
                XCTAssertNil(controller.interactionTestExportImage)
            }
        }
    }

    func testPrimaryReplacementRejectsLatePlaybackGeometryAndCancelsItsOwner() async {
        let (controller, root) = makeController()
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let old = playbackWindow(start: start, meetingID: nil)
        let stale = playbackWindow(start: start.addingTimeInterval(1000), meetingID: nil)
        controller.interactionTestStartHistory(window: old, at: start, uptime: 0)
        let started = expectation(description: "Playback geometry read suspended")
        var resume: CheckedContinuation<HistoricalTimelineSegmentWindow, Never>?
        controller.interactionTestPlaybackWindow = { _ in
            await withCheckedContinuation { resume = $0; started.fulfill() }
        }
        controller.interactionTestRefreshPlayback(at: stale.segments[0].startDate)
        await fulfillment(of: [started], timeout: 2)
        let pending = controller.interactionTestPendingPlaybackRefresh
        XCTAssertNotNil(pending)
        await controller.prepareForPrimaryReplacement()
        XCTAssertNil(controller.interactionTestPendingPlaybackRefresh)
        XCTAssertTrue(pending?.isCancelled == true)
        resume?.resume(returning: stale)
        await pending?.value
        XCTAssertEqual(controller.interactionTestPresentationInterval, old.validSeekInterval)
        controller.interactionTestRefreshPlayback(at: stale.segments[0].startDate)
        await controller.interactionTestPendingPlaybackRefresh?.value
        XCTAssertEqual(controller.interactionTestPresentationInterval, old.validSeekInterval)
    }

    private func meetingTranscript(start: Date) -> LibreReverseMeetingTranscript {
        .init(segmentID: 42, title: "Weekly review", text: "The captured transcript stays readable.",
            startDate: start, endDate: start.addingTimeInterval(10), words: [], processingState: .complete)
    }

    private func dismissViewer(_ controller: LibreReverseTimelineWindowController) {
        // Escape first dismisses expanded Search, then the viewer itself.
        controller.interactionTestEscape()
        if controller.window?.isVisible == true { controller.interactionTestEscape() }
        XCTAssertFalse(controller.window?.isVisible ?? true)
    }

    private func playbackWindow(start: Date, meetingID: Int64?) -> HistoricalTimelineSegmentWindow {
        .init(segments: [.init(startDate: start, endDate: start.addingTimeInterval(10),
            bundleID: "fixture", rawID: meetingID ?? 1, rawType: meetingID == nil ? .capturedScreen : .audio)],
            validSeekInterval: .init(start: start, end: start.addingTimeInterval(10)),
            playbackFrameDates: [start, start.addingTimeInterval(10)])
    }

    func testQuitDrainsActualStarMutationAndAllowsItsPrimaryReplacementToFinish() async throws {
        let lifetime = LibreReverseUIMutationLifetime()
        let (controller, root) = makeController(mutationLifetime: lifetime, allowsLibraryMutations: true)
        defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
        var installation: LibreReverseInstallationLock? = try .init(directory: root)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let selected = moment(at: date, root: root)
        controller.interactionTestResolver = { _, _ in selected }
        controller.interactionTestMediaPreparation = { _ in
            .init(frameImage: NSImage(size: NSSize(width: 8, height: 8)), playbackURL: nil, playbackPreparationError: nil)
        }
        controller.interactionTestClick(to: date)
        await controller.interactionTestDrain()
        let entered = expectation(description: "accepted write reached persistence boundary")
        var release: CheckedContinuation<Void, Never>?
        var committed = false
        controller.interactionTestStarMutation = { frameID, date, starred in
            // Rename/delete own the same lifetime and may request this barrier.
            // It must not wait on the mutation that requested it.
            await controller.prepareForPrimaryReplacement()
            await withCheckedContinuation { continuation in
                release = continuation
                entered.fulfill()
            }
            committed = true
            await controller.primaryReplacementDidComplete()
            return .init(frameID: frameID, wallDate: date, isStarred: starred, owner: .primary)
        }
        controller.interactionTestSetStarred(true)
        await fulfillment(of: [entered], timeout: 2)
        controller.closeMutationAdmission()
        let tasks = lifetime.beginShutdown()
        XCTAssertEqual(tasks.count, 1)
        do {
            try await lifetime.perform { XCTFail("Quit must reject a newly submitted mutation") }
            XCTFail("Closed mutation owner accepted work")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        var replied = false
        let stopping = expectation(description: "shutdown awaiting admitted mutation")
        let shutdown = Task {
            await LibreReverseShutdownBoundary.complete(backgroundTasks: tasks,
                stopBackground: { stopping.fulfill() }, finishCapture: {
                    XCTAssertTrue(committed)
                }, reply: { installation = nil; replied = true })
        }
        await fulfillment(of: [stopping], timeout: 2)
        XCTAssertFalse(replied)
        XCTAssertNotNil(installation)
        XCTAssertThrowsError(try LibreReverseInstallationLock(directory: root))
        release?.resume()
        await shutdown.value
        await controller.interactionTestPendingStarMutation?.value
        XCTAssertTrue(replied)
        controller.interactionTestSetStarred(false)
        XCTAssertNil(controller.interactionTestPendingStarMutation,
            "The actual star control must keep admission closed after shutdown")
    }

    func testArchiveRequestOpensStorageOnlyForItsStillVisibleSelection() async throws {
        for outcome in ["disconnected", "failure"] {
            for navigation in ["stay", "seek", "dismiss"] {
                var generalOpens = 0
                var storageOpens = 0
                let (controller, root) = makeController(allowsLibraryMutations: true, enablesArchive: true,
                    openSettings: { generalOpens += 1 }, openStorage: { storageOpens += 1 })
                defer { controller.interactionTestTearDown(); try? FileManager.default.removeItem(at: root) }
                let library = LibreReverseLibraryConfiguration(databaseURL: root.appendingPathComponent("library.sqlite3"),
                    keyFileURL: root.appendingPathComponent("key"), mediaRoot: root)
                try LibreReverseLibraryStore.initialize(library)
                controller.window?.hidesOnDeactivate = false
                controller.window?.orderFrontRegardless()
                let date = Date(timeIntervalSince1970: 1_700_000_000)
                controller.interactionTestOfferArchive(date: date, ordinal: 12)
                let started = expectation(description: "archive request suspended")
                var release: CheckedContinuation<Void, Never>?
                var requestCount = 0
                controller.interactionTestArchiveRequest = { requestedDate, ordinal, videoID in
                    requestCount += 1
                    XCTAssertEqual(requestedDate, date)
                    XCTAssertEqual(ordinal, 12)
                    XCTAssertNil(videoID)
                    await withCheckedContinuation { continuation in
                        release = continuation
                        started.fulfill()
                    }
                    if outcome == "failure" { throw CocoaError(.fileWriteUnknown) }
                    return .init(request: .init(date: date, shardOrdinal: 12), phase: .disconnected)
                }
                controller.interactionTestRequestArchive()
                await fulfillment(of: [started], timeout: 2)
                if navigation == "seek" {
                    controller.interactionTestOfferArchive(date: date.addingTimeInterval(3600), ordinal: 13)
                } else if navigation == "dismiss" { controller.dismiss() }
                controller.interactionTestRequestArchive()
                release?.resume()
                await controller.interactionTestPendingArchiveRequest?.value
                XCTAssertEqual(requestCount, 1, "Repeated clicks must not enqueue duplicate work")
                XCTAssertEqual(generalOpens, 0, "Archive repair must route to Storage, not General")
                XCTAssertEqual(storageOpens, outcome == "disconnected" && navigation == "stay" ? 1 : 0)
                if navigation == "seek" {
                    XCTAssertEqual(controller.interactionTestSeekDate, date.addingTimeInterval(3600))
                    XCTAssertNotEqual(controller.interactionTestArchiveTitle, "Couldn’t save this download",
                        "An old failure must not overwrite the newly selected recording")
                }
            }
        }
    }

    private func makeController(playerCache: LibreReversePlayerCache? = nil,
        mutationLifetime: LibreReverseUIMutationLifetime? = nil,
        allowsLibraryMutations: Bool = false,
        enablesArchive: Bool = false,
        openSettings: (() -> Void)? = nil,
        openStorage: (() -> Void)? = nil) -> (LibreReverseTimelineWindowController, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LibreReverseLibraryConfiguration(databaseURL: root.appendingPathComponent("library.sqlite3"),
            keyFileURL: root.appendingPathComponent("key"), mediaRoot: root)
        let controller = LibreReverseTimelineWindowController(dataDirectory: root,
            libraryConfiguration: library, transcriptionQueue: .init(root: root),
            archiveDownloads: enablesArchive ? .init(library: library) : nil,
            openSettingsHandler: openSettings, allowsLibraryMutations: allowsLibraryMutations,
            playerCache: playerCache, mutationLifetime: mutationLifetime,
            openStorageSettingsHandler: openStorage)
        return (controller, root)
    }

    private func result(at date: Date) -> OCRSearchResult {
        .init(result: .init(candidate: .init(docID: 1, frameID: 2, segmentID: 3,
            frameDate: date, bundleID: nil, windowName: nil, text: "result", otherText: ""),
            representativeInstant: date, resolvedTitle: "Result", segmentType: .capturedScreen,
            matchRectangle: nil), firstNode: .init(nodeOrder: 0, textOffset: 0, textLength: 6,
                leftX: 0, topY: 0, width: 1, height: 1, windowIndex: 0))
    }

    private func moment(at date: Date, root: URL) -> HistoricalTimelineMoment {
        .init(frameID: 2, wallDate: date, databaseVideoID: nil, chunkURL: nil,
            frameImageURL: root.appendingPathComponent("frame.png"), mediaTime: nil,
            videoFrameIndex: nil, videoFrameRate: nil, videoWidth: 64, videoHeight: 64,
            segmentID: 3, bundleID: nil, segmentStartDate: nil, segmentEndDate: nil,
            windowName: nil, browserURL: nil, segmentType: 0, isStarred: false, isPendingImage: true)
    }
}
#endif
