import Foundation
import Observation

@MainActor @Observable
final class AppContainer {
    let network: APIClient
    let repository: any DramaRepository
    let catalog: CatalogStore
    let homeFeed: HomeFeedStore
    let library: LibraryStore
    let membership: MembershipStore

    init(network: APIClient? = nil,
         repository: (any DramaRepository)? = nil,
         subscriptions: (any SubscriptionService)? = nil,
         defaults: UserDefaults = .standard) {
        self.network = network ?? APIClient(headerProvider: { _ in
            #if DEBUG
            DebugHTTPHeaders.current
            #else
            [:]
            #endif
        })
        let repository = repository ?? DemoDramaRepository()
        self.repository = repository
        catalog = CatalogStore(repository: repository)
        homeFeed = HomeFeedStore(network: self.network)
        library = LibraryStore(defaults: defaults)
        membership = MembershipStore(service: subscriptions ?? StoreKitSubscriptionService(productIDs: []))
    }
}
