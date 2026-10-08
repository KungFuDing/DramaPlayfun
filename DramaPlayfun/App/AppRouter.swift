import SwiftUI
import Observation

enum AppTab: String, CaseIterable, Identifiable {
    case home = "首页", theater = "剧场", rankings = "排行榜", membership = "会员", profile = "我的"
    var id: Self { self }
    private var iconAssetPrefix: String {
        switch self {
        case .home: "TabHome"
        case .theater: "TabTheater"
        case .rankings: "TabRankings"
        case .membership: "TabMembership"
        case .profile: "TabProfile"
        }
    }

    func iconAsset(isSelected: Bool) -> String {
        iconAssetPrefix + (isSelected ? "Selected" : "Normal")
    }
}

enum AppRoute: Hashable { case drama(Drama) }

struct PlaybackRequest: Identifiable {
    let drama: Drama
    let episode: Episode
    var id: String { "\(drama.id):\(episode.id)" }
}

@MainActor @Observable
final class AppRouter {
    var selectedTab: AppTab = .home
    var paths: [AppTab: [AppRoute]] = [:]
    var playback: PlaybackRequest?
    var membershipPresented = false

    func openPlayback(_ drama: Drama, episode: Episode? = nil) {
        playback = PlaybackRequest(drama: drama, episode: episode ??
            Episode(id: "", number: 1, title: "第1集", requiresMembership: false))
    }

    func path(for tab: AppTab) -> Binding<[AppRoute]> {
        Binding(get: { self.paths[tab, default: []] }, set: { self.paths[tab] = $0 })
    }
}
