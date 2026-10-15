import Darwin
import Foundation

nonisolated enum NetworkLocationError: Error, Equatable {
    case invalidEndpoint, invalidIP, invalidCountryCode, invalidResponse
    case httpStatus(Int)
}

nonisolated struct NetworkLocation: Equatable, Sendable {
    let ip: String
    let countryCode: String?

    init(ip: String, countryCode: String?) throws {
        let address = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        guard !address.utf8.contains(0), !address.contains("%"),
              inet_pton(AF_INET, address, &ipv4) == 1 || inet_pton(AF_INET6, address, &ipv6) == 1 else {
            throw NetworkLocationError.invalidIP
        }
        let country = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let country, !country.isEmpty {
            guard country.utf8.count == 2,
                  country.utf8.allSatisfy({ (65...90).contains($0) }),
                  Self.countryCodes.contains(country) else { throw NetworkLocationError.invalidCountryCode }
            self.countryCode = country
        } else {
            self.countryCode = nil
        }
        self.ip = address
    }

    var headers: [String: String] {
        var values = ["ip": ip]
        if let countryCode { values["countryCode"] = countryCode }
        return values
    }

    private static let countryCodes = Set(Locale.Region.isoRegions.map(\.identifier))
}

/// Fetches public network metadata without sharing the app's authenticated transport.
nonisolated struct NetworkLocationLookup: Sendable {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let endpoint: URL?
    private let load: DataLoader

    static func fromBundle(_ bundle: Bundle = .main) -> Self {
        let session = URLSession(configuration: sessionConfiguration())
        return Self(bundle: bundle, load: { try await session.data(for: $0) })
    }

    init(endpoint: URL, session: URLSession) {
        self.init(endpoint: endpoint, load: { try await session.data(for: $0) })
    }

    init(endpoint: URL, load: @escaping DataLoader) {
        self.endpoint = endpoint
        self.load = load
    }

    init(bundle: Bundle, load: @escaping DataLoader) {
        if let configured = bundle.object(forInfoDictionaryKey: "IPGeolocationURL") {
            endpoint = (configured as? String).flatMap { value in
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : URL(string: value)
            }
        } else {
            endpoint = URL(string: "https://api.country.is/")
        }
        self.load = load
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    func fetch() async throws -> NetworkLocation {
        try Task.checkCancellation()
        guard let endpoint, endpoint.scheme?.lowercased() == "https",
              endpoint.host?.isEmpty == false, endpoint.user == nil, endpoint.password == nil,
              endpoint.fragment == nil else { throw NetworkLocationError.invalidEndpoint }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await load(request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw NetworkLocationError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw NetworkLocationError.httpStatus(response.statusCode)
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return try NetworkLocation(ip: payload.ip, countryCode: payload.country)
    }

    nonisolated private struct Payload: Decodable {
        let ip: String
        let country: String?
    }
}
