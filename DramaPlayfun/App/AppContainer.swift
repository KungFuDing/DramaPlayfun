import Foundation
import Observation
#if DEBUG
import Moya
#endif

@MainActor @Observable
final class AppContainer {
    let network: APIClient
    let guestSession: GuestSessionStore
    let repository: any DramaRepository
    let catalog: CatalogStore
    let homeCategories: DramaTabFeedStore
    let rankings: DramaTabFeedStore
    let watchHistory: WatchHistoryStore
    let homeFeed: HomeFeedStore
    let theaterFeed: TheaterFeedStore
    let library: LibraryStore
    let hlsCache: HLSOfflineCache
    let theaterPlayback: TheaterPlayerPool
    let membership: MembershipStore

    init(network: APIClient? = nil,
         repository: (any DramaRepository)? = nil,
         subscriptions: (any SubscriptionService)? = nil,
         defaults: UserDefaults = .standard) {
        #if DEBUG
        let fixture = (ProcessInfo.processInfo.arguments.contains("-TheaterUITestFixture") ||
                       ProcessInfo.processInfo.arguments.contains("-FeedUITestFixture") ||
                       ProcessInfo.processInfo.arguments.contains("-HistoryUITestFixture"))
            ? Self.theaterUITestClient() : nil
        #endif
        self.network = network ?? {
            #if DEBUG
            if let fixture { return fixture }
            #endif
            return APIClient(headerProvider: { _ in
            #if DEBUG
            DebugHTTPHeaders.current
            #else
            [:]
            #endif
            })
        }()
        guestSession = GuestSessionStore(network: self.network, defaults: defaults)
        let repository = repository ?? APIDramaRepository(network: self.network,
                                                          fallback: DemoDramaRepository())
        self.repository = repository
        catalog = CatalogStore(repository: repository)
        homeCategories = DramaTabFeedStore(network: self.network, source: .homeTags)
        rankings = DramaTabFeedStore(network: self.network, source: .rankings)
        watchHistory = WatchHistoryStore(network: self.network)
        homeFeed = HomeFeedStore(network: self.network)
        theaterFeed = TheaterFeedStore(network: self.network)
        library = LibraryStore(defaults: defaults)
        hlsCache = .shared
        theaterPlayback = TheaterPlayerPool(library: library, cache: hlsCache,
            progressReporter: TheaterProgressReporter(network: self.network))
        membership = MembershipStore(service: subscriptions ?? StoreKitSubscriptionService(productIDs: []))
    }

