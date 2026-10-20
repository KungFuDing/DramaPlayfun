import Foundation
import Observation

enum ProfileCollection: String, CaseIterable, Identifiable {
    case favorites = "收藏", likes = "点赞"
    var id: Self { self }
    var title: String { L10n.tr(rawValue) }
}

struct ProfileCollectionItem: Identifiable {
    let drama: Drama
    let playbackPosition: PlaybackPosition
    var id: String { drama.id }
}

@MainActor @Observable
final class ProfileStore {
    private(set) var profile = APIModels.V1GetMyProfileRes()
    private(set) var hasLoadedProfile = false
    private(set) var config = AppConfiguration()
    private(set) var collections: [ProfileCollection: [ProfileCollectionItem]] = [:]
    private(set) var loading: Set<ProfileCollection> = []
    private var failures: [ProfileCollection: Error] = [:]
    var errors: [ProfileCollection: String] {
        _ = LocalizationStore.shared.language
        return failures.mapValues(\.appLocalizedDescription)
    }
    private(set) var hasMore: [ProfileCollection: Bool] = [:]
    private var pages: [ProfileCollection: Int] = [:]
    private var network: APIClient

    init(network: APIClient) { self.network = network }

    var nickname: String { profile.nickname.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.tr("短剧爱好者") }
    var autoPlaysNext: Bool { profile.autoPlayNext != "off" }

    func setAutoPlayNext(_ enabled: Bool) async throws {
        let result = try await network.request(AppAPI.v1ClientMeAutoPlayNextSet,
            body: .init(autoPlayNext: enabled ? "on" : "off"), unwrapEnvelope: true)
        profile.autoPlayNext = result.autoPlayNext ?? (enabled ? "on" : "off")
    }

    func updateCoinBalance(_ balance: Int64) { profile.coinAmount = balance }
    var hasVIP: Bool {
        guard let expiry = profile.vipExpireAt else { return false }
        return Date(timeIntervalSince1970: Double(expiry) / 1000) > Date()
    }
    var expiryText: String? {
        profile.vipExpireAt.map { Date(timeIntervalSince1970: Double($0) / 1000).formatted(.iso8601.year().month().day().dateSeparator(.dash)) }
    }

    func reloadProfile() async {
        do {
            let result = try await network.request(AppAPI.v1ClientMe, body: .init(), unwrapEnvelope: true)
            try Task.checkCancellation()
            profile = result
            hasLoadedProfile = true
        } catch { /* Keep the last known profile when offline. */ }
    }

    func loadSettings() async {
        do {
            let result = try await network.request(AppAPI.v1ClientAppConfig, body: .init(), unwrapEnvelope: true)
            try Task.checkCancellation()
            config = AppConfiguration(remote: result)
        } catch is CancellationError {
            return
        } catch {
            config = AppConfiguration()
        }
    }

    func load(_ collection: ProfileCollection, refresh: Bool = false) async {
        guard !loading.contains(collection) else { return }
        if !refresh, collections[collection] != nil, hasMore[collection] != true { return }
        let page = refresh ? 1 : (pages[collection] ?? 0) + 1
        loading.insert(collection)
        failures[collection] = nil
        defer { loading.remove(collection) }
        do {
            let items: [ProfileCollectionItem]
            let more: Bool
            switch collection {
            case .favorites:
                let result = try await network.request(AppAPI.v1ClientMeFavorites, body: .init(page: page, pageSize: 20), unwrapEnvelope: true)
                items = (result.list ?? []).compactMap { item in
                    guard let drama = Self.drama(id: item.dramaId ?? item.id ?? item.rootDramaId,
                        rootID: item.rootDramaId, title: item.dramaTitle, cover: item.coverUrl,
                        summary: item.episodeText) else { return nil }
                    return ProfileCollectionItem(drama: drama,
                        playbackPosition: PlaybackPosition(episodeNumber: item.episodeNo,
                            seconds: item.progressSeconds.map(Double.init)))
                }
                more = result.hasMore ?? false
            case .likes:
                let result = try await network.request(AppAPI.v1ClientMeLikes, body: .init(page: page, pageSize: 20), unwrapEnvelope: true)
                items = (result.list ?? []).compactMap { item in
                    guard let drama = Self.drama(id: item.dramaId ?? item.id ?? item.rootDramaId,
                        rootID: item.rootDramaId, title: item.dramaTitle, cover: item.coverUrl,
                        summary: item.dramaDesc ?? item.episodeText) else { return nil }
                    return ProfileCollectionItem(drama: drama,
                        playbackPosition: PlaybackPosition(episodeNumber: item.episodeNo,
                            seconds: item.progressSeconds.map(Double.init)))
                }
                more = result.hasMore ?? false
            }
            try Task.checkCancellation()
            var ids = Set<String>()
            collections[collection] = ((page == 1 ? [] : collections[collection] ?? []) + items).filter { ids.insert($0.id).inserted }
            pages[collection] = page
            hasMore[collection] = more
        } catch is CancellationError {
        } catch { failures[collection] = error }
    }

    func updateNickname(_ nickname: String) async throws {
        _ = try await network.request(AppAPI.v1ClientMeProfile, body: .init(nickname: nickname), unwrapEnvelope: true)
        profile.nickname = nickname
    }

    func deactivate() async throws {
        _ = try await network.request(AppAPI.v1AuthDeactivate, body: .init(), unwrapEnvelope: true)
        profile = .init()
        hasLoadedProfile = false
        collections = [:]
        pages = [:]
        hasMore = [:]
        failures = [:]
    }

    private static func drama(id: Int64?, rootID: Int64?, title: String?, cover: String?, summary: String?) -> Drama? {
        guard let id, let title, !title.isEmpty else { return nil }
        return Drama(id: String(id), title: title, summary: summary ?? "", category: .all,
            episodeCount: 0, heat: 0, badge: nil, coverURL: cover.flatMap(URL.init(string:)), rootDramaID: rootID)
    }
}
