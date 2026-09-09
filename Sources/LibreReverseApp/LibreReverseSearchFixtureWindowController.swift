#if os(macOS)
import AppKit
import LibreReverseCore

/// Capture-free harness for reviewing the exact Search views shipped in the
/// timeline. It intentionally owns no library, recorder, permission, archive,
/// calendar, transcription, or network object.
@MainActor
final class LibreReverseSearchFixtureWindowController: NSWindowController {
    enum State: String {
        case results
        case ocr
        case previewMeeting = "preview-meeting"
        case previewOCR = "preview-ocr"
        case appsSelected = "apps-selected"
        case appsFiltered = "apps-filtered"
        case apps
        case loading
        case empty
        case error
    }

    private var isApps: Bool { [.apps, .appsSelected, .appsFiltered].contains(fixtureState) }
    private let overlay = LibreReverseSearchOverlayView()
    private let results = LibreReverseSearchResultsView()
    private let fixtureState: State

    init(state: State) {
        fixtureState = state
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 850),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "LibreReverse Search"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(
            srgbRed: BrandVibrancyBackgroundContract.brandBlackRed,
            green: BrandVibrancyBackgroundContract.brandBlackGreen,
            blue: BrandVibrancyBackgroundContract.brandBlackBlue,
            alpha: 1
        )
        super.init(window: window)
        buildContent()
        applyFixtureState()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window else { return }
        window.center()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(nil)
        if isApps {
            window.contentView?.layoutSubtreeIfNeeded()
            overlay.presentApplicationPickerForValidation()
            if fixtureState == .appsFiltered { overlay.filterApplicationsForValidation("Chrome") }
        }
        if fixtureState == .previewMeeting || fixtureState == .previewOCR {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.results.presentFirstPreviewForValidation() }
        }
        if let destination = LibreReverseDevelopmentEnvironment.values[
            "LIBREREVERSE_SEARCH_UI_FIXTURE_SCREENSHOT"
        ], !destination.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.writeScreenshot(to: destination)
            }
        }
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = window?.backgroundColor.cgColor

        content.addSubview(overlay)
        content.addSubview(results)
        overlay.setResultsPresented(!isApps)
        results.isHidden = isApps

        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            isApps
                ? overlay.centerYAnchor.constraint(equalTo: content.centerYAnchor)
                : LibreReverseSearchCompositionLayout.centeredResultsConstraint(
                    overlay: overlay, results: results, in: content),
            overlay.heightAnchor.constraint(
                equalToConstant: LibreReverseSearchOverlayView.preferredSize.height
            ),
            results.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            results.topAnchor.constraint(equalTo: overlay.bottomAnchor),
        ])

    }

    private func applyFixtureState() {
        overlay.setAvailableApplicationCounts(Self.applicationOptions.map {
            .init(bundleID: $0.bundleID, count: $0.count)
        })

        switch fixtureState {
        case .results, .previewMeeting:
            var state = LibreReverseSearchOverlayState(query: "meeting")
            state.filters.insert(.meetings)
            results.query = state.query
            overlay.setState(state)
            results.show(transcriptResults: Self.transcriptResults())
        case .apps, .appsSelected, .appsFiltered:
            overlay.setState(.init(applicationBundleIDs: fixtureState == .appsSelected ? ["com.google.Chrome"] : []))
        case .ocr, .previewOCR:
            overlay.setState(.init(query: "launch"))
            results.query = "launch"
            let instant = Date(timeIntervalSince1970: 1_777_124_400)
            let candidate = HistoricalSearchCandidate(docID: 1, frameID: 1, segmentID: 1,
                frameDate: instant, bundleID: "com.apple.Notes", windowName: "Launch checklist",
                text: "Launch checklist: review the design and verify the app.", otherText: "")
            let result = OCRSearchResult(result: .init(candidate: candidate, representativeInstant: instant,
                resolvedTitle: "Launch checklist", segmentType: .capturedScreen, matchRectangle: nil),
                firstNode: .init(nodeOrder: 0, textOffset: 0, textLength: 16,
                    leftX: 0.0625, topY: 0.16, width: 0.39, height: 0.1, windowIndex: 0))
            results.previewProvider = { _ in
                NSImage(size: NSSize(width: 640, height: 400), flipped: false) { rect in
                    NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); rect.fill()
                    ("Launch checklist" as NSString).draw(at: NSPoint(x: 40, y: 300), withAttributes: [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.white])
                    ("Review the design and verify the app." as NSString).draw(at: NSPoint(x: 40, y: 240), withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.lightGray])
                    return true
                }
            }
            results.show(results: [result])
        case .loading:
            overlay.setState(.init(query: "meeting"))
            results.showLoading()
        case .empty:
            overlay.setState(.init(query: "no matching phrase"))
            results.show(results: [])
        case .error:
            overlay.setState(.init(query: "quarterly plan"))
            results.show(error: FixtureError())
        }
    }

    private func writeScreenshot(to destination: String) {
        guard let content = window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        guard let representation = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return }
        content.cacheDisplay(in: content.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: URL(fileURLWithPath: destination))
    }

    private static func transcriptResults() -> [TranscriptSearchResult] {
        let snippets = [
            "We should make meeting capture feel invisible, then let the transcript become the durable memory of the conversation.",
            "The daily recap needs to turn a busy day into a clear story: focused work, meetings, and the moments worth returning to.",
            "Keep the interface slim. Search should reveal meeting context quickly without taking over the timeline underneath it.",
            "Compatibility matters because existing transcripts and archived history should continue to open exactly where people expect.",
            "The next milestone is validation against real calls, including long sessions, device changes, and interrupted connectivity.",
            "Once the capture path is solid, polish the result cards, keyboard flow, empty states, and opening a selected moment.",
        ]
        let base = Date(timeIntervalSince1970: 1_777_124_400)
        let titles = ["Product review", "Weekly planning", "Interface review", "Archive compatibility", "Capture validation", "Launch planning"]
        return snippets.enumerated().map { index, snippet in
            let instant = base.addingTimeInterval(TimeInterval(-index * 1_140))
            let candidate = HistoricalSearchCandidate(
                docID: Int64(index + 1),
                frameID: nil,
                segmentID: Int64(900 + index),
                frameDate: instant,
                bundleID: SearchFacets.meetingRecorderBundleID,
                windowName: titles[index],
                segmentType: .audio,
                text: snippet,
                otherText: ""
            )
            return TranscriptSearchResult(
                result: PopulatedSearchResult(
                    candidate: candidate,
                    representativeInstant: instant,
                    resolvedTitle: titles[index],
                    segmentType: .audio,
                    matchRectangle: nil,
                    transcriptDetails: .init(
                        id: Int64(2_000 + index),
                        transcript: snippet,
                        matchInstant: instant
                    )
                )
            )
        }
    }

    private static let applicationOptions: [LibreReverseSearchApplicationOption] = [
        .init(bundleID: "com.google.Chrome", title: "Chrome", count: 42),
        .init(bundleID: "com.apple.Notes", title: "Notes", count: 18),
        .init(bundleID: "com.microsoft.VSCode", title: "Code", count: 15),
        .init(bundleID: "com.apple.finder", title: "Finder", count: 12),
        .init(bundleID: "com.hnc.Discord", title: "Discord", count: 9),
        .init(bundleID: "com.apple.MobileSMS", title: "Messages", count: 7),
        .init(bundleID: "dev.warp.Warp-Stable", title: "Warp", count: 5),
    ]

    private struct FixtureError: LocalizedError {
        var errorDescription: String? {
            "Search couldn’t load these results. Check your library and try again."
        }
    }
}
#endif
