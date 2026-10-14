import XCTest
import StoreKit
import StoreKitTest
import Moya
@testable import DramaPlayfun

/// Exercises StoreKit 2 with local transactions, without using a real Apple account or charging money.
@MainActor
final class MembershipStoreKitTests: XCTestCase {
    private var session: SKTestSession!
    private let productID = "test.membership.coins"

    override func setUpWithError() throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Membership", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: file)
        session.resetToDefaultState()
        session.disableDialogs = true
        guard session.disableDialogs else {
            throw XCTSkip("StoreKit 本地测试服务未启用；请使用 Debug 模拟器开发签名运行，勿设置 CODE_SIGNING_ALLOWED=NO。")
        }
        session.clearTransactions()
    }

    override func tearDownWithError() throws {
        session?.clearTransactions()
        session?.resetToDefaultState()
        session = nil
    }

    func testApplePricesUpdateOnlyMatchingProductsAndPreserveCatalogOrder() async throws {
        let appleProducts = try await Product.products(for: [productID])
        let appleProduct = try XCTUnwrap(appleProducts.first)
        let backend = StorePurchaseBackend(network: try client { _ in
            """
            {"code":200,"data":{
              "vipProducts":[{"channelProductId":"missing.week","vipDays":7,"priceAmount":19.99,"priceCurrency":"CNY"}],
              "coinProducts":[
                {"channelProductId":"\(self.productID)","productName":"服务器金币包","coinAmount":500,"giftCoinAmount":100,"priceAmount":8.99,"priceCurrency":"USD"},
                {"channelProductId":"missing.coins","coinAmount":1000,"priceAmount":16.99,"priceCurrency":"USD"}
              ]
            }}
            """
        })
        let service = StoreKitSubscriptionService(backend: backend, loadProducts: { ids in
            XCTAssertEqual(ids, ["missing.week", self.productID, "missing.coins"])
            return appleProducts
        })
        var serverPlans: [MembershipPlan] = []
        let plans = try await service.plans(onUpdate: { serverPlans = $0 })
        XCTAssertEqual(plans.map(\.id), ["missing.week", productID, "missing.coins"])
        XCTAssertEqual(serverPlans.count, 3)
        XCTAssertEqual(plans[0], serverPlans[0])
        XCTAssertEqual(plans[2], serverPlans[2])
        XCTAssertEqual(plans[1].price, appleProduct.displayPrice)
        XCTAssertNotEqual(plans[1].price, serverPlans[1].price)
        XCTAssertEqual(plans[1].category, .coins)
        XCTAssertEqual(plans[1].coinAmount, 600)
        XCTAssertEqual(plans[1].giftCoinAmount, 100)
        XCTAssertTrue(plans[1].isAvailableForPurchase)
        XCTAssertFalse(serverPlans[1].isAvailableForPurchase)
    }

    func testWrongAppleProductTypeKeepsServerPriceAndCannotBePurchased() async throws {
        let appleProducts = try await Product.products(for: [productID])
        XCTAssertEqual(appleProducts.count, 1)
        var paths: [String] = []
        let backend = StorePurchaseBackend(network: try client { target in
            paths.append(target.path)
            return """
            {"code":200,"data":{"vipProducts":[{"channelProductId":"\(self.productID)","vipDays":7,"priceAmount":19.99,"priceCurrency":"CNY"}]}}
            """
        })
        let service = StoreKitSubscriptionService(backend: backend, loadProducts: { _ in appleProducts })
        var serverPlans: [MembershipPlan] = []
        let plans = try await service.plans(onUpdate: { serverPlans = $0 })
        XCTAssertEqual(plans, serverPlans)
        XCTAssertEqual(plans.first?.category, .weekly)
        XCTAssertEqual(plans.first?.isAvailableForPurchase, false)
        do {
            _ = try await service.purchase(planID: productID)
            XCTFail("金币 SKU 不能作为周会员购买")
        } catch StorePurchaseError.productUnavailable { }
        XCTAssertEqual(paths, [AppAPI.v1StoreProductList.path])
    }

    func testVerifiedCoinTransactionStaysUnfinishedUntilServerGrantsAssets() async throws {
        var granted = false
        var reported: [String] = []
        let backend = StorePurchaseBackend(network: try client { target in
            if target.path == AppAPI.v1StoreProductList.path { return self.catalog }
            if target.path == AppAPI.v1PayResultReport.path {
                let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: String]
                if let id = body?["channelTransactionId"] { reported.append(id) }
                return "{\"code\":200,\"data\":{\"grantStatus\":\"\(granted ? "success" : "pending")\"}}"
            }
            return #"{"code":200,"data":{"orderNo":"test-order"}}"#
        })
        let service = StoreKitSubscriptionService(backend: backend)
        let plans = try await service.plans()
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.category, .coins)
        do {
            _ = try await service.purchase(planID: productID)
            XCTFail("服务端未发放不应返回购买完成")
        } catch StorePurchaseError.awaitingGrant { }
        let unfinished = await unfinishedIDs(expectedCount: 1)
        XCTAssertEqual(unfinished.count, 1)
        XCTAssertEqual(reported, unfinished)
        granted = true
        try await service.restore()
        let remaining = await unfinishedIDs(expectedCount: 0)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(reported, unfinished + unfinished, "恢复购买重试同一交易，服务端可据此幂等处理")
    }

    func testAskToBuyRemainsPendingWithoutReportingPayment() async throws {
        session.askToBuyEnabled = true
        var reports = 0
        let backend = StorePurchaseBackend(network: try client { target in
            if target.path == AppAPI.v1StoreProductList.path { return self.catalog }
            if target.path == AppAPI.v1PayResultReport.path { reports += 1 }
            return #"{"code":200,"data":{"orderNo":"test-order"}}"#
        })
        let service = StoreKitSubscriptionService(backend: backend)
        _ = try await service.plans()
        let outcome = try await service.purchase(planID: productID)
        guard case .pending = outcome else { return XCTFail("家长批准前应保持待处理") }
        XCTAssertEqual(reports, 0)
    }

    private func unfinishedIDs(expectedCount: Int) async -> [String] {
        // StoreKit's local transaction cache can trail the purchase/finish completion.
        var ids: [String] = []
        for _ in 0..<40 {
            ids = []
            for await result in StoreKit.Transaction.unfinished {
                if case .verified(let transaction) = result, transaction.productID == productID { ids.append(String(transaction.id)) }
            }
            if ids.count == expectedCount { return ids }
            try? await _Concurrency.Task.sleep(for: .milliseconds(50))
        }
        return ids
    }
    private var catalog: String {
        "{\"code\":200,\"data\":{\"coinProducts\":[{\"channelProductId\":\"\(productID)\",\"coinAmount\":500}]}}"
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
