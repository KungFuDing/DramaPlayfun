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

enum AppRoute: Hashable { case drama(Drama), shortDrama(Drama), playback(PlaybackRequest), search, welfare, settings, wallet, history }

struct PlaybackRequest: Identifiable, Hashable {
    let drama: Drama
    let episode: Episode
    var startsFromBeginning = false
    var startPosition: PlaybackPosition?
    var preparation: PlaybackPreparation?
    var id: String { "\(drama.id):\(episode.id.isEmpty ? String(episode.number) : episode.id)" }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor @Observable
final class AppRouter {
    var selectedTab: AppTab = .home
    var paths: [AppTab: [AppRoute]] = [:]
    var membershipPresented = false

    // Keep the player in the same path as its source page, so a native pop
    // preserves that page's local state (including submitted search results).
    var playback: PlaybackRequest? {
        get {
            for route in paths[selectedTab, default: []].reversed() {
                if case .playback(let request) = route { return request }
            }
            return nil
        }
        set {
            if let index = paths[selectedTab, default: []].lastIndex(where: {
                if case .playback = $0 { return true }
                return false
            }) {
                if let newValue { paths[selectedTab, default: []][index] = .playback(newValue) }
                else { paths[selectedTab, default: []].removeSubrange(index...) }
            } else if let newValue {
                paths[selectedTab, default: []].append(.playback(newValue))
            }
        }
    }

    func resetForLanguageChange() {
        // Route payloads can contain server-localized titles and descriptions.
        // Keep the settings destination where the user made the selection.
        let profileSource = paths[.profile]?.last {
            if case .playback = $0 { return false }
            return true
        }
        let keepsSettings = selectedTab == .profile && profileSource == .settings
        paths = keepsSettings ? [.profile: [.settings]] : [:]
        membershipPresented = false
    }

    func openPlayback(_ drama: Drama, episode: Episode? = nil) {
        if episode == nil, let position = drama.playbackPosition {
            openPlayback(drama, position: position)
            return
        }
        playback = PlaybackRequest(drama: drama, episode: episode ??
            Episode(id: "", number: 1, title: "", requiresMembership: false))
    }

    func openPlayback(_ drama: Drama, episodeNumber: Int, preparation: PlaybackPreparation? = nil) {
        playback = PlaybackRequest(drama: drama,
            episode: Episode(id: "", number: episodeNumber, title: "", requiresMembership: false),
            startsFromBeginning: true, preparation: preparation)
    }

    func openPlayback(_ drama: Drama, position: PlaybackPosition) {
        playback = PlaybackRequest(drama: drama,
            episode: Episode(id: "", number: position.episodeNumber, title: "", requiresMembership: false),
            startPosition: position)
    }

    func path(for tab: AppTab) -> Binding<[AppRoute]> {
        Binding(get: { self.paths[tab, default: []] }, set: { self.paths[tab] = $0 })
    }
}
