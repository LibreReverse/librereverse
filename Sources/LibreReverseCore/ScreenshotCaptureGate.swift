public enum ScreenshotAdmissionDecision: Equatable, Sendable {
    case admitted
    case dropped
}

/// Serializes sparse screenshot work across asynchronous timer ticks. Rejected
/// ticks do not queue work or increase capacity: the current capture must finish
/// before another can enter the recorder and its difference detector.
public actor ScreenshotCaptureGate {
    private var captureInFlight = false
    private var stopped = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func beginScreenshot() -> ScreenshotAdmissionDecision {
        guard !stopped, !captureInFlight else { return .dropped }
        captureInFlight = true
        return .admitted
    }

    public func finishScreenshot() {
        precondition(captureInFlight, "unbalanced screenshot completion")
        captureInFlight = false
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Permanently closes admission before shutdown/reset and waits for durable
    /// work already admitted, including detached PNG writes, to finish. Task
    /// cancellation must not let the caller finalize/delete storage early.
    public func stopAndDrain() async {
        stopped = true
        guard captureInFlight else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }
}
