import Foundation
import Moya
import XCTest
@testable import DramaPlayfun

@MainActor
final class APIAccountResetTests: XCTestCase {
    func testResetCancelsTransportAndRejectsRequestsUntilReopened() async throws {
        let probe = AccountResetRequestProbe()
        let client = try makeClient(probe: probe)
        client.setDeviceIdentifier("installation-id")
        client.setAccessToken("old-token", accountID: "old-account")
        let old = _Concurrency.Task { try await client.request(endpoint("/old"), body: EmptyBody()) }
        let sent = await waitUntil { probe.targets.count == 1 }
        XCTAssertTrue(sent)

        client.beginAccountReset()
        switch await old.result {
        case .success: XCTFail("A response from the deleted account must not escape")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        do {
            _ = try await client.request(endpoint("/blocked"), body: EmptyBody())
            XCTFail("Account cleanup must close request admission")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(probe.targets.count, 1)

        client.endAccountReset()
        client.setAccessToken("new-token", accountID: "new-account")
        let response = try await client.request(endpoint("/new"), body: EmptyBody())
        XCTAssertEqual(response.value, "ok")
        XCTAssertEqual(probe.targets.last?.requestHeaders["Authorization"], "Bearer new-token")
        XCTAssertEqual(probe.targets.last?.requestHeaders["deviceId"], "installation-id")
    }

    func testRequestWaitingForLocationCannotSendUnderReplacementAccount() async throws {
        let probe = AccountResetRequestProbe()
        let location = AccountResetLocationGate(suspendedCalls: 1)
        let client = try makeClient(probe: probe, location: location)
        client.setAccessToken("old-token")
        let old = _Concurrency.Task { try await client.request(endpoint("/old"), body: EmptyBody()) }
        let waiting = await waitUntil { location.callCount == 1 }
        XCTAssertTrue(waiting)
        client.beginAccountReset()
        client.endAccountReset()
        client.setAccessToken("new-token")
        location.release(call: 1)

        switch await old.result {
        case .success: XCTFail("Old account work must stop after location lookup")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(probe.targets.isEmpty)
        _ = try await client.request(endpoint("/new"), body: EmptyBody())
        XCTAssertEqual(probe.targets.count, 1)
        XCTAssertEqual(probe.targets[0].path, "/new")
    }

    func testRequestEncodingDuringResetNeverReachesTransport() async throws {
        let probe = AccountResetRequestProbe()
        let client = try makeClient(probe: probe)
        let gate = AccountResetWorkGate()
        defer { gate.release() }
        let requestEndpoint = APIEndpoint<BlockingBody, Payload>(path: "/encoding")
        let old = _Concurrency.Task {
            try await client.request(requestEndpoint, body: BlockingBody(gate: gate))
        }
        let encoding = await waitUntil { gate.hasStarted }
        XCTAssertTrue(encoding)
        client.beginAccountReset()
        client.endAccountReset()
        gate.release()

        switch await old.result {
        case .success: XCTFail("Old encoded data must never be sent")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(probe.targets.isEmpty)
    }

    func testResponseDecodingDuringResetCannotReturnOldData() async throws {
        let probe = AccountResetRequestProbe()
        let gate = AccountResetWorkGate()
        let key = UUID().uuidString
        BlockingPayload.gates.insert(gate, for: key)
        defer {
            gate.release()
            BlockingPayload.gates.remove(key)
        }
        probe.responseValue = key
        let client = try makeClient(probe: probe)
        let requestEndpoint = APIEndpoint<EmptyBody, BlockingPayload>(path: "/decoding")
        let old = _Concurrency.Task { try await client.request(requestEndpoint, body: EmptyBody()) }
        let decoding = await waitUntil { gate.hasStarted }
        XCTAssertTrue(decoding)
        client.beginAccountReset()
        client.endAccountReset()
        gate.release()

        switch await old.result {
        case .success: XCTFail("Decoded data from the deleted account must be discarded")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancelledEncryptionLookupCannotClearNewSharedLookup() async throws {
        let probe = AccountResetRequestProbe()
        let location = AccountResetLocationGate(suspendedCalls: 2)
        let client = try makeClient(probe: probe, location: location, negotiatesEncryption: true)
        let old = _Concurrency.Task { try await client.request(endpoint("/old"), body: EmptyBody()) }
        let oldWaiting = await waitUntil { location.callCount == 1 }
        XCTAssertTrue(oldWaiting)
        client.beginAccountReset()
        client.endAccountReset()

        let firstNew = _Concurrency.Task { try await client.request(endpoint("/new-a"), body: EmptyBody()) }
        let newWaiting = await waitUntil { location.callCount == 2 }
        XCTAssertTrue(newWaiting)
        // The cancelled lookup finishes only after its replacement has been installed.
        location.release(call: 1)
        switch await old.result {
        case .success: XCTFail("Old negotiation must be invalidated")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        let secondNew = _Concurrency.Task { try await client.request(endpoint("/new-b"), body: EmptyBody()) }
        // Give the second caller a chance to join the still-suspended shared lookup.
        for _ in 0..<20 { await _Concurrency.Task<Never, Never>.yield() }
        location.release(call: 2)
        _ = try await firstNew.value
        _ = try await secondNew.value

        let lookups = probe.targets.filter { $0.path == AppAPI.v1ClientTransportEncryptionConfig.path }
        XCTAssertEqual(lookups.count, 1, "Old task completion must not erase the replacement lookup")
        XCTAssertFalse(probe.targets.contains { $0.path == "/old" })
    }

    private func endpoint(_ path: String) -> APIEndpoint<EmptyBody, Payload> {
        APIEndpoint(path: path)
    }

    private func makeClient(probe: AccountResetRequestProbe,
                            location: (any NetworkLocationProviding)? = nil,
                            negotiatesEncryption: Bool = false) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            probe.record(target)
            let data = target.path == AppAPI.v1ClientTransportEncryptionConfig.path
                ? Data(#"{"enabled":false}"#.utf8)
                : try! JSONEncoder().encode(Payload(value: probe.responseValue))
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                            sampleResponseClosure: { .networkResponse(200, data) },
                            method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { $0.path == "/old" ? .delayed(seconds: 0.2) : .immediate })
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                         provider: provider, usesServerEncryptionConfiguration: negotiatesEncryption,
                         networkLocationProvider: location)
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if predicate() { return true }
            try? await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(2))
        }
        return predicate()
    }
}

nonisolated private struct EmptyBody: Encodable, Sendable {}
nonisolated private struct Payload: Codable, Sendable { let value: String }

nonisolated private final class AccountResetRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [APITarget] = []
    private var value = "ok"
    var targets: [APITarget] { lock.withLock { recorded } }
    var responseValue: String {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    func record(_ target: APITarget) { lock.withLock { recorded.append(target) } }
}

@MainActor
private final class AccountResetLocationGate: NetworkLocationProviding {
    private let suspendedCalls: Int
    private var continuations: [Int: CheckedContinuation<NetworkLocation?, Never>] = [:]
    private(set) var callCount = 0
    init(suspendedCalls: Int) { self.suspendedCalls = suspendedCalls }
    func current() async -> NetworkLocation? {
        callCount += 1
        let call = callCount
        guard call <= suspendedCalls else { return nil }
        return await withCheckedContinuation { continuations[call] = $0 }
    }
    func release(call: Int) { continuations.removeValue(forKey: call)?.resume(returning: nil) }
}

nonisolated private final class AccountResetWorkGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var started = false
    var hasStarted: Bool { lock.withLock { started } }
    func block() {
        lock.withLock { started = true }
        _ = semaphore.wait(timeout: .now() + 5)
    }
    func release() { semaphore.signal() }
}

nonisolated private struct BlockingBody: Encodable, Sendable {
    let gate: AccountResetWorkGate
    func encode(to encoder: any Encoder) throws {
        gate.block()
        var container = encoder.singleValueContainer()
        try container.encode("old-account-body")
    }
}

nonisolated private struct BlockingPayload: Decodable, Sendable {
    static let gates = AccountResetGateRegistry()
    let value: String
    init(from decoder: any Decoder) throws {
        value = try Payload(from: decoder).value
        Self.gates.gate(for: value)?.block()
    }
}

nonisolated private final class AccountResetGateRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: AccountResetWorkGate] = [:]
    func insert(_ gate: AccountResetWorkGate, for key: String) { lock.withLock { values[key] = gate } }
    func gate(for key: String) -> AccountResetWorkGate? { lock.withLock { values[key] } }
    func remove(_ key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}
