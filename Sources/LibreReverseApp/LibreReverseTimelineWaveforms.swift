#if os(macOS)
import Foundation
import LibreReverseCore

/// Prepares only visible local meetings. Drawing consumes immutable envelopes;
/// neither the renderer nor this coordinator can request archive hydration.
@MainActor
final class LibreReverseTimelineWaveforms {
    typealias Resolve = (TimelineSegment) async -> HistoricalTimelineMoment?
    private struct Key: Hashable {
        let id: Int64
        let start: Date
        let end: Date
        let children: [Int64]
        init(_ segment: TimelineSegment) {
            id = segment.rawID; start = segment.startDate; end = segment.endDate
            children = segment.mergedSegmentIDs ?? [segment.rawID]
        }
    }
    private let resolve: Resolve
    private let cache = MeetingWaveformCache()
    private var envelopes: [Key: MeetingWaveformEnvelope] = [:]
    private var visibleKeys: [Key] = []
    private var unavailableUntil: [Key: Date] = [:]
    private var generation: UInt64 = 0
    private var preparation: Task<Void, Never>?
    var onChange: (() -> Void)?

    init(resolve: @escaping Resolve) { self.resolve = resolve }

    func envelope(for segment: TimelineSegment) -> MeetingWaveformEnvelope? {
        envelopes[Key(segment)]
    }

    func update(visible: [TimelineSegment], rawSegments: [TimelineSegment], force: Bool = false) {
        let keys = visible.map(Key.init)
        guard keys != visibleKeys || (force && preparation == nil) else { return }
        visibleKeys = keys
        generation &+= 1
        let revision = generation
        preparation?.cancel()
        // Retain a small working set across nearby pans, without accumulating a
        // whole library's envelopes in a long-lived explorer window.
        if envelopes.count > 32 { envelopes = envelopes.filter { keys.contains($0.key) } }
        let now = Date()
        unavailableUntil = unavailableUntil.filter { $0.value > now }
        let pending = visible.filter { envelopes[Key($0)] == nil && unavailableUntil[Key($0)] == nil }
        guard !pending.isEmpty else { preparation = nil; return }
        let resolve = resolve, cache = cache
        preparation = Task { [weak self] in
            defer { if self?.generation == revision { self?.preparation = nil } }
            for display in pending {
                guard !Task.isCancelled else { return }
                let ids = Set(display.mergedSegmentIDs ?? [display.rawID])
                var children = rawSegments.filter { ids.contains($0.rawID) && $0.rawType == .audio }
                if children.isEmpty && ids == [display.rawID] { children = [display] }
                guard Set(children.map(\.rawID)) == ids else { continue }
                var parts: [MeetingWaveformEnvelope.Part] = []
                var complete = true
                for child in children {
                    guard !Task.isCancelled else { return }
                    guard let moment = await resolve(child), let url = moment.chunkURL,
                        url.isFileURL,
                        let envelope = await cache.envelope(forLocalMediaURL: url),
                        !envelope.peaks.isEmpty else {
                        // Unavailable audio must never masquerade as measured
                        // silence in a merged meeting's unfilled sections.
                        complete = false
                        break
                    }
                    let mediaOrigin = moment.wallDate.addingTimeInterval(-(moment.mediaTime ?? 0))
                    parts.append(.init(envelope: envelope,
                        startOffset: mediaOrigin.timeIntervalSince(display.startDate)))
                }
                guard !Task.isCancelled else { return }
                if complete, !parts.isEmpty {
                    let duration = display.endDate.timeIntervalSince(display.startDate)
                    let readyParts = parts
                    let envelope = await Task.detached(priority: .utility) {
                        MeetingWaveformEnvelope.combining(readyParts, duration: duration)
                    }.value
                    guard !Task.isCancelled, let self, self.generation == revision else { return }
                    self.envelopes[Key(display)] = envelope
                    self.onChange?()
                } else if let self, self.generation == revision {
                    // Missing legacy metadata is a supported state. Repeated
                    // seeks must not requery the DB or reread identity bytes.
                    self.unavailableUntil[Key(display)] = Date().addingTimeInterval(30)
                }
            }
        }
    }

    /// Media became locally available after an earlier metadata-only miss.
    /// This is an explicit lifecycle event, never an ordinary scrub sample.
    func retry(visible: [TimelineSegment], rawSegments: [TimelineSegment]) {
        for segment in visible { unavailableUntil[Key(segment)] = nil }
        preparation?.cancel()
        preparation = nil
        visibleKeys = []
        update(visible: visible, rawSegments: rawSegments, force: true)
    }

    #if DEBUG
    func waitForPreparationForTesting() async { await preparation?.value }
    #endif

    func suspend() {
        generation &+= 1
        preparation?.cancel()
        preparation = nil
        visibleKeys = []
        unavailableUntil = [:]
        // Cancel metadata work owned by this explorer without affecting another
        // window. Neither this cache nor a cache miss ever decodes audio.
        let cache = cache
        Task { await cache.cancelAll() }
    }
}
#endif
