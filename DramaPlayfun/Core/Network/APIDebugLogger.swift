#if DEBUG
import Foundation
import Moya
import Alamofire

/// Console diagnostics for Debug builds only. Credentials and personal fields are masked.
nonisolated enum APIDebugLogger {
    private static let outputLock = NSLock()

    static func request(id: String, target: APITarget) {
        let url = target.baseURL.appendingPathComponent(target.path)
        let headers = formattedJSONObject(target.requestHeaders)
        let body = formattedBody(target.body)
        output(id: id, event: "REQUEST", text: "→ \(target.method.rawValue) \(url.absoluteString)\nHeaders: \(headers)\nBody: \(body)")
    }

    static func response(id: String, response: Moya.Response, duration: TimeInterval) {
        let body = formattedBody(response.data)
        output(id: id, event: "RESPONSE", text: "← HTTP \(response.statusCode) (\(String(format: "%.2f", duration))s) · \(response.data.count) bytes\nBody: \(body)")
    }

    static func failure(id: String, path: String, error: Error) {
        let label = error is CancellationError ? "cancelled" : "failed"
        output(id: id, event: "ERROR", text: "\(label) \(path): \(error.localizedDescription)")
    }

    static func formattedBody(_ data: Data) -> String {
        if data.isEmpty { return "<empty>" }
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return formattedJSONObject(object)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return "<binary, \(data.count) bytes>"
    }

    /// Use stdout instead of one oversized NSLog/unified-log entry. Keep each block small and
    /// serialize the complete message so simultaneous requests cannot interleave their parts.
    private static func output(id: String, event: String, text: String) {
        let parts = chunks(text)
        outputLock.lock()
        defer { outputLock.unlock() }
        for (index, part) in parts.enumerated() {
            print("[API \(id)] \(event) [\(index + 1)/\(parts.count)]\n\(part)")
        }
        print("[API \(id)] \(event) END")
    }

    /// Byte-based limits keep Chinese and emoji payloads small without splitting a UTF-8 scalar.
    static func chunks(_ text: String, maximumUTF8Bytes: Int = 1800) -> [String] {
        precondition(maximumUTF8Bytes >= 4)
        var result: [String] = []
        var part = ""
        var bytes = 0
        for scalar in text.unicodeScalars {
            let size = scalar.utf8.count
            if bytes + size > maximumUTF8Bytes {
                result.append(part)
                part = ""
                bytes = 0
            }
            part.unicodeScalars.append(scalar)
            bytes += size
        }
        if !part.isEmpty || result.isEmpty { result.append(part) }
        return result
    }

    private static func formattedJSONObject(_ object: Any) -> String {
        let safe = redact(object)
        guard let data = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
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
