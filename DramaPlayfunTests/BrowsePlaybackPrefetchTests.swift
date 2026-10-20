import XCTest
@testable import DramaPlayfun

@MainActor
final class BrowsePlaybackPrefetchTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)

    func testSelectsClosestThreeDistinctDramasInViewport() {
        let candidates = [
            candidate("edge", x: 10, y: 40),
            candidate("center", x: 150, y: 350),
            candidate("nearby", x: 150, y: 470),
            candidate("third", x: 150, y: 190),
            candidate("center", x: 10, y: 650),
            candidate("below", x: 150, y: 900)
        ]
        XCTAssertEqual(BrowsePlaybackPrefetch.selectedDramaIDs(from: candidates, viewport: viewport),
                       ["center", "nearby", "third"])
    }

    func testRejectsMostlyClippedHorizontalCardAndCoveredHeader() {
        let shelfClip = CGRect(x: 20, y: 200, width: 360, height: 150)
        let candidates = [
            candidate("visible", x: 30, y: 210, clips: [shelfClip]),
            candidate("partial", x: 340, y: 210, clips: [shelfClip]),
            candidate("outside", x: 390, y: 210, clips: [shelfClip]),
            candidate("covered", x: 150, y: 0)
        ]
        let unobscuredViewport = CGRect(x: 0, y: 80, width: 400, height: 720)
        XCTAssertEqual(BrowsePlaybackPrefetch.selectedDramaIDs(from: candidates, viewport: unobscuredViewport),
                       ["visible"])
    }

    func testIntersectingNestedClipsCannotExposeAnAdjacentPage() {
        let candidates = [
            candidate("active", x: 120, y: 300, clips: [viewport, CGRect(x: 20, y: 250, width: 360, height: 200)]),
            candidate("adjacent", x: 120, y: 300, clips: [viewport, CGRect(x: 410, y: 250, width: 360, height: 200)]),
            candidate("missing-clip", x: 120, y: 300, clips: [.zero])
        ]
        XCTAssertEqual(BrowsePlaybackPrefetch.selectedDramaIDs(from: candidates, viewport: viewport), ["active"])
    }

    func testCancellationDuringDwellStartsNoRequests() async {
        var requested: [String] = []
        let task = Task {
            await BrowsePlaybackPrefetch.afterDwell(dramaIDs: ["a", "b"]) { requested.append($0) }
        }
        await Task.yield()
        task.cancel()
        await task.value
        XCTAssertTrue(requested.isEmpty)
    }

    func testCancellationDuringRequestDropsRemainingBatch() async {
        var requested: [String] = []
        var releaseFirstRequest: CheckedContinuation<Void, Never>?
        let firstStarted = expectation(description: "First request began")
        let task = Task {
            await BrowsePlaybackPrefetch.afterDwell(dramaIDs: ["a", "b", "c"], delay: .zero) { id in
                requested.append(id)
                await withCheckedContinuation { continuation in
                    releaseFirstRequest = continuation
                    firstStarted.fulfill()
                }
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)
        task.cancel()
        releaseFirstRequest?.resume()
        await task.value
        XCTAssertEqual(requested, ["a"])
    }

    func testBatchStartsRequestsSequentially() async {
        var requested: [String] = []
        var firstFinished = false
        await BrowsePlaybackPrefetch.afterDwell(dramaIDs: ["a", "b"], delay: .zero) { id in
            if id == "b" { XCTAssertTrue(firstFinished) }
            requested.append(id)
            await Task.yield()
            if id == "a" { firstFinished = true }
        }
        XCTAssertEqual(requested, ["a", "b"])
    }

    private func candidate(_ id: String, x: CGFloat, y: CGFloat, clips: [CGRect] = []) -> BrowsePlaybackCandidate {
        BrowsePlaybackCandidate(dramaID: id, frame: CGRect(x: x, y: y, width: 100, height: 100), clipFrames: clips)
    }
}
