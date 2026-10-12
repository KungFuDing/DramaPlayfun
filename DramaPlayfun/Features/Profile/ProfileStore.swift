import Foundation
import Observation

struct ProfileLanguage: Identifiable {
    let id: String
    let title: String
    static let defaults = [ProfileLanguage(id: "zh", title: "中文"),
        ProfileLanguage(id: "en", title: "English"), ProfileLanguage(id: "ja", title: "にほんご"),
        ProfileLanguage(id: "ko", title: "한국어")]
}

enum ProfileCollection: String, CaseIterable, Identifiable {
    case favorites = "收藏", likes = "点赞"
    var id: Self { self }
}

@MainActor @Observable
final class ProfileStore {
    private(set) var profile = APIModels.V1GetMyProfileRes()
    private(set) var config = APIModels.V1GetAppConfigRes()
    private(set) var languages = ProfileLanguage.defaults
    private(set) var collections: [ProfileCollection: [Drama]] = [:]
    private(set) var loading: Set<ProfileCollection> = []
    private(set) var errors: [ProfileCollection: String] = [:]
    private(set) var hasMore: [ProfileCollection: Bool] = [:]
    private var pages: [ProfileCollection: Int] = [:]
    private var network: APIClient

    init(network: APIClient) { self.network = network }

    var nickname: String { profile.nickname.flatMap { $0.isEmpty ? nil : $0 } ?? "短剧爱好者" }
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
        } catch { /* Keep the last known profile when offline. */ }
    }

    func loadSettings() async {
        do {
            let result = try await network.request(AppAPI.v1ClientAppConfig, body: .init(), unwrapEnvelope: true)
            try Task.checkCancellation()
            config = result
        } catch { }
        do {
            let result = try await network.request(AppAPI.v1ClientLanguageList, body: .init(), unwrapEnvelope: true)
            try Task.checkCancellation()
            var ids = Set<String>()
            let options = (result.list ?? []).sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }.compactMap { item -> ProfileLanguage? in
                guard let code = item.languageCode, !code.isEmpty, ids.insert(code).inserted,
                      let title = item.translatedName ?? item.languageName, !title.isEmpty else { return nil }
                return ProfileLanguage(id: code, title: title)
            }
            if !options.isEmpty { languages = options }
        } catch { }
    }

    func load(_ collection: ProfileCollection, refresh: Bool = false) async {
        guard !loading.contains(collection) else { return }
        if !refresh, collections[collection] != nil, hasMore[collection] != true { return }
        let page = refresh ? 1 : (pages[collection] ?? 0) + 1
        loading.insert(collection)
        errors[collection] = nil
        defer { loading.remove(collection) }
        do {
            let dramas: [Drama]
            let more: Bool
            switch collection {
            case .favorites:
                let result = try await network.request(AppAPI.v1ClientMeFavorites, body: .init(page: page, pageSize: 20), unwrapEnvelope: true)
                dramas = (result.list ?? []).compactMap { Self.drama(id: $0.dramaId ?? $0.id ?? $0.rootDramaId,
                    rootID: $0.rootDramaId, title: $0.dramaTitle, cover: $0.coverUrl, summary: $0.episodeText) }
                more = result.hasMore ?? false
            case .likes:
                let result = try await network.request(AppAPI.v1ClientMeLikes, body: .init(page: page, pageSize: 20), unwrapEnvelope: true)
                dramas = (result.list ?? []).compactMap { Self.drama(id: $0.dramaId ?? $0.id ?? $0.rootDramaId,
                    rootID: $0.rootDramaId, title: $0.dramaTitle, cover: $0.coverUrl, summary: $0.dramaDesc ?? $0.episodeText) }
                more = result.hasMore ?? false
            }
            try Task.checkCancellation()
            var ids = Set<String>()
            collections[collection] = ((page == 1 ? [] : collections[collection] ?? []) + dramas).filter { ids.insert($0.id).inserted }
            pages[collection] = page
            hasMore[collection] = more
        } catch is CancellationError {
        } catch { errors[collection] = error.localizedDescription }
    }

    func updateNickname(_ nickname: String) async throws {
        _ = try await network.request(AppAPI.v1ClientMeProfile, body: .init(nickname: nickname), unwrapEnvelope: true)
        profile.nickname = nickname
    }

    func deactivate() async throws {
        _ = try await network.request(AppAPI.v1AuthDeactivate, body: .init(), unwrapEnvelope: true)
        profile = .init()
        collections = [:]
        pages = [:]
        hasMore = [:]
        errors = [:]
    }

    private static func drama(id: Int64?, rootID: Int64?, title: String?, cover: String?, summary: String?) -> Drama? {
        guard let id, let title, !title.isEmpty else { return nil }
        return Drama(id: String(id), title: title, summary: summary ?? "", category: .all,
            episodeCount: 0, heat: 0, badge: nil, coverURL: cover.flatMap(URL.init(string:)), rootDramaID: rootID)
    }
}
