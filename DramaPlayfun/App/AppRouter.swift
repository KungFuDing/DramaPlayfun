import SwiftUI
import Observation

enum AppTab: String, CaseIterable, Identifiable {
    case home = "首页", theater = "剧场", rankings = "排行榜", membership = "会员", profile = "我的"
    var id: Self { self }
    var title: String { L10n.tr(rawValue) }
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

enum AppRoute: Hashable { case drama(Drama), shortDrama(Drama), search, welfare, settings }

struct PlaybackRequest: Identifiable {
    let drama: Drama
    let episode: Episode
    var startsFromBeginning = false
    var preparation: PlaybackPreparation?
    var id: String { "\(drama.id):\(episode.id.isEmpty ? String(episode.number) : episode.id)" }
}

@MainActor @Observable
final class AppRouter {
    var selectedTab: AppTab = .home
    var paths: [AppTab: [AppRoute]] = [:]
    var playback: PlaybackRequest?
    var membershipPresented = false

    func resetForLanguageChange() {
        // Route payloads can contain server-localized titles and descriptions.
        // Keep the settings destination where the user made the selection.
        let keepsSettings = selectedTab == .profile && paths[.profile]?.last == .settings
        paths = keepsSettings ? [.profile: [.settings]] : [:]
        playback = nil
        membershipPresented = false
    }

    func openPlayback(_ drama: Drama, episode: Episode? = nil) {
        playback = PlaybackRequest(drama: drama, episode: episode ??
            Episode(id: "", number: 1, title: "", requiresMembership: false))
    }

    func openPlayback(_ drama: Drama, episodeNumber: Int, preparation: PlaybackPreparation? = nil) {
        playback = PlaybackRequest(drama: drama,
            episode: Episode(id: "", number: episodeNumber, title: "", requiresMembership: false),
            startsFromBeginning: true, preparation: preparation)
    }

    func path(for tab: AppTab) -> Binding<[AppRoute]> {
        Binding(get: { self.paths[tab, default: []] }, set: { self.paths[tab] = $0 })
    }
}
