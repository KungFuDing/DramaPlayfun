import Foundation
import Observation

enum WalletRecordKind: String, CaseIterable, Identifiable {
    case recharge = "我的充值", income = "我的获取", expense = "我的消耗"
    var id: Self { self }
    var title: String { L10n.tr(rawValue) }
    var emptyTitle: String {
        switch self {
        case .recharge: L10n.tr("暂无充值记录")
        case .income: L10n.tr("暂无获取记录")
        case .expense: L10n.tr("暂无消耗记录")
        }
    }
    var billType: String { self == .income ? "income" : "expense" }
}

enum WalletRecordText {
    case verbatim(String)
    case localized(String)
    case coins(sign: String, magnitude: String)
    case unlockedEpisode(title: String, number: Int)

    var value: String {
        switch self {
        case .verbatim(let text): text
        case .localized(let key): L10n.tr(key)
        case .coins(let sign, let magnitude): L10n.tr("%@%@金币", sign, magnitude)
        case .unlockedEpisode(let title, let number): L10n.tr("解锁“%@”第%d集", title, number)
        }
    }
}

struct WalletRecord: Identifiable {
    let id: String
    let titleValue: WalletRecordText
    let date: String
    let amountValue: WalletRecordText
    var title: String { titleValue.value }
    var amount: String { amountValue.value }
}

struct WalletRecordGroup: Identifiable {
    let id: String
    var records: [WalletRecord]
    var title: String {
        guard id != "unknown" else { return L10n.tr("未知月份") }
        let parts = id.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else { return id }
        return L10n.tr("%d年%d月", year, month)
    }
}

@MainActor @Observable
final class WalletStore {
    private let network: APIClient
    private let profile: ProfileStore
    private(set) var balance: Int64?
    private enum BalanceIssue { case missingBalance, failure(Error) }
    private var balanceIssue: BalanceIssue?
    var balanceError: String? {
        _ = LocalizationStore.shared.language
        switch balanceIssue {
        case .missingBalance: return L10n.tr("暂时无法获取金币余额，请稍后重试。")
        case .failure(let error): return error.appLocalizedDescription
        case nil: return nil
        }
    }
    private(set) var groups: [WalletRecordKind: [WalletRecordGroup]] = [:]
    private(set) var loading: Set<WalletRecordKind> = []
    private var failures: [WalletRecordKind: Error] = [:]
    var errors: [WalletRecordKind: String] {
        _ = LocalizationStore.shared.language
        return failures.mapValues(\.appLocalizedDescription)
    }
    private(set) var hasMore: [WalletRecordKind: Bool] = [:]
    private var pages: [WalletRecordKind: Int] = [:]
    private var counts: [WalletRecordKind: Int] = [:]

    init(network: APIClient, profile: ProfileStore) {
        self.network = network
        self.profile = profile
    }

    var availableBalance: Int64? { balance ?? profile.profile.coinAmount }
    var balanceText: String { availableBalance.map(String.init) ?? "—" }

    func updateBalance(_ balance: Int64) {
        self.balance = balance
        profile.updateCoinBalance(balance)
    }

    func reloadBalance() async {
        do {
            let response = try await network.request(AppAPI.v1WalletInfo, body: .init(), unwrapEnvelope: true)
            try Task.checkCancellation()
            guard let balance = response.balanceCoin else {
                balanceIssue = .missingBalance
                return
            }
            updateBalance(balance)
            balanceIssue = nil
        } catch is CancellationError {
        } catch { balanceIssue = .failure(error) }
    }

    func load(_ kind: WalletRecordKind, refresh: Bool = false) async {
        guard !loading.contains(kind) else { return }
        if !refresh, groups[kind] != nil, hasMore[kind] != true { return }
        let page = refresh ? 1 : (pages[kind] ?? 0) + 1
        loading.insert(kind)
        failures[kind] = nil
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
                        titleValue: item.productName.map(WalletRecordText.verbatim) ?? .localized("充值金币"), date: Self.date(item.transactionTime),
                        amountValue: .verbatim(Self.price(item.payAmount, currency: item.currency)))
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
                    WalletRecordGroup(id: group.yearMonth ?? "unknown", records: (group.items ?? []).enumerated().map { index, item in
                        let amount = item.changeCoin.map { WalletRecordText.coins(sign: kind == .income ? "+" : "−", magnitude: String($0.magnitude)) } ?? .verbatim("—")
                        return WalletRecord(id: "\(kind.billType)-\(page)-\(groupIndex)-\(index)",
                            titleValue: Self.billTitle(item), date: Self.date(item.createdAt), amountValue: amount)
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
        } catch { failures[kind] = error }
    }

    private static func billTitle(_ item: APIModels.V1MyCoinBillItem) -> WalletRecordText {
        if item.bizType == "unlock_episode", let title = item.sourceTitle, let number = item.episodeNo {
            return .unlockedEpisode(title: title, number: number)
        }
        if let title = item.sourceTitle, !title.isEmpty { return .verbatim(title) }
        switch item.bizType {
        case "daily_sign_in": return .localized("每日签到")
        case "watch_drama": return .localized("观看视频")
        case "share_video": return .localized("分享视频")
        case "like_video": return .localized("点赞视频")
        case "collect_video": return .localized("收藏视频")
        default: return .localized("金币变动")
        }
    }

    private static func date(_ milliseconds: Int64?, format: String = "yyyy.MM.dd") -> String {
        guard let milliseconds else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
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
