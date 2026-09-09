import Foundation

/// Retains accepted writes independently of the view that started them. A
/// pinned transcript can close while its archive mutation is still running.
@MainActor
final class LibreReverseUIMutationLifetime {
    private var accepting = true
    private var drains: [UUID: Task<Void, Never>] = [:]

    func perform<Value: Sendable>(
        _ operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        guard accepting else { throw CancellationError() }
        let id = UUID()
        let task = Task { try await operation() }
        // Cancelling this waiter cannot discard a write already in progress.
        // The write owns its persistence acknowledgement through completion.
        drains[id] = Task { _ = await task.result }
        defer { drains[id] = nil }
        return try await task.value
    }

    /// Only quit closes this owner. A mutation may itself request primary
    /// replacement; draining here from that path would wait on itself.
    func beginShutdown() -> [Task<Void, Never>] {
        accepting = false
        return Array(drains.values)
    }
}
