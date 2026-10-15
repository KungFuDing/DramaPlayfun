import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class MembershipTests: XCTestCase {
    func testCatalogUsesAppleProductsDeduplicatesAndIncludesCoinBonuses() async throws {
        let backend = StorePurchaseBackend(network: try client { target in
            XCTAssertEqual(target.path, AppAPI.v1StoreProductList.path)
            XCTAssertEqual(self.body(target)["payChannel"] as? String, "apple")
            return #"{"code":200,"data":{"vipProducts":[{"channelProductId":"week","vipDays":7},{"channelProductId":"year","vipDays":365},{"channelProductId":"year","vipDays":365},{"channelProductId":"android","vipDays":7,"payChannel":"google"},{"vipDays":7}],"coinProducts":[{"channelProductId":"coin","coinAmount":500,"giftCoinAmount":100},{"channelProductId":"total","coinAmount":500,"giftCoinAmount":100,"totalCoinAmount":600},{"channelProductId":"invalid","coinAmount":-1}]}}"#
        })
        let products = try await backend.products()
        XCTAssertEqual(products.map(\.id), ["week", "year", "coin", "total"])
        XCTAssertEqual(products.map(\.category), [.weekly, .yearly, .coins, .coins])
        XCTAssertEqual(products[2].coinAmount, 600)
        XCTAssertEqual(products[3].coinAmount, 600)
    }

    func testCatalogPreservesServerPricesNamesAndPurchaseMetadata() async throws {
        let backend = StorePurchaseBackend(network: try client { _ in
            #"{"code":200,"data":{"vipProducts":[{"channelProductId":"week","channelPlanId":"weekly-plan","productName":"每周会员","vipDays":7,"priceAmount":19.99,"priceCurrency":"CNY"}],"coinProducts":[{"channelProductId":"coin","productName":"超值金币包","coinAmount":500,"giftCoinAmount":100,"priceAmount":8.99,"priceCurrency":"USD"}]}}"#
        })
        let products = try await backend.products()
        XCTAssertEqual(products.map(\.title), ["每周会员", "超值金币包"])
        XCTAssertEqual(products.map(\.priceAmount), [19.99, 8.99])
        XCTAssertEqual(products.map(\.priceCurrency), ["CNY", "USD"])
        XCTAssertEqual(products.first?.channelPlanID, "weekly-plan")
        let plans = products.map(\.plan)
        XCTAssertEqual(plans.map(\.price), [(19.99).formatted(.currency(code: "CNY")),
                                            (8.99).formatted(.currency(code: "USD"))])
        XCTAssertEqual(plans.map(\.period), [L10n.tr("每1周"), ""])
        XCTAssertEqual(plans.last?.coinAmount, 600)
        XCTAssertEqual(plans.last?.giftCoinAmount, 100)
        XCTAssertTrue(plans.allSatisfy { !$0.isAvailableForPurchase })
    }

    func testServerPriceFallbackDoesNotInventCurrencyOrFreePrices() {
        for amount: Double? in [nil, -1, .infinity, -Double.infinity, .nan] {
            let plan = StoreProductConfiguration(id: "year", category: .yearly,
                priceAmount: amount, priceCurrency: "USD").plan
            XCTAssertEqual(plan.price, L10n.tr("价格待更新"))
            XCTAssertEqual(plan.title, L10n.tr("年会员"))
            XCTAssertEqual(plan.period, L10n.tr("每1年"))
            XCTAssertFalse(plan.isAvailableForPurchase)
        }
        for currency: String? in [nil, "", "  "] {
            let plan = StoreProductConfiguration(id: "week", category: .weekly,
                priceAmount: 19.99, priceCurrency: currency).plan
            XCTAssertEqual(plan.price, (19.99).formatted(.number))
        }
        let normalized = StoreProductConfiguration(id: "coin", category: .coins,
            priceAmount: 8.99, priceCurrency: " usd ").plan
        XCTAssertEqual(normalized.price, (8.99).formatted(.currency(code: "USD")))
        let zero = StoreProductConfiguration(id: "coin", category: .coins, priceAmount: 0).plan
        XCTAssertEqual(zero.price, 0.formatted(.number))
    }

    func testStoreShowsServerPricesBeforeAppleRespondsAndRetainsMissingProducts() async throws {
        let backend = StorePurchaseBackend(network: try client { target in
            if target.path == AppAPI.v1StoreProductList.path { return self.pricedCatalog }
            return #"{"code":200,"data":{}}"#
        })
        weak var loadingStore: MembershipStore?
        var serverPlans: [MembershipPlan] = []
        var appleRequests = 0
        let service = StoreKitSubscriptionService(backend: backend, loadProducts: { ids in
            appleRequests += 1
            XCTAssertEqual(ids, ["week", "coin"])
            let store = try XCTUnwrap(loadingStore)
            XCTAssertTrue(store.isLoading)
            serverPlans = store.plans
            XCTAssertEqual(serverPlans.map(\.id), ["week", "coin"])
            XCTAssertEqual(serverPlans.map(\.price), [(19.99).formatted(.currency(code: "CNY")),
                                                      (8.99).formatted(.currency(code: "USD"))])
            XCTAssertTrue(serverPlans.allSatisfy { !$0.isAvailableForPurchase })
            return []
        })
        let store = MembershipStore(service: service)
        loadingStore = store
        await store.loadPlans()
        XCTAssertEqual(appleRequests, 1)
        XCTAssertEqual(store.plans, serverPlans)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.message)
    }

    func testStoreRetainsPublishedServerPricesWhenAppleFailsOrCancels() async throws {
        let errors: [Error] = [URLError(.notConnectedToInternet), CancellationError()]
        for error in errors {
            let backend = StorePurchaseBackend(network: try client { target in
                if target.path == AppAPI.v1StoreProductList.path { return self.pricedCatalog }
                return #"{"code":200,"data":{}}"#
            })
            weak var loadingStore: MembershipStore?
            var serverPlans: [MembershipPlan] = []
            let service = StoreKitSubscriptionService(backend: backend, loadProducts: { _ in
                serverPlans = try XCTUnwrap(loadingStore).plans
                XCTAssertEqual(serverPlans.count, 2)
                throw error
            })
            let store = MembershipStore(service: service)
            loadingStore = store
            await store.loadPlans()
            XCTAssertEqual(store.plans, serverPlans)
            XCTAssertTrue(store.plans.allSatisfy { !$0.isAvailableForPurchase })
            XCTAssertFalse(store.isLoading)
            if error is CancellationError { XCTAssertNil(store.message) }
            else { XCTAssertNotNil(store.message) }
        }
    }

    func testUnknownOrPendingGrantDoesNotUpdateAssets() async throws {
        for status in ["pending", "failed", "", "unexpected"] {
            var updated = false
            let backend = StorePurchaseBackend(network: try client { target in
                if target.path == AppAPI.v1StoreProductList.path { return self.catalog }
                return "{\"code\":200,\"data\":{\"grantStatus\":\"\(status)\",\"walletBalance\":600}}"
            }, didUpdateAssets: { _ in updated = true })
            do {
                try await backend.report(productID: "coin", transactionID: "42", originalID: "42", accountToken: nil)
                XCTFail("未确认发放不应成功")
            } catch StorePurchaseError.awaitingGrant { } catch { XCTFail("\(error)") }
            XCTAssertFalse(updated)
        }
    }

    func testReportSendsVerifiedTransactionIdentityAndAppliesServerBalance() async throws {
        let token = UUID()
        var balance: Int64?
        var reports = 0
        let backend = StorePurchaseBackend(network: try client { target in
            if target.path == AppAPI.v1StoreProductList.path { return self.catalog }
            XCTAssertEqual(target.path, AppAPI.v1PayResultReport.path)
            let body = self.body(target)
            XCTAssertEqual(body["payChannel"] as? String, "apple")
            XCTAssertEqual(body["orderType"] as? String, "coin")
            XCTAssertEqual(body["channelTransactionId"] as? String, "42")
            XCTAssertEqual(body["channelOriginalTxnId"] as? String, "40")
            XCTAssertEqual(body["appAccountToken"] as? String, token.uuidString)
            reports += 1
            return #"{"code":200,"data":{"grantStatus":"success","walletBalance":1600}}"#
        }, didUpdateAssets: { balance = $0 })
        try await backend.report(productID: "coin", transactionID: "42", originalID: "40", accountToken: token)
        try await backend.report(productID: "coin", transactionID: "42", originalID: "40", accountToken: token)
        XCTAssertEqual(balance, 1600, "重复上报只替换服务端余额，不能在客户端重复累加金币")
        XCTAssertEqual(reports, 2)
    }

    func testBackendErrorNeverUpdatesWallet() async throws {
        var updated = false
        let backend = StorePurchaseBackend(network: try client { target in
            if target.path == AppAPI.v1StoreProductList.path { return self.catalog }
            return #"{"code":500,"message":"支付校验失败","data":null}"#
        }, didUpdateAssets: { _ in updated = true })
        do {
            try await backend.report(productID: "coin", transactionID: "42", originalID: "42", accountToken: nil)
            XCTFail("失败响应不应发放权益")
        } catch { }
        XCTAssertFalse(updated)
    }

    func testPrecreateAndRestoreRequestContracts() async throws {
        var paths: [String] = []
        let backend = StorePurchaseBackend(network: try client { target in
            paths.append(target.path)
            let body = self.body(target)
            XCTAssertEqual(body["payChannel"] as? String, "apple")
            if target.path == AppAPI.v1PayOrderPrecreate.path {
                XCTAssertEqual(body["channelProductId"] as? String, "week")
                XCTAssertEqual(body["channelPlanId"] as? String, "plan")
                XCTAssertEqual(body["orderType"] as? String, "vip")
                return #"{"code":200,"data":{"orderNo":"test-order"}}"#
            } else {
                XCTAssertEqual(body["channelTransactionId"] as? String, "12")
                XCTAssertEqual(body["channelOriginalTxnId"] as? String, "10")
            }
            return #"{"code":200,"data":{}}"#
        })
        try await backend.prepare(.init(id: "week", category: .weekly, channelPlanID: "plan"))
        try await backend.restore(transactionID: "12", originalID: "10")
        XCTAssertEqual(paths, [AppAPI.v1PayOrderPrecreate.path, AppAPI.v1PayPurchaseRestore.path])
    }

    func testMissingPrecreatedOrderStopsPurchaseFlow() async throws {
        let backend = StorePurchaseBackend(network: try client { _ in #"{"code":200,"data":{}}"# })
        do {
            try await backend.prepare(.init(id: "week", category: .weekly))
            XCTFail("空响应不应视为订单创建成功")
        } catch StorePurchaseError.orderUnavailable { } catch { XCTFail("\(error)") }
    }

    func testVIPStateUsesCycleAndServerStatus() async throws {
        var status = "active"
        let backend = StorePurchaseBackend(network: try client { _ in
            "{\"code\":200,\"data\":{\"vipStatus\":\"\(status)\",\"currentVipCycle\":\"year\",\"expireAt\":1893456000000}}"
        })
        let active = try await backend.entitlement()
        XCTAssertTrue(active.isActive(for: .yearly))
        XCTAssertFalse(active.isActive(for: .weekly))
        XCTAssertFalse(active.isActive(for: .coins))
        XCTAssertEqual(active.expirationDate, Date(timeIntervalSince1970: 1893456000))
        status = "expired"
        let expired = try await backend.entitlement()
        XCTAssertFalse(expired.isActive)
    }

    func testTemporaryEntitlementFailurePreservesKnownMembership() async {
        let service = MembershipTestService()
        service.asset = .init(isActive: true, category: .yearly)
        let store = MembershipStore(service: service)
        await store.refresh()
        service.failRefresh = true
        await store.refresh()
        XCTAssertTrue(store.isActive)
        XCTAssertNotNil(store.message)
    }

    func testCoinPurchaseDoesNotGrantMembership() async {
        let service = MembershipTestService()
        let store = MembershipStore(service: service)
        await store.purchase(.init(id: "coin", title: "金币", price: "$4.99", period: "", category: .coins))
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(store.message, L10n.tr("充值成功，金币已到账"))
    }

    private var catalog: String { #"{"code":200,"data":{"coinProducts":[{"channelProductId":"coin","coinAmount":500}]}}"# }
    private var pricedCatalog: String {
        #"{"code":200,"data":{"vipProducts":[{"channelProductId":"week","vipDays":7,"priceAmount":19.99,"priceCurrency":"CNY"}],"coinProducts":[{"channelProductId":"coin","coinAmount":500,"priceAmount":8.99,"priceCurrency":"USD"}]}}"#
    }
    private func body(_ target: APITarget) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Any] ?? [:]
    }
    private func client(response: @escaping (APITarget) -> String) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(response(target).utf8)) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in .immediate })
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!), provider: provider)
    }
}

@MainActor
private final class MembershipTestService: SubscriptionService {
    var asset = MembershipEntitlement()
    var failRefresh = false
    func plans() async throws -> [MembershipPlan] { [] }
    func hasActiveSubscription() async throws -> Bool { asset.isActive }
    func entitlement() async throws -> MembershipEntitlement {
        if failRefresh { throw URLError(.notConnectedToInternet) }
        return asset
    }
    func purchase(planID: String) async throws -> PurchaseOutcome { .purchased }
    func restore() async throws { }
    func observeTransactions(onChange: @escaping @MainActor () async -> Void) async { }
}
