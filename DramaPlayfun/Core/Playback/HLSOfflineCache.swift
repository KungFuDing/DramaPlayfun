import AVFoundation
import Foundation

/// Creates a fresh gateway lease for every playback. Encrypted segments are
/// cached by HLSMediaCache; downloaded packages cannot keep temporary key routes alive.
nonisolated final class HLSOfflineCache: NSObject, AVAssetDownloadDelegate, @unchecked Sendable {
    static let shared = HLSOfflineCache()

    private let migration: HLSLegacyAssetMigration
    private let secret: Data?
    private let lock = NSLock()
    private var legacySession: AVAssetDownloadURLSession?

    init(defaults: UserDefaults = .standard, libraryDirectory: URL? = nil,
         cancelLegacyDownloads: Bool = true, secret: Data? = nil) {
        self.secret = secret
        migration = HLSLegacyAssetMigration(defaults: defaults, libraryDirectory: libraryDirectory
            ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0])
        super.init()
        guard cancelLegacyDownloads else { return }
        // Reconnect only to cancel downloads created by earlier app versions.
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "com.video.test.DramaPlayfun.theater.hls-cache")
        let session = AVAssetDownloadURLSession(configuration: configuration,
            assetDownloadDelegate: self, delegateQueue: nil)
        legacySession = session
        session.getAllTasks { [weak self] tasks in
            for case let task as AVAssetDownloadTask in tasks {
                self?.migration.record(task.urlAsset.url)
            }
            tasks.forEach { $0.cancel() }
            session.invalidateAndCancel()
            self?.migration.removePackages()
        }
    }

    @MainActor
    func asset(for episodeID: String, remoteURL: URL,
               identity: HLSKeyIdentity) async throws -> AVURLAsset {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-PlaybackProgressUITestFixture"),
           let url = Bundle.main.url(forResource: "PlaybackProgressFixture", withExtension: "mp4") {
            return AVURLAsset(url: url)
        }
        #endif
        return try await HLSLocalGateway.shared.asset(remoteURL: remoteURL, identity: identity,
            secret: secret ?? HLSPlaybackKey.configuredSecret())
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    willDownloadTo location: URL) {
        migration.record(location)
        assetDownloadTask.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        migration.removePackages()
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        migration.removePackages()
        lock.lock()
        legacySession = nil
        lock.unlock()
    }
}

/// Removes only packages recorded by the retired cache. Unknown or malformed
/// entries are forgotten, without expanding cleanup to other application files.
nonisolated final class HLSLegacyAssetMigration: @unchecked Sendable {
    static let completedKey = "theater.hls.completed-assets.v1"
    static let pendingKey = "theater.hls.pending-assets.v1"

    private let libraryDirectory: URL
    private let lock = NSLock()
    private var paths: Set<String>

    init(defaults: UserDefaults, libraryDirectory: URL) {
        self.libraryDirectory = libraryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let completed = defaults.data(forKey: Self.completedKey)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let completedPaths = completed.values.compactMap { ($0 as? [String: Any])?["path"] as? String }
        let pendingPaths = defaults.dictionary(forKey: Self.pendingKey)?.values.compactMap { $0 as? String } ?? []
        paths = Set(completedPaths + pendingPaths)
        // Revoke old hits before asynchronous task restoration or playback starts.
        defaults.removeObject(forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.pendingKey)
        removePackages()
    }

    func record(_ location: URL) {
        guard location.isFileURL else { return }
        lock.lock()
        paths.insert(location.path)
        lock.unlock()
    }

    func removePackages() {
        lock.lock()
        let candidates = paths
        lock.unlock()
        for path in candidates {
            guard let url = packageURL(path: path) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func packageURL(path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        // AVFoundation can persist its no-follow alias for the same sandbox.
        let normalized = path.hasPrefix("/.nofollow/") ? String(path.dropFirst("/.nofollow".count)) : path
        let url = URL(fileURLWithPath: normalized).standardizedFileURL
        let container = url.deletingLastPathComponent()
        guard url.pathExtension == "movpkg",
              container.lastPathComponent.hasPrefix("com.apple.UserManagedAssets."),
              container.lastPathComponent != "com.apple.UserManagedAssets.",
              container.deletingLastPathComponent().resolvingSymlinksInPath() == libraryDirectory,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let containerValues = try? container.resourceValues(forKeys: [.isSymbolicLinkKey]),
              containerValues.isSymbolicLink != true else { return nil }
        return url
    }
}
