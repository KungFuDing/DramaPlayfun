#if DEBUG
import Foundation
import Moya
import Alamofire

/// Console diagnostics for Debug builds only. Credentials and personal fields are masked.
nonisolated enum APIDebugLogger {
    private static let writer = Writer()

    static func request(id: String, target: APITarget, plaintextBody: Data? = nil) {
        let baseURL = target.baseURL
        let path = target.path
        let method = target.method.rawValue
        let headers = target.requestHeaders
        let data = plaintextBody ?? target.body
        writer.enqueue(id: id, event: "REQUEST") {
            let url = baseURL.appendingPathComponent(path)
            return "→ \(method) \(url.absoluteString)\nHeaders: \(formattedJSONObject(headers))\nBody: \(formattedBody(data))"
        }
    }

    static func response(id: String, response: Moya.Response, duration: TimeInterval,
                         plaintextBody: Data? = nil, isEncrypted: Bool = false) {
        // Moya.Response is not Sendable; retain only its immutable value snapshots.
        let data = response.data
        let statusCode = response.statusCode
        writer.enqueue(id: id, event: "RESPONSE") {
            let body = plaintextBody.map(formattedBody)
                ?? (isEncrypted ? "<encrypted, \(data.count) bytes>" : formattedBody(data))
            return "← HTTP \(statusCode) (\(String(format: "%.2f", duration))s) · \(data.count) bytes\nBody: \(body)"
        }
    }

    static func failure(id: String, path: String, error: Error) {
        writer.enqueue(id: id, event: "ERROR") {
            let label = error is CancellationError ? "cancelled" : "failed"
            return "\(label) \(path): \(error.localizedDescription)"
        }
    }

    static func formattedBody(_ data: Data) -> String {
        if data.isEmpty { return "<empty>" }
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return formattedJSONObject(object)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return "<binary, \(data.count) bytes>"
    }

    /// Format, redact and write on one background queue. Logging must never make an API
    /// completion wait for a large JSON payload or for the debugger's stdout consumer.
    nonisolated struct Writer: Sendable {
        private let queue = DispatchQueue(label: "com.dramaplayfun.api-debug-log", qos: .utility)
        private let write: @Sendable (String) -> Void

        init(write: @escaping @Sendable (String) -> Void = { print($0) }) {
            self.write = write
        }

        func enqueue(id: String, event: String, text: @escaping @Sendable () -> String) {
            queue.async {
                let parts = APIDebugLogger.chunks(text())
                // Keep complete messages ordered, including all chunks and their END marker.
                for (index, part) in parts.enumerated() {
                    self.write("[API \(id)] \(event) [\(index + 1)/\(parts.count)]\n\(part)")
                }
                self.write("[API \(id)] \(event) END")
            }
        }
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
