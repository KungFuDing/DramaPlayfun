import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class NetworkLocationHeaderTests: XCTestCase {
    private let business = APIEndpoint<APIModels.V1GuestLoginReq, APIModels.V1GuestLoginRes>(path: "/test/business")
    private var login: APIModels.V1GuestLoginReq {
        .init(currentVersion: "1.0", deviceIdentifier: "test-device")
    }
    private var staleHeaders: [String: String] {
        ["ip": "192.0.2.1", "IP": "192.0.2.2", "Ip": "192.0.2.3",
         "countryCode": "US", "COUNTRYCODE": "GB", "CountryCode": "CA",
         "language": "zh-Hans"]
    }

    func testBusinessRequestUsesRuntimeLocationAndRemovesAllStaticCaseVariants() async throws {
        let location = try NetworkLocation(ip: "203.0.113.1", countryCode: "TW")
        let lookup = StubNetworkLocationProvider(location: location)
        var requestCount = 0
        let client = try makeClient(networkLocationProvider: lookup, headers: staleHeaders) { target in
            requestCount += 1
            XCTAssertEqual(target.path, self.business.path)
            self.assertLocationHeaders(target, ip: "203.0.113.1", countryCode: "TW")
            XCTAssertEqual(target.headers?["language"], AppLanguage.current.rawValue)
            return Data(#"{"accessToken":"business-token"}"#.utf8)
        }

        let result = try await client.request(business, body: login)

        XCTAssertEqual(result.accessToken, "business-token")
        XCTAssertEqual(lookup.callCount, 1)
        XCTAssertEqual(requestCount, 1)
    }

    func testGuestLoginSendsIPv6AndItsCountryWithoutAuthorization() async throws {
        let lookup = StubNetworkLocationProvider(
            location: try NetworkLocation(ip: "2001:db8::1234", countryCode: "JP"))
        let client = try makeClient(networkLocationProvider: lookup,
                                    headers: ["Authorization": "Bearer stale-token"]) { target in
            XCTAssertEqual(target.path, AppAPI.v1AuthGuestLogin.path)
            self.assertLocationHeaders(target, ip: "2001:db8::1234", countryCode: "JP")
            XCTAssertFalse(target.requestHeaders.keys.contains { $0.lowercased() == "authorization" })
            return Data(#"{"accessToken":"guest-token"}"#.utf8)
        }

        let result = try await client.request(AppAPI.v1AuthGuestLogin, body: login)

        XCTAssertEqual(result.accessToken, "guest-token")
        XCTAssertEqual(lookup.callCount, 1)
    }

    func testEncryptionBootstrapAndEncryptedLoginBothReceiveRuntimeLocation() async throws {
        let lookup = StubNetworkLocationProvider(
            location: try NetworkLocation(ip: "203.0.113.2", countryCode: "SG"))
        let cipher = APIPayloadCipher(password: "network-location-header-test")
        let encryptedReply = try cipher.encryptForTransport(Data(#"{"accessToken":"encrypted-token"}"#.utf8))
        var paths: [String] = []
        let client = try makeClient(networkLocationProvider: lookup, headers: staleHeaders,
                                    usesServerEncryptionConfiguration: true, payloadCipher: cipher) { target in
            paths.append(target.path)
            self.assertLocationHeaders(target, ip: "203.0.113.2", countryCode: "SG")
            if target.path == AppAPI.v1ClientTransportEncryptionConfig.path {
                XCTAssertEqual(target.headers?["Content-Type"], "application/json")
                return Data(#"{"code":200,"data":{"enabled":true}}"#.utf8)
            }
            XCTAssertEqual(target.path, AppAPI.v1AuthGuestLogin.path)
            XCTAssertEqual(target.headers?["Content-Type"], "text/plain; charset=utf-8")
            return encryptedReply
        }

        let result = try await client.request(AppAPI.v1AuthGuestLogin, body: login)

        XCTAssertEqual(result.accessToken, "encrypted-token")
        XCTAssertEqual(paths, [AppAPI.v1ClientTransportEncryptionConfig.path, AppAPI.v1AuthGuestLogin.path])
        XCTAssertEqual(lookup.callCount, 2)
    }

    func testLookupFailureOmitsStaticLocationHeadersAndAllowsBusinessRequest() async throws {
        let lookup = StubNetworkLocationProvider(location: nil)
        var requestCount = 0
        let client = try makeClient(networkLocationProvider: lookup, headers: staleHeaders) { target in
            requestCount += 1
            self.assertNoLocationHeaders(target)
            XCTAssertEqual(target.headers?["language"], AppLanguage.current.rawValue)
            return Data(#"{"accessToken":"available-without-location"}"#.utf8)
        }

        let result = try await client.request(business, body: login)

        XCTAssertEqual(result.accessToken, "available-without-location")
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(lookup.callCount, 1)
    }

    func testNoProviderOmitsStaticLocationHeadersWithoutAdditionalRequests() async throws {
        var paths: [String] = []
        let client = try makeClient(headers: staleHeaders) { target in
            paths.append(target.path)
            self.assertNoLocationHeaders(target)
            return Data(#"{"accessToken":"stub-token"}"#.utf8)
        }

        let result = try await client.request(business, body: login)

        XCTAssertEqual(result.accessToken, "stub-token")
        XCTAssertEqual(paths, [business.path])
    }

    func testEachRequestUsesTheProvidersCurrentLocation() async throws {
        let lookup = StubNetworkLocationProvider(
            location: try NetworkLocation(ip: "203.0.113.3", countryCode: "TW"))
        var receivedHeaders: [[String: String]] = []
        let client = try makeClient(networkLocationProvider: lookup) { target in
            receivedHeaders.append(target.requestHeaders)
            return Data("{}".utf8)
        }

        _ = try await client.request(business, body: login)
        lookup.location = try NetworkLocation(ip: "2001:db8::5678", countryCode: "JP")
        _ = try await client.request(business, body: login)

        XCTAssertEqual(receivedHeaders.map { $0["ip"] }, ["203.0.113.3", "2001:db8::5678"])
        XCTAssertEqual(receivedHeaders.map { $0["countryCode"] }, ["TW", "JP"])
        XCTAssertEqual(lookup.callCount, 2)
    }

    func testCancellationWhileWaitingForLookupDoesNotSendBusinessRequest() async throws {
        let lookupStarted = expectation(description: "Location lookup started")
        let lookup = SuspendedNetworkLocationProvider { lookupStarted.fulfill() }
        var requestCount = 0
        let client = try makeClient(networkLocationProvider: lookup) { _ in
            requestCount += 1
            return Data("{}".utf8)
        }
        let pending = _Concurrency.Task { try await client.request(business, body: login) }
        await fulfillment(of: [lookupStarted], timeout: 2)
        XCTAssertEqual(requestCount, 0)

        pending.cancel()
        lookup.complete(with: try NetworkLocation(ip: "203.0.113.4", countryCode: "TW"))

        do {
            _ = try await pending.value
            XCTFail("A request cancelled during lookup must throw CancellationError")
        } catch is CancellationError { }
        XCTAssertEqual(requestCount, 0)
    }

    private func assertLocationHeaders(_ target: APITarget, ip: String, countryCode: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(target.requestHeaders["ip"], ip, file: file, line: line)
        XCTAssertEqual(target.requestHeaders["countryCode"], countryCode, file: file, line: line)
        for name in ["ip", "countrycode"] {
            XCTAssertEqual(target.requestHeaders.keys.filter { $0.lowercased() == name }.count, 1,
                           file: file, line: line)
        }
    }

    private func assertNoLocationHeaders(_ target: APITarget,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(target.requestHeaders.keys.contains { ["ip", "countrycode"].contains($0.lowercased()) },
                       file: file, line: line)
    }

    private func makeClient(networkLocationProvider: (any NetworkLocationProviding)? = nil,
                            headers: [String: String] = [:],
                            usesServerEncryptionConfiguration: Bool = false,
                            payloadCipher: APIPayloadCipher? = nil,
                            response: @escaping (APITarget) -> Data) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let responseData = response(target)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                            sampleResponseClosure: { .networkResponse(200, responseData) },
                            method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in .immediate })
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                         provider: provider, payloadCipher: payloadCipher,
                         usesServerEncryptionConfiguration: usesServerEncryptionConfiguration,
                         networkLocationProvider: networkLocationProvider, headerProvider: { _ in headers })
    }
}

@MainActor
private final class StubNetworkLocationProvider: NetworkLocationProviding {
    var location: NetworkLocation?
    private(set) var callCount = 0

    init(location: NetworkLocation?) {
        self.location = location
    }

    func current() async -> NetworkLocation? {
        callCount += 1
        return location
    }
}

@MainActor
private final class SuspendedNetworkLocationProvider: NetworkLocationProviding {
    private let onStart: () -> Void
    private var continuation: CheckedContinuation<NetworkLocation?, Never>?

    init(onStart: @escaping () -> Void) {
        self.onStart = onStart
    }

    func current() async -> NetworkLocation? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            onStart()
        }
    }

    func complete(with location: NetworkLocation?) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: location)
    }
}
