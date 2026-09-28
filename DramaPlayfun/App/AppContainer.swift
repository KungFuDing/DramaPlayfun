import Foundation
import Observation

@MainActor @Observable
final class AppContainer {
    let network: APIClient
    let repository: any DramaRepository
    let catalog: CatalogStore
    let library: LibraryStore
    let membership: MembershipStore

    init(network: APIClient? = nil,
         repository: (any DramaRepository)? = nil,
         subscriptions: (any SubscriptionService)? = nil,
         defaults: UserDefaults = .standard) {
        self.network = network ?? APIClient()
        let repository = repository ?? DemoDramaRepository()
        self.repository = repository
        catalog = CatalogStore(repository: repository)
        library = LibraryStore(defaults: defaults)
        membership = MembershipStore(service: subscriptions ?? StoreKitSubscriptionService(productIDs: []))
    }
}
