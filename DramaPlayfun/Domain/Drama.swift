import Foundation

struct Drama: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let summary: String
    let category: DramaCategory
    let episodeCount: Int
    let heat: Int
    let badge: String?
    let coverURL: URL?
    let tagNames: [String]

    init(id: String, title: String, summary: String, category: DramaCategory, episodeCount: Int,
         heat: Int, badge: String?, coverURL: URL?, tagNames: [String] = []) {
        self.id = id
        self.title = title
        self.summary = summary
        self.category = category
        self.episodeCount = episodeCount
        self.heat = heat
        self.badge = badge
        self.coverURL = coverURL
        self.tagNames = tagNames
    }

    var displayTags: String {
        if !tagNames.isEmpty { return tagNames.joined(separator: " · ") }
        return category == .all ? "" : category.rawValue
    }

    var displayBadge: String? {
        guard let badge = badge?.trimmingCharacters(in: .whitespacesAndNewlines), !badge.isEmpty else { return nil }
        switch badge.lowercased() {
        case "hot": return "爆款"
        case "new": return "新品"
        default: return badge
        }
    }
}

enum DramaCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case all = "精选", liveAction = "真人剧", drama = "剧情", costume = "古装", romance = "甜宠"
    var id: String { rawValue }
}

struct Episode: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let number: Int
    let title: String
    let requiresMembership: Bool
}

struct WatchProgress: Codable, Equatable {
    let dramaID: Drama.ID
    let episodeID: Episode.ID
    let episodeNumber: Int
    let seconds: Double
    let duration: Double
    let updatedAt: Date

    var fraction: Double { duration > 0 ? min(max(seconds / duration, 0), 1) : 0 }
}
