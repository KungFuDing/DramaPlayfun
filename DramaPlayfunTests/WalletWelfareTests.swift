import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class WalletWelfareTests: XCTestCase {
    func testBillPaginationMergesMonthsAndKeepsIdenticalTransactions() async throws {
        let network = try client { target in
            let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Any]
            XCTAssertEqual(body?["billType"] as? String, "income")
            XCTAssertNotNil(body?["page"] as? Int)
            return #"{"code":200,"data":{"total":2,"list":[{"yearMonth":"2026-09","items":[{"sourceTitle":"观看视频","changeCoin":100,"createdAt":1789171200000}]}]}}"#
        }
        let wallet = WalletStore(network: network, profile: ProfileStore(network: network))
        await wallet.load(.income)
        XCTAssertEqual(wallet.hasMore[.income], true)
        await wallet.load(.income)
        XCTAssertEqual(wallet.groups[.income]?.count, 1)
        XCTAssertEqual(wallet.groups[.income]?.first?.records.count, 2)
        XCTAssertEqual(Set(wallet.groups[.income]!.first!.records.map(\.id)).count, 2)
        XCTAssertEqual(wallet.groups[.income]?.first?.records.first?.amount, "+100金币")
        XCTAssertEqual(wallet.hasMore[.income], false)
        await wallet.load(.income, refresh: true)
        XCTAssertEqual(wallet.groups[.income]?.first?.records.count, 1)
    }

    func testSignInUpdatesSharedBalanceAndPreventsDuplicateClaim() async throws {
        let network = try client { target in
            switch target.path {
            case AppAPI.v1WelfareTaskList.path:
                return #"{"code":200,"data":{"continuousSignDays":1,"list":[{"taskCode":"daily_sign_in","signRewards":[{"signDay":1,"rewardCoin":20,"status":true},{"signDay":2,"rewardCoin":30,"status":false}]}]}}"#
            case AppAPI.v1WelfareSignPopupStatus.path:
                return #"{"code":200,"data":{"hasReceivedToday":false,"signDay":2}}"#
            case AppAPI.v1WelfareSignReceive.path:
                let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: String]
                XCTAssertEqual(body?["popupScene"], "manual")
                return #"{"code":200,"data":{"received":true,"rewardCoin":30,"walletBalance":20030,"signDay":2}}"#
            default: return #"{"code":200,"data":{}}"#
            }
        }
        let profile = ProfileStore(network: network)
        let wallet = WalletStore(network: network, profile: profile)
        let welfare = WelfareStore(network: network, wallet: wallet)
        await welfare.reload()
        XCTAssertEqual(welfare.continuousDays, 1)
        XCTAssertFalse(welfare.hasReceivedToday)
        await welfare.signIn()
        XCTAssertTrue(welfare.hasReceivedToday)
        XCTAssertTrue(welfare.days.last!.received)
        XCTAssertEqual(welfare.continuousDays, 2)
        XCTAssertEqual(wallet.balance, 20030)
        XCTAssertEqual(profile.profile.coinAmount, 20030)
        await welfare.signIn()
        XCTAssertEqual(wallet.balance, 20030)
    }

    func testFailedMutationsPreserveSignInAndAutoPlayState() async throws {
        let network = try client { target in
            if target.path == AppAPI.v1WelfareSignPopupStatus.path {
                return #"{"code":200,"data":{"hasReceivedToday":false,"signDay":1}}"#
            }
            if target.path == AppAPI.v1WelfareTaskList.path { return #"{"code":200,"data":{"list":[]}}"# }
            return #"{"code":500,"message":"请求失败","data":null}"#
        }
        let profile = ProfileStore(network: network)
        let wallet = WalletStore(network: network, profile: profile)
        let welfare = WelfareStore(network: network, wallet: wallet)
        await welfare.reload()
        await welfare.signIn()
        XCTAssertFalse(welfare.hasReceivedToday)
        XCTAssertNil(wallet.balance)
        XCTAssertNotNil(welfare.error)
        do { try await profile.setAutoPlayNext(false); XCTFail("应返回接口错误") } catch { }
        XCTAssertTrue(profile.autoPlaysNext)
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
