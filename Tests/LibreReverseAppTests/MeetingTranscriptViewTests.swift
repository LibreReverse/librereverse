import AppKit
import XCTest

@testable import LibreReverseApp
import LibreReverseCore

@MainActor
final class MeetingTranscriptViewTests: XCTestCase {
    func testKnownSourcesRenderDistinctlyWhileUnknownWordsRemainNeutral() throws {
        let view = makeView()
        view.present(transcript(), at: start.addingTimeInterval(1.5))
        let textView = try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSTextView }.first)
        let rendered = try XCTUnwrap(textView.textStorage)

        XCTAssertEqual(rendered.string, "mine theirs neutral")
        XCTAssertEqual(
            rendered.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor,
            NSColor.systemCyan.withAlphaComponent(0.14)
        )
        // The active second word must override its source tint with the active
        // playback highlight rather than layering two ambiguous backgrounds.
        XCTAssertEqual(
            rendered.attribute(.backgroundColor, at: 5, effectiveRange: nil) as? NSColor,
            NSColor.systemYellow.withAlphaComponent(0.34)
        )
        XCTAssertNil(rendered.attribute(.backgroundColor, at: 12, effectiveRange: nil))
        XCTAssertTrue(
            descendants(of: view)
                .compactMap { $0 as? NSTextField }
                .compactMap(\.toolTip)
                .contains(where: { $0.contains("You/Others") })
        )
    }

    func testPlaybackHighlightPreservesSelectionAndFontMetrics() throws {
        let view = makeView()
        view.present(transcript(), at: start)
        let textView = try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSTextView }.first)
        let storage = try XCTUnwrap(textView.textStorage)
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        textView.setSelectedRange(NSRange(location: 0, length: 4))

        view.updatePlayback(at: start.addingTimeInterval(1.5))

        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 4))
        XCTAssertEqual(storage.string, "mine theirs neutral")
        XCTAssertEqual(storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont, font)
        XCTAssertEqual(storage.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor,
            NSColor.systemCyan.withAlphaComponent(0.14))
        XCTAssertEqual(storage.attribute(.backgroundColor, at: 5, effectiveRange: nil) as? NSColor,
            NSColor.systemYellow.withAlphaComponent(0.34))
    }

    func testMetadataOnlyRefreshPreservesNativeTextSelection() throws {
        let view = makeView()
        let original = transcript()
        view.present(original, at: start)
        let textView = try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSTextView }.first)
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        let updated = LibreReverseMeetingTranscript(
            segmentID: original.segmentID,
            title: original.title,
            text: original.text,
            startDate: original.startDate,
            endDate: original.endDate,
            words: original.words,
            metadata: .init(
                provider: .zoom,
                calendarTitle: "Work",
                participants: ["Ada", "Grace"]
            ),
            processingState: original.processingState
        )

        view.present(updated, at: start)

        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 4))
        XCTAssertTrue(
            descendants(of: view)
                .compactMap { $0 as? NSTextField }
                .map(\.stringValue)
                .contains(where: { $0.contains("Zoom") && $0.contains("2 participants") })
        )
    }

    func testPinPresentationCopiesTranscriptAndExposesAccessibleToggle() throws {
        let source = makeView()
        source.onTogglePlayback = {}
        source.onTogglePin = {}
        source.present(transcript(), at: start.addingTimeInterval(1.5))
        source.setPlaybackAvailable(true)

        let destination = makeView()
        destination.onTogglePlayback = {}
        destination.onTogglePin = {}
        XCTAssertTrue(source.copyPresentation(to: destination))
        destination.setPinned(true)

        XCTAssertEqual(destination.presentedSegmentID, 42)
        XCTAssertEqual(destination.presentedDate, start.addingTimeInterval(1.5))
        let pin = try XCTUnwrap(
            descendants(of: destination)
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "timeline.meetingTranscript.pin" }
        )
        XCTAssertEqual(pin.accessibilityLabel(), "Unpin meeting transcript")
        XCTAssertTrue(pin.isEnabled)
        XCTAssertEqual(pin.contentTintColor, NSColor.systemBlue)
    }

    func testPinnedTranscriptWindowIsMovableResizableAndNotAlwaysOnTop() throws {
        let view = makeView()
        view.onTogglePin = {}
        view.present(transcript(), at: start)
        view.setPinned(true)
        let controller = LibreReversePinnedTranscriptWindowController(transcriptView: view)
        let window = try XCTUnwrap(controller.window)

        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(window.minSize, NSSize(width: 360, height: 260))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.frame, window.contentView?.bounds)
        XCTAssertEqual(view.layer?.cornerRadius, 0)
        XCTAssertEqual(view.layer?.borderWidth, 0)
    }

    func testDeletionNotifiesPinnedOwnerOnceAndStaleDeletionKeepsNewSelection() {
        let view = makeView()
        view.present(transcript(), at: start)
        view.setPinned(true)
        var closures = 0
        view.onTranscriptCleared = {
            closures += 1
            XCTAssertNil(view.presentedSegmentID)
        }
        // A different meeting's delayed completion must leave this one open.
        view.applyCompletedDeletion(segmentID: 99)
        XCTAssertEqual(view.presentedSegmentID, 42)
        XCTAssertEqual(closures, 0)
        view.applyCompletedDeletion(segmentID: 42)
        XCTAssertNil(view.presentedSegmentID)
        XCTAssertTrue(view.isHidden)
        XCTAssertEqual(closures, 1)
        view.clear()
        XCTAssertEqual(closures, 1)
        view.onTranscriptCleared = nil
    }

    func testHeaderDragReportsIncrementalWindowCoordinatesWithoutChangingTranscript() throws {
        let view = makeView()
        view.present(transcript(), at: start)
        var deltas: [NSSize] = []
        view.onDrag = { deltas.append($0) }
        let header = try XCTUnwrap(descendants(of: view).first {
            $0.accessibilityIdentifier() == "timeline.meetingTranscript.drag"
        })
        func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0))
        }
        header.mouseDown(with: try event(.leftMouseDown, x: 100, y: 100))
        header.mouseDragged(with: try event(.leftMouseDragged, x: 120, y: 115))
        header.mouseDragged(with: try event(.leftMouseDragged, x: 126, y: 110))
        header.mouseUp(with: try event(.leftMouseUp, x: 126, y: 110))
        XCTAssertEqual(deltas, [NSSize(width: 20, height: 15), NSSize(width: 6, height: -5)])
        XCTAssertEqual(view.presentedSegmentID, 42)
    }

    func testSecondaryMeetingActionsRemainAvailableWithMutationPermissions() {
        let view = makeView()
        view.onRename = { _, title in title }
        view.onUpdateContext = { _, names, calendar in .init(participants: names, calendarTitle: calendar) }
        view.onDelete = { _ in }
        view.present(transcript(), at: start)
        let actions = view.makeActionsMenu().items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(actions.map(\.title), ["Rename meeting…", "Edit meeting details…", "Export transcript…", "Delete meeting…"])
        XCTAssertTrue(actions.allSatisfy { $0.isEnabled && $0.action != nil && $0.target != nil })
        view.onRename = nil
        view.onUpdateContext = nil
        view.onDelete = nil
        view.present(transcript(), at: start)
        let disabled = view.makeActionsMenu().items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(disabled.map(\.isEnabled), [false, false, true, false])
    }

    func testExportPanelExposesAllFormatsAndEncodesTheNativeSelection() throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Product.review.txt"
        LibreReverseTranscriptExportPanel.configure(panel)
        XCTAssertTrue(panel.showsContentTypes)
        XCTAssertEqual(panel.allowedContentTypes.compactMap(\.preferredFilenameExtension), ["txt", "vtt", "json"])
        XCTAssertEqual(LibreReverseTranscriptExportPanel.selectedFormat(in: panel), .plainText)
        XCTAssertEqual(panel.nameFieldStringValue, "Product.review.txt")
        panel.currentContentType = panel.allowedContentTypes[1]
        let subtitles = try LibreReverseMeetingTranscriptExport.data(transcript(),
            format: LibreReverseTranscriptExportPanel.selectedFormat(in: panel))
        XCTAssertTrue(String(decoding: subtitles, as: UTF8.self).hasPrefix("WEBVTT"))
        panel.currentContentType = panel.allowedContentTypes[2]
        let metadata = try LibreReverseMeetingTranscriptExport.data(transcript(),
            format: LibreReverseTranscriptExportPanel.selectedFormat(in: panel))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: metadata) as? [String: Any])
    }

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeView() -> LibreReverseMeetingTranscriptView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 320))
        let view = LibreReverseMeetingTranscriptView(frame: host.bounds)
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        return view
    }

    private func transcript() -> LibreReverseMeetingTranscript {
        LibreReverseMeetingTranscript(
            segmentID: 42,
            title: "Source fixture",
            text: "mine theirs neutral",
            startDate: start,
            endDate: start.addingTimeInterval(20),
            words: [
                .init(
                    id: 1,
                    speechSource: "me",
                    text: "mine",
                    startSeconds: 0,
                    durationSeconds: 1,
                    fullTextUTF16Offset: 0
                ),
                .init(
                    id: 2,
                    speechSource: "others",
                    text: "theirs",
                    startSeconds: 1,
                    durationSeconds: 1,
                    fullTextUTF16Offset: 5
                ),
                .init(
                    id: 3,
                    speechSource: "unknown",
                    text: "neutral",
                    startSeconds: 2,
                    durationSeconds: 1,
                    fullTextUTF16Offset: 12
                ),
            ],
            processingState: .complete
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
