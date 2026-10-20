import Foundation
import CryptoKit

/// Shares detail requests between feed prefetching and playback, including across app launches.
@MainActor
final class PlaybackDetailCache {
    private typealias Response = APIModels.V1GetDramaEpisodeListRes

    private struct Flight {
        let id: UUID
        let task: Task<Response, Error>
    }

    private let network: APIClient
    private let disk: PlaybackDetailDisk
    private let maxAge: TimeInterval
    private let capacity: Int
    private let now: () -> Date
    private var scope: String
    private var memory: [PlaybackDetailKey: PlaybackDetailEntry] = [:]
    private var flights: [PlaybackDetailKey: Flight] = [:]
    private var prefetchSlots: [PlaybackDetailKey: UUID] = [:]
    private var prefetchWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var epoch = UUID()
    private var revisions: [PlaybackDetailKey: UUID] = [:]
    private var diskBarrier: Task<Void, Never>?

    init(network: APIClient, directory: URL? = nil, maxAge: TimeInterval = 300,
         capacity: Int = 60, now: @escaping () -> Date = Date.init) {
        self.network = network
        self.maxAge = max(0, maxAge)
        self.capacity = max(1, capacity)
        self.now = now
        scope = network.playbackCacheScope
        let root = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlaybackDetails-v1", isDirectory: true)
        disk = PlaybackDetailDisk(directory: root, capacity: max(1, capacity))
    }

    func load(dramaID: String, forceRefresh: Bool = false) async throws -> APIModels.V1GetDramaEpisodeListRes {
        try Task.checkCancellation()
        guard let numericID = Int64(dramaID), numericID > 0 else { throw CatalogError.notFound }
        synchronizeScope()
        let key = PlaybackDetailKey(scope: scope, dramaID: String(numericID))
        if forceRefresh { invalidate(key) }
        if var entry = memory[key], entry.isFresh(at: now(), maxAge: maxAge) {
            entry.accessedAt = now()
            memory[key] = entry
            return entry.response
        }
        memory[key] = nil
        let startedEpoch = epoch
        let revision = revisions[key]
        let flight: Flight
        if let existing = flights[key] {
            flight = existing
        } else {
            let id = UUID()
            // An unstructured task belongs to the cache, not to a scrolling cell's lifetime.
            let task = Task { try await self.fetch(key, numericID: numericID, id: id, forceRefresh: forceRefresh) }
            flight = Flight(id: id, task: task)
            flights[key] = flight
        }
        let response = try await flight.task.value
        // Cancelled screens never receive a successful result, while the shared work can finish.
        try Task.checkCancellation()
        guard network.playbackCacheScope == key.scope, epoch == startedEpoch,
              revisions[key] == revision else { throw CancellationError() }
        return response
    }

    func prefetch(dramaID: String) async {
        guard !Task.isCancelled, let numericID = Int64(dramaID), numericID > 0 else { return }
        synchronizeScope()
        let key = PlaybackDetailKey(scope: scope, dramaID: String(numericID))
        let startedEpoch = epoch
        let revision = revisions[key]
        while true {
            guard !Task.isCancelled, epoch == startedEpoch, revisions[key] == revision,
                  network.playbackCacheScope == key.scope else { return }
            // Existing work is free to share; speculative new requests have a global bound.
            if flights[key] != nil {
                _ = try? await load(dramaID: dramaID)
                return
            }
            if prefetchSlots.count < 2 { break }
            do { try await waitForPrefetchSlot() }
            catch { return }
        }
        let slot = UUID()
        prefetchSlots[key] = slot
        defer {
            if prefetchSlots[key] == slot {
                prefetchSlots[key] = nil
                resumePrefetchWaiters()
            }
        }
        _ = try? await load(dramaID: dramaID)
    }

    func invalidate(dramaID: String) {
        guard let numericID = Int64(dramaID), numericID > 0 else { return }
        synchronizeScope()
        invalidate(PlaybackDetailKey(scope: scope, dramaID: String(numericID)))
    }

