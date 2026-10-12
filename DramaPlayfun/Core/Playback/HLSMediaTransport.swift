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

        init(group: UUID, connection: NWConnection, task: URLSessionDataTask, authorization: HLSAuthorizationState) {
            self.group = group
            self.connection = connection
            self.task = task
            self.authorization = authorization
        }
    }

    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private var session: URLSession!
    private let logger = Logger(subsystem: "com.video.test.DramaPlayfun.playback", category: "media")

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

    func start(_ request: URLRequest, group: UUID, connection: NWConnection, authorization: HLSAuthorizationState) {
        let task = session.dataTask(with: request)
        lock.lock()
        transfers[task.taskIdentifier] = Transfer(group: group, connection: connection, task: task, authorization: authorization)
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
        lock.unlock()
        tasks.forEach { $0.cancel() }
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
        if let error, resumeIfPossible(transfer, after: error) { return }
        lock.lock()
        transfers[task.taskIdentifier] = nil
        lock.unlock()
        if transfer.rejected { return }
        let connection = transfer.connection
        let hasCompleteBody = transfer.expectedBytes > 0 && Int64(transfer.receivedBytes) == transfer.expectedBytes
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
              transfer.receivedBytes > 0, Int64(transfer.receivedBytes) < transfer.expectedBytes,
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
