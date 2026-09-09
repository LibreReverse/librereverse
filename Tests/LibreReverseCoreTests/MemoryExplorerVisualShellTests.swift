import Foundation
import Testing
@testable import LibreReverseCore

@Suite("Memory Explorer visual shell")
struct MemoryExplorerVisualShellTests {
    @Test("Transport modules fit one floating strip and share one mapped baseline")
    func transportGeometry() {
        for width: CGFloat in [640, 982, 1512, 2560] {
            let shell = MemoryExplorerVisualShell.transportFrame(viewportWidth: width)
            let belt = MemoryExplorerVisualShell.timelineShellFrame(viewportWidth: width)
            let readout = MemoryExplorerVisualShell.momentChipFrame(viewportWidth: width)
            let playhead = MemoryExplorerVisualShell.playheadFrame(viewportWidth: width)
            let zoom = MemoryExplorerVisualShell.zoomFrame(viewportWidth: width)
            let overflow = MemoryExplorerVisualShell.overflowFrame(viewportWidth: width)
            #expect(shell.contains(belt))
            #expect(shell.contains(readout))
            #expect(shell.contains(zoom))
            #expect(shell.contains(overflow))
            #expect(readout.maxX < belt.minX)
            let zoomIn = MemoryExplorerVisualShell.zoomInFrame(viewportWidth: width)
            let search = MemoryExplorerVisualShell.searchFrame(viewportWidth: width)
            let dividers = MemoryExplorerVisualShell.moduleDividers(viewportWidth: width)
            #expect(readout.maxX < zoom.minX)
            #expect(zoom.maxX < belt.minX)
            #expect(zoom.midX == zoomIn.midX)
            #expect(zoom.maxY < zoomIn.minY)
            #expect(belt.maxX < search.minX)
            #expect(search.midX == overflow.midX)
            #expect(overflow.maxY < search.minY)
            #expect(search.midY == zoomIn.midY)
            #expect(overflow.midY == zoom.midY)
            #expect(zoom.union(zoomIn).midY == shell.midY)
            #expect(overflow.union(search).midY == shell.midY)
            #expect(dividers[0].height == dividers[1].height)
            #expect(dividers[0].minY == dividers[1].minY)
            #expect(shell.contains(zoomIn))
            #expect(shell.contains(search))
            #expect(playhead.midX == belt.midX)
            #expect(playhead.midY == MemoryExplorerVisualShell.timelineCenterFromBottom)
            #expect(shell.minY > 0)
            #expect(shell.height == 80)
        }
        #expect(MemoryExplorerVisualShell.gradientMaximumBlackAlpha == 0)
        #expect(MemoryExplorerVisualShell.expandedSearchFrame(in: CGSize(width: 1512, height: 982))
            == CGRect(x: 506, y: 434, width: 500, height: 114))
    }

    @Test("Scrubbing minimizes search and its affordance restores it")
    func searchPresentation() {
        var presentation = MemoryExplorerSearchPresentation.expanded
        presentation.apply(.timelineScrubbed)
        #expect(presentation == .collapsed)
        presentation.apply(.collapsedSearchActivated)
        #expect(presentation == .expanded)
        presentation.apply(.explorerPresented)
        #expect(presentation == .expanded)
    }

    @Test("Playhead formatter preserves exact signed thresholds")
    func playheadFormatterDecisionTree() {
        let now = Date(timeIntervalSinceReferenceDate: 100_000)

        #expect(PlayheadTimeText.presentation(for: nil, relativeTo: now) == .empty)
        #expect(
            PlayheadTimeText.presentation(
                for: now.addingTimeInterval(-2.999),
                relativeTo: now
            ) == .now
        )
        #expect(
            PlayheadTimeText.presentation(
                for: now.addingTimeInterval(2.999),
                relativeTo: now
            ) == .now
        )

        let exactlyThreeSecondsPast = now.addingTimeInterval(-3)
        #expect(
            PlayheadTimeText.presentation(
                for: exactlyThreeSecondsPast,
                relativeTo: now
            ) == .relative(exactlyThreeSecondsPast, relativeTo: now)
        )

        let exactlyOneHourPast = now.addingTimeInterval(-3_600)
        #expect(
            PlayheadTimeText.presentation(
                for: exactlyOneHourPast,
                relativeTo: now
            ) == .relative(exactlyOneHourPast, relativeTo: now)
        )

        let olderThanOneHour = now.addingTimeInterval(-3_600.001)
        #expect(
            PlayheadTimeText.presentation(
                for: olderThanOneHour,
                relativeTo: now
            ) == .absolute(olderThanOneHour)
        )

        let farFuture = now.addingTimeInterval(86_400)
        #expect(
            PlayheadTimeText.presentation(
                for: farFuture,
                relativeTo: now
            ) == .relative(farFuture, relativeTo: now)
        )
        #expect(PlayheadTimeText.absoluteDateFormat == "MMM d h:mm a")
    }

    @Test("Zoom control scalars match the recovered SwiftUI composition")
    func zoomControlContract() {
        #expect(TimelineZoomControlContract.expandedMaximumWidth == 200)
        #expect(TimelineZoomControlContract.symbolSize == 16)
        #expect(TimelineZoomControlContract.minimumLeadingPadding == 2)
        #expect(TimelineZoomControlContract.minimumTrailingPadding == 6)
        #expect(TimelineZoomControlContract.maximumLeadingPadding == 6)
        #expect(TimelineZoomControlContract.maximumTrailingPadding == 2)
        #expect(TimelineZoomControlContract.springResponse == 0.5)
        #expect(TimelineZoomControlContract.springDampingFraction == 1)
        #expect(TimelineZoomControlContract.springBlendDuration == 0)
        #expect(TimelineZoomControlContract.animationSpeed == 2)
        #expect(TimelineZoomControlContract.dismissalDelay == 5)
    }
}
