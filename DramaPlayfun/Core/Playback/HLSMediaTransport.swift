import Foundation
import Network
import OSLog

/// Relays encrypted media without retaining a complete segment in memory.
/// Each asset reuses its own CDN connections and serial delegate queue. A paused
/// neighbor's downstream backpressure must not block the foreground asset.
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
        var isResuming = false
        var retryableStatus: Int?
        let failureID = UUID()
        let authorization: HLSAuthorizationState
        let cacheScope: String?
        var cacheWriter: HLSMediaCache.Writer?
        #if DEBUG
        var pendingWriteStartedAt: Date?
        #endif

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

    private final class ManifestRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false

        func install(_ task: URLSessionDataTask) {
            lock.lock()
            self.task = task
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
        }
    }

    private let lock = NSLock()
    private var transfers: [ObjectIdentifier: Transfer] = [:]
    private var cachedTransfers: [ObjectIdentifier: CachedTransfer] = [:]
    private let cacheQueue = DispatchQueue(label: "drama.hls.cached-media", qos: .userInitiated)
    private var sessions: [UUID: URLSession] = [:]
    private let logger = Logger(subsystem: "com.video.test.DramaPlayfun.playback", category: "media")
    #if DEBUG
    private var events: [String] = []
    var debugEvents: [String] {
        lock.lock(); defer { lock.unlock() }; return events
    }
    func debugHasBlockedMediaWrite(group: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return transfers.values.contains {
            $0.group == group && ($0.pendingWriteStartedAt.map { Date().timeIntervalSince($0) >= 0.1 } ?? false)
        }
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

    func register(group: UUID) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 4
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        lock.lock()
        let previous = sessions.updateValue(session, forKey: group)
        lock.unlock()
        previous?.invalidateAndCancel()
    }

    private func session(for group: UUID) -> URLSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[group]
    }

    func start(_ request: URLRequest, group: UUID, connection: NWConnection,
               authorization: HLSAuthorizationState, cacheScope: String?) {
        guard let session = session(for: group) else { connection.cancel(); return }
        if let cacheScope, let reader = HLSMediaCache.shared.reader(for: request, scope: cacheScope) {
            serveCached(reader, group: group, connection: connection)
            return
        }
        lock.lock()
        guard sessions[group] === session else {
            lock.unlock()
            connection.cancel()
            return
        }
        let task = session.dataTask(with: request)
        transfers[ObjectIdentifier(task)] = Transfer(group: group, connection: connection, task: task,
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

    func data(for request: URLRequest, group: UUID) async throws -> (Data, URLResponse) {
        for attempt in 0...2 {
            do {
                let result = try await manifestData(for: request, group: group)
                if let http = result.1 as? HTTPURLResponse,
                   HLSAuthorizationState.isTransient(status: http.statusCode), attempt < 2 {
                    trace("manifest retry attempt=\(attempt + 1)")
                    try await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
                    continue
                }
                return result
            } catch {
                guard HLSAuthorizationState.isTransient(error), attempt < 2 else { throw error }
                trace("manifest retry attempt=\(attempt + 1)")
                try await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
            }
        }
        throw URLError(.badServerResponse)
    }

    private func manifestData(for request: URLRequest, group: UUID) async throws -> (Data, URLResponse) {
        let pending = ManifestRequest()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                // Group removal and task creation use the same lock. Never create
                // a task on a session that cancel(group:) has already invalidated.
                lock.lock()
                guard let session = sessions[group] else {
                    lock.unlock()
                    continuation.resume(throwing: URLError(.cancelled))
                    return
                }
                let task = session.dataTask(with: request) { data, response, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, let response { continuation.resume(returning: (data, response)) }
                    else { continuation.resume(throwing: URLError(.badServerResponse)) }
                }
                pending.install(task)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            pending.cancel()
        }
    }

    func cancel(group: UUID) {
        lock.lock()
        let session = sessions.removeValue(forKey: group)
        let active = transfers.values.filter { $0.group == group }
        let cached = cachedTransfers.values.filter { $0.group == group }
        lock.unlock()
        // Cancel downstream too so a pending write releases its delegate queue.
        active.forEach { $0.connection.cancel() }
        session?.invalidateAndCancel()
        cached.forEach { finishCached($0) }
    }

    private func serveCached(_ reader: HLSMediaCache.Reader, group: UUID, connection: NWConnection) {
        let transfer = CachedTransfer(group: group, connection: connection, reader: reader)
        lock.lock()
        guard sessions[group] != nil else {
            lock.unlock()
            reader.close()
            connection.cancel()
            return
        }
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
        return transfers[ObjectIdentifier(task)]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // Async manifest data tasks also use this asset's session so their established
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
        if HLSAuthorizationState.isTransient(status: http.statusCode) {
            transfer.retryableStatus = http.statusCode
            completionHandler(.cancel)
            return
        }
        if transfer.isResuming {
            let start = transfer.rangeStart + Int64(transfer.receivedBytes)
            let end = transfer.rangeStart + transfer.expectedBytes - 1
            let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            guard http.statusCode == 206, range.hasPrefix("bytes \(start)-\(end)/"),
                  http.expectedContentLength == transfer.expectedBytes - Int64(transfer.receivedBytes) else {
                logger.info("media resume rejected status=\(http.statusCode) length=\(http.expectedContentLength) expected=\(transfer.expectedBytes - Int64(transfer.receivedBytes)) range=\(range, privacy: .public)")
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
        #if DEBUG
        lock.lock()
        transfer.pendingWriteStartedAt = Date()
        lock.unlock()
        defer {
            lock.lock()
            transfer.pendingWriteStartedAt = nil
            lock.unlock()
        }
        #endif
        transfer.connection.send(content: body, completion: .contentProcessed { error in
            if error != nil { dataTask.cancel() }
            written.signal()
        })
        if written.wait(timeout: .now() + 15) == .timedOut { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = transfer(for: task) else { return }
        let status = transfer.retryableStatus
        transfer.retryableStatus = nil
        let failure: Error? = status.map {
            NSError(domain: NSURLErrorDomain, code: URLError.badServerResponse.rawValue,
                    userInfo: ["HTTPStatusCode": $0]) as Error
        } ?? error
        let hasCompleteBody = transfer.expectedBytes > 0 && Int64(transfer.receivedBytes) == transfer.expectedBytes
        trace("media end code=\(failure.map { ($0 as NSError).code } ?? 0) bytes=\(transfer.receivedBytes) expected=\(transfer.expectedBytes) retries=\(transfer.retries)")
        if let failure, !hasCompleteBody {
            // AVPlayer can abandon a damaged stream before the Range retry finishes.
            // Retain the real upstream failure so the player can classify that case.
            transfer.authorization.recordTransientFailure(failure, requestID: transfer.failureID)
            if retryIfPossible(transfer, after: failure) { return }
        }
        lock.lock()
        transfers[ObjectIdentifier(task)] = nil
        lock.unlock()
        if transfer.rejected { return }
        let connection = transfer.connection
        if failure == nil || hasCompleteBody {
            transfer.authorization.clearTransientFailure(requestID: transfer.failureID)
            transfer.cacheWriter?.finish(expectedLength: transfer.expectedBytes)
        }
        else { transfer.cacheWriter?.discard() }
        if let error = failure, !hasCompleteBody {
            logger.info("media failed code=\((error as NSError).code) bytes=\(transfer.receivedBytes)")
            if !transfer.sentHeaders {
                let header = "HTTP/1.1 \(status ?? 502) Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else { connection.cancel() }
        } else {
            logger.debug("media complete bytes=\(transfer.receivedBytes) ms=\(Int(Date().timeIntervalSince(transfer.started) * 1000))")
            connection.send(content: transfer.chunked ? Data("0\r\n\r\n".utf8) : nil,
                isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func retryIfPossible(_ transfer: Transfer, after error: Error) -> Bool {
        guard HLSAuthorizationState.isTransient(error),
              transfer.retries < 2, !transfer.rejected,
              var request = transfer.task.originalRequest,
              let session = session(for: transfer.group) else { return false }
        if transfer.sentHeaders {
            guard transfer.expectedBytes > 0, Int64(transfer.receivedBytes) < transfer.expectedBytes else { return false }
            let start = transfer.rangeStart + Int64(transfer.receivedBytes)
            let end = transfer.rangeStart + transfer.expectedBytes - 1
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            if let validator = transfer.validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        }
        lock.lock()
        guard sessions[transfer.group] === session else {
            lock.unlock()
            return false
        }
        let next = session.dataTask(with: request)
        transfers[ObjectIdentifier(transfer.task)] = nil
        transfer.task = next
        transfer.retries += 1
        transfer.isResuming = transfer.sentHeaders
        transfers[ObjectIdentifier(next)] = transfer
        lock.unlock()
        logger.info("media retry attempt=\(transfer.retries) bytes=\(transfer.receivedBytes) range=\(transfer.isResuming)")
        if transfer.isResuming { next.resume() }
        else {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2 * Double(transfer.retries)) {
                next.resume()
            }
        }
        return true
    }
}
