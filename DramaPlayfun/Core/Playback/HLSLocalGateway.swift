import AVFoundation
import Foundation
import Network
import ObjectiveC
import OSLog

/// Set by the CDN transport, including segment failures that AVPlayer may only report as a stall.
nonisolated final class HLSAuthorizationState: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private var transientFailures: [UUID: (error: NSError, recordedAt: Date)] = [:]
    var isExpired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }
    func record(status: Int) {
        guard status == 401 || status == 403 else { return }
        lock.lock()
        expired = true
        lock.unlock()
    }

    var recentTransientFailure: NSError? {
        lock.lock()
        defer { lock.unlock() }
        pruneTransientFailures()
        return transientFailures.values.max { $0.recordedAt < $1.recordedAt }?.error
    }

    func recordTransientFailure(_ error: Error, requestID: UUID) {
        guard Self.isTransient(error) else { return }
        lock.lock()
        defer { lock.unlock() }
        pruneTransientFailures()
        // Retries retain their request ID, replacing their own evidence. One
        // successful stream must never erase a different stream's failure.
        transientFailures[requestID] = (error as NSError, Date())
        if transientFailures.count > 32,
           let oldest = transientFailures.min(by: { $0.value.recordedAt < $1.value.recordedAt })?.key {
            transientFailures[oldest] = nil
        }
    }

    func clearTransientFailure(requestID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        transientFailures[requestID] = nil
    }

    private func pruneTransientFailures() {
        let now = Date()
        transientFailures = transientFailures.filter { now.timeIntervalSince($0.value.recordedAt) < 30 }
    }

    static func isTransient(status: Int) -> Bool {
        [408, 429, 500, 502, 503, 504].contains(status)
    }

    static func isTransient(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        if let status = error.userInfo["HTTPStatusCode"] as? Int { return isTransient(status: status) }
        return [URLError.networkConnectionLost.rawValue, URLError.timedOut.rawValue,
                URLError.cannotConnectToHost.rawValue, URLError.dnsLookupFailed.rawValue].contains(error.code)
    }
}

/// Proxies HLS only on the loopback interface so every CDN request carries X-Media-Token.
/// AES-128 key requests are answered locally; encrypted media bytes remain encrypted in transit.
final class HLSLocalGateway: @unchecked Sendable {
    static let shared = try! HLSLocalGateway()

