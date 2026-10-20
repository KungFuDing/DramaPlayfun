import Foundation
import CryptoKit

nonisolated struct PlaybackDetailSnapshot: Sendable {
    let response: APIModels.V1GetDramaEpisodeListRes
    let storedAt: Date
    let requiresAccessValidation: Bool
}

/// Keeps metadata for a day, refreshes stale details in the background, and never
/// treats a cached authorization grant as fresh beyond the shorter access window.
@MainActor
final class PlaybackDetailCache {
    private struct Flight {
        let id: UUID
        let task: Task<PlaybackDetailEntry, Error>
    }

    private struct Context {
        let key: PlaybackDetailKey
        let numericID: Int64
        let epoch: UUID
        let revision: UUID?
    }

    private let network: APIClient
    private let disk: PlaybackDetailDisk
    private let maxAge: TimeInterval
    private let retentionAge: TimeInterval
    private let accessMaxAge: TimeInterval
    private let capacity: Int
    private let now: () -> Date
    private var scope: String
    private var memory: [PlaybackDetailKey: PlaybackDetailEntry] = [:]
    private var flights: [PlaybackDetailKey: Flight] = [:]
    private var retryAfter: [PlaybackDetailKey: Date] = [:]
    private var prefetchSlots: [PlaybackDetailKey: UUID] = [:]
    private var prefetchWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var epoch = UUID()
    private var revisions: [PlaybackDetailKey: UUID] = [:]
    private var diskBarrier: Task<Void, Never>?

    init(network: APIClient, directory: URL? = nil, maxAge: TimeInterval = 1800,
         retentionAge: TimeInterval = 86_400, accessMaxAge: TimeInterval = 300,
         capacity: Int = 60, now: @escaping () -> Date = Date.init) {
        self.network = network
        self.maxAge = max(0, maxAge)
        self.retentionAge = max(0, retentionAge)
        self.accessMaxAge = max(0, accessMaxAge)
        self.capacity = max(1, capacity)
        self.now = now
        scope = network.playbackCacheScope
        let root = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlaybackDetails-v1", isDirectory: true)
        disk = PlaybackDetailDisk(directory: root, capacity: max(1, capacity))
    }

    func load(dramaID: String, forceRefresh: Bool = false) async throws -> APIModels.V1GetDramaEpisodeListRes {
        try await loadSnapshot(dramaID: dramaID, forceRefresh: forceRefresh).response
    }

    func loadSnapshot(dramaID: String, forceRefresh: Bool = false) async throws -> PlaybackDetailSnapshot {
        let context = try context(dramaID: dramaID, forceRefresh: forceRefresh)
        if !forceRefresh, let entry = try await cachedEntry(context) {
            try validate(context)
            if !entry.isFresh(at: now(), maxAge: maxAge), canRetry(context.key) {
                _ = flight(context)
            }
            return snapshot(entry)
        }
        return try await awaitRefresh(context)
    }

    /// Await the same refresh started by a stale load. Fresh metadata and entries
    /// in retry backoff return immediately, allowing playback to keep its current data.
    func revalidate(dramaID: String) async throws -> PlaybackDetailSnapshot {
        let context = try context(dramaID: dramaID)
        if let entry = try await cachedEntry(context) {
            try validate(context)
            if flights[context.key] == nil,
               entry.isFresh(at: now(), maxAge: maxAge) || !canRetry(context.key) {
                return snapshot(entry)
            }
        }
        return try await awaitRefresh(context)
    }

    func prefetch(dramaID: String) async {
        guard let context = try? context(dramaID: dramaID) else { return }
        while true {
            guard (try? validate(context)) != nil else { return }
            if let existing = flights[context.key] {
                _ = try? await existing.task.value
                return
            }
            if prefetchSlots[context.key] == nil, prefetchSlots.count < 2 { break }
            do { try await waitForPrefetchSlot(for: context.key) }
            catch { return }
        }
        let slot = UUID()
        prefetchSlots[context.key] = slot
        defer {
            if prefetchSlots[context.key] == slot {
                prefetchSlots[context.key] = nil
                resumePrefetchWaiters()
            }
        }
        // Unlike a foreground load, prefetch holds its slot until revalidation
        // finishes, even if the scrolling cell that started it has disappeared.
        do {
            if let entry = try await cachedEntry(context),
               entry.isFresh(at: now(), maxAge: maxAge) || !canRetry(context.key) { return }
            try validate(context)
            let shared = flight(context)
            _ = try? await shared.task.value
        } catch {}
    }

    func invalidate(dramaID: String) {
        guard let numericID = Int64(dramaID), numericID > 0 else { return }
        synchronizeScope()
        let key = PlaybackDetailKey(scope: scope, dramaID: String(numericID))
        supersede(key)
        memory[key] = nil
        enqueueDisk { await $0.remove(key) }
    }

    func clear() async {
        resetMemory()
        let operation = enqueueDisk { await $0.clear() }
        await operation.value
    }

    func diskSize() async -> UInt {
        await diskBarrier?.value
        return await disk.size()
    }

    /// URL renewal patches retained metadata without extending its age or access grants.
    func updatePlaybackURLs(dramaID: String, replacing: [String: URL], with urls: [String: URL]) async {
        guard !urls.isEmpty, let context = try? context(dramaID: dramaID),
              let existing = try? await cachedEntry(context),
              (try? validate(context)) != nil else { return }
        var entry = memory[context.key] ?? existing
        guard entry.isFresh(at: now(), maxAge: retentionAge),
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
        let retentionAge = retentionAge
        let date = now()
        await enqueueDisk { await $0.write(saved, now: date, maxAge: retentionAge) }.value
    }

