#if os(macOS)
import Foundation
import Observation
import RubienCore

/// Coalesces requests from lazily displayed rows and caches even empty results.
@MainActor @Observable
final class LibrarySearchExcerptLoader {
    private(set) var excerpts: [Int64: LibrarySearchExcerpt] = [:]
    @ObservationIgnored private var pending: [Int64: Reference] = [:]
    @ObservationIgnored private var requested: Set<Int64> = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    func reset() {
        generation &+= 1
        task?.cancel()
        task = nil
        pending = [:]
        requested = []
        excerpts = [:]
    }

    func request(
        _ reference: Reference,
        load: @escaping @Sendable ([Reference]) async throws -> [Int64: LibrarySearchExcerpt]
    ) {
        guard let id = reference.id, requested.insert(id).inserted else { return }
        pending[id] = reference
        guard task == nil else { return }
        let generation = generation
        task = Task { [weak self] in
            // Rows appearing in the same layout pass share one database read.
            try? await Task.sleep(for: .milliseconds(25))
            guard !Task.isCancelled, let self else { return }
            defer { if self.generation == generation { self.task = nil } }
            while !self.pending.isEmpty, !Task.isCancelled {
                let batch = Array(self.pending.values)
                self.pending = [:]
                do {
                    let fetched = try await load(batch)
                    guard !Task.isCancelled, self.generation == generation else { return }
                    self.excerpts.merge(fetched) { _, new in new }
                } catch {
                    // Excerpts are supplementary; the matching references stay usable.
                    guard !Task.isCancelled, self.generation == generation else { return }
                }
            }
        }
    }

    deinit { task?.cancel() }
}
#endif
