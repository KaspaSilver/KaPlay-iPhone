import Foundation

/// Which queued send (`ChatService.enqueueOutgoingTxOperation`) the current task is running
/// inside. A queued operation that calls something that queues again (a .kas profile change, a
/// domain transfer, a coin combine) must run that part at once: waiting on the queue it is itself
/// holding would never end.
///
/// The id travels with the task (`@TaskLocal`), and only counts while that operation is still
/// running: a task it started that queues something after it ended waits its turn like any other.
enum OutgoingTxQueueContext {
    @TaskLocal static var operationId: UUID?

    @MainActor private static var running: Set<UUID> = []

    @MainActor static var isInsideRunningOperation: Bool {
        guard let id = operationId else { return false }
        return running.contains(id)
    }

    @MainActor static func run<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        let id = UUID()
        running.insert(id)
        defer { running.remove(id) }
        return try await $operationId.withValue(id) {
            try await operation()
        }
    }
}
