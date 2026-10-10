import AVFoundation
import Foundation

/// Persists completed VOD HLS packages. Streaming preload remains AVPlayer's responsibility.
final class HLSOfflineCache: NSObject, AVAssetDownloadDelegate, @unchecked Sendable {
    static let shared = HLSOfflineCache()

    private struct Entry: Codable {
        let path: String
        let savedAt: Date
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let indexKey = "theater.hls.completed-assets.v1"
    private let pendingKey = "theater.hls.pending-assets.v1"
    private let maxCachedAssets = 30
    private let maxCacheBytes: Int64 = 500 * 1024 * 1024
    private let maxActiveDownloads = 2
    private var entries: [String: Entry]
    private var pendingLocations: [String: String]
    private var activeEpisodeIDs: Set<String> = []
    private var playbackOwners: Set<UUID> = []
    private var session: AVAssetDownloadURLSession!

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = (defaults.data(forKey: indexKey)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) }) ?? [:]
        pendingLocations = defaults.dictionary(forKey: pendingKey) as? [String: String] ?? [:]
        super.init()
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "com.video.test.DramaPlayfun.theater.hls-cache"
        )
        configuration.isDiscretionary = false
        session = AVAssetDownloadURLSession(configuration: configuration,
                                            assetDownloadDelegate: self, delegateQueue: nil)
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.lock.lock()
            self.activeEpisodeIDs.formUnion(tasks.compactMap(\.taskDescription))
            self.lock.unlock()
        }
    }

    func asset(for episodeID: String, remoteURL: URL,
               identity: HLSKeyIdentity) async throws -> AVURLAsset {
        if let url = localURL(for: episodeID) { return AVURLAsset(url: url) }
        return try await HLSLocalGateway.shared.asset(remoteURL: remoteURL, identity: identity,
                                                       secret: HLSPlaybackKey.configuredSecret())
    }

    func cachedAsset(for episodeID: String, identity: HLSKeyIdentity) throws -> AVURLAsset? {
        guard let url = localURL(for: episodeID) else { return nil }
        return AVURLAsset(url: url)
    }

    func localURL(for episodeID: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[episodeID] else { return nil }
        let url = URL(fileURLWithPath: entry.path)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        entries[episodeID] = nil
        saveIndex()
        return nil
    }

    func downloadIfNeeded(episodeID: String, asset: AVURLAsset, title: String) {
        guard asset.url.isFileURL == false else { return }
        lock.lock()
        guard !activeEpisodeIDs.contains(episodeID), entries[episodeID] == nil,
              activeEpisodeIDs.count < maxActiveDownloads else {
            lock.unlock()
            return
        }
        activeEpisodeIDs.insert(episodeID)
        lock.unlock()

        let configuration = AVAssetDownloadConfiguration(asset: asset, title: title)
        let task = session.makeAssetDownloadTask(downloadConfiguration: configuration)
        task.taskDescription = episodeID
        lock.lock()
        if playbackOwners.isEmpty { task.resume() }
        lock.unlock()
    }

    /// Keep full-episode caching from competing with any foreground player.
    func setPlaybackActive(_ active: Bool, owner: UUID) {
        lock.lock()
        let changed = active ? playbackOwners.insert(owner).inserted : playbackOwners.remove(owner) != nil
        lock.unlock()
        guard changed else { return }
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.lock.lock()
            let shouldPause = !self.playbackOwners.isEmpty
            for task in tasks {
                if shouldPause, task.state == .running { task.suspend() }
                else if !shouldPause, task.state == .suspended { task.resume() }
            }
            self.lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    willDownloadTo location: URL) {
        guard let episodeID = assetDownloadTask.taskDescription else { return }
        lock.lock()
        pendingLocations[episodeID] = location.path
        defaults.set(pendingLocations, forKey: pendingKey)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let episodeID = task.taskDescription else { return }
        lock.lock()
        activeEpisodeIDs.remove(episodeID)
        let path = pendingLocations.removeValue(forKey: episodeID)
        defaults.set(pendingLocations, forKey: pendingKey)
        if error == nil, let path, FileManager.default.fileExists(atPath: path) {
            entries[episodeID] = Entry(path: path, savedAt: Date())
            evictOldAssetsIfNeeded()
            saveIndex()
        }
        lock.unlock()
    }

    private func evictOldAssetsIfNeeded() {
        var totalBytes = entries.values.reduce(Int64(0)) { $0 + allocatedSize(at: $1.path) }
        for (key, entry) in entries.sorted(by: { $0.value.savedAt < $1.value.savedAt }) {
            guard entries.count > maxCachedAssets || totalBytes > maxCacheBytes else { break }
            totalBytes -= allocatedSize(at: entry.path)
            try? FileManager.default.removeItem(atPath: entry.path)
            entries[key] = nil
        }
    }

    private func allocatedSize(at path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        guard let enumerator = FileManager.default.enumerator(at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: indexKey)
    }
}
