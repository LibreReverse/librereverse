import Foundation
import Testing
@testable import LibreReverseCore

@Suite("Recovered Memory Explorer lifecycle")
struct MemoryExplorerLifecycleTests {
    private let display = MemoryExplorerWindowContract.Display(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949)
    )

    @Test("Timeline window configuration")
    func flags() {
        #expect(MemoryExplorerWindowContract.styleMask == 32_768)
        #expect(MemoryExplorerWindowContract.level == 97)
        #expect(MemoryExplorerWindowContract.collectionBehavior == 256)
        #expect(MemoryExplorerWindowContract.activationPolicy == 1)
        #expect(MemoryExplorerWindowContract.hidesOnDeactivate)
        #expect(!MemoryExplorerWindowContract.releasedWhenClosed)
    }

    @Test("Entrance is one top-system-inset below the steady display frame")
    func entranceGeometry() {
        #expect(display.topSystemInset == 33)
        #expect(
            MemoryExplorerWindowContract.entranceFrame(on: display)
                == CGRect(x: 0, y: -33, width: 1512, height: 982)
        )
        #expect(
            MemoryExplorerWindowContract.steadyFrame(on: display)
                == CGRect(x: 0, y: 0, width: 1512, height: 982)
        )
    }

    @Test("Presentation orders, settles, activates, and focuses search")
    func presentation() {
        var lifecycle = MemoryExplorerLifecycle()
        lifecycle.orderFront(on: display)
        #expect(lifecycle.phase == .orderedAtEntranceFrame)
        #expect(lifecycle.frame?.origin.y == -33)

        lifecycle.finishPresentation(on: display)
        #expect(lifecycle.phase == .activeAndSearchFocused)
        #expect(lifecycle.frame == display.frame)
    }

    @Test(arguments: [
        MemoryExplorerLifecycle.Dismissal.escape,
        .applicationDeactivated,
        .screenParametersChanged
    ])
    func dismissal(reason: MemoryExplorerLifecycle.Dismissal) {
        var lifecycle = MemoryExplorerLifecycle()
        lifecycle.orderFront(on: display)
        lifecycle.finishPresentation(on: display)
        lifecycle.dismiss(reason)
        #expect(lifecycle.phase == .hidden)
    }
}