    func clear() async {
        epoch = UUID()
        revisions.removeAll()
        memory.removeAll()
        prefetchSlots.removeAll()
        resumePrefetchWaiters(throwing: CancellationError())
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
        let operation = enqueueDisk { await $0.clear() }
        await operation.value
    }

    func diskSize() async -> UInt {
        await diskBarrier?.value
        return await disk.size()
    }

    /// Keep renewed signed URLs without extending the authorization/detail response's lifetime.
    func updatePlaybackURLs(dramaID: String, replacing: [String: URL], with urls: [String: URL]) async {
        guard let numericID = Int64(dramaID), numericID > 0, !urls.isEmpty else { return }
        synchronizeScope()
        let key = PlaybackDetailKey(scope: scope, dramaID: String(numericID))
        let startedEpoch = epoch
        let revision = revisions[key]
        guard flights[key] == nil else { return }
        var existing = memory[key]
        if existing == nil {
            await diskBarrier?.value
            existing = await disk.read(key, now: now(), maxAge: maxAge)
        }
        guard network.playbackCacheScope == key.scope, epoch == startedEpoch,
              revisions[key] == revision, flights[key] == nil,
              var entry = memory[key] ?? existing, entry.isFresh(at: now(), maxAge: maxAge),
              var episodes = entry.response.episodes else { return }
        var changed = false
        for index in episodes.indices {
            guard let id = episodes[index].episodeId.map(String.init),
                  let previous = replacing[id], let replacement = urls[id],
                  episodes[index].videoUrl.flatMap(URL.init(string:)) == previous else { continue }
            episodes[index].videoUrl = replacement.absoluteString
            changed = true
        }
        guard changed else { return }
        entry.response.episodes = episodes
        remember(entry)
        let saved = entry
        let maxAge = maxAge
        let date = now()
        await enqueueDisk { await $0.write(saved, now: date, maxAge: maxAge) }.value
    }

    private func synchronizeScope() {
        let current = network.playbackCacheScope
        guard scope != current else { return }
        scope = current
        epoch = UUID()
        revisions.removeAll()
        memory.removeAll()
        prefetchSlots.removeAll()
        resumePrefetchWaiters(throwing: CancellationError())
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
    }

    private func invalidate(_ key: PlaybackDetailKey) {
        revisions[key] = UUID()
        memory[key] = nil
        flights.removeValue(forKey: key)?.task.cancel()
        enqueueDisk { await $0.remove(key) }
    }

    private func fetch(_ key: PlaybackDetailKey, numericID: Int64, id: UUID,
                       forceRefresh: Bool) async throws -> Response {
        defer {
            if flights[key]?.id == id { flights[key] = nil }
        }
        await diskBarrier?.value
        try validate(key, id: id)
        if !forceRefresh, let entry = await disk.read(key, now: now(), maxAge: maxAge) {
            try validate(key, id: id)
            remember(entry)
            return entry.response
        }
        try validate(key, id: id)
        let response = try await network.request(AppAPI.v1ClientDramaEpisodeList,
            body: .init(dramaId: numericID), unwrapEnvelope: true)
        try validate(key, id: id)
        if PlaybackDetailEntry.isCacheable(response, dramaID: numericID) {
            let entry = PlaybackDetailEntry(key: key, storedAt: now(), accessedAt: now(), response: response)
            remember(entry)
            // Serialize writes with invalidation so a late response cannot restore deleted data.
            let maxAge = maxAge
            let operation = enqueueDisk { await $0.write(entry, now: entry.storedAt, maxAge: maxAge) }
            await operation.value
            try validate(key, id: id)
        }
        return response
    }

    private func validate(_ key: PlaybackDetailKey, id: UUID) throws {
        try Task.checkCancellation()
        guard network.playbackCacheScope == key.scope, flights[key]?.id == id else { throw CancellationError() }
    }

    private func remember(_ entry: PlaybackDetailEntry) {
        memory[entry.key] = entry
        memory = memory.filter { $0.value.isFresh(at: now(), maxAge: maxAge) }
        while memory.count > capacity,
              let oldest = memory.min(by: { $0.value.accessedAt < $1.value.accessedAt })?.key {
            memory[oldest] = nil
        }
    }

