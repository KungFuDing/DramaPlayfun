import Foundation
import Moya
import XCTest
@testable import DramaPlayfun

@MainActor
final class TheaterProgressAccountResetTests: XCTestCase {
    func testRetiringPoolDropsQueuedAndLateReportsAcrossAccountReset() async throws {
        let probe = ProgressResetProbe()
        let location = ProgressResetLocationGate()
        let network = try makeClient(probe: probe, location: location)
        network.setAccessToken("old-token", accountID: "old-account")
        let reporter = TheaterProgressReporter(network: network)
        let pool = makePool(reporter: reporter)
        reporter.report(progress(episodeID: "101"))
        let waiting = await waitUntil { location.isWaiting }
        XCTAssertTrue(waiting)
        reporter.report(progress(episodeID: "102"))

        pool.retireAccount()
        network.beginAccountReset()
        network.endAccountReset()
        network.setAccessToken("new-token", accountID: "new-account")
        reporter.report(progress(episodeID: "103"))
        location.release()
        await reporter.flush()
        XCTAssertTrue(probe.reports.isEmpty, "No old or queued progress may reach the replacement account")

        let replacement = TheaterProgressReporter(network: network)
        replacement.report(progress(episodeID: "201"))
        await replacement.flush()
        XCTAssertEqual(probe.reports.map(\.episodeID), [201])
        XCTAssertEqual(probe.reports.first?.authorization, "Bearer new-token")
    }

    func testDetachedPlayerReporterCannotContinueOrRestartAfterSessionChanges() async throws {
        let probe = ProgressResetProbe()
        let location = ProgressResetLocationGate()
        let network = try makeClient(probe: probe, location: location)
        network.setAccessToken("old-token", accountID: "old-account")
        let reporter = TheaterProgressReporter(network: network)
        reporter.report(progress(episodeID: "101"))
        let waiting = await waitUntil { location.isWaiting }
        XCTAssertTrue(waiting)
        reporter.report(progress(episodeID: "102"))

        // A detail player's private pool is not directly retired by AppContainer.
        network.beginAccountReset()
        network.endAccountReset()
        network.setAccessToken("new-token", accountID: "new-account")
        location.release()
        await reporter.flush()
        reporter.report(progress(episodeID: "103"), force: true)
        await reporter.flush()
        XCTAssertTrue(probe.reports.isEmpty, "Session identity must reject both queued and later callbacks")
    }

    func testOrdinaryPoolResetKeepsSameAccountReportingAvailable() async throws {
        let probe = ProgressResetProbe()
        let network = try makeClient(probe: probe)
        let reporter = TheaterProgressReporter(network: network)
        let pool = makePool(reporter: reporter)
        // Reporters can be constructed before the initial guest login completes.
        network.setAccessToken("guest-token", accountID: "guest-account")
        reporter.report(progress(episodeID: "101"))
        await reporter.flush()
        pool.reset()
        reporter.report(progress(episodeID: "102"))
        await reporter.flush()
        XCTAssertEqual(probe.reports.map(\.episodeID), [101, 102])
        XCTAssertEqual(Set(probe.reports.compactMap(\.authorization)), ["Bearer guest-token"])
    }

    private func progress(episodeID: String) -> WatchProgress {
        WatchProgress(dramaID: "100", episodeID: episodeID, episodeNumber: 1,
                      seconds: 20, duration: 60, updatedAt: Date())
    }

    private func makePool(reporter: TheaterProgressReporter) -> TheaterPlayerPool {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return TheaterPlayerPool(library: LibraryStore(defaults: defaults),
            cache: HLSOfflineCache(defaults: defaults, cancelLegacyDownloads: false),
            progressReporter: reporter)
    }

    private func makeClient(probe: ProgressResetProbe,
                            location: (any NetworkLocationProviding)? = nil) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            probe.record(target)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(#"{"code":200,"data":{"saved":true}}"#.utf8)) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: MoyaProvider.immediatelyStub)
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                         provider: provider, networkLocationProvider: location)
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if predicate() { return true }
            try? await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(2))
        }
        return predicate()
    }
}

nonisolated private final class ProgressResetProbe: @unchecked Sendable {
    struct Report {
        let episodeID: Int64
        let authorization: String?
    }
    private let lock = NSLock()
    private var recorded: [Report] = []
    var reports: [Report] { lock.withLock { recorded } }

    func record(_ target: APITarget) {
        guard target.path == AppAPI.v1ClientDramaProgress.path,
              let body = try? JSONDecoder().decode(APIModels.V1ReportDramaProgressReq.self, from: target.body) else { return }
        lock.withLock {
            recorded.append(Report(episodeID: body.episodeId, authorization: target.requestHeaders["Authorization"]))
        }
    }
}

@MainActor
private final class ProgressResetLocationGate: NetworkLocationProviding {
    private var continuation: CheckedContinuation<NetworkLocation?, Never>?
    private var callCount = 0
    var isWaiting: Bool { continuation != nil }

    func current() async -> NetworkLocation? {
        callCount += 1
        guard callCount == 1 else { return nil }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
