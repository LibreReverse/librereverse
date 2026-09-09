import AppKit
import XCTest
import LibreReverseCore
@testable import LibreReverseApp

@MainActor
final class MeetingTimelineAppearanceTests: XCTestCase {
    func testMeetingLabelRemainsAnchoredWhileVisibleFragmentChanges() {
        let content = NSRect(x: 0, y: 0, width: 1000, height: 32)
        for x in stride(from: 0.0, through: 300, by: 10) {
            XCTAssertEqual(LibreReverseAudioSegmentDrawingView.labelOrigin(content: content,
                visible: NSRect(x: x, y: 0, width: 700, height: 32), width: 200), 400)
        }
        XCTAssertEqual(LibreReverseAudioSegmentDrawingView.labelOrigin(content: content,
            visible: NSRect(x: 500, y: 0, width: 500, height: 32), width: 200), 510)
    }

    func testRepeatedDrawingAndUpdatedTitleMatchFreshView() throws {
        func makeView(title: String, appearance: NSAppearance.Name) -> LibreReverseAudioSegmentDrawingView {
            let view = LibreReverseAudioSegmentDrawingView(frame: NSRect(x: 0, y: 0, width: 420, height: 81))
            update(view, title: title, appearance: appearance)
            return view
        }
        func update(_ view: LibreReverseAudioSegmentDrawingView, title: String, appearance: NSAppearance.Name) {
            view.appearance = NSAppearance(named: appearance)
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            view.presentation = .init(segment: .init(startDate: start, endDate: start.addingTimeInterval(240),
                bundleID: "app.librereverse.meeting", windowName: title,
                rawID: 1, rawType: .audio), selected: true, onClick: { _, _ in })
        }
        func pixels(_ view: LibreReverseAudioSegmentDrawingView) throws -> Data {
            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            NSColor.gray.setFill()
            view.bounds.fill()
            view.appearance?.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
            image.unlockFocus()
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let view = makeView(title: "Initial title", appearance: .darkAqua)
        let first = try pixels(view)
        XCTAssertEqual(try pixels(view), first)
        update(view, title: "A much longer meeting title after rename", appearance: .aqua)
        let updated = try pixels(view)
        XCTAssertNotEqual(updated, first)
        XCTAssertEqual(updated, try pixels(makeView(title: "A much longer meeting title after rename", appearance: .aqua)))
    }

    func testMeetingTrackRendersInIsolation() throws {
        let view = LibreReverseAudioSegmentDrawingView(frame: NSRect(x: 0, y: 0, width: 420, height: 81))
        view.appearance = NSAppearance(named: .darkAqua)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        view.presentation = .init(segment: .init(startDate: start, endDate: start.addingTimeInterval(240),
            bundleID: "app.librereverse.meeting", windowName: "Weekly planning — release review",
            rawID: 1, rawType: .audio), selected: true, onClick: { _, _ in })
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        view.bounds.fill()
        view.appearance?.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
        image.unlockFocus()
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        if let path = ProcessInfo.processInfo.environment["LIBREREVERSE_MEETING_TRACK_PREVIEW"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path))
        }
    }
    func testSilentRecordingUsesSameFilamentAsPendingEnvelopeAndSpeechUsesRealBars() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let segment = TimelineSegment(startDate: start, endDate: start.addingTimeInterval(4),
            bundleID: "app.librereverse.meeting", contiguousStartOffset: 0, contiguousEndOffset: 4,
            windowName: "Design review", rawID: 4, rawType: .audio)
        let view = LibreReverseAudioSegmentDrawingView(frame: NSRect(x: 0, y: 0, width: 420, height: 52))
        view.appearance = NSAppearance(named: .darkAqua)
        func render(_ envelope: MeetingWaveformEnvelope?) throws -> Data {
            view.presentation = .init(segment: segment, selected: false, waveform: envelope,
                wallDateAtOffset: { start.addingTimeInterval($0) }, onClick: { _, _ in })
            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            NSColor.black.setFill()
            view.bounds.fill()
            view.draw(view.bounds)
            image.unlockFocus()
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let pending = try render(nil)
        let silence = try render(.init(duration: 4, binDuration: 1, peaks: Data([0, 0, 0, 0])))
        XCTAssertEqual(silence, pending, "Silence keeps the capture microdots, with persistent meeting boundary gates")
        let speech = try render(.init(duration: 4, binDuration: 1, peaks: Data([0, 255, 64, 0])))
        XCTAssertNotEqual(speech, silence, "The displayed waveform must come from recording peaks")
        XCTAssertTrue(view.toolTip?.contains("Design review") == true)
        XCTAssertTrue(view.toolTip?.contains("–") == true)
        XCTAssertTrue(view.accessibilityPerformPress())
    }

}
