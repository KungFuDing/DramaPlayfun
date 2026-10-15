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
    let profile: ProfileStore
    let wallet: WalletStore
    let welfare: WelfareStore

    init(network: APIClient? = nil,
         repository: (any DramaRepository)? = nil,
         subscriptions: (any SubscriptionService)? = nil,
         defaults: UserDefaults = .standard) {
        #if DEBUG
        let fixture = (ProcessInfo.processInfo.arguments.contains("-ProfileUITestFixture") ||
                       ProcessInfo.processInfo.arguments.contains("-TheaterUITestFixture") ||
                       ProcessInfo.processInfo.arguments.contains("-FeedUITestFixture") ||
                       ProcessInfo.processInfo.arguments.contains("-HistoryUITestFixture") ||
                       ProcessInfo.processInfo.arguments.contains("-WelfareUITestFixture") ||
                       ProcessInfo.processInfo.arguments.contains("-SearchUITestFixture") ||
                       ProcessInfo.processInfo.arguments.contains("-PlayerUnlockUITestFixture") ||
                       ProcessInfo.processInfo.arguments.contains("-MembershipUITestFixture"))
            ? Self.theaterUITestClient() : nil
        #endif
        self.network = network ?? {
            #if DEBUG
            if let fixture { return fixture }
            #endif
            return APIClient(payloadCipher: APIPayloadCipher(password: "8Oq60JucZPKeyttJdhqX"),
                usesServerEncryptionConfiguration: true, headerProvider: { _ in
            #if DEBUG
            DebugHTTPHeaders.current
            #else
            [:]
            #endif
            })
        }()
        guestSession = GuestSessionStore(network: self.network, defaults: defaults)
        profile = ProfileStore(network: self.network)
        wallet = WalletStore(network: self.network, profile: profile)
        welfare = WelfareStore(network: self.network, wallet: wallet)
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
            progressReporter: TheaterProgressReporter(network: self.network),
            refreshURLs: { [theaterFeed] item in try await theaterFeed.refreshPlaybackURLs(for: item) })
        let purchaseBackend = StorePurchaseBackend(network: self.network) { [wallet, profile] balance in
            if let balance { wallet.updateBalance(balance) }
            await profile.reloadProfile()
            await wallet.reloadBalance()
        }
        var subscriptionService: any SubscriptionService = subscriptions ?? StoreKitSubscriptionService(backend: purchaseBackend)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-MembershipUITestFixture") ||
            ProcessInfo.processInfo.arguments.contains("-PlayerUnlockUITestFixture") {
            subscriptionService = MembershipUITestService()
        }
        #endif
        membership = MembershipStore(service: subscriptionService)
    }

    #if DEBUG
    private static func theaterUITestClient() -> APIClient {
        let welfareAccount = WelfareUITestAccount()
        let unlockAccount = ProcessInfo.processInfo.arguments.contains("-PlayerUnlockUITestFixture")
            ? PlayerUnlockUITestAccount() : nil
        var searchHistory = ["重生之我和白月光", "不是哥们,你开局玩这么大", "炎帝", "我是祖国人", "都市甜宠", "白月光的日常生活", "重生", "我以异能斩规则"]
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            if let response = unlockAccount?.response(for: target) {
                return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                                sampleResponseClosure: { .networkResponse(200, Data(response.utf8)) },
                                method: target.method, task: target.task, httpHeaderFields: target.headers)
            }
            let response: String
            switch target.path {
            case "/mobile/v1/auth/guest/login":
                response = #"{"code":200,"data":{"accessToken":"ui-test-guest-token"}}"#
            case "/mobile/v1/client/me":
                let vip = ProcessInfo.processInfo.arguments.contains("-ProfileVIPUITestFixture")
                response = String(data: try! JSONSerialization.data(withJSONObject: ["code": 200, "data":
                    ["userNo": "143143257", "nickname": "晚风放映厅",
                     "coinAmount": ProcessInfo.processInfo.arguments.contains("-WelfareUITestFixture") ? welfareAccount.snapshot.balance : 360,
                     "autoPlayNext": welfareAccount.snapshot.autoPlayNext,
                     "vipExpireAt": vip ? 1893456000000 : 0]]), encoding: .utf8)!
            case "/mobile/v1/wallet/info":
                response = "{\"code\":200,\"data\":{\"balanceCoin\":\(welfareAccount.snapshot.balance)}}"
            case "/mobile/v1/client/me/autoPlayNext/set":
                let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: String]
                welfareAccount.setAutoPlay(body?["autoPlayNext"] ?? "on")
                response = "{\"code\":200,\"data\":{\"autoPlayNext\":\"\(body?["autoPlayNext"] ?? "on")\"}}"
            case "/mobile/v1/welfare/sign/popup/status":
                let account = welfareAccount.snapshot
                response = "{\"code\":200,\"data\":{\"shouldPopup\":\(!account.signed),\"hasReceivedToday\":\(account.signed),\"rewardCoin\":30,\"signDay\":\(account.signed ? account.signDays : account.signDays + 1)}}"
            case "/mobile/v1/welfare/sign/receive":
                let received = welfareAccount.signIn()
                let account = welfareAccount.snapshot
                response = "{\"code\":200,\"data\":{\"received\":\(received),\"rewardCoin\":30,\"walletBalance\":\(account.balance),\"signDay\":\(account.signDays)}}"
            case "/mobile/v1/welfare/task/list":
                let account = welfareAccount.snapshot
                let rewards: [[String: Any]] = [20, 30, 40, 50, 60, 70, 120].enumerated().map { index, coins in
                    ["signDay": index + 1, "rewardCoin": coins, "status": index < account.signDays]
                }
                let tasks: [[String: Any]] = [
                    ["taskCode": "daily_sign_in", "signRewards": rewards],
                    ["taskCode": "share_video", "taskName": "分享视频", "completedCount": 10, "dailyLimit": 10, "rewardCoin": 100],
                    ["taskCode": "watch_drama", "taskName": "观看视频", "completedCount": 9, "dailyLimit": 15, "rewardCoin": 100],
                    ["taskCode": "like_video", "taskName": "点赞视频", "completedCount": 0, "dailyLimit": 10, "rewardCoin": 100],
                    ["taskCode": "collect_video", "taskName": "收藏视频", "completedCount": 0, "dailyLimit": 10, "rewardCoin": 100]]
                response = String(data: try! JSONSerialization.data(withJSONObject:
                    ["code": 200, "data": ["continuousSignDays": account.signDays, "list": tasks]]), encoding: .utf8)!
            case "/mobile/v1/order/recharge/list":
                let records: [[String: Any]] = (0..<8).map { index in
                    ["productName": "订阅周会员", "payAmount": 98, "currency": "USD",
                     "transactionTime": index < 4 ? 1789171200000 : 1791763200000]
                }
                response = String(data: try! JSONSerialization.data(withJSONObject:
                    ["code": 200, "data": ["total": 8, "list": records]]), encoding: .utf8)!
            case "/mobile/v1/wallet/bill/list":
                let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Any]
                let expense = body?["billType"] as? String == "expense"
                let groups: [[String: Any]] = ["2026-09", "2026-10"].enumerated().map { month, yearMonth in
                    let records: [[String: Any]] = (0..<4).map { index in
                        ["bizType": expense ? "unlock_episode" : "reward",
                         "sourceTitle": expense ? (index == 1 ? "我的女儿谁害的我的女儿谁害的我的女儿" : "我的女儿谁害的") : ["充值500金币", "充值500金币", "观看视频", "点赞视频"][index],
                         "episodeNo": index == 1 ? 12 : 2, "changeCoin": expense ? -20 : 100,
                         "createdAt": month == 0 ? 1789171200000 : 1791763200000]
                    }
                    return ["yearMonth": yearMonth, "items": records]
                }
                response = String(data: try! JSONSerialization.data(withJSONObject:
                    ["code": 200, "data": ["total": 8, "list": groups]]), encoding: .utf8)!
            case "/mobile/v1/client/app/config":
                response = #"{"code":200,"data":{}}"#
            case "/mobile/v1/client/language/list":
                response = #"{"code":200,"data":{"list":[{"languageCode":"zh","translatedName":"中文","sortOrder":0},{"languageCode":"en","translatedName":"English","sortOrder":1},{"languageCode":"ja","translatedName":"にほんご","sortOrder":2},{"languageCode":"ko","translatedName":"한국어","sortOrder":3},{"languageCode":"es","translatedName":"Español","sortOrder":4},{"languageCode":"fr","translatedName":"Français","sortOrder":5},{"languageCode":"de","translatedName":"Deutsch","sortOrder":6}]}}"#
            case "/mobile/v1/client/me/favorites", "/mobile/v1/client/me/likes":
                response = #"{"code":200,"data":{"page":1,"hasMore":false,"list":[{"dramaId":101,"dramaTitle":"重生之我和白月光","episodeText":"剧情  都市  甜宠"},{"dramaId":102,"dramaTitle":"重生之我和白月光的日常生活","episodeText":"剧情  都市  甜宠"},{"dramaId":103,"dramaTitle":"重生之我和白月光的日常生活","episodeText":"剧情  都市  甜宠"},{"dramaId":104,"dramaTitle":"重生之我和白月光","episodeText":"剧情  都市  甜宠"}]}}"#
            case "/mobile/v1/client/drama/share/text":
                response = #"{"code":200,"data":{"text":"https://example.invalid/drama/first-episode"}}"#
            case "/mobile/v1/client/drama/detail":
                let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Int]
                let id = body?["dramaId"] ?? 101
                let summary = String(repeating: "这是详情接口返回的剧情简介，讲述主角重生后改变命运的故事。", count: 8)
                response = String(data: try! JSONSerialization.data(withJSONObject: ["code": 200, "data": ["drama":
                    ["dramaId": id, "dramaTitle": "详情测试\(id)", "dramaDesc": summary,
                     "tagNames": ["剧情", "都市", "甜宠"], "episodePassed": 68,
                     "isFavorited": id == 202, "favoriteCount": 20]]]), encoding: .utf8)!
            case "/mobile/v1/client/drama/guess/like":
                response = #"{"code":200,"data":{"list":[{"dramaId":201,"dramaTitle":"推荐短剧甲","tagNames":["剧情","都市","甜宠"],"badge":"hot"},{"dramaId":202,"dramaTitle":"推荐短剧乙","tagNames":["剧情","都市"],"badge":"new"},{"dramaId":203,"dramaTitle":"推荐短剧丙"}]}}"#
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
                if ProcessInfo.processInfo.arguments.contains("-ProfileHistoryUITestFixture") {
                    let titles = ["赶得上,就娶你", "全家抢我神笔许愿,全玩脱了", "重生后,我掀翻侯府"]
                    let records: [[String: Any]] = (0..<6).map { index -> [String: Any] in
                        let episode = index == 0 ? 3 : 12
                        return ["dramaId": 111 + index, "rootDramaId": 110,
                         "dramaTitle": titles[index % 3], "episodeId": 1111 + index,
                         "episodeNo": episode, "progressSeconds": 65,
                         "episodeText": index == 0 ? "3集/134集" : "12集/134集",
                         "isOnline": index == 5 ? "offline" : "online"]
                    }
                    response = String(data: try! JSONSerialization.data(withJSONObject:
                        ["code": 200, "data": ["page": 1, "hasMore": false, "list": records]]), encoding: .utf8)!
                } else {
                    response = ProcessInfo.processInfo.arguments.contains("-HistoryUITestFixture")
                        ? #"{"code":200,"data":{"page":1,"hasMore":false,"list":[{"dramaId":111,"rootDramaId":110,"dramaTitle":"历史测试剧","episodeId":1111,"episodeNo":3,"progressSeconds":65,"isOnline":"online"},{"dramaId":112,"dramaTitle":"历史测试剧乙","episodeId":1112,"episodeNo":5,"progressSeconds":30}]}}"#
                        : #"{"code":200,"data":{"page":1,"hasMore":false,"list":[]}}"#
                }
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
                if ProcessInfo.processInfo.arguments.contains("-SearchUITestFixture") {
                    response = #"{"code":200,"data":{"hasMore":false,"list":[{"dramaId":31,"dramaTitle":"重生之我和白月光","tagNames":["剧情","都市","甜宠"],"badge":"new"},{"dramaId":32,"dramaTitle":"重生之我和白月光的日常生活","tagNames":["剧情","都市","甜宠"],"badge":"new"},{"dramaId":33,"dramaTitle":"重生之我和白月光的日常生活","tagNames":["剧情","都市","甜宠"],"badge":"hot"},{"dramaId":34,"dramaTitle":"重生之我和白月光","tagNames":["剧情","都市","甜宠"]}]}}"#
                } else if ProcessInfo.processInfo.arguments.contains("-WaterfallUITestFixture") {
                    response = #"{"code":200,"data":{"hasMore":false,"list":[{"dramaId":31,"dramaTitle":"短标题","tagNames":["剧情","都市","甜宠"]},{"dramaId":32,"dramaTitle":"这是一个需要换行展示的较长短剧标题","tagNames":["剧情","甜宠"]},{"dramaId":33,"dramaTitle":"第二个短标题","tagNames":["都市"]},{"dramaId":34,"dramaTitle":"另一部需要两行展示名称的短剧","tagNames":["剧情","都市","甜宠"]},{"dramaId":35,"dramaTitle":"第三个短标题"},{"dramaId":36,"dramaTitle":"长标题继续测试瀑布流的固定间距"}]}}"#
                } else {
                    response = #"{"code":200,"data":{"hasMore":false,"list":[{"dramaId":31,"dramaTitle":"推荐测试"},{"dramaId":32,"dramaTitle":"热门测试"}]}}"#
                }
            case "/mobile/v1/theater/search/history":
                response = String(data: try! JSONSerialization.data(withJSONObject:
                    ["code": 200, "data": ["list": searchHistory]]), encoding: .utf8)!
            case "/mobile/v1/theater/search/history/clear":
                searchHistory = []
                response = #"{"code":200,"data":{}}"#
            case "/mobile/v1/theater/search", "/mobile/v1/theater/search/guess":
                let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Any]
                let keyword = body?["keyword"] as? String ?? ""
                if target.path == "/mobile/v1/theater/search" {
                    searchHistory = [keyword] + searchHistory.filter { $0 != keyword }
                }
                let items: [[String: Any]] = keyword == "不存在" ? [] : [
                    ["dramaId": 801, "rootDramaId": 801, "dramaTitle": keyword,
                     "tagNames": ["剧情", "都市", "甜宠"], "dramaDesc": "什么忍者卡卡西，拙劣模仿五条悟大人的可笑货色罢了！"]]
                response = String(data: try! JSONSerialization.data(withJSONObject:
                    ["code": 200, "data": ["list": items, "page": 1, "hasMore": false]]), encoding: .utf8)!
            case "/mobile/v2/client/list":
                response = #"{"code":200,"data":{"page":1,"hasMore":false,"list":[{"dramaId":101,"rootDramaId":101,"dramaTitle":"剧场测试甲","tagNames":["剧情","古装","甜宠"],"dramaDesc":"这是剧场测试简介，展开后应按文字高度向上显示，不在底部预留空白。","episodePassed":12,"episodes":[{"episodeId":1001,"episodeNo":1,"videoUrl":"https://example.invalid/first.m3u8"}]},{"dramaId":102,"rootDramaId":102,"dramaTitle":"剧场测试乙","episodePassed":24,"episodes":[{"episodeId":1002,"episodeNo":1,"videoUrl":"https://example.invalid/second.m3u8"}]},{"dramaId":103,"rootDramaId":103,"dramaTitle":"剧场测试丙","episodePassed":36,"episodes":[{"episodeId":1003,"episodeNo":1,"videoUrl":"https://example.invalid/third.m3u8"}]}]}}"#
            case "/mobile/v1/client/drama/episode/list":
                let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Int]
                let dramaID = body?["dramaId"] ?? 101
                let expanded = ProcessInfo.processInfo.arguments.contains("-EpisodesUITestFixture")
                let episodes: [[String: Any]] = (1...(expanded ? 80 : 6)).map { number in
                    let locked = expanded ? number >= 17 : number == 6
                    var episode: [String: Any] = ["episodeId": dramaID == 111 && number == 3 ? 1111 : dramaID * 100 + number,
                            "episodeNo": number, "unlockCoin": (expanded ? number >= 11 : locked) ? 10 : 0,
                            "isUnlocked": expanded ? (3...16).contains(number) : !locked,
                            "looked": expanded && number <= 2, "likeCount": number * 10]
                    if ProcessInfo.processInfo.arguments.contains("-PlaybackProgressUITestFixture") {
                        episode["videoUrl"] = "https://example.invalid/progress.m3u8"
                    }
                    return episode
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
