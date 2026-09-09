import Foundation

/// A quit reply releases installation ownership, so it must follow both
/// background cancellation acknowledgement and final capture persistence.
@MainActor
enum LibreReverseShutdownBoundary {
    static func complete(
        backgroundTasks: [Task<Void, Never>],
        stopBackground: () async -> Void,
        finishCapture: () async -> Void,
        reply: () -> Void
    ) async {
        for task in backgroundTasks { task.cancel() }
        await stopBackground()
        for task in backgroundTasks { await task.value }
        await finishCapture()
        reply()
    }
}
