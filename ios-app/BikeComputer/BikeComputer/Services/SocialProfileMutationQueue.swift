import Foundation

/// Profile fields, preferences and avatars share the server's profile version.
/// Each edit must read the version returned by the preceding accepted edit.
@MainActor
final class SocialProfileMutationQueue {
    private var tail: Task<Void, Never>?

    func perform(
        generation: UUID,
        currentGeneration: @escaping @MainActor @Sendable () -> UUID,
        operation: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        let previous = tail
        let task = Task { @MainActor in
            _ = await previous?.value
            guard generation == currentGeneration() else { throw SocialFailure.accountChanged }
            try await operation()
            guard generation == currentGeneration() else { throw SocialFailure.accountChanged }
        }
        tail = Task { @MainActor in _ = try? await task.value }
        try await task.value
    }
}
