import Foundation
import Observation

enum WalletRecordKind: String, CaseIterable, Identifiable {
    case recharge = "我的充值", income = "我的获取", expense = "我的消耗"
    var id: Self { self }
    var billType: String { self == .income ? "income" : "expense" }
}

struct WalletRecord: Identifiable {
    let id: String
    let title: String
    let date: String
    let amount: String
}

struct WalletRecordGroup: Identifiable {
    let id: String
    var records: [WalletRecord]
    var title: String { id.contains("-") ? id.replacingOccurrences(of: "-", with: "年") + "月" : id }
}

@MainActor @Observable
final class WalletStore {
    private let network: APIClient
    private let profile: ProfileStore
    private(set) var balance: Int64?
    private(set) var balanceError: String?
    private(set) var groups: [WalletRecordKind: [WalletRecordGroup]] = [:]
    private(set) var loading: Set<WalletRecordKind> = []
    private(set) var errors: [WalletRecordKind: String] = [:]
    private(set) var hasMore: [WalletRecordKind: Bool] = [:]
    private var pages: [WalletRecordKind: Int] = [:]
    private var counts: [WalletRecordKind: Int] = [:]

    init(network: APIClient, profile: ProfileStore) {
        self.network = network
        self.profile = profile
    }

    var balanceText: String { (balance ?? profile.profile.coinAmount).map(String.init) ?? "—" }

    func updateBalance(_ balance: Int64) {
        self.balance = balance
        profile.updateCoinBalance(balance)
    }

    func reloadBalance() async {
        do {
            let response = try await network.request(AppAPI.v1WalletInfo, body: .init(), unwrapEnvelope: true)
            try Task.checkCancellation()
            if let balance = response.balanceCoin { updateBalance(balance) }
            balanceError = nil
        } catch is CancellationError {
        } catch { balanceError = error.localizedDescription }
    }

    func load(_ kind: WalletRecordKind, refresh: Bool = false) async {
        guard !loading.contains(kind) else { return }
        if !refresh, groups[kind] != nil, hasMore[kind] != true { return }
        let page = refresh ? 1 : (pages[kind] ?? 0) + 1
        loading.insert(kind)
        errors[kind] = nil
        defer { loading.remove(kind) }
        do {
            let newGroups: [WalletRecordGroup]
            let itemCount: Int
            let total: Int?
            if kind == .recharge {
                let response = try await network.request(AppAPI.v1OrderRechargeList,
                    body: .init(page: page, size: 20), unwrapEnvelope: true)
                let items = response.list ?? []
                var result: [WalletRecordGroup] = []
                for (index, item) in items.enumerated() {
                    let month = Self.date(item.transactionTime, format: "yyyy-MM")
                    let record = WalletRecord(id: "recharge-\(page)-\(index)",
                        title: item.productName ?? "充值金币", date: Self.date(item.transactionTime),
                        amount: Self.price(item.payAmount, currency: item.currency))
                    if let position = result.firstIndex(where: { $0.id == month }) {
                        result[position].records.append(record)
                    } else { result.append(.init(id: month, records: [record])) }
                }
                newGroups = result
                itemCount = items.count
                total = response.total
            } else {
                let response = try await network.request(AppAPI.v1WalletBillList,
                    body: .init(page: page, size: 20, billType: kind.billType), unwrapEnvelope: true)
                let items = response.list ?? []
                newGroups = items.enumerated().map { groupIndex, group in
                    WalletRecordGroup(id: group.yearMonth ?? "未知月份", records: (group.items ?? []).enumerated().map { index, item in
                        let amount = item.changeCoin.map { "\(kind == .income ? "+" : "−")\($0.magnitude)金币" } ?? "—"
                        return WalletRecord(id: "\(kind.billType)-\(page)-\(groupIndex)-\(index)",
                            title: Self.billTitle(item), date: Self.date(item.createdAt), amount: amount)
                    })
                }
                itemCount = newGroups.reduce(0) { $0 + $1.records.count }
                total = response.total
            }
            try Task.checkCancellation()
            var merged = page == 1 ? [] : groups[kind] ?? []
            for group in newGroups {
                if let position = merged.firstIndex(where: { $0.id == group.id }) {
                    merged[position].records.append(contentsOf: group.records)
                } else { merged.append(group) }
            }
            groups[kind] = merged
            pages[kind] = page
            let count = (page == 1 ? 0 : counts[kind] ?? 0) + itemCount
            counts[kind] = count
            hasMore[kind] = itemCount > 0 && (total.map { count < $0 } ?? (itemCount >= 20))
        } catch is CancellationError {
        } catch { errors[kind] = error.localizedDescription }
    }

    private static func billTitle(_ item: APIModels.V1MyCoinBillItem) -> String {
        if item.bizType == "unlock_episode", let title = item.sourceTitle, let number = item.episodeNo {
            return "解锁“\(title)”第\(number)集"
        }
        if let title = item.sourceTitle, !title.isEmpty { return title }
        switch item.bizType {
        case "daily_sign_in": return "每日签到"
        case "watch_drama": return "观看视频"
        case "share_video": return "分享视频"
        case "like_video": return "点赞视频"
        case "collect_video": return "收藏视频"
        default: return "金币变动"
        }
    }

    private static func date(_ milliseconds: Int64?, format: String = "yyyy.MM.dd") -> String {
        guard let milliseconds else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = format
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    private static func price(_ amount: Double?, currency: String?) -> String {
        guard let amount else { return "—" }
        let value = amount.formatted(.number.precision(.fractionLength(0...2)))
        let symbol = ["USD": "$", "CNY": "¥", "EUR": "€", "GBP": "£"][currency?.uppercased() ?? ""]
        return value + (symbol ?? currency.map { " \($0)" } ?? "")
    }
}
