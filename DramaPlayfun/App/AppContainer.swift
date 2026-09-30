import Foundation
import Observation
#if DEBUG
import Moya
#endif

@MainActor @Observable
final class AppContainer {
    let network: APIClient
    let repository: any DramaRepository
    let catalog: CatalogStore
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
        let fixture = ProcessInfo.processInfo.arguments.contains("-TheaterUITestFixture")
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
        let repository = repository ?? APIDramaRepository(network: self.network,
                                                          fallback: DemoDramaRepository())
        self.repository = repository
        catalog = CatalogStore(repository: repository)
        homeFeed = HomeFeedStore(network: self.network)
        theaterFeed = TheaterFeedStore(network: self.network)
        library = LibraryStore(defaults: defaults)
        hlsCache = .shared
        theaterPlayback = TheaterPlayerPool(library: library, cache: hlsCache)
        membership = MembershipStore(service: subscriptions ?? StoreKitSubscriptionService(productIDs: []))
    }

    #if DEBUG
    private static func theaterUITestClient() -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let response: String
            switch target.path {
            case "/mobile/v2/client/list":
                response = #"{"code":200,"data":{"page":1,"hasMore":false,"list":[{"dramaId":101,"rootDramaId":101,"dramaTitle":"剧场测试甲","episodePassed":12,"episodes":[{"episodeId":1001,"episodeNo":1,"videoUrl":"https://example.invalid/first.m3u8"}]},{"dramaId":102,"rootDramaId":102,"dramaTitle":"剧场测试乙","episodePassed":24,"episodes":[{"episodeId":1002,"episodeNo":1,"videoUrl":"https://example.invalid/second.m3u8"}]},{"dramaId":103,"rootDramaId":103,"dramaTitle":"剧场测试丙","episodePassed":36,"episodes":[{"episodeId":1003,"episodeNo":1,"videoUrl":"https://example.invalid/third.m3u8"}]}]}}"#
            case "/mobile/v1/client/drama/episode/list":
                response = #"{"code":200,"data":{"episodes":[{"episodeId":1002,"episodeNo":1,"videoUrl":"https://example.invalid/second.m3u8","unlockCoin":0},{"episodeId":2002,"episodeNo":2,"videoUrl":"https://example.invalid/locked.m3u8","unlockCoin":10}]}}"#
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