    private func waitForPrefetchSlot() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard prefetchSlots.count >= 2 else { return }
            try await withCheckedThrowingContinuation { continuation in
                prefetchWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.prefetchWaiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
            }
        }
    }

    private func resumePrefetchWaiters(throwing error: Error? = nil) {
        let waiters = prefetchWaiters.values
        prefetchWaiters.removeAll()
        // Every resumed caller checks capacity again. Waking all prevents a cancelled
        // waiter from consuming the only wakeup while a live candidate remains asleep.
        for waiter in waiters {
            if let error { waiter.resume(throwing: error) }
            else { waiter.resume() }
        }
    }

    @discardableResult
    private func enqueueDisk(_ operation: @escaping @Sendable (PlaybackDetailDisk) async -> Void) -> Task<Void, Never> {
        let previous = diskBarrier
        let disk = disk
        let task = Task {
            await previous?.value
            await operation(disk)
        }
        diskBarrier = task
        return task
    }
}

nonisolated private struct PlaybackDetailKey: Codable, Hashable, Sendable {
    let scope: String
    let dramaID: String

    var filename: String {
        SHA256.hash(data: Data("\(scope)\n\(dramaID)".utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }
}

nonisolated private struct PlaybackDetailEntry: Codable, Sendable {
    let key: PlaybackDetailKey
    let storedAt: Date
    var accessedAt: Date
    var response: APIModels.V1GetDramaEpisodeListRes

    func isFresh(at now: Date, maxAge: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(storedAt)
        return age >= 0 && age < maxAge
    }

    static func isCacheable(_ response: APIModels.V1GetDramaEpisodeListRes, dramaID: Int64) -> Bool {
        guard response.dramaId == nil || response.dramaId == dramaID,
              let episodes = response.episodes, !episodes.isEmpty else { return false }
        // A metadata-only/malformed response must not pin an unplayable source in cache.
        guard episodes.contains(where: {
            guard let raw = $0.videoUrl, let url = URL(string: raw) else { return false }
            return url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
                && url.user == nil && url.password == nil
        }) else { return false }
        var seen: Set<Int> = []
        return episodes.allSatisfy {
            guard let id = $0.episodeId, id > 0, let number = $0.episodeNo, number > 0 else { return false }
            return seen.insert(id).inserted
        }
    }
}

/// All encoding and filesystem work executes off the main actor.
private actor PlaybackDetailDisk {
    private let directory: URL
    private let capacity: Int

    init(directory: URL, capacity: Int) {
        self.directory = directory
        self.capacity = capacity
    }

    func read(_ key: PlaybackDetailKey, now: Date, maxAge: TimeInterval) -> PlaybackDetailEntry? {
        let url = directory.appendingPathComponent(key.filename)
        guard let data = try? Data(contentsOf: url),
              var entry = try? JSONDecoder().decode(PlaybackDetailEntry.self, from: data),
              entry.key == key, entry.isFresh(at: now, maxAge: maxAge),
              let numericID = Int64(key.dramaID),
              PlaybackDetailEntry.isCacheable(entry.response, dramaID: numericID) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        entry.accessedAt = now
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: url, options: .atomic) }
        return entry
    }

    func write(_ entry: PlaybackDetailEntry, now: Date, maxAge: TimeInterval) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entry)
            try data.write(to: directory.appendingPathComponent(entry.key.filename), options: .atomic)
            prune(now: now, maxAge: maxAge)
        } catch {
            // Persistence is optional; a disk failure must not prevent playback.
        }
    }

    func remove(_ key: PlaybackDetailKey) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(key.filename))
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    func size() -> UInt {
        files().reduce(0) { total, url in
            total + UInt((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey])) ?? []).filter { $0.pathExtension == "json" }
    }

    private func prune(now: Date, maxAge: TimeInterval) {
        var live: [(URL, Date)] = []
        for url in files() {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(PlaybackDetailEntry.self, from: data),
                  entry.isFresh(at: now, maxAge: maxAge) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            live.append((url, entry.accessedAt))
        }
        for (url, _) in live.sorted(by: { $0.1 > $1.1 }).dropFirst(capacity) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
