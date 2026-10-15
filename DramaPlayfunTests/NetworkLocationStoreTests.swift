import XCTest
@testable import DramaPlayfun

@MainActor
final class NetworkLocationStoreTests: XCTestCase {
    func testCachesSuccessfulLookupAndRefreshesAfterExpiry() async throws {
        var time = Date(timeIntervalSince1970: 1_000)
        var calls = 0
        let first = try NetworkLocation(ip: "203.0.113.1", countryCode: "TW")
        let second = try NetworkLocation(ip: "2001:db8::1", countryCode: "US")
        let store = NetworkLocationStore(now: { time }) {
            calls += 1
            return calls == 1 ? first : second
        }
        let initial = await store.current()
        time = time.addingTimeInterval(299)
        let cached = await store.current()
        XCTAssertEqual(initial, first)
        XCTAssertEqual(cached, first)
        XCTAssertEqual(calls, 1)
        time = time.addingTimeInterval(1)
        let refreshed = await store.current()
        XCTAssertEqual(refreshed, second)
        XCTAssertEqual(calls, 2)
    }

    func testConcurrentRequestsShareLookupAndOneCancellationDoesNotCancelOthers() async throws {
        let started = expectation(description: "Shared lookup started")
        let gate = LocationLookupGate(started: [started])
        let store = NetworkLocationStore { try await gate.lookup() }
        let first = Task { await store.current() }
        let second = Task { await store.current() }
        await fulfillment(of: [started], timeout: 2)
        first.cancel()
        let location = try NetworkLocation(ip: "203.0.113.1", countryCode: "TW")
        gate.finish(at: 0, with: location)
        let cancelled = await first.value
        let shared = await second.value
        let cached = await store.current()
        XCTAssertNil(cancelled)
        XCTAssertEqual(shared, location)
        XCTAssertEqual(cached, location)
        XCTAssertEqual(gate.calls, 1)
    }

    func testFailureBacksOffThenRetriesWithoutReturningExpiredLocation() async throws {
        var time = Date(timeIntervalSince1970: 1_000)
        var calls = 0
        let location = try NetworkLocation(ip: "203.0.113.1", countryCode: "TW")
        let store = NetworkLocationStore(now: { time }) {
            calls += 1
            if calls == 2 { throw URLError(.timedOut) }
            return location
        }
        _ = await store.current()
        time = time.addingTimeInterval(300)
        let failed = await store.current()
        XCTAssertNil(failed)
        time = time.addingTimeInterval(29)
        let backedOff = await store.current()
        XCTAssertNil(backedOff)
        XCTAssertEqual(calls, 2)
        time = time.addingTimeInterval(1)
        let retried = await store.current()
        XCTAssertEqual(retried, location)
        XCTAssertEqual(calls, 3)
    }

    func testCancelledSoleCallerStillStartsCacheExpiryWhenLookupCompletes() async throws {
        var time = Date(timeIntervalSince1970: 1_000)
        var calls = 0
        let started = expectation(description: "Lookup started")
        let gate = LocationLookupGate(started: [started])
        let fresh = try NetworkLocation(ip: "203.0.113.2", countryCode: "JP")
        let store = NetworkLocationStore(now: { time }) {
            calls += 1
            if calls == 1 { return try await gate.lookup() }
            return fresh
        }
        let request = Task { await store.current() }
        await fulfillment(of: [started], timeout: 2)
        request.cancel()
        gate.finish(at: 0, with: try NetworkLocation(ip: "203.0.113.1", countryCode: "TW"))
        let cancelled = await request.value
        XCTAssertNil(cancelled)
        time = time.addingTimeInterval(300)
        let refreshed = await store.current()
        XCTAssertEqual(refreshed, fresh)
        XCTAssertEqual(calls, 2)
    }

    func testInvalidationClearsCacheAndFailureBackoff() async throws {
        var calls = 0
        let location = try NetworkLocation(ip: "203.0.113.1", countryCode: "TW")
        let store = NetworkLocationStore {
            calls += 1
            if calls == 2 { throw URLError(.notConnectedToInternet) }
            return location
        }
        _ = await store.current()
        store.invalidate()
        let failed = await store.current()
        XCTAssertNil(failed)
        store.invalidate()
        let refreshed = await store.current()
        XCTAssertEqual(refreshed, location)
        XCTAssertEqual(calls, 3)
    }

    func testLateResponseFromPreviousNetworkCannotReplaceNewNetworkLocation() async throws {
        let oldStarted = expectation(description: "Old network lookup started")
        let newStarted = expectation(description: "New network lookup started")
        let gate = LocationLookupGate(started: [oldStarted, newStarted])
        let store = NetworkLocationStore { try await gate.lookup() }
        let oldRequest = Task { await store.current() }
        await fulfillment(of: [oldStarted], timeout: 2)
        store.invalidate()
        let newRequest = Task { await store.current() }
        await fulfillment(of: [newStarted], timeout: 2)
        let newLocation = try NetworkLocation(ip: "2001:db8::2", countryCode: "JP")
        gate.finish(at: 1, with: newLocation)
        let current = await newRequest.value
        XCTAssertEqual(current, newLocation)
        // Simulate a transport that returns even after its task was cancelled.
        gate.finish(at: 0, with: try NetworkLocation(ip: "203.0.113.1", countryCode: "TW"))
        let discarded = await oldRequest.value
        let cached = await store.current()
        XCTAssertNil(discarded)
        XCTAssertEqual(cached, newLocation)
        XCTAssertEqual(gate.calls, 2)
    }

    func testCancelledCallerDoesNotStartLookup() async {
        var calls = 0
        let store = NetworkLocationStore {
            calls += 1
            throw URLError(.unknown)
        }
        let task = Task { await store.current() }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(calls, 0)
    }
}

@MainActor
private final class LocationLookupGate {
    private let started: [XCTestExpectation]
    private var continuations: [CheckedContinuation<NetworkLocation, Error>] = []
    var calls: Int { continuations.count }

    init(started: [XCTestExpectation]) { self.started = started }

    func lookup() async throws -> NetworkLocation {
        try await withCheckedThrowingContinuation { continuation in
            let index = continuations.count
            continuations.append(continuation)
            if index < started.count { started[index].fulfill() }
        }
    }

    func finish(at index: Int, with location: NetworkLocation) {
        continuations[index].resume(returning: location)
    }
}
