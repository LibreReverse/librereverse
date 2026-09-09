#if os(macOS)
import XCTest
import AppKit
@testable import LibreReverseApp
@testable import LibreReverseCore

final class SearchViewTests: XCTestCase {
    func testApplicationSelectionEnablesAppsAndExcludesMeetings() {
        let state = LibreReverseSearchOverlayState(
            query: "review",
            filters: [.meetings, .starred],
            applicationBundleIDs: ["com.google.Chrome"]
        )

        XCTAssertEqual(state.filters, [.apps, .starred])
        XCTAssertEqual(state.searchFacets.applicationBundleIDs, ["com.google.Chrome"])
        XCTAssertFalse(state.searchFacets.isTranscript)
        XCTAssertTrue(state.searchFacets.isStarred)
    }

    func testMeetingAndStarredFacetsRemainComposable() {
        let state = LibreReverseSearchOverlayState(
            query: "decision",
            filters: [.meetings, .starred]
        )

        XCTAssertEqual(
            state.searchFacets.effectiveApplicationBundleIDs,
            [SearchFacets.meetingRecorderBundleID]
        )
        XCTAssertTrue(state.searchFacets.isTranscript)
        XCTAssertTrue(state.searchFacets.isStarred)
    }

    @MainActor
    func testSearchInputAndEvidenceListShareCompactWidth() {
        let overlay = LibreReverseSearchOverlayView()
        let results = LibreReverseSearchResultsView()

        XCTAssertEqual(overlay.intrinsicContentSize.width, 500)
        XCTAssertEqual(results.intrinsicContentSize.width, 500)
        XCTAssertEqual(LibreReverseSearchResultsView.preferredSize.height, 278)
    }

    @MainActor
    func testAppsFacetLabelTracksZeroOneAndMultipleSelections() {
        let overlay = LibreReverseSearchOverlayView()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let buttons = descendants(overlay).compactMap { $0 as? NSButton }
        let facet = buttons.first { $0.title == "Apps  ⌄" }!
        overlay.setState(.init(applicationBundleIDs: ["com.apple.Notes"]))
        XCTAssertEqual(facet.title, "1 app  ⌄")
        overlay.setState(.init(applicationBundleIDs: ["com.apple.Notes", "com.apple.Safari"]))
        XCTAssertEqual(facet.title, "2 apps  ⌄")
        overlay.setState(.init())
        XCTAssertEqual(facet.title, "Apps  ⌄")
    }

