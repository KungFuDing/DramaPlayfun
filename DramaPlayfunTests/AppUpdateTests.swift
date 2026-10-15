import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class AppUpdateTests: XCTestCase {
    func testCheckUsesCurrentVersionAndUnwrapsServerNotice() async throws {
        let store = try makeStore { target in
            XCTAssertEqual(target.path, AppAPI.v1ClientAppUpdateCheck.path)
            let body = try? JSONDecoder().decode(APIModels.V1CheckAppUpdateReq.self, from: target.body)
            XCTAssertEqual(body?.currentVersion, "1.0.5")
            return #"{"code":200,"data":{"hasUpdate":true,"latestVersion":" 1.1.6 ","forceUpdate":false,"title":" 新版本 ","content":" 新功能已上线 ","downloadUrl":" https://apps.apple.com/cn/app/id123 "}}"#
        }
        await store.checkForUpdates()
        XCTAssertEqual(store.notice?.version, "1.1.6")
        XCTAssertEqual(store.notice?.title, "新版本")
        XCTAssertEqual(store.notice?.content, "新功能已上线")
        XCTAssertEqual(store.notice?.downloadURL?.absoluteString, "https://apps.apple.com/cn/app/id123")
        XCTAssertEqual(store.notice?.isForced, false)
        XCTAssertFalse(store.isChecking)
        XCTAssertNil(store.errorMessage)
    }

    func testForcedNoticeUsesDefaultsAndCannotDismissWithoutDownloadURL() async throws {
        let store = try makeStore { _ in
            #"{"code":200,"data":{"hasUpdate":true,"latestVersion":"1.1.6","forceUpdate":true,"title":" ","content":""}}"#
        }
        await store.checkForUpdates()
        let notice = try XCTUnwrap(store.notice)
        XCTAssertEqual(notice.title, "版本升级提醒")
        XCTAssertEqual(notice.content, "为了保障服务稳定，请完成本次版本升级后继续使用")
        XCTAssertTrue(notice.isForced)
        XCTAssertNil(notice.downloadURL)
        store.dismiss()
        XCTAssertEqual(store.notice, notice)
        await store.openUpdate { _ in
            XCTFail("Missing download URLs must not launch a replacement destination")
            return true
        }
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.notice, notice)
        XCTAssertFalse(store.isOpening)
    }

    func testOptionalDismissalIsVersionSpecificAndForcedUpdateOverridesIt() async throws {
        var version = "1.1.6"
        var forced = false
        let store = try makeStore { _ in
            "{\"code\":200,\"data\":{\"hasUpdate\":true,\"latestVersion\":\"\(version)\",\"forceUpdate\":\(forced)}}"
        }
        await store.checkForUpdates()
        XCTAssertEqual(store.notice?.title, "新版本已就绪")
        XCTAssertEqual(store.notice?.content, "本次更新优化了播放体验，并带来更多内容推荐。立即更新，体验更流畅")
        store.dismiss()
        XCTAssertNil(store.notice)
        await store.checkForUpdates()
        XCTAssertNil(store.notice)
        version = "1.1.7"
        await store.checkForUpdates()
        XCTAssertEqual(store.notice?.version, "1.1.7")
        store.dismiss()
        version = "1.1.6"
        forced = true
        await store.checkForUpdates()
        XCTAssertEqual(store.notice?.version, "1.1.6")
        XCTAssertEqual(store.notice?.isForced, true)
    }

    func testNewStoreDoesNotInheritOptionalSuppression() async throws {
        let response = #"{"code":200,"data":{"hasUpdate":true,"latestVersion":"1.1.6","forceUpdate":false}}"#
        let first = try makeStore { _ in response }
        await first.checkForUpdates()
        first.dismiss()
        let nextSession = try makeStore { _ in response }
        await nextSession.checkForUpdates()
        XCTAssertNotNil(nextSession.notice)
    }

    func testFailureRetainsMandatoryNoticeAndSuccessfulRetryCanClearIt() async throws {
        var response = #"{"code":200,"data":{"hasUpdate":true,"latestVersion":"1.1.6","forceUpdate":true}}"#
        let store = try makeStore { _ in response }
        await store.checkForUpdates()
        let notice = try XCTUnwrap(store.notice)
        for failure in [
            #"{"code":500,"message":"unavailable","data":null}"#,
            #"{"code":200,"data":{}}"#,
            #"{"code":200,"data":{"hasUpdate":true,"latestVersion":"1.1.6"}}"#,
            #"{"code":200,"data":{"hasUpdate":true,"forceUpdate":false}}"#,
            #"{"code":200,"data":{"hasUpdate":"invalid"}}"#
        ] {
            response = failure
            await store.checkForUpdates()
            XCTAssertEqual(store.notice, notice)
            XCTAssertNotNil(store.errorMessage)
            XCTAssertFalse(store.isChecking)
        }
        response = #"{"code":200,"data":{"hasUpdate":false}}"#
        await store.checkForUpdates()
        XCTAssertNil(store.notice)
        XCTAssertNil(store.errorMessage)
    }

    func testDownloadURLValidationDoesNotHideMandatoryNotices() throws {
        for invalid: String? in [nil, "", " ", "relative/path", "https:///", "file:///tmp/update",
                                "javascript:alert(1)", "https://bad host/app", "https://user:password@example.com/app"] {
            let notice = try XCTUnwrap(AppUpdateNotice(response: .init(hasUpdate: true,
                forceUpdate: true, downloadUrl: invalid)))
            XCTAssertTrue(notice.isForced)
            XCTAssertNil(notice.downloadURL, "Unexpectedly accepted \(invalid ?? "nil")")
        }
        for valid in ["https://apps.apple.com/cn/app/id123", "http://example.com/app",
                      "itms-apps://apps.apple.com/app/id123"] {
            let notice = AppUpdateNotice(response: .init(hasUpdate: true, downloadUrl: valid))
            XCTAssertEqual(notice?.downloadURL?.absoluteString, valid)
        }
        XCTAssertNil(AppUpdateNotice(response: .init(hasUpdate: false, forceUpdate: true)))
        XCTAssertNil(AppUpdateNotice(response: .init(forceUpdate: true)))
    }

    func testOpeningFailureCanRetryAndSuccessDoesNotDismissMandatoryNotice() async throws {
        let store = try makeStore { _ in
            #"{"code":200,"data":{"hasUpdate":true,"latestVersion":"1.1.6","forceUpdate":true,"downloadUrl":"itms-apps://apps.apple.com/app/id123"}}"#
        }
        await store.checkForUpdates()
        let notice = try XCTUnwrap(store.notice)
        await store.openUpdate { url in
            XCTAssertEqual(url, notice.downloadURL)
            XCTAssertTrue(store.isOpening)
            await store.openUpdate { _ in
                XCTFail("An in-flight open must prevent repeated launches")
                return true
            }
            return false
        }
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isOpening)
        XCTAssertEqual(store.notice, notice)
        await store.openUpdate { _ in true }
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isOpening)
        XCTAssertEqual(store.notice, notice)
    }

    func testChecksDoNotOverlapAndCancellationCanRetry() async throws {
        let started = expectation(description: "First update check started")
        var requests = 0
        let store = try makeStore(response: { _ in
            requests += 1
            if requests == 1 { started.fulfill() }
            return #"{"code":200,"data":{"hasUpdate":true,"latestVersion":"1.1.6","forceUpdate":false}}"#
        }, delay: 0.1)
        let pending = _Concurrency.Task { await store.checkForUpdates() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(store.isChecking)
        await store.checkForUpdates()
        XCTAssertEqual(requests, 1)
        pending.cancel()
        await pending.value
        XCTAssertNil(store.notice)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isChecking)
        await store.checkForUpdates()
        XCTAssertEqual(requests, 2)
        XCTAssertNotNil(store.notice)
    }

    private func makeStore(response: @escaping (APITarget) -> String,
                           delay: TimeInterval = 0) throws -> AppUpdateStore {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let json = response(target)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in delay > 0 ? .delayed(seconds: delay) : .immediate })
        let network = APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                                provider: provider)
        return AppUpdateStore(network: network, currentVersion: "1.0.5")
    }
}
