import Foundation
import Network
import OSLog

/// Relays encrypted media without retaining a complete segment in memory.
/// URLSession reuses CDN connections; NWConnection provides downstream backpressure.
nonisolated final class HLSMediaTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Transfer {
        let group: UUID
        let connection: NWConnection
        var task: URLSessionDataTask
        let started = Date()
        var chunked = false
        var sentHeaders = false
        var receivedBytes = 0
        var rejected = false
        var expectedBytes: Int64 = -1
        var rangeStart: Int64 = 0
        var validator: String?
        var retries = 0
        let authorization: HLSAuthorizationState
        let cacheScope: String?
        var cacheWriter: HLSMediaCache.Writer?

        init(group: UUID, connection: NWConnection, task: URLSessionDataTask,
             authorization: HLSAuthorizationState, cacheScope: String?) {
            self.group = group
            self.connection = connection
            self.task = task
            self.authorization = authorization
            self.cacheScope = cacheScope
        }
    }

    private final class CachedTransfer: @unchecked Sendable {
        let group: UUID
        let connection: NWConnection
        let reader: HLSMediaCache.Reader
        init(group: UUID, connection: NWConnection, reader: HLSMediaCache.Reader) {
            self.group = group; self.connection = connection; self.reader = reader
        }
    }

    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private var cachedTransfers: [ObjectIdentifier: CachedTransfer] = [:]
    private let cacheQueue = DispatchQueue(label: "drama.hls.cached-media", qos: .userInitiated)
    private var session: URLSession!
    private let logger = Logger(subsystem: "com.video.test.DramaPlayfun.playback", category: "media")
    #if DEBUG
    private var events: [String] = []
    var debugEvents: [String] {
        lock.lock(); defer { lock.unlock() }; return events
    }
    #endif
    private func trace(_ event: String) {
        #if DEBUG
        lock.lock()
        events.append(event)
        if events.count > 128 { events.removeFirst(events.count - 128) }
        lock.unlock()
        #endif
    }

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 4
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    func start(_ request: URLRequest, group: UUID, connection: NWConnection,
               authorization: HLSAuthorizationState, cacheScope: String?) {
        if let cacheScope, let reader = HLSMediaCache.shared.reader(for: request, scope: cacheScope) {
            serveCached(reader, group: group, connection: connection)
            return
        }
        let task = session.dataTask(with: request)
        lock.lock()
        transfers[task.taskIdentifier] = Transfer(group: group, connection: connection, task: task,
                                                authorization: authorization, cacheScope: cacheScope)
        lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                if let connection { self?.cancel(connection: connection) }
            default: break
            }
        }
        task.resume()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func cancel(group: UUID) {
        lock.lock()
        let tasks = transfers.values.filter { $0.group == group }.map(\.task)
        let cached = cachedTransfers.values.filter { $0.group == group }
        lock.unlock()
        tasks.forEach { $0.cancel() }
        cached.forEach { finishCached($0) }
    }

    private func serveCached(_ reader: HLSMediaCache.Reader, group: UUID, connection: NWConnection) {
        let transfer = CachedTransfer(group: group, connection: connection, reader: reader)
        lock.lock()
        cachedTransfers[ObjectIdentifier(connection)] = transfer
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finishCached(transfer) }
            if case .cancelled = state { self?.finishCached(transfer) }
        }
        let partial = reader.contentRange != nil
        var header = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\n"
        header += "Content-Type: \(reader.contentType)\r\nContent-Length: \(reader.length)\r\n"
        if let range = reader.contentRange { header += "Content-Range: \(range)\r\n" }
        header += "Connection: close\r\n\r\n"
        logger.debug("media cache hit bytes=\(reader.length)")
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.finishCached(transfer) }
            else { self?.sendCachedChunk(transfer) }
        })
    }

    private func sendCachedChunk(_ transfer: CachedTransfer) {
        cacheQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let active = self.cachedTransfers[ObjectIdentifier(transfer.connection)] != nil
            self.lock.unlock()
            guard active else { return }
            do {
                let data = try transfer.reader.read()
                transfer.connection.send(content: data.isEmpty ? nil : data, isComplete: data.isEmpty,
                    completion: .contentProcessed { [weak self] error in
                        if error != nil || data.isEmpty { self?.finishCached(transfer) }
                        else { self?.sendCachedChunk(transfer) }
                    })
            } catch { self.finishCached(transfer) }
        }
    }

    private func finishCached(_ transfer: CachedTransfer) {
        lock.lock()
        let removed = cachedTransfers.removeValue(forKey: ObjectIdentifier(transfer.connection))
        lock.unlock()
        guard removed != nil else { return }
        transfer.connection.stateUpdateHandler = nil
        transfer.connection.cancel()
        cacheQueue.async { transfer.reader.close() }
    }

    private func cancel(connection: NWConnection) {
        lock.lock()
        let tasks = transfers.values.filter { $0.connection === connection }.map(\.task)
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }

    private func transfer(for task: URLSessionTask) -> Transfer? {
        lock.lock()
        defer { lock.unlock() }
        return transfers[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // Async manifest data tasks also use this session so their established
        // CDN connections can be reused for the initialization/media requests.
        guard let transfer = transfer(for: dataTask) else {
            completionHandler(.allow)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        transfer.authorization.record(status: http.statusCode)
        trace("media status=\(http.statusCode) length=\(http.expectedContentLength) retries=\(transfer.retries)")
        if transfer.retries > 0 {
            let start = transfer.rangeStart + Int64(transfer.receivedBytes)
            let end = transfer.rangeStart + transfer.expectedBytes - 1
            let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            guard http.statusCode == 206, range.hasPrefix("bytes \(start)-\(end)/"),
                  http.expectedContentLength == transfer.expectedBytes - Int64(transfer.receivedBytes) else {
                logger.info("media resume rejected status=\(http.statusCode)")
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
            return
        }
        transfer.sentHeaders = true
        guard http.statusCode == 200 || http.statusCode == 206 else {
            transfer.rejected = true
            logger.info("media rejected status=\(http.statusCode)")
            let header = "HTTP/1.1 \(http.statusCode) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            let connection = transfer.connection
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            completionHandler(.cancel)
            return
        }
        transfer.chunked = http.expectedContentLength < 0
        transfer.expectedBytes = http.expectedContentLength
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let start = range.dropFirst("bytes ".count).split(separator: "-").first.flatMap({ Int64($0) }) {
            transfer.rangeStart = start
        }
        transfer.validator = http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "Last-Modified")
        if let request = dataTask.originalRequest, let scope = transfer.cacheScope {
            transfer.cacheWriter = HLSMediaCache.shared.writer(for: request, response: http, scope: scope)
        }
        var header = "HTTP/1.1 \(http.statusCode) \(http.statusCode == 206 ? "Partial Content" : "OK")\r\n"
        header += "Content-Type: \(http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")\r\n"
        header += transfer.chunked ? "Transfer-Encoding: chunked\r\n" : "Content-Length: \(http.expectedContentLength)\r\n"
        if let range = http.value(forHTTPHeaderField: "Content-Range") { header += "Content-Range: \(range)\r\n" }
        header += "Connection: close\r\n\r\n"
        transfer.connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
            if error != nil { dataTask.cancel() }
        })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(for: dataTask) else { return }
        if transfer.receivedBytes == 0 {
            logger.debug("media first-byte ms=\(Int(Date().timeIntervalSince(transfer.started) * 1000))")
        }
        transfer.receivedBytes += data.count
        transfer.cacheWriter?.append(data)
        let body = transfer.chunked ? Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n".utf8) : data
        // Keep the CDN request alive. Suspending a data task between chunks can
        // tear down HTTP/2 streams; wait for the loopback write on this dedicated
        // delegate queue instead of repeatedly restarting the upstream request.
        let written = DispatchSemaphore(value: 0)
        transfer.connection.send(content: body, completion: .contentProcessed { error in
            if error != nil { dataTask.cancel() }
            written.signal()
        })
        if written.wait(timeout: .now() + 15) == .timedOut { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = transfer(for: task) else { return }
        trace("media end code=\(error.map { ($0 as NSError).code } ?? 0) bytes=\(transfer.receivedBytes) expected=\(transfer.expectedBytes) retries=\(transfer.retries)")
        if let error, resumeIfPossible(transfer, after: error) { return }
        lock.lock()
        transfers[task.taskIdentifier] = nil
        lock.unlock()
        if transfer.rejected { return }
        let connection = transfer.connection
        let hasCompleteBody = transfer.expectedBytes > 0 && Int64(transfer.receivedBytes) == transfer.expectedBytes
        if error == nil || hasCompleteBody { transfer.cacheWriter?.finish(expectedLength: transfer.expectedBytes) }
        else { transfer.cacheWriter?.discard() }
        if let error, !hasCompleteBody {
            logger.info("media failed code=\((error as NSError).code) bytes=\(transfer.receivedBytes)")
            if !transfer.sentHeaders {
                let header = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else { connection.cancel() }
        } else {
            logger.debug("media complete bytes=\(transfer.receivedBytes) ms=\(Int(Date().timeIntervalSince(transfer.started) * 1000))")
            connection.send(content: transfer.chunked ? Data("0\r\n\r\n".utf8) : nil,
                isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func resumeIfPossible(_ transfer: Transfer, after error: Error) -> Bool {
        let code = (error as NSError).code
        guard (error as NSError).domain == NSURLErrorDomain,
              code == URLError.networkConnectionLost.rawValue || code == URLError.timedOut.rawValue,
              transfer.retries == 0, transfer.sentHeaders, !transfer.rejected,
              transfer.expectedBytes > 0, Int64(transfer.receivedBytes) < transfer.expectedBytes,
              var request = transfer.task.originalRequest else { return false }
        let start = transfer.rangeStart + Int64(transfer.receivedBytes)
        let end = transfer.rangeStart + transfer.expectedBytes - 1
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        if let validator = transfer.validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        let next = session.dataTask(with: request)
        lock.lock()
        transfers[transfer.task.taskIdentifier] = nil
        transfer.task = next
        transfer.retries += 1
        transfers[next.taskIdentifier] = transfer
        lock.unlock()
        logger.info("media resume bytes=\(transfer.receivedBytes)")
        next.resume()
        return true
    }
}
