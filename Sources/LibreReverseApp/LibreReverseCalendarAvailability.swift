#if os(macOS)
import Foundation

/// Small UI-owned availability cache. The loader owns each individual read;
/// requests are not shared so cancellation cannot affect another caller.
@MainActor
final class LibreReverseCalendarAvailability {
    private let loader: @Sendable ([DateInterval]) async throws -> [Date]
    private var entries: [[DateInterval]: [Date]] = [:]
    private var recency: [[DateInterval]] = []
    private var generation: UInt64 = 0
    private var requests: [[DateInterval]: UUID] = [:]
    private static let capacity = 32

    init(loader: @escaping @Sendable ([DateInterval]) async throws -> [Date]) {
        self.loader = loader
    }

    func cached(_ periods: [DateInterval]) -> [Date]? {
        guard let value = entries[periods] else { return nil }
        touch(periods)
        return value
    }

    func load(_ periods: [DateInterval]) async throws -> [Date] {
        try Task.checkCancellation()
        if let value = cached(periods) { return value }
        return try await refresh(periods)
    }

    /// Revalidates a visible period while its cached value remains usable.
    func refresh(_ periods: [DateInterval]) async throws -> [Date] {
        try Task.checkCancellation()
        let admittedGeneration = generation
        let requestID = UUID()
        requests[periods] = requestID
        defer {
            if requests[periods] == requestID { requests.removeValue(forKey: periods) }
        }
        let value = try await loader(periods)
        try Task.checkCancellation()
        guard generation == admittedGeneration, requests[periods] == requestID else {
            throw CancellationError()
        }
        entries[periods] = value
        touch(periods)
        if recency.count > Self.capacity {
            entries.removeValue(forKey: recency.removeFirst())
        }
        return value
    }

    func invalidate() {
        generation &+= 1
        requests.removeAll(keepingCapacity: true)
        entries.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
    }

    private func touch(_ periods: [DateInterval]) {
        recency.removeAll { $0 == periods }
        recency.append(periods)
    }
}
#endif
