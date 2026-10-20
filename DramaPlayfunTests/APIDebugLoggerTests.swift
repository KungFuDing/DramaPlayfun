#if DEBUG
import XCTest
@testable import DramaPlayfun

final class APIDebugLoggerTests: XCTestCase {
    @MainActor
    func testFormattingLeavesMainActorAndQueuedMessagesStayTogether() async throws {
        let formattingStarted = expectation(description: "Background formatting started")
        let messagesFinished = expectation(description: "Both messages were written")
        messagesFinished.expectedFulfillmentCount = 2
        let releaseFormatting = DispatchSemaphore(value: 0)
        let output = DebugLogOutput()
        let writer = APIDebugLogger.Writer { line in
            XCTAssertFalse(Thread.isMainThread, "Console writes must not block UI events")
            output.append(line)
            if line.hasSuffix(" END") { messagesFinished.fulfill() }
        }
        let body = Data(String(repeating: "短剧🎬", count: 1500).utf8)

        writer.enqueue(id: "first", event: "RESPONSE") {
            XCTAssertFalse(Thread.isMainThread, "Payload formatting must not run on the caller")
            formattingStarted.fulfill()
            // A busy logger cannot stop the main actor from enqueuing another event and
            // releasing this gate. The timeout also makes an inline-work regression fail safely.
            XCTAssertEqual(releaseFormatting.wait(timeout: .now() + 5), .success)
            return APIDebugLogger.formattedBody(body)
        }
        writer.enqueue(id: "second", event: "ERROR") { "second message" }

        await fulfillment(of: [formattingStarted], timeout: 2)
        releaseFormatting.signal()
        await fulfillment(of: [messagesFinished], timeout: 5)

        let lines = output.lines
        let firstEnd = try XCTUnwrap(lines.firstIndex(of: "[API first] RESPONSE END"))
        XCTAssertGreaterThan(firstEnd, 1, "The first response must span several chunks")
        XCTAssertTrue(lines[...firstEnd].allSatisfy { $0.hasPrefix("[API first] RESPONSE") })
        XCTAssertEqual(Array(lines[(firstEnd + 1)...]), [
            "[API second] ERROR [1/1]\nsecond message",
            "[API second] ERROR END"
        ])
    }

    func testLargeJSONKeepsLastRecordAndRedactsBeforeChunking() throws {
        let rows = (0..<1500).map { index in
            ["dramaTitle": "短剧第\(index)部 🎬", "videoUrl": "https://example.invalid/master.m3u8?X-Media-Token=test-secret&quality=1080"]
        }
        let body: [String: Any] = ["code": 200, "data": ["list": rows, "accessToken": "test-access-secret"]]
        let data = try JSONSerialization.data(withJSONObject: body)
        let formatted = APIDebugLogger.formattedBody(data)
        let parts = APIDebugLogger.chunks(formatted)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertEqual(parts.joined(), formatted)
        XCTAssertTrue(parts.allSatisfy { $0.utf8.count <= 1800 })
        XCTAssertFalse(formatted.contains("test-secret"))
        XCTAssertFalse(formatted.contains("test-access-secret"))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(parts.joined().utf8)) as? [String: Any])
        let payload = try XCTUnwrap(decoded["data"] as? [String: Any])
        let decodedRows = try XCTUnwrap(payload["list"] as? [[String: Any]])
        XCTAssertEqual(decodedRows.count, 1500)
        XCTAssertEqual(decodedRows.last?["dramaTitle"] as? String, "短剧第1499部 🎬")
        XCTAssertEqual(payload["accessToken"] as? String, "<redacted>")
    }

    func testLongPlainTextIsNotCutOffOrMisclassifiedAtUnicodeBoundary() {
        let text = String(repeating: "短剧🎬\n", count: 3000) + "END-OF-RESPONSE"
        let formatted = APIDebugLogger.formattedBody(Data(text.utf8))
        XCTAssertEqual(formatted, text)
        let parts = APIDebugLogger.chunks(formatted)
        XCTAssertEqual(parts.joined(), text)
        XCTAssertTrue(parts.allSatisfy { $0.utf8.count <= 1800 })
        XCTAssertTrue(parts.last?.hasSuffix("END-OF-RESPONSE") == true)
    }

    func testEmptyBinaryAndScalarResponsesRemainReadable() throws {
        XCTAssertEqual(APIDebugLogger.formattedBody(Data()), "<empty>")
        XCTAssertEqual(APIDebugLogger.formattedBody(Data([0xff, 0xfe])), "<binary, 2 bytes>")
        let string = try JSONSerialization.data(withJSONObject: "剧集", options: .fragmentsAllowed)
        let decoded = try JSONSerialization.jsonObject(with: Data(APIDebugLogger.formattedBody(string).utf8), options: .fragmentsAllowed)
        XCTAssertEqual(decoded as? String, "剧集")
    }
}

/// The writer mutates this on its queue; assertions read a locked snapshot after completion.
nonisolated private final class DebugLogOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLines: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedLines
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        storedLines.append(line)
    }
}
#endif
