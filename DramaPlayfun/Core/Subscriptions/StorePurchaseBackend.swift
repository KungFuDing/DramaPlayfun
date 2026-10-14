import Foundation

struct StoreProductConfiguration {
    let id: String
    let category: MembershipCategory
    var channelPlanID: String?
    var coinAmount: Int64 = 0
    var giftCoinAmount: Int64 = 0
    var orderType: String { category == .coins ? "coin" : "vip" }
}

/// The server grants assets idempotently by Apple's transaction ID. Never increment balances locally.
@MainActor
final class StorePurchaseBackend {
    private let network: APIClient
    private var catalog: [String: StoreProductConfiguration] = [:]
    private let didUpdateAssets: @MainActor (Int64?) async -> Void

    init(network: APIClient, didUpdateAssets: @escaping @MainActor (Int64?) async -> Void = { _ in }) {
        self.network = network
        self.didUpdateAssets = didUpdateAssets
    }

    func products() async throws -> [StoreProductConfiguration] {
        let result = try await network.request(AppAPI.v1StoreProductList,
            body: .init(payChannel: "apple"), unwrapEnvelope: true)
        var items: [StoreProductConfiguration] = []
        for item in result.vipProducts ?? [] {
            guard item.payChannel == nil || item.payChannel == "apple",
                  let id = item.channelProductId, !id.isEmpty else { continue }
            let category: MembershipCategory
            switch item.vipDays {
            case 7: category = .weekly
            case 365, 366: category = .yearly
            default: continue
            }
            items.append(.init(id: id, category: category, channelPlanID: item.channelPlanId))
        }
        for item in result.coinProducts ?? [] {
            guard item.payChannel == nil || item.payChannel == "apple",
                  let id = item.channelProductId, !id.isEmpty,
                  let amount = item.totalCoinAmount ?? item.coinAmount, amount > 0 else { continue }
            let gift = max(0, item.giftCoinAmount ?? 0)
            let sum = amount.addingReportingOverflow(gift)
            guard item.totalCoinAmount != nil || !sum.overflow else { continue }
            let total = item.totalCoinAmount ?? sum.partialValue
            guard total > 0 else { continue }
            items.append(.init(id: id, category: .coins, coinAmount: total, giftCoinAmount: gift))
        }
        var seen = Set<String>()
        items = items.filter { seen.insert($0.id).inserted }
        catalog = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return items
    }

    func configuration(for id: String) async throws -> StoreProductConfiguration {
        if let item = catalog[id] { return item }
        _ = try await products()
        guard let item = catalog[id] else { throw StorePurchaseError.productUnavailable }
        return item
    }

    func prepare(_ item: StoreProductConfiguration) async throws {
        let result = try await network.request(AppAPI.v1PayOrderPrecreate,
            body: .init(payChannel: "apple", channelProductId: item.id,
                        channelPlanId: item.channelPlanID, orderType: item.orderType), unwrapEnvelope: true)
        guard result.orderNo?.isEmpty == false || (result.paymentOrderId ?? 0) > 0 else {
            throw StorePurchaseError.orderUnavailable
        }
    }

    func report(productID: String, transactionID: String, originalID: String, accountToken: UUID?) async throws {
        let item = try await configuration(for: productID)
        let result = try await network.request(AppAPI.v1PayResultReport,
            body: .init(payChannel: "apple", channelTransactionId: transactionID,
                        channelOriginalTxnId: originalID, channelProductId: productID,
                        channelPlanId: item.channelPlanID, orderType: item.orderType,
                        appAccountToken: accountToken?.uuidString), unwrapEnvelope: true)
        // A successful HTTP envelope alone does not mean that the assets have been granted.
        // Unknown/missing statuses keep the StoreKit transaction unfinished for recovery.
        // The API schema omits this enum; confirm "success" with the backend before sandbox acceptance.
        guard result.grantStatus == "success" else { throw StorePurchaseError.awaitingGrant }
        await didUpdateAssets(result.walletBalance)
    }

    func restore(transactionID: String, originalID: String) async throws {
        let result = try await network.request(AppAPI.v1PayPurchaseRestore,
            body: .init(payChannel: "apple", channelTransactionId: transactionID,
                        channelOriginalTxnId: originalID), unwrapEnvelope: true)
        await didUpdateAssets(result.walletBalance)
    }

    func entitlement() async throws -> MembershipEntitlement {
        let result = try await network.request(AppAPI.v1VipAsset, body: .init(), unwrapEnvelope: true)
        let category: MembershipCategory? = switch result.currentVipCycle {
        case "week": .weekly
        case "year": .yearly
        default: nil
        }
        return MembershipEntitlement(isActive: result.vipStatus == "active", category: category,
            expirationDate: result.expireAt.map { Date(timeIntervalSince1970: Double($0) / 1000) })
    }
}

enum StorePurchaseError: LocalizedError {
    case productUnavailable, unverified, unknown, awaitingGrant, orderUnavailable
    var errorDescription: String? {
        switch self {
        case .productUnavailable: "该商品暂时无法购买，请稍后重试。"
        case .orderUnavailable: "订单创建未完成，请稍后重试。"
        case .unverified: "无法验证本次交易，请稍后恢复购买。"
        case .unknown: "购买未完成，请稍后重试。"
        case .awaitingGrant: "支付结果正在同步，权益尚未确认到账。请稍后点恢复购买重试。"
        }
    }
}