    @MainActor
    func testAppsPickerKeepsRowsDirectlyBelowFilterAndPreservesSelection() {
        _ = NSApplication.shared
        let picker = LibreReverseSearchApplicationFacetView(options: [
            .init(bundleID: "com.apple.Notes", title: "Notes", count: 4),
            .init(bundleID: "com.apple.Safari", title: "Safari", count: 2)],
            selectedBundleIDs: ["com.apple.Notes"])
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 220, height: 310),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = picker
        picker.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let scroll = descendants(picker).compactMap { $0 as? NSScrollView }.first!
        let rows = descendants(picker).compactMap { $0 as? NSButton }
        let first = rows.first { $0.title == "Notes" }!
        XCTAssertEqual(first.convert(first.bounds, to: picker).maxY, scroll.frame.maxY, accuracy: 0.5)
        XCTAssertEqual(first.state, .on)
        picker.filterForValidation("Safari")
        XCTAssertTrue(first.isHidden)
        XCTAssertFalse(rows.first { $0.title == "Safari" }!.isHidden)
        window.orderOut(nil)
    }

    func testTranscriptSnippetKeepsLateMatchVisibleAndUnicodeIntact() {
        let transcript = String(repeating: "Earlier discussion. ", count: 80) + "We agreed on café 🚀 launch for Friday."
        let snippet = LibreReverseSearchSnippet.text(in: transcript, query: "CAFE")
        XCTAssertTrue(snippet.contains("café 🚀 launch"))
        XCTAssertTrue(snippet.hasPrefix("… "))
        XCTAssertLessThanOrEqual(snippet.count, 163)
        XCTAssertEqual(LibreReverseSearchSnippet.text(in: "Short note", query: "missing"), "Short note")
    }

    func testOCRSnippetFollowsTheMatchedNodeInsteadOfDocumentPrefix() {
        let prefix = String(repeating: "unrelated opening text ", count: 40)
        let candidate = HistoricalSearchCandidate(docID: 1, frameID: 2, segmentID: 3,
            frameDate: Date(), bundleID: "com.apple.Notes", windowName: "Launch review",
            text: prefix + "launch checklist 🚀 approved for Friday", otherText: "")
        let result = OCRSearchResult(result: .init(candidate: candidate, representativeInstant: Date(),
            resolvedTitle: "Launch review", segmentType: .capturedScreen, matchRectangle: nil),
            firstNode: .init(nodeOrder: 1, textOffset: prefix.utf16.count, textLength: 38,
                leftX: 0.2, topY: 0.2, width: 0.3, height: 0.05, windowIndex: 0))
        let snippet = LibreReverseSearchSnippet.text(for: result)
        XCTAssertTrue(snippet.contains("launch checklist 🚀"))
        XCTAssertTrue(snippet.hasPrefix("… "))
        XCTAssertLessThan(snippet.utf16.count, 190)
    }

    @MainActor
    func testFooterActionsUseExistingResultAndAskCallbacksWithoutEagerPreviewLoading() async {
        _ = NSApplication.shared
        let candidate = HistoricalSearchCandidate(docID: 1, frameID: 2, segmentID: 3,
            frameDate: Date(), bundleID: "com.apple.Notes", windowName: "Launch review",
            text: "launch checklist", otherText: "")
        let result = OCRSearchResult(result: .init(candidate: candidate, representativeInstant: Date(),
            resolvedTitle: "Launch review", segmentType: .capturedScreen, matchRectangle: nil),
            firstNode: .init(nodeOrder: 0, textOffset: 0, textLength: 16,
                leftX: 0.2, topY: 0.2, width: 0.3, height: 0.05, windowIndex: 0))
        let view = LibreReverseSearchResultsView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 278),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        var selected: OCRSearchResult?
        var asked = false
        var previewRequests = 0
        view.onSelect = { selected = $0 }
        view.onAsk = { asked = true }
        view.previewProvider = { _ in previewRequests += 1; return nil }
        view.show(results: [result])
        view.layoutSubtreeIfNeeded()
        await Task.yield()
        XCTAssertEqual(previewRequests, 0, "Listing results must not eagerly read/decode screenshot previews")
        func buttons(_ view: NSView) -> [NSButton] {
            view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) }
        }
        buttons(view).first { $0.title == "Open moment" }?.performClick(nil)
        buttons(view).first { $0.title == "Ask AI" }?.performClick(nil)
        XCTAssertEqual(selected, result)
        XCTAssertTrue(asked)
        view.show(results: [])
        XCTAssertFalse(buttons(view).first { $0.title == "Open moment" }?.isEnabled ?? true)
    }

    @MainActor
    func testSearchCompositionStaysCenteredAcrossResultHeightsAndHeaderOnlyState() {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1_180, height: 850))
        let window = NSWindow(contentRect: content.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = content
        defer { window.orderOut(nil) }
        let overlay = LibreReverseSearchOverlayView()
        let results = LibreReverseSearchResultsView()
        content.addSubview(overlay)
        content.addSubview(results)
        let headerCenter = overlay.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        let compositionCenter = LibreReverseSearchCompositionLayout.centeredResultsConstraint(
            overlay: overlay, results: results, in: content)
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            overlay.heightAnchor.constraint(equalToConstant: LibreReverseSearchOverlayView.preferredSize.height),
            results.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            results.topAnchor.constraint(equalTo: overlay.bottomAnchor),
            compositionCenter,
        ])
        let candidate = HistoricalSearchCandidate(docID: 1, frameID: 2, segmentID: 3,
            frameDate: Date(), bundleID: "com.apple.Notes", windowName: "Launch review",
            text: "meeting checklist", otherText: "")
        let result = OCRSearchResult(result: .init(candidate: candidate, representativeInstant: Date(),
            resolvedTitle: "Launch review", segmentType: .capturedScreen, matchRectangle: nil),
            firstNode: .init(nodeOrder: 0, textOffset: 0, textLength: 17,
                leftX: 0.2, topY: 0.2, width: 0.3, height: 0.05, windowIndex: 0))
        for count in [0, 1, 3, 8, 0] {
            results.show(results: Array(repeating: result, count: count))
            content.layoutSubtreeIfNeeded()
            let card = overlay.frame.union(results.frame)
            XCTAssertEqual(card.midX, content.bounds.midX, accuracy: 0.5)
            XCTAssertEqual(card.midY, content.bounds.midY, accuracy: 0.5)
            XCTAssertEqual(card.width, 500, accuracy: 0.5)
            XCTAssertEqual(card.height, 86 + (count == 0 ? 184 : CGFloat(min(3, count)) * 79 + 41), accuracy: 0.5)
        }
        compositionCenter.isActive = false
        headerCenter.isActive = true
        results.isHidden = true
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(overlay.frame.midY, content.bounds.midY, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.midX, content.bounds.midX, accuracy: 0.5)
    }

    func testCaptureFreeFixtureCoversEverySearchPresentationState() {
        XCTAssertEqual(
            ["results", "apps", "loading", "empty", "error"].compactMap(
                LibreReverseSearchFixtureWindowController.State.init(rawValue:)
            ).count,
            5
        )
    }
}
#endif
