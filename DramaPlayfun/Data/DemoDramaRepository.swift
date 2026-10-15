import Foundation

/// Offline fixtures. Replace this dependency in AppContainer when the API is ready.
struct DemoDramaRepository: DramaRepository {
    func fetchDramas() async throws -> [Drama] { Self.dramas }

    func fetchEpisodes(dramaID: Drama.ID) async throws -> [Episode] {
        guard let drama = Self.dramas.first(where: { $0.id == dramaID }) else {
            throw CatalogError.notFound
        }
        return (1...drama.episodeCount).map {
            Episode(id: "\(dramaID)-\($0)", number: $0, title: "", requiresMembership: $0 > 3)
        }
    }

    func playbackURL(dramaID: Drama.ID, episodeID: Episode.ID) async throws -> URL {
        // Deliberately no unrelated public test video or fabricated production URL.
        throw CatalogError.mediaNotConfigured
    }

    static let dramas: [Drama] = [
        Drama(id: "campus", title: "重生之我逆袭做校花", summary: "重启人生，这一次她要为自己赢一次。", category: .liveAction, episodeCount: 60, heat: 986000, badge: "最新", coverURL: nil, isLocalDemo: true),
        Drama(id: "wish", title: "全家抢我神笔许愿，全玩脱了", summary: "一支神笔，照见人心；失去的一切，她将亲手夺回。", category: .drama, episodeCount: 80, heat: 1280000, badge: "爆款", coverURL: nil, isLocalDemo: true),
        Drama(id: "meet", title: "赶得上，就娶你", summary: "兜兜转转，原来最好的相遇从未迟到。", category: .romance, episodeCount: 72, heat: 870000, badge: "新品", coverURL: nil, isLocalDemo: true),
        Drama(id: "palace", title: "重生后，我执掌凤印", summary: "深宫再相逢，命运由她重新书写。", category: .costume, episodeCount: 68, heat: 930000, badge: nil, coverURL: nil, isLocalDemo: true),
        Drama(id: "moon", title: "重生之我和白月光", summary: "再来一次，她终于听见了未曾说出口的心意。", category: .romance, episodeCount: 56, heat: 760000, badge: "新品", coverURL: nil, isLocalDemo: true),
        Drama(id: "contract", title: "我反手就是主仆契约", summary: "一纸契约，改写两个人的故事。", category: .costume, episodeCount: 90, heat: 1120000, badge: "爆款", coverURL: nil, isLocalDemo: true)
    ]
}
