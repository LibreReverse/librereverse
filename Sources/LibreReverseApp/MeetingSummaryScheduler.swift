import Foundation
import os
import LibreReverseCore

/// Owns summary work from admission through provider cancellation and durable
/// completion. A stopped runner must finish before another runner can start.
@MainActor
final class MeetingSummaryScheduler {
    struct Summary {
        let text: String
        let isLocal: Bool
    }

    struct BatchResult {
        var completed = 0
        var failed = 0
    }

    private let onStopped: () -> Void
    private let loadJobs: () throws -> [LibreReverseMeetingSummaryJob]
    private let summarize: (LibreReverseMeetingSummaryJob) async throws -> Summary
    private let finish: (LibreReverseMeetingSummaryJob, Summary?) throws -> Void
    private let wait: () async throws -> Void
    private let onBatchFinished: (BatchResult) -> Void
    private var runner: Task<Void, Never>?

    convenience init(configuration: LibreReverseLibraryConfiguration,
                     onBatchFinished: @escaping (BatchResult) -> Void) {
        let session = LibreReverseLibraryWriteSession(configuration: configuration)
        self.init(loadJobs: {
            try LibreReverseLibraryStore.pendingMeetingSummaries(configuration: configuration, session: session)
        }, summarize: { job in
            // A settings change during the request cannot relabel its result.
            let profile = LibreReverseAIProfiles.selected()
            let text = try await LibreReverseAIService.summarize(job.transcript,
                profile: profile, configuration: configuration)
            return Summary(text: text, isLocal: profile.provider == .local)
        }, finish: { job, summary in
            try LibreReverseLibraryStore.finishMeetingSummary(eventID: job.eventID,
                text: summary?.text, configuration: configuration,
                isLocal: summary?.isLocal ?? true, session: session)
        }, onStopped: { session.close() }, onBatchFinished: onBatchFinished)
    }

    init(loadJobs: @escaping () throws -> [LibreReverseMeetingSummaryJob],
         summarize: @escaping (LibreReverseMeetingSummaryJob) async throws -> Summary,
         finish: @escaping (LibreReverseMeetingSummaryJob, Summary?) throws -> Void,
         wait: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 15_000_000_000) },
         onStopped: @escaping () -> Void = {},
         onBatchFinished: @escaping (BatchResult) -> Void = { _ in }) {
        self.onStopped = onStopped
        self.loadJobs = loadJobs
        self.summarize = summarize
        self.finish = finish
        self.wait = wait
        self.onBatchFinished = onBatchFinished
    }

    func start() {
        guard runner == nil else { return }
        runner = Task { [self] in
            defer { onStopped(); runner = nil }
            await run()
        }
    }

    func cancel() { runner?.cancel() }

    func stop() async {
        let current = runner
        current?.cancel()
        await current?.value
        // The task clears itself before completing. Do not clear here: a
        // caller may already have started a successor while this await yields.
    }

    private func run() async {
        while !Task.isCancelled {
            var result = BatchResult()
            do {
                let signposter = OSSignposter(subsystem: "local.librereverse", category: .pointsOfInterest)
                let poll = signposter.beginInterval("SummaryQueuePoll", id: signposter.makeSignpostID())
                let jobs: [LibreReverseMeetingSummaryJob]
                do {
                    defer { signposter.endInterval("SummaryQueuePoll", poll) }
                    jobs = try loadJobs()
                }
                for job in jobs {
                    try Task.checkCancellation()
                    do {
                        let summary = try await summarize(job)
                        try Task.checkCancellation()
                        try finish(job, summary)
                        result.completed += 1
                    } catch {
                        guard !Task.isCancelled else { return }
                        // Provider and persistence errors never log transcripts,
                        // tokens, URLs, or provider response bodies.
                        do {
                            try finish(job, nil)
                            result.failed += 1
                        } catch { /* The next poll retries queue access. */ }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
            }
            if result.completed > 0 || result.failed > 0 { onBatchFinished(result) }
            do { try await wait() } catch { return }
        }
    }
}
