import XCTest
@testable import DramaPlayfun

final class HLSMediaCacheTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HLSMediaCacheTests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func request(_ token: String = "old", content: String = "seg.ts?v=1&quality=1080") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://media.example.invalid/\(content)&x-media-token=\(token)")!)
        request.setValue(token, forHTTPHeaderField: "X-Media-Token")
        return request
    }

    private func response(_ request: URLRequest, length: Int, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(length), "Content-Type": "video/mp2t"])!
    }

    private func store(_ body: Data, in cache: HLSMediaCache, request: URLRequest, scope: String = "episode:1:key:1") throws {
        let writer = try XCTUnwrap(cache.writer(for: request, response: response(request, length: body.count), scope: scope))
        writer.append(body)
        writer.finish(expectedLength: Int64(body.count))
    }

    private func read(_ reader: HLSMediaCache.Reader) throws -> Data {
        defer { reader.close() }
        var body = Data()
        while true {
            let chunk = try reader.read()
            if chunk.isEmpty { return body }
            body += chunk
        }
    }

    func testRotatedTokenReusesPersistedBytesAcrossCacheInstances() throws {
        let directory = try directory()
        let cache = HLSMediaCache(directory: directory)
        let body = Data((0..<200_000).map { UInt8($0 % 251) })
        try store(body, in: cache, request: request())
        let reopened = HLSMediaCache(directory: directory)
        let reader = try XCTUnwrap(reopened.reader(for: request("new"), scope: "episode:1:key:1"))
        XCTAssertEqual(reader.length, Int64(body.count))
        XCTAssertEqual(reader.contentType, "video/mp2t")
        XCTAssertEqual(try read(reader), body)
        XCTAssertNil(reopened.reader(for: request("new"), scope: "episode:2:key:1"))
        XCTAssertNil(reopened.reader(for: request("new"), scope: "episode:1:key:2"))
        XCTAssertNil(reopened.reader(for: request("new", content: "seg.ts?v=2&quality=1080"), scope: "episode:1:key:1"))
        XCTAssertNil(reopened.reader(for: request("new", content: "seg.ts?v=1&quality=720"), scope: "episode:1:key:1"))
    }

    func testByteRangesReadExactBytesFromFullCachedSegment() throws {
        let cache = HLSMediaCache(directory: try directory())
        let body = Data(0..<100)
        try store(body, in: cache, request: request())
        let ranges: [(String, Data, String)] = [
            ("bytes=17-63", Data(body[17...63]), "bytes 17-63/100"),
            ("bytes=90-", Data(body[90...99]), "bytes 90-99/100"),
            ("bytes=-5", Data(body[95...99]), "bytes 95-99/100"),
            ("bytes=95-200", Data(body[95...99]), "bytes 95-99/100")
        ]
        for (header, expected, contentRange) in ranges {
            var request = request("new")
            request.setValue(header, forHTTPHeaderField: "Range")
            let reader = try XCTUnwrap(cache.reader(for: request, scope: "episode:1:key:1"))
            XCTAssertEqual(reader.contentRange, contentRange)
            XCTAssertEqual(try read(reader), expected)
        }
        var invalid = request()
        invalid.setValue("bytes=200-300", forHTTPHeaderField: "Range")
        XCTAssertNil(cache.reader(for: invalid, scope: "episode:1:key:1"))
    }

    func testIncompletePartialAndUnauthorizedBodiesNeverBecomeHits() throws {
        let cache = HLSMediaCache(directory: try directory())
        let request = request()
        let scope = "episode:1:key:1"
        let writer = try XCTUnwrap(cache.writer(for: request, response: response(request, length: 100), scope: scope))
        writer.append(Data(0..<50))
        XCTAssertNil(cache.reader(for: request, scope: scope))
        writer.finish(expectedLength: 100)
        XCTAssertNil(cache.reader(for: request, scope: scope))
        XCTAssertEqual(cache.diskSize, 0)
        XCTAssertNil(cache.writer(for: request, response: response(request, length: 100, status: 403), scope: scope))
        XCTAssertNil(cache.writer(for: request, response: response(request, length: 100, status: 206), scope: scope))
        var ranged = request
        ranged.setValue("bytes=0-49", forHTTPHeaderField: "Range")
        XCTAssertNil(cache.writer(for: ranged, response: response(ranged, length: 100), scope: scope))
    }

    func testClearingCachePreventsAnOlderDownloadFromRepublishing() throws {
        let cache = HLSMediaCache(directory: try directory())
        let request = request()
        let writer = try XCTUnwrap(cache.writer(for: request, response: response(request, length: 10), scope: "scope"))
        writer.append(Data(0..<10))
        cache.clear()
        writer.finish(expectedLength: 10)
        XCTAssertNil(cache.reader(for: request, scope: "scope"))
        XCTAssertEqual(cache.diskSize, 0)
        try store(Data(0..<10), in: cache, request: request, scope: "scope")
        XCTAssertNotNil(cache.reader(for: request, scope: "scope"))
    }

    func testCacheBudgetAndExpirationEvictOldSegments() throws {
        let directory = try directory()
        let cache = HLSMediaCache(directory: directory, maxBytes: 150)
        try store(Data(repeating: 1, count: 100), in: cache, request: request(content: "first.ts?v=1"))
        try store(Data(repeating: 2, count: 100), in: cache, request: request(content: "second.ts?v=1"))
        XCTAssertNil(cache.reader(for: request(content: "first.ts?v=1"), scope: "episode:1:key:1"))
        XCTAssertNotNil(cache.reader(for: request(content: "second.ts?v=1"), scope: "episode:1:key:1"))
        let expired = HLSMediaCache(directory: directory, maxAge: 0)
        XCTAssertEqual(expired.diskSize, 0)
    }
}
