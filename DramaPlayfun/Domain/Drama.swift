import Foundation

struct Drama: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let rootDramaID: Int64?
    private let storedTitle: String
    private let storedSummary: String
    private let isLocalDemo: Bool?
    let category: DramaCategory
    let episodeCount: Int
    let heat: Int
    let badge: String?
    let coverURL: URL?
    let tagNames: [String]
    let playbackPosition: PlaybackPosition?

    init(id: String, title: String, summary: String, category: DramaCategory, episodeCount: Int,
         heat: Int, badge: String?, coverURL: URL?, tagNames: [String] = [],
         rootDramaID: Int64? = nil, isLocalDemo: Bool? = nil, playbackPosition: PlaybackPosition? = nil) {
        self.id = id
        self.rootDramaID = rootDramaID
        self.storedTitle = title
        self.storedSummary = summary
        self.isLocalDemo = isLocalDemo
        self.category = category
        self.episodeCount = episodeCount
        self.heat = heat
        self.badge = badge
        self.coverURL = coverURL
        self.tagNames = tagNames
        self.playbackPosition = playbackPosition
    }

    // Keep persisted/server values intact while rendering bundled demo copy in the active language.
    private enum CodingKeys: String, CodingKey {
        case id, rootDramaID, category, episodeCount, heat, badge, coverURL, tagNames, isLocalDemo, playbackPosition
        case storedTitle = "title"
        case storedSummary = "summary"
    }

    var title: String {
        guard isLocalDemo == true else { return storedTitle }
        switch id {
        case "campus": return L10n.tr("重生之我逆袭做校花")
        case "wish": return L10n.tr("全家抢我神笔许愿，全玩脱了")
        case "meet": return L10n.tr("赶得上，就娶你")
        case "palace": return L10n.tr("重生后，我执掌凤印")
        case "moon": return L10n.tr("重生之我和白月光")
        case "contract": return L10n.tr("我反手就是主仆契约")
        default: return storedTitle
        }
    }

    var summary: String {
        guard isLocalDemo == true else { return storedSummary }
        switch id {
        case "campus": return L10n.tr("重启人生，这一次她要为自己赢一次。")
        case "wish": return L10n.tr("一支神笔，照见人心；失去的一切，她将亲手夺回。")
        case "meet": return L10n.tr("兜兜转转，原来最好的相遇从未迟到。")
        case "palace": return L10n.tr("深宫再相逢，命运由她重新书写。")
        case "moon": return L10n.tr("再来一次，她终于听见了未曾说出口的心意。")
        case "contract": return L10n.tr("一纸契约，改写两个人的故事。")
        default: return storedSummary
        }
    }

    var displayTags: String {
        if !tagNames.isEmpty { return tagNames.joined(separator: " · ") }
        return category == .all ? "" : category.title
    }

    var displayBadge: String? {
        guard let badge = badge?.trimmingCharacters(in: .whitespacesAndNewlines), !badge.isEmpty else { return nil }
        switch badge.lowercased() {
        case "hot", "爆款": return L10n.tr("爆款")
        case "new", "新品": return L10n.tr("新品")
        case "最新": return L10n.tr("最新")
        default: return badge
        }
    }
}

enum DramaCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case all = "精选", liveAction = "真人剧", drama = "剧情", costume = "古装", romance = "甜宠"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: L10n.tr("精选")
        case .liveAction: L10n.tr("真人剧")
        case .drama: L10n.tr("剧情")
        case .costume: L10n.tr("古装")
        case .romance: L10n.tr("甜宠")
        }
    }
}

struct Episode: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let number: Int
    let title: String
    let requiresMembership: Bool
    let unlockCoin: Int64
    let isUnlocked: Bool
    let looked: Bool?

    init(id: String, number: Int, title: String, requiresMembership: Bool,
         unlockCoin: Int64 = 0, isUnlocked: Bool = true, looked: Bool? = nil) {
        self.id = id
        self.number = number
        self.title = title
        self.requiresMembership = requiresMembership
        self.unlockCoin = unlockCoin
        self.isUnlocked = isUnlocked
        self.looked = looked
    }

    var displayTitle: String { title.isEmpty ? L10n.tr("第%d集", number) : title }
    var requiresCoinUnlock: Bool { unlockCoin > 0 && !isUnlocked }
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
