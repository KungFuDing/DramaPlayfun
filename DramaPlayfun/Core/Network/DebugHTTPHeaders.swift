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
        var headers = values
        if let token = headers["accessToken"]?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            headers["accessToken"] = token
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }
}
#endif
