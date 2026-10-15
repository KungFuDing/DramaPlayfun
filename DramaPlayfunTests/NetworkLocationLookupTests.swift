import XCTest
@testable import DramaPlayfun

final class NetworkLocationLookupTests: XCTestCase {
    func testValidAddressesAndNormalizedCountryProduceHeaders() throws {
        let ipv4 = try NetworkLocation(ip: " 203.0.113.7\n", countryCode: " tw\n")
        XCTAssertEqual(ipv4.headers, ["ip": "203.0.113.7", "countryCode": "TW"])
        let ipv6 = try NetworkLocation(ip: "2001:db8::7", countryCode: "us")
        XCTAssertEqual(ipv6.headers, ["ip": "2001:db8::7", "countryCode": "US"])
    }

    func testUnknownCountryDoesNotInventCountryHeader() throws {
        for country: String? in [nil, "", " \n"] {
            let location = try NetworkLocation(ip: "203.0.113.7", countryCode: country)
            XCTAssertNil(location.countryCode)
            XCTAssertEqual(location.headers, ["ip": "203.0.113.7"])
        }
    }

    func testMalformedAddressesAndCountriesAreRejected() {
        for ip in ["", "localhost", "999.1.1.1", "1.2.3", "2001:db8::zzz", "203.0.113.7\0bad",
                   "203.0.113.7\r\nAuthorization: secret", "https://203.0.113.7", "fe80::1%en0"] {
            XCTAssertThrowsError(try NetworkLocation(ip: ip, countryCode: "US"), "Invalid IP: \(ip)") {
                XCTAssertEqual($0 as? NetworkLocationError, .invalidIP)
            }
        }
        for country in ["ZZ", "USA", "1A", "U\nS", "美国", "US\0"] {
            XCTAssertThrowsError(try NetworkLocation(ip: "203.0.113.7", countryCode: country), "Invalid country: \(country)") {
                XCTAssertEqual($0 as? NetworkLocationError, .invalidCountryCode)
            }
        }
    }

    func testLookupUsesIndependentHTTPSGetAndDecodesCountry() async throws {
        let lookup = NetworkLocationLookup(endpoint: URL(string: "https://geo.example.invalid/")!) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://geo.example.invalid/")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.timeoutInterval, 3)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.allHTTPHeaderFields, ["Accept": "application/json"])
            return (Data(#"{"ip":"2001:db8::7","country":" us "}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let location = try await lookup.fetch()
        XCTAssertEqual(location, try NetworkLocation(ip: "2001:db8::7", countryCode: "US"))
    }

    func testSessionDisablesSharedCredentialsCookiesAndCachingAndBoundsTimeouts() {
        let configuration = NetworkLocationLookup.sessionConfiguration()
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 3)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 3)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpAdditionalHeaders)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testMissingConfigurationUsesDocumentedDefault() async throws {
        let lookup = NetworkLocationLookup(bundle: try bundle()) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.country.is/")
            return (Data(#"{"ip":"203.0.113.7","country":null}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let location = try await lookup.fetch()
        XCTAssertEqual(location.headers, ["ip": "203.0.113.7"])
    }

    func testCustomConfigurationIsUsed() async throws {
        let lookup = NetworkLocationLookup(bundle: try bundle(configuredURL: " https://geo.example.invalid/location \n")) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://geo.example.invalid/location")
            return (Data(#"{"ip":"203.0.113.7","country":"JP"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let location = try await lookup.fetch()
        XCTAssertEqual(location.countryCode, "JP")
    }

    func testInvalidConfigurationFailsWithoutSendingOrFallingBack() async throws {
        for value: Any in ["", " \n", "relative/path", "$(IP_GEOLOCATION_URL)", "http://geo.example.invalid/",
                           "https://user:password@geo.example.invalid/", "https://geo.example.invalid/#fragment", 42] {
            let lookup = NetworkLocationLookup(bundle: try bundle(configuredURL: value)) { _ in
                XCTFail("An invalid configured endpoint must not issue any request")
                throw URLError(.badURL)
            }
            do {
                _ = try await lookup.fetch()
                XCTFail("Invalid configuration must fail: \(value)")
            } catch {
                XCTAssertEqual(error as? NetworkLocationError, .invalidEndpoint)
            }
        }
    }

    func testHTTPFailureIsRejectedBeforeDecoding() async throws {
        for status in [301, 401, 429, 503] {
            let lookup = stub(status: status, json: "not-json")
            do {
                _ = try await lookup.fetch()
                XCTFail("HTTP failure must not produce a location")
            } catch {
                XCTAssertEqual(error as? NetworkLocationError, .httpStatus(status))
            }
        }
    }

    func testInvalidResponseAndPayloadCannotBecomeHeaders() async throws {
        let lookup = NetworkLocationLookup(endpoint: URL(string: "https://geo.example.invalid/")!) { request in
            (Data(#"{"ip":"203.0.113.7","country":"US"}"#.utf8),
             URLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: 0, textEncodingName: nil))
        }
        do {
            _ = try await lookup.fetch()
            XCTFail("Only HTTP responses are accepted")
        } catch {
            XCTAssertEqual(error as? NetworkLocationError, .invalidResponse)
        }
        for json in ["", "[]", "{}", #"{"ip":null,"country":"US"}"#, #"{"ip":123,"country":"US"}"#,
                     #"{"ip":"invalid","country":"US"}"#, #"{"ip":"203.0.113.7","country":123}"#,
                     #"{"ip":"203.0.113.7","country":"ZZ"}"#] {
            do {
                _ = try await stub(json: json).fetch()
                XCTFail("Malformed lookup response must fail: \(json)")
            } catch { }
        }
    }

    func testTransportErrorsPropagate() async {
        let lookup = NetworkLocationLookup(endpoint: URL(string: "https://geo.example.invalid/")!) { _ in
            throw URLError(.timedOut)
        }
        do {
            _ = try await lookup.fetch()
            XCTFail("Lookup timeout must fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    private func stub(status: Int = 200, json: String) -> NetworkLocationLookup {
        NetworkLocationLookup(endpoint: URL(string: "https://geo.example.invalid/")!) { request in
            (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func bundle(configuredURL: Any? = nil) throws -> Bundle {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var values: [String: Any] = ["CFBundleIdentifier": "tests.location.\(UUID().uuidString)"]
        values["IPGeolocationURL"] = configuredURL
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(path: directory.path))
    }
}