    #if DEBUG
    private static func theaterUITestClient() -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let response: String
            switch target.path {
            case "/mobile/v1/auth/guest/login":
                response = #"{"code":200,"data":{"accessToken":"ui-test-guest-token"}}"#
            case "/mobile/v1/client/drama/share/text":
                response = #"{"code":200,"data":{"text":"https://example.invalid/drama/first-episode"}}"#
            case "/mobile/v1/client/drama/like":
                let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Any]
                let liked = body?["like"] as? Bool ?? false
                response = "{\"code\":200,\"data\":{\"isLiked\":\(liked),\"likeCount\":12}}"
            case "/mobile/v1/client/drama/favorite":
                let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Any]
                let favorite = body?["favorite"] as? Bool ?? false
                response = "{\"code\":200,\"data\":{\"isFavorited\":\(favorite)}}"
            case "/mobile/v1/client/drama/share":
                response = #"{"code":200,"data":{}}"#
            case "/mobile/v1/client/drama/progress":
                response = #"{"code":200,"data":{"saved":true}}"#
            case "/mobile/v1/client/me/history/list":
                response = ProcessInfo.processInfo.arguments.contains("-HistoryUITestFixture")
                    ? #"{"code":200,"data":{"page":1,"hasMore":false,"list":[{"dramaId":111,"rootDramaId":110,"dramaTitle":"历史测试剧","episodeId":1111,"episodeNo":3,"progressSeconds":65,"isOnline":"online"},{"dramaId":112,"dramaTitle":"历史测试剧乙","episodeId":1112,"episodeNo":5,"progressSeconds":30}]}}"#
                    : #"{"code":200,"data":{"page":1,"hasMore":false,"list":[]}}"#
            case "/mobile/v1/drama/tag/list":
                response = #"{"code":200,"data":{"list":[{"tagId":11,"tagName":"真人剧"},{"tagId":12,"tagName":"剧情"},{"tagId":13,"tagName":"古装"}]}}"#
            case "/mobile/v1/drama/tag/series/list":
                let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Int]
                let id = body?["tagId"] ?? 0
                response = "{\"code\":200,\"data\":{\"hasMore\":false,\"list\":[{\"dramaId\":\(id),\"dramaTitle\":\"标签测试\(id)\"}]}}"
            case "/mobile/v1/drama/category/list":
                response = #"{"code":200,"data":{"list":[{"categoryId":21,"categoryName":"日榜"},{"categoryId":22,"categoryName":"周榜"},{"categoryId":23,"categoryName":"月榜"}]}}"#
            case "/mobile/v2/theater/rank/list":
                let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Int]
                let id = body?["categoryId"] ?? 0
                let list: [[String: Any]] = (1...5).map { rank in
                    ["dramaId": rank == 1 ? id : id * 100 + rank,
                     "dramaTitle": rank == 1 ? "榜单测试\(id)" : "榜单\(id)第\(rank)名",
                     "tagNames": ["剧情", "都市", "甜宠"],
                     "dramaDesc": "榜单简介\(id)，探索精彩故事，发现更多值得观看的好剧。"]
                }
                response = String(data: try! JSONSerialization.data(withJSONObject: ["code": 200, "data": ["list": list]]), encoding: .utf8)!
            case "/mobile/v1/client/drama/random/list":
                response = #"{"code":200,"data":{"list":[{"dramaId":51,"dramaTitle":"随机片刻甲"},{"dramaId":52,"dramaTitle":"随机片刻乙"},{"dramaId":53,"dramaTitle":"随机片刻丙"}]}}"#
            case "/mobile/v1/theater/home":
                response = #"{"code":200,"data":{"banners":[{"id":31,"dramaTitle":"推荐测试"}],"rank":[{"dramaId":41,"dramaTitle":"今日片刻甲","lastEpisodeNo":3},{"dramaId":42,"dramaTitle":"今日片刻乙"},{"dramaId":43,"dramaTitle":"今日片刻丙"},{"dramaId":44,"dramaTitle":"第四项不展示"}],"list":[{"categoryName":"最新发布","list":[{"dramaId":31,"dramaTitle":"推荐测试"}]}]}}"#
            case "/mobile/v1/theater/home/hot/page":
                response = #"{"code":200,"data":{"hasMore":false,"list":[{"dramaId":31,"dramaTitle":"推荐测试"},{"dramaId":32,"dramaTitle":"热门测试"}]}}"#
            case "/mobile/v2/client/list":
                response = #"{"code":200,"data":{"page":1,"hasMore":false,"list":[{"dramaId":101,"rootDramaId":101,"dramaTitle":"剧场测试甲","tagNames":["剧情","古装","甜宠"],"dramaDesc":"这是剧场测试简介，展开后应按文字高度向上显示，不在底部预留空白。","episodePassed":12,"episodes":[{"episodeId":1001,"episodeNo":1,"videoUrl":"https://example.invalid/first.m3u8"}]},{"dramaId":102,"rootDramaId":102,"dramaTitle":"剧场测试乙","episodePassed":24,"episodes":[{"episodeId":1002,"episodeNo":1,"videoUrl":"https://example.invalid/second.m3u8"}]},{"dramaId":103,"rootDramaId":103,"dramaTitle":"剧场测试丙","episodePassed":36,"episodes":[{"episodeId":1003,"episodeNo":1,"videoUrl":"https://example.invalid/third.m3u8"}]}]}}"#
            case "/mobile/v1/client/drama/episode/list":
                let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Int]
                let dramaID = body?["dramaId"] ?? 101
                let expanded = ProcessInfo.processInfo.arguments.contains("-EpisodesUITestFixture")
                let episodes: [[String: Any]] = (1...(expanded ? 80 : 6)).map { number in
                    let locked = expanded ? number >= 17 : number == 6
                    return ["episodeId": dramaID == 111 && number == 3 ? 1111 : dramaID * 100 + number,
                            "episodeNo": number, "unlockCoin": (expanded ? number >= 11 : locked) ? 10 : 0,
                            "isUnlocked": expanded ? (3...16).contains(number) : !locked,
                            "looked": expanded && number <= 2, "likeCount": number * 10]
                }
                response = String(data: try! JSONSerialization.data(withJSONObject:
                    ["code": 200, "data": ["rootDramaId": dramaID, "episodes": episodes]]), encoding: .utf8)!
            default:
                response = #"{"code":200,"data":{}}"#
            }
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                            sampleResponseClosure: { .networkResponse(200, Data(response.utf8)) },
                            method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in .immediate })
        return APIClient(configuration: try! APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                         provider: provider)
    }
    #endif
}
