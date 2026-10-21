import CryptoKit
import Foundation

/// Stores complete upstream media bodies, never manifests or AES keys. Bytes remain encrypted.
nonisolated final class HLSMediaCache: @unchecked Sendable {
    static let shared = HLSMediaCache()
    fileprivate struct Metadata: Codable {
        let length: Int64
        let contentType: String
    }

    final class Reader: @unchecked Sendable {
        let length: Int64
        let contentType: String
        let contentRange: String?
        private let handle: FileHandle
        private var remaining: Int64

        fileprivate init(handle: FileHandle, metadata: Metadata, range: ClosedRange<Int64>?) throws {
            self.handle = handle
            contentType = metadata.contentType
            length = range.map { $0.upperBound - $0.lowerBound + 1 } ?? metadata.length
            remaining = length
            contentRange = range.map { "bytes \($0.lowerBound)-\($0.upperBound)/\(metadata.length)" }
            try handle.seek(toOffset: UInt64(range?.lowerBound ?? 0))
        }

        func read() throws -> Data {
            guard remaining > 0 else { return Data() }
            let data = try handle.read(upToCount: Int(min(remaining, 64 * 1024))) ?? Data()
            guard !data.isEmpty else { throw URLError(.cannotDecodeContentData) }
            remaining -= Int64(data.count)
            return data
        }

        func close() { try? handle.close() }
        deinit { close() }
    }

    final class Writer {
        private let cache: HLSMediaCache
        private let handle: FileHandle
        private let file: URL
        private let key: String
        private let contentType: String
        private let generation: Int
        private var count: Int64 = 0
        private var finished = false

        fileprivate init(cache: HLSMediaCache, file: URL, key: String, contentType: String, generation: Int) throws {
            self.cache = cache
            self.file = file
            self.key = key
            self.contentType = contentType
            self.generation = generation
            handle = try FileHandle(forWritingTo: file)
        }

        func append(_ data: Data) {
            guard !finished else { return }
            guard count + Int64(data.count) <= min(cache.maxBytes, 64 * 1024 * 1024) else { discard(); return }
            do { try handle.write(contentsOf: data); count += Int64(data.count) }
            catch { discard() }
        }

        func finish(expectedLength: Int64) {
            guard !finished else { return }
            guard count > 0, expectedLength < 0 || count == expectedLength else { discard(); return }
            finished = true
            try? handle.close()
            cache.commit(file: file, key: key, metadata: Metadata(length: count, contentType: contentType),
                         generation: generation)
        }

        func discard() {
            guard !finished else { return }
            finished = true
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
        }

        deinit { discard() }
    }

    private let lock = NSLock()
    private let directory: URL
    private let maxBytes: Int64
    private let maxAge: TimeInterval
    private var generation = 0

    init(directory: URL? = nil, maxBytes: Int64 = 250 * 1024 * 1024, maxAge: TimeInterval = 7 * 24 * 3600) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HLSMediaSegments", isDirectory: true)
        self.maxBytes = maxBytes
        self.maxAge = maxAge
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        // Temporary files from terminated downloads are never valid cache entries.
        for file in files() where file.pathExtension == "tmp" { try? FileManager.default.removeItem(at: file) }
        prune()
    }

    static func cacheKey(for url: URL, scope: String) -> String {
        let identity = Data((scope + "\n" + MediaResourceURL.contentKey(for: url)).utf8)
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    func reader(for request: URLRequest, scope: String) -> Reader? {
        guard let url = request.url else { return nil }
        let key = Self.cacheKey(for: url, scope: scope)
        lock.lock()
        defer { lock.unlock() }
        let file = directory.appendingPathComponent(key + ".media")
        let info = directory.appendingPathComponent(key + ".json")
        guard let bytes = try? Data(contentsOf: info), let metadata = try? JSONDecoder().decode(Metadata.self, from: bytes),
              let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              Int64(values.fileSize ?? 0) == metadata.length, metadata.length > 0,
              Date().timeIntervalSince(values.contentModificationDate ?? .distantPast) < maxAge else { return nil }
        let range: ClosedRange<Int64>?
        if let header = request.value(forHTTPHeaderField: "Range") {
            guard let parsed = Self.byteRange(header, length: metadata.length) else { return nil }
            range = parsed
        } else { range = nil }
        guard let handle = try? FileHandle(forReadingFrom: file),
              let reader = try? Reader(handle: handle, metadata: metadata, range: range) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return reader
    }

    var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func writer(for request: URLRequest, response: HTTPURLResponse, scope: String,
                expectedGeneration: Int? = nil) -> Writer? {
        // A partial/range response must never poison a full-segment entry.
        guard response.statusCode == 200, request.value(forHTTPHeaderField: "Range") == nil,
              response.expectedContentLength <= min(maxBytes, 64 * 1024 * 1024), let url = request.url else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard expectedGeneration == nil || expectedGeneration == generation else { return nil }
        let file = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { return nil }
        return try? Writer(cache: self, file: file, key: Self.cacheKey(for: url, scope: scope),
            contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream", generation: generation)
    }

    var diskSize: UInt {
        lock.lock()
        defer { lock.unlock() }
        return UInt(files().reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) })
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        files().forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func commit(file: URL, key: String, metadata: Metadata, generation: Int) {
        lock.lock()
        defer { lock.unlock(); try? FileManager.default.removeItem(at: file) }
        guard generation == self.generation else { return }
        let target = directory.appendingPathComponent(key + ".media")
        let info = directory.appendingPathComponent(key + ".json")
        do {
            let data = try JSONEncoder().encode(metadata)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: file, to: target)
            try data.write(to: info, options: .atomic)
            prune()
        } catch {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: info)
        }
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
    }

    private func prune() {
        let media = files().filter { $0.pathExtension == "media" }.map { file in
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (file, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = media.reduce(Int64(0)) { $0 + $1.1 }
        for (file, size, date) in media where total > maxBytes || Date().timeIntervalSince(date) >= maxAge {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.deletingPathExtension().appendingPathExtension("json"))
            total -= size
        }
    }

    private static func byteRange(_ header: String, length: Int64) -> ClosedRange<Int64>? {
        guard header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let bounds = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty {
            guard let suffix = Int64(bounds[1]), suffix > 0 else { return nil }
            return max(0, length - suffix)...(length - 1)
        }
        guard let start = Int64(bounds[0]), start >= 0, start < length else { return nil }
        let end = bounds[1].isEmpty ? length - 1 : Int64(bounds[1])
        guard let end, end >= start else { return nil }
        return start...min(end, length - 1)
    }
}
