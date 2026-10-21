import Foundation
import Observation

@MainActor @Observable
final class LibraryStore {
    private(set) var favoriteIDs: Set<Drama.ID>
    private(set) var progress: [Drama.ID: WatchProgress]
    private let defaults: UserDefaults
    private var acceptsChanges = true
    private static let favoritesKey = "library.favorites.v1"
    private static let progressKey = "library.progress.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favoriteIDs = Set(defaults.stringArray(forKey: Self.favoritesKey) ?? [])
        progress = defaults.data(forKey: Self.progressKey)
            .flatMap { try? JSONDecoder().decode([String: WatchProgress].self, from: $0) } ?? [:]
    }

    func toggleFavorite(_ id: Drama.ID) {
        guard acceptsChanges else { return }
        if favoriteIDs.contains(id) { favoriteIDs.remove(id) } else { favoriteIDs.insert(id) }
        defaults.set(Array(favoriteIDs), forKey: Self.favoritesKey)
    }

    func setFavorite(_ id: Drama.ID, isFavorite: Bool) {
        guard acceptsChanges else { return }
        if isFavorite { favoriteIDs.insert(id) } else { favoriteIDs.remove(id) }
        defaults.set(Array(favoriteIDs), forKey: Self.favoritesKey)
    }

    func save(_ value: WatchProgress) {
        guard acceptsChanges else { return }
        guard value.seconds.isFinite, value.duration.isFinite, value.seconds >= 0 else { return }
        progress[value.dramaID] = value
        if let data = try? JSONEncoder().encode(progress) {
            defaults.set(data, forKey: Self.progressKey)
        }
    }

    var recentProgress: [WatchProgress] { progress.values.sorted { $0.updatedAt > $1.updatedAt } }

    func clearAccountData() {
        favoriteIDs = []
        progress = [:]
        defaults.removeObject(forKey: Self.favoritesKey)
        defaults.removeObject(forKey: Self.progressKey)
    }

    /// Retired players can still receive onDisappear or progress callbacks.
    /// They must never persist the deleted account's state again.
    func retireAccount() {
        acceptsChanges = false
        clearAccountData()
    }
}
