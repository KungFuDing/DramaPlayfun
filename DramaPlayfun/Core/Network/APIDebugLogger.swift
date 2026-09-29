#if DEBUG
import Foundation
import Moya
import Alamofire

/// Console diagnostics for Debug builds only. Credentials and personal fields are masked.
nonisolated enum APIDebugLogger {
    static func request(id: String, target: APITarget) {
        let url = target.baseURL.appendingPathComponent(target.path)
        let headers = formattedJSONObject(target.requestHeaders)
        let body = formattedBody(target.body)
        NSLog("%@", "[API \(id)] → \(target.method.rawValue) \(url.absoluteString)\nHeaders: \(headers)\nBody: \(body)")
    }

    static func response(id: String, response: Moya.Response, duration: TimeInterval) {
        let body = formattedBody(response.data)
        NSLog("%@", "[API \(id)] ← HTTP \(response.statusCode) (\(String(format: "%.2f", duration))s)\nBody: \(body)")
    }

    static func failure(id: String, path: String, error: Error) {
        let label = error is CancellationError ? "cancelled" : "failed"
        NSLog("%@", "[API \(id)] \(label) \(path): \(error.localizedDescription)")
    }

    static func formattedBody(_ data: Data) -> String {
        if data.isEmpty { return "<empty>" }
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return formattedJSONObject(object)
        }
        if let text = String(data: data.prefix(4096), encoding: .utf8) {
            return text + (data.count > 4096 ? "… <truncated, \(data.count) bytes total>" : "")
        }
        return "<binary, \(data.count) bytes>"
    }

    private static func formattedJSONObject(_ object: Any) -> String {
        let safe = redact(object)
        guard JSONSerialization.isValidJSONObject(safe),
              let data = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return String(describing: safe) }
        return text
    }

    private static func redact(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = isSensitive(entry.key) ? "<redacted>" : redact(entry.value)
            }
        }
        if let array = value as? [Any] { return array.map(redact) }
        if let string = value as? String, var url = URLComponents(string: string),
           url.scheme != nil, let items = url.queryItems {
            url.queryItems = items.map { item in
                isSensitive(item.name) ? URLQueryItem(name: item.name, value: "<redacted>") : item
            }
            return url.string ?? string
        }
        return value
    }

    private static func isSensitive(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter }
        return ["authorization", "cookie", "password", "secret", "token", "credential",
                "phone", "email", "sessionid", "deviceidentifier", "deviceid", "ipaddress"].contains {
            normalized.contains($0)
        } || normalized == "ip"
    }
}
#endif
