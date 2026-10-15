#if DEBUG
import Foundation

nonisolated enum DebugHTTPHeaders {
    static var current: [String: String] {
        guard let values = Bundle.main.object(forInfoDictionaryKey: "DebugHTTPHeaders") as? [String: String] else {
            return [:]
        }
        return addingAuthorization(to: values.filter { !$0.value.isEmpty && !$0.value.hasPrefix("$(") })
    }

    static func addingAuthorization(to values: [String: String]) -> [String: String] {
        var headers = values.filter { $0.key.lowercased() != "accesstoken" }
        let configuredToken = values["accessToken"] ?? values.first { $0.key.lowercased() == "accesstoken" }?.value
        if let token = configuredToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            headers = headers.filter { $0.key.lowercased() != "authorization" }
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }
}
#endif
