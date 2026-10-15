import Foundation
import Network

@MainActor
protocol NetworkLocationProviding {
    func current() async -> NetworkLocation?
}

@MainActor
final class NetworkLocationStore: NetworkLocationProviding {
    private let lookup: () async throws -> NetworkLocation
    private let now: () -> Date
    private let cacheLifetime: TimeInterval
    private let retryDelay: TimeInterval
    private var cached: NetworkLocation?
    private var expiresAt: Date?
    private var pending: PendingLookup?
    private var generation = 0
    private var pathMonitor: NWPathMonitor?
    private var lastPath: NWPath?

    nonisolated private struct PendingLookup {
        let id = UUID()
        let generation: Int
        let task: Task<NetworkLocation?, Never>
    }

    init(cacheLifetime: TimeInterval = 300, retryDelay: TimeInterval = 30,
         now: @escaping () -> Date = Date.init,
         monitorsNetworkChanges: Bool = false,
         lookup: @escaping () async throws -> NetworkLocation) {
        self.cacheLifetime = cacheLifetime
        self.retryDelay = retryDelay
        self.now = now
        self.lookup = lookup
        if monitorsNetworkChanges {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor [weak self] in self?.networkPathDidChange(path) }
            }
            pathMonitor = monitor
            monitor.start(queue: DispatchQueue(label: "com.dramaplayfun.network-location"))
        }
    }

    static func live(bundle: Bundle = .main) -> NetworkLocationStore {
        let lookup = NetworkLocationLookup.fromBundle(bundle)
        return NetworkLocationStore(monitorsNetworkChanges: true) { try await lookup.fetch() }
    }

    deinit {
        pathMonitor?.cancel()
        pending?.task.cancel()
    }

    func current() async -> NetworkLocation? {
        guard !Task.isCancelled else { return nil }
        if let expiresAt, now() < expiresAt { return cached }

        let request: PendingLookup
        if let pending {
            request = pending
        } else {
            request = PendingLookup(generation: generation, task: Task { [lookup] in
                try? await lookup()
            })
            pending = request
        }
        let result = await request.task.value
        // A cancelled caller must not cancel a lookup shared by other requests.
        guard generation == request.generation else { return nil }
        if pending?.id == request.id {
            cached = result
            expiresAt = now().addingTimeInterval(result == nil ? retryDelay : cacheLifetime)
            pending = nil
        }
        return Task.isCancelled ? nil : result
    }

    func invalidate() {
        generation += 1
        cached = nil
        expiresAt = nil
        pending?.task.cancel()
        pending = nil
    }

    private func networkPathDidChange(_ path: NWPath) {
        if let lastPath, lastPath != path { invalidate() }
        lastPath = path
    }
}
