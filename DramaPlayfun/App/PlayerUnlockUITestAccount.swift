#if DEBUG
import Foundation

/// One account backs profile, wallet and episode responses so unlocks survive page reloads.
final class PlayerUnlockUITestAccount: @unchecked Sendable {
    private let lock = NSLock()
    private let expanded: Bool
    private let isVIP: Bool
    private var balance: Int64
    private var autoPlayNext: String
    private var unlockedEpisodeIDs: Set<Int64> = []

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        expanded = arguments.contains("-EpisodesUITestFixture")
        isVIP = arguments.contains("-PlayerUnlockVIP")
        balance = arguments.contains("-PlayerUnlockSufficientBalance") ? 100 : 5
        autoPlayNext = arguments.contains("-PlayerUnlockAutoOff") ? "off" : "on"
    }

    func response(for target: APITarget) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Any] ?? [:]
        let data: [String: Any]
        switch target.path {
        case "/mobile/v1/client/me":
            data = ["userNo": "143143257", "nickname": "晚风放映厅", "coinAmount": balance,
                    "autoPlayNext": autoPlayNext, "vipExpireAt": isVIP ? 1893456000000 : 0]
        case "/mobile/v1/wallet/info":
            data = ["balanceCoin": balance]
        case "/mobile/v1/client/me/autoPlayNext/set":
            autoPlayNext = body["autoPlayNext"] as? String ?? "on"
            data = ["autoPlayNext": autoPlayNext]
        case "/mobile/v1/client/drama/episode/list":
            let dramaID = (body["dramaId"] as? NSNumber)?.int64Value ?? 31
            let episodes: [[String: Any]] = (1...(expanded ? 80 : 8)).map { number in
                let id = dramaID * 100 + Int64(number)
                return ["episodeId": id, "episodeNo": number, "unlockCoin": cost(for: number),
                        "isUnlocked": cost(for: number) == 0 || isCoinUnlocked(id), "looked": expanded && number <= 2,
                        "likeCount": number * 10, "durationSeconds": 60,
                        "videoUrl": "https://example.invalid/unlock-\(id).m3u8"]
            }
            data = ["rootDramaId": dramaID, "episodes": episodes]
        case "/mobile/v1/drama/episode/unlock":
            let id = (body["episodeId"] as? NSNumber)?.int64Value ?? 0
            let price = cost(for: Int(id % 100))
            if !canWatch(id), balance >= price {
                balance -= price
                unlockedEpisodeIDs.insert(id)
            }
            data = ["unlocked": canWatch(id), "canWatch": canWatch(id), "walletBalance": balance,
                    "unlockType": isVIP ? "vip" : price == 0 ? "free" : "coin_unlock"]
        case "/mobile/v1/drama/episode/unlock/status":
            let id = (body["episodeId"] as? NSNumber)?.int64Value ?? 0
            let coinUnlocked = isCoinUnlocked(id)
            let free = cost(for: Int(id % 100)) == 0
            data = ["episodeId": id, "hasCoinUnlocked": coinUnlocked, "isVipActive": isVIP,
                    "vipExpireAt": isVIP ? 1893456000000 : 0, "canWatch": canWatch(id),
                    "watchAccessType": free ? "free" : isVIP ? "vip" : coinUnlocked ? "coin_unlock" : "not_unlocked"]
        default:
            return nil
        }
        return String(data: try! JSONSerialization.data(withJSONObject: ["code": 200, "data": data]), encoding: .utf8)!
    }

    private func cost(for number: Int) -> Int64 {
        expanded ? (number >= 11 ? 10 : 0) : (number >= 6 ? 20 : 0)
    }

    private func isCoinUnlocked(_ id: Int64) -> Bool {
        unlockedEpisodeIDs.contains(id) || (expanded && (11...16).contains(Int(id % 100)))
    }

    private func canWatch(_ id: Int64) -> Bool {
        isVIP || cost(for: Int(id % 100)) == 0 || isCoinUnlocked(id)
    }
}
#endif
