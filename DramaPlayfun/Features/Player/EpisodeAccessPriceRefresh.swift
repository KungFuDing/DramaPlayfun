import Foundation

/// Shares only the in-flight price lookup so parallel permission denials do not
/// cancel each other's forced detail refresh. Successful responses are not cached.
@MainActor
final class EpisodeAccessPriceRefresh {
    private typealias Response = APIModels.V1GetDramaEpisodeListRes
    private typealias Waiter = CheckedContinuation<Response, Error>

    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
    }

    private var flight: Flight?

    func load(_ operation: @escaping @MainActor () async throws -> APIModels.V1GetDramaEpisodeListRes) async throws -> APIModels.V1GetDramaEpisodeListRes {
        try Task.checkCancellation()
        let waiterID = UUID()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: Waiter) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                join(waiterID: waiterID, continuation: continuation, operation: operation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(waiterID) }
        }
        try Task.checkCancellation()
        return response
    }

    func cancel() {
        guard let previous = flight else { return }
        flight = nil
        previous.task.cancel()
        for waiter in previous.waiters.values { waiter.resume(throwing: CancellationError()) }
    }

    private func join(waiterID: UUID, continuation: Waiter,
                      operation: @escaping @MainActor () async throws -> Response) {
        if var existing = flight {
            existing.waiters[waiterID] = continuation
            flight = existing
            return
        }
        let id = UUID()
        let task = Task {
            let result: Result<Response, Error>
            do {
                let response = try await operation()
                try Task.checkCancellation()
                result = .success(response)
            } catch {
                result = .failure(error)
            }
            finish(id: id, result: result)
        }
        flight = Flight(id: id, task: task, waiters: [waiterID: continuation])
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard var current = flight,
              let waiter = current.waiters.removeValue(forKey: waiterID) else { return }
        if current.waiters.isEmpty {
            flight = nil
            current.task.cancel()
        } else {
            flight = current
        }
        waiter.resume(throwing: CancellationError())
    }

    private func finish(id: UUID, result: Result<Response, Error>) {
        guard let completed = flight, completed.id == id else { return }
        flight = nil
        for waiter in completed.waiters.values { waiter.resume(with: result) }
    }
}
