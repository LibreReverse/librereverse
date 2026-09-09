import Foundation

/// Balances the timeline's primary-database replacement barrier across every
/// operation exit, including thrown errors and cooperative cancellation.
public enum LibreReverseMeetingLibraryMutationScope {
    public static func perform<Result>(
        prepare: () async -> Void,
        complete: () async -> Void,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        await prepare()
        do {
            let result = try await operation()
            await complete()
            return result
        } catch {
            await complete()
            throw error
        }
    }
}

/// Generation ownership for restartable meeting maintenance tasks. A successor
/// may be installed while its cancelled predecessor drains, but only the
/// current generation may clear the stored handle, publish status, or schedule
/// another retry.
public struct LibreReverseMeetingMaintenanceTaskState: Equatable, Sendable {
    public private(set) var generation: UInt64 = 0

    public init() {}

    public mutating func beginTask() -> UInt64 {
        generation &+= 1
        return generation
    }

    public mutating func invalidate() {
        generation &+= 1
    }

    public func owns(_ taskGeneration: UInt64) -> Bool {
        generation == taskGeneration
    }
}