    private func context(dramaID: String, forceRefresh: Bool = false) throws -> Context {
        try Task.checkCancellation()
        guard let numericID = Int64(dramaID), numericID > 0 else { throw CatalogError.notFound }
        synchronizeScope()
        let key = PlaybackDetailKey(scope: scope, dramaID: String(numericID))
        if forceRefresh { supersede(key) }
        return Context(key: key, numericID: numericID, epoch: epoch, revision: revisions[key])
    }

    private func synchronizeScope() {
        let current = network.playbackCacheScope
        guard scope != current else { return }
        scope = current
        resetMemory()
    }

    private func resetMemory() {
        epoch = UUID()
        revisions.removeAll()
        memory.removeAll()
        retryAfter.removeAll()
        prefetchSlots.removeAll()
        resumePrefetchWaiters(throwing: CancellationError())
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
    }

    private func supersede(_ key: PlaybackDetailKey) {
        revisions[key] = UUID()
        retryAfter[key] = nil
        flights.removeValue(forKey: key)?.task.cancel()
    }

    private func cachedEntry(_ context: Context) async throws -> PlaybackDetailEntry? {
        try validate(context)
        if var entry = memory[context.key], entry.isFresh(at: now(), maxAge: retentionAge) {
            entry.accessedAt = now()
            memory[context.key] = entry
            return entry
        }
        memory[context.key] = nil
        await diskBarrier?.value
        try validate(context)
        let saved = await disk.read(context.key, now: now(), maxAge: retentionAge)
        try validate(context)
        // A concurrent refresh may have completed while the disk actor was reading.
        if let newer = memory[context.key], newer.isFresh(at: now(), maxAge: retentionAge) { return newer }
        if let saved { remember(saved) }
        return saved
    }

    private func flight(_ context: Context) -> Flight {
        if let existing = flights[context.key] { return existing }
        let id = UUID()
        let task = Task { try await self.fetch(context, id: id) }
        let flight = Flight(id: id, task: task)
        flights[context.key] = flight
        return flight
    }

    private func awaitRefresh(_ context: Context) async throws -> PlaybackDetailSnapshot {
        try validate(context)
        let entry = try await flight(context).task.value
        try validate(context)
        return snapshot(entry)
    }

    private func fetch(_ context: Context, id: UUID) async throws -> PlaybackDetailEntry {
        defer {
            if flights[context.key]?.id == id { flights[context.key] = nil }
        }
        do {
            await diskBarrier?.value
            try validate(context, flightID: id)
            let response = try await network.request(AppAPI.v1ClientDramaEpisodeList,
                body: .init(dramaId: context.numericID), unwrapEnvelope: true)
            try validate(context, flightID: id)
            guard response.dramaId == nil || response.dramaId == context.numericID else {
                throw APIError.decoding(DecodingError.dataCorrupted(.init(codingPath: [],
                    debugDescription: "Detail response belongs to a different drama")))
            }
            guard PlaybackDetailEntry.isCacheable(response, dramaID: context.numericID) else {
                // Preserve cold-load tolerance: the player can filter duplicate
                // rows and show locked episodes whose URL is not available yet.
                // A malformed refresh must never replace retained valid details.
                if try await cachedEntry(context) != nil {
                    throw APIError.decoding(DecodingError.dataCorrupted(.init(codingPath: [],
                        debugDescription: "Detail response contains no valid playable episodes")))
                }
                try validate(context, flightID: id)
                return PlaybackDetailEntry(key: context.key, storedAt: now(), accessedAt: now(), response: response)
            }
            let entry = PlaybackDetailEntry(key: context.key, storedAt: now(), accessedAt: now(), response: response)
            remember(entry)
            retryAfter[context.key] = nil
            let retentionAge = retentionAge
            await enqueueDisk { await $0.write(entry, now: entry.storedAt, maxAge: retentionAge) }.value
            try validate(context, flightID: id)
            return entry
        } catch {
            if (try? validate(context, flightID: id)) != nil, !(error is CancellationError) {
                retryAfter = retryAfter.filter { $0.value > now() }
                retryAfter[context.key] = now().addingTimeInterval(30)
                while retryAfter.count > capacity,
                      let oldest = retryAfter.min(by: { $0.value < $1.value })?.key {
                    retryAfter[oldest] = nil
                }
            }
            throw error
        }
    }

    private func canRetry(_ key: PlaybackDetailKey) -> Bool {
        retryAfter[key].map { $0 <= now() } ?? true
    }

    private func snapshot(_ entry: PlaybackDetailEntry) -> PlaybackDetailSnapshot {
        PlaybackDetailSnapshot(response: entry.response, storedAt: entry.storedAt,
            requiresAccessValidation: !entry.isFresh(at: now(), maxAge: accessMaxAge))
    }

    private func validate(_ context: Context, flightID: UUID? = nil) throws {
        try Task.checkCancellation()
        guard network.playbackCacheScope == context.key.scope, epoch == context.epoch,
              revisions[context.key] == context.revision else { throw CancellationError() }
        if let flightID, flights[context.key]?.id != flightID { throw CancellationError() }
    }

    private func remember(_ entry: PlaybackDetailEntry) {
        memory[entry.key] = entry
        memory = memory.filter { $0.value.isFresh(at: now(), maxAge: retentionAge) }
        while memory.count > capacity,
              let oldest = memory.min(by: { $0.value.accessedAt < $1.value.accessedAt })?.key {
            memory[oldest] = nil
        }
    }

    private func waitForPrefetchSlot(for key: PlaybackDetailKey) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard prefetchSlots.count >= 2 || prefetchSlots[key] != nil else { return }
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
