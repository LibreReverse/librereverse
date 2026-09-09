#if os(macOS)
import Foundation

/// Serializes the ownership boundary between ordinary sparse screenshots and
/// dense meeting capture. Meeting startup first closes sparse admission and
/// waits for every admitted screenshot to finish. Sparse admission reopens only
/// after the dense writer has finalized, preventing a task queued on the old
/// side of the boundary from capturing on the new side.
public actor LibreReverseMeetingCaptureHandoff {
    private var sparseCaptureCount = 0
    private var meetingCapturePending = false
    private var drainWaiter:
        (
            id: UUID,
            continuation: CheckedContinuation<Bool, Never>
        )?

    public init() {}

    public func beginSparseCapture() -> Bool {
        guard !meetingCapturePending else { return false }
        sparseCaptureCount += 1
        return true
    }

    public func finishSparseCapture() {
        guard sparseCaptureCount > 0 else { return }
        sparseCaptureCount -= 1
        guard sparseCaptureCount == 0 else { return }
        guard let drainWaiter else { return }
        self.drainWaiter = nil
        drainWaiter.continuation.resume(returning: true)
    }

    /// Closes sparse admission and waits for already-admitted screenshots.
    /// Exactly one meeting acquisition may own this boundary. Cancellation
    /// while draining resumes the waiter with `false` and reopens sparse
    /// admission instead of stranding shutdown or the ordinary recorder.
    public func beginMeetingCapture() async -> Bool {
        guard !Task.isCancelled, !meetingCapturePending else { return false }
        meetingCapturePending = true
        guard sparseCaptureCount > 0 else { return true }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    meetingCapturePending = false
                    continuation.resume(returning: false)
                } else {
                    drainWaiter = (waiterID, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelDrainWaiter(waiterID) }
        }
    }

    public func finishMeetingCapture() {
        if let drainWaiter {
            self.drainWaiter = nil
            drainWaiter.continuation.resume(returning: false)
        }
        meetingCapturePending = false
    }

    public var sparseCapturesInFlight: Int { sparseCaptureCount }
    public var meetingOwnsCapture: Bool { meetingCapturePending }

    private func cancelDrainWaiter(_ waiterID: UUID) {
        guard let drainWaiter, drainWaiter.id == waiterID else { return }
        self.drainWaiter = nil
        meetingCapturePending = false
        drainWaiter.continuation.resume(returning: false)
    }
}
#endif
