import XCTest
import SwiftUI
@testable import DramaPlayfun

@MainActor
final class DramaPlayfunTests: XCTestCase {
    func testCatalogCombinesCategoryAndSearch() async {
        let store = CatalogStore(repository: DemoDramaRepository())
        await store.loadIfNeeded()
        XCTAssertEqual(store.filtered(category: .romance, query: " " + L10n.tr("重生之我和白月光") + " ").map(\.id), ["moon"])
        XCTAssertTrue(store.filtered(category: .costume, query: L10n.tr("重生之我和白月光")).isEmpty)
    }

    func testLibraryPersistsFavoritesAndResumePosition() throws {
        let suite = "DramaPlayfunTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(defaults: defaults)
        store.toggleFavorite("moon")
        let progress = WatchProgress(dramaID: "moon", episodeID: "moon-2", episodeNumber: 2,
                                     seconds: 30, duration: 120, updatedAt: Date())
        store.save(progress)
        let restored = LibraryStore(defaults: defaults)
        XCTAssertTrue(restored.favoriteIDs.contains("moon"))
        XCTAssertEqual(restored.progress["moon"], progress)
        XCTAssertEqual(restored.progress["moon"]?.fraction, 0.25)
        restored.toggleFavorite("moon")
        XCTAssertTrue(LibraryStore(defaults: defaults).favoriteIDs.isEmpty)
    }

    func testTabsKeepIndependentNavigationPaths() {
        let router = AppRouter()
        let drama = DemoDramaRepository.dramas[0]
        router.path(for: .home).wrappedValue = [.drama(drama)]
        router.selectedTab = .theater
        XCTAssertTrue(router.path(for: .theater).wrappedValue.isEmpty)
        XCTAssertEqual(router.path(for: .home).wrappedValue, [.drama(drama)])
    }

    func testPendingAndCancelledPurchasesDoNotGrantMembership() async {
        let service = TestSubscriptions()
        let store = MembershipStore(service: service)
        await store.loadPlans()
        await store.purchase(service.plan)
        XCTAssertFalse(store.isActive)
        XCTAssertNotNil(store.message)
        service.outcome = .cancelled
        await store.purchase(service.plan)
        XCTAssertFalse(store.isActive)
        XCTAssertNil(store.message)
    }

    func testPurchaseAndRestoreReadVerifiedEntitlements() async {
        let service = TestSubscriptions()
        service.outcome = .purchased
        let store = MembershipStore(service: service)
        await store.purchase(service.plan)
        XCTAssertTrue(store.isActive)
        service.active = false
        await store.refresh()
        XCTAssertFalse(store.isActive)
        await store.restore()
        XCTAssertTrue(store.isActive)
    }
}

@MainActor
private final class TestSubscriptions: SubscriptionService {
    let plan = MembershipPlan(id: "test.monthly", title: "月度会员", price: "¥10", period: "每1个月自动续订")
    var outcome: PurchaseOutcome = .pending
    var active = false
    func plans() async throws -> [MembershipPlan] { [plan] }
    func hasActiveSubscription() async throws -> Bool { active }
    func purchase(planID: String) async throws -> PurchaseOutcome {
        if case .purchased = outcome { active = true }
        return outcome
    }
    func restore() async throws { active = true }
    func observeTransactions(onChange: @escaping @MainActor () async -> Void) async {}
}
