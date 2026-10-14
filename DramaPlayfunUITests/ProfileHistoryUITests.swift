import XCTest

final class ProfileHistoryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testThreeColumnHistoryAndResumePlayback() {
        let app = XCUIApplication()
        app.launchArguments = ["-ProfileUITestFixture", "-ProfileHistoryUITestFixture"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 10))
        app.tabBars.buttons["我的"].tap()
        app.buttons["profile-history"].tap()
        let first = app.buttons["profile-history-111"]
        let second = app.buttons["profile-history-112"]
        let third = app.buttons["profile-history-113"]
        let fourth = app.buttons["profile-history-114"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.frame.minX, 12, accuracy: 1)
        XCTAssertEqual(second.frame.minX - first.frame.maxX, 10, accuracy: 1)
        XCTAssertEqual(third.frame.minX - second.frame.maxX, 10, accuracy: 1)
        XCTAssertEqual(first.frame.minY, third.frame.minY, accuracy: 1)
        XCTAssertEqual(fourth.frame.minX, first.frame.minX, accuracy: 1)
        XCTAssertGreaterThan(fourth.frame.minY, first.frame.maxY)
        XCTAssertTrue(app.staticTexts["3集/134集"].exists)
        XCTAssertFalse(app.buttons["profile-history-116"].isEnabled)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "我的-历史记录-三列"
        attachment.lifetime = .keepAlways
        add(attachment)
        first.tap()
        let player = app.scrollViews["player-episode-feed"]
        XCTAssertTrue(player.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == %@", "第3集"), evaluatedWith: player)
        waitForExpectations(timeout: 5)
        app.buttons["player-back"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        app.buttons["profile-history-back"].tap()
        XCTAssertTrue(app.buttons["profile-history"].waitForExistence(timeout: 5))
    }
}