    private enum Kind { case manifest, media, key }
    private struct Route {
        let group: UUID
        let remoteURL: URL?
        let token: String
        let key: Data
        let kind: Kind
        let authorization: HLSAuthorizationState
        let cacheScope: String?
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "drama.hls.gateway", qos: .userInitiated)
    private let listener: NWListener
    private let logger = Logger(subsystem: "com.video.test.DramaPlayfun.playback", category: "manifest")
    private let mediaTransport = HLSMediaTransport()
    private var routes: [String: Route] = [:]
    private var startWaiters: [CheckedContinuation<UInt16, Error>] = []
    private var port: UInt16?
    private var started = false
    #if DEBUG
    private var events: [String] = []
    var debugEvents: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events + mediaTransport.debugEvents
    }
    func debugHasBlockedMediaWrite(for asset: AVAsset) -> Bool {
        guard let lease = objc_getAssociatedObject(asset, &Self.leaseKey) as? Lease else { return false }
        return mediaTransport.debugHasBlockedMediaWrite(group: lease.group)
    }
    private func trace(_ event: String) {
        lock.lock()
        events.append(event)
        if events.count > 512 { events.removeFirst(events.count - 512) }
        lock.unlock()
    }
    #else
    private func trace(_ event: String) { }
    #endif
    private static var leaseKey: UInt8 = 0

    private init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
    }

    func asset(remoteURL: URL, identity: HLSKeyIdentity, secret: Data,
               token explicitToken: String? = nil) async throws -> AVURLAsset {
        guard remoteURL.scheme == "https" || remoteURL.isLoopbackHTTP else {
            throw URLError(.unsupportedURL)
        }
        let token = explicitToken ?? Self.mediaToken(from: remoteURL)
        guard let token, !token.isEmpty else { throw HLSKeyError.invalidMediaToken }
        let key = try HLSPlaybackKey.derive(identity, secret: secret)
        let port = try await readyPort()
        let group = UUID()
        mediaTransport.register(group: group)
        let authorization = HLSAuthorizationState()
        let cacheScope = identity.material.base64EncodedString() + ":" + key.base64EncodedString()
        let path = register(Route(group: group, remoteURL: remoteURL, token: token,
                                  key: key, kind: .manifest, authorization: authorization, cacheScope: cacheScope), suffix: "m3u8")
        let asset = AVURLAsset(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        objc_setAssociatedObject(asset, &Self.leaseKey, Lease(gateway: self, group: group, authorization: authorization),
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }

    static func authorizationExpired(for asset: AVAsset) -> Bool {
        (objc_getAssociatedObject(asset, &leaseKey) as? Lease)?.authorization.isExpired == true
    }

    static func transientTransportFailure(for asset: AVAsset) -> NSError? {
        (objc_getAssociatedObject(asset, &leaseKey) as? Lease)?.authorization.recentTransientFailure
    }

    static func mediaToken(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("X-Media-Token") == .orderedSame })?.value
    }

    private func readyPort() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let port {
                lock.unlock()
                continuation.resume(returning: port)
                return
            }
            startWaiters.append(continuation)
            let shouldStart = !started
            started = true
            lock.unlock()
            if shouldStart { listener.start(queue: queue) }
        }
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let value = listener.port?.rawValue else { return }
            lock.lock()
            port = value
            let waiters = startWaiters
            startWaiters.removeAll()
            lock.unlock()
            waiters.forEach { $0.resume(returning: value) }
        case .failed(let error):
            lock.lock()
            let waiters = startWaiters
            startWaiters.removeAll()
            lock.unlock()
            waiters.forEach { $0.resume(throwing: error) }
        default: break
        }
    }

    private func register(_ route: Route, suffix: String) -> String {
        let path = "/hls/\(UUID().uuidString).\(suffix)"
        lock.lock()
        routes[path] = route
        lock.unlock()
        return path
    }

    private func route(for path: String) -> Route? {
        lock.lock()
        defer { lock.unlock() }
        return routes[path]
    }

    private func currentPort() -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return port ?? 0
    }

    private func release(_ group: UUID) {
        lock.lock()
        routes = routes.filter { $0.value.group != group }
        lock.unlock()
        mediaTransport.cancel(group: group)
    }

    private func handle(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint,
              host == .init("127.0.0.1") || host == .init("::1") else {
            connection.cancel()
            return
        }
        trace("accepted")
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            let received = buffer + (data ?? Data())
            self.trace("received \(received.count)")
            if received.count > 32_768 || error != nil {
                self.trace("receive failed")
                connection.cancel()
                return
            }
            guard let separator = received.range(of: Data("\r\n\r\n".utf8)) else {
                self.receiveRequest(connection, buffer: received)
                return
            }
            let header = String(decoding: received[..<separator.lowerBound], as: UTF8.self)
            self.trace("parsed")
            Task { await self.respond(to: connection, request: header) }
        }
    }

    private func respond(to connection: NWConnection, request: String) async {
        trace("responding")
        let lines = request.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2, first[0] == "GET" else {
            send(Data(), status: 405, contentType: "text/plain", to: connection)
            return
        }
        let path = String(first[1]).components(separatedBy: "?")[0]
        guard let route = route(for: path) else {
            send(Data(), status: 404, contentType: "text/plain", to: connection)
            return
        }
        if route.kind == .key {
            trace("key request")
            send(route.key, status: 200, contentType: "application/octet-stream", to: connection)
            return
        }
        trace(route.kind == .manifest ? "manifest request" : "media request")
        guard let remoteURL = route.remoteURL else {
            send(Data(), status: 404, contentType: "text/plain", to: connection)
            return
        }
        var upstream = URLRequest(url: remoteURL)
        trace("upstream start")
        upstream.setValue(route.token, forHTTPHeaderField: "X-Media-Token")
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            upstream.setValue(range.dropFirst(6).trimmingCharacters(in: .whitespaces),
                              forHTTPHeaderField: "Range")
        }
        if route.kind == .media {
            upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            mediaTransport.start(upstream, group: route.group, connection: connection,
                                 authorization: route.authorization, cacheScope: route.cacheScope)
            return
        }
        let requestID = UUID()
        do {
            let started = Date()
            upstream.timeoutInterval = 20
            let (body, response) = try await mediaTransport.data(for: upstream, group: route.group)
            trace("upstream received")
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            route.authorization.record(status: http.statusCode)
            logger.debug("manifest status=\(http.statusCode) bytes=\(body.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            guard (200..<300).contains(http.statusCode) else {
                route.authorization.recordTransientFailure(NSError(domain: NSURLErrorDomain,
                    code: URLError.badServerResponse.rawValue, userInfo: ["HTTPStatusCode": http.statusCode]),
                    requestID: requestID)
                send(Data(), status: http.statusCode, contentType: "text/plain", to: connection)
                return
            }
            guard let manifest = String(data: body, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            let rewritten = rewrite(manifest, base: http.url ?? remoteURL, route: route)
            send(Data(rewritten.utf8), status: 200,
                 contentType: "application/vnd.apple.mpegurl", to: connection)
        } catch {
            route.authorization.recordTransientFailure(error, requestID: requestID)
            logger.info("manifest failed code=\((error as NSError).code)")
            trace("upstream failed")
            send(Data(), status: 502, contentType: "text/plain", to: connection)
        }
    }

    private func rewrite(_ manifest: String, base: URL, route: Route) -> String {
        manifest.components(separatedBy: .newlines).map { line in
            if (line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:")),
               line.contains("METHOD=AES-128") {
                return replacingURIs(in: line) { _ in
                    let path = register(Route(group: route.group, remoteURL: nil, token: route.token,
                                              key: route.key, kind: .key, authorization: route.authorization,
                                              cacheScope: route.cacheScope), suffix: "key")
                    return "http://127.0.0.1:\(currentPort())\(path)"
                }
            }
            if line.hasPrefix("#") {
                let isKey = line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:")
                return replacingURIs(in: line) { registerResolved($0, base: base, route: route, cacheable: !isKey) }
            }
            guard !line.isEmpty else { return line }
            return registerResolved(line, base: base, route: route)
        }.joined(separator: "\n")
    }

    private func replacingURIs(in line: String, transform: (String) -> String) -> String {
        let regex = try! NSRegularExpression(pattern: #"URI="([^"]+)""#)
        var result = line
        let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        for match in matches.reversed() {
            guard let value = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(value, with: transform(String(result[value])))
        }
        return result
    }

    private func registerResolved(_ reference: String, base: URL, route: Route, cacheable: Bool = true) -> String {
        guard let url = URL(string: reference, relativeTo: base)?.absoluteURL,
              url.scheme == "https" || url.isLoopbackHTTP else { return reference }
        let kind: Kind = ["m3u8", "m3u"].contains(url.pathExtension.lowercased()) ? .manifest : .media
        let suffix = kind == .manifest ? "m3u8" : (url.pathExtension.isEmpty ? "bin" : url.pathExtension)
        let path = register(Route(group: route.group, remoteURL: url, token: route.token,
                                  key: route.key, kind: kind, authorization: route.authorization,
                                  cacheScope: cacheable ? route.cacheScope : nil), suffix: suffix)
        return "http://127.0.0.1:\(currentPort())\(path)"
    }

    private func send(_ body: Data, status: Int, contentType: String,
                      extraHeaders: [String: String] = [:], to connection: NWConnection) {
        trace("sending \(status)")
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 206: reason = "Partial Content"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Bad Gateway"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in extraHeaders { header += "\(name): \(value)\r\n" }
        header += "\r\n"
        connection.send(content: Data(header.utf8) + body,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private final class Lease {
        let gateway: HLSLocalGateway
        let group: UUID
        let authorization: HLSAuthorizationState
        init(gateway: HLSLocalGateway, group: UUID, authorization: HLSAuthorizationState) {
            self.gateway = gateway; self.group = group; self.authorization = authorization
        }
        deinit { gateway.release(group) }
    }
}

private extension URL {
    var isLoopbackHTTP: Bool {
        scheme == "http" && (host == "127.0.0.1" || host == "localhost")
    }
}
