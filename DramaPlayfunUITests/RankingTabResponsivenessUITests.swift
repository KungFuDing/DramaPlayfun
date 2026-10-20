import XCTest

final class RankingTabResponsivenessUITests: XCTestCase {
    @MainActor
    func testFirstTapShowsRankingsWhileRequestIsPendingAndAllowsSwitchingAway() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-FeedUITestFixture", "-SlowRankingTabsUITestFixture",
            "-profile.language.v1", "zh-Hant"
        ]
        app.launch()

        // Find tabs by label so this also works with the system's wide-screen tab bar.
        let rankings = app.buttons["排行榜"].firstMatch
        let home = app.buttons["首頁"].firstMatch
        XCTAssertTrue(rankings.waitForExistence(timeout: 10))
        rankings.tap() // A single tap must show the screen before the server responds.
        XCTAssertTrue(app.otherElements["ranking-header"].waitForExistence(timeout: 3))
        XCTAssertTrue(rankings.isSelected)
        XCTAssertFalse(app.staticTexts["榜单测试21"].exists)

        home.tap()
        XCTAssertTrue(home.isSelected, "An in-flight ranking request must not block tab switching.")
        rankings.tap()
        XCTAssertTrue(app.otherElements["ranking-header"].waitForExistence(timeout: 3))
        XCTAssertTrue(rankings.isSelected)
        XCTAssertTrue(app.staticTexts["榜单测试21"].waitForExistence(timeout: 25))

        // The loaded category should remain available on subsequent visits.
        home.tap()
        rankings.tap()
        XCTAssertTrue(rankings.isSelected)
        XCTAssertTrue(app.staticTexts["榜单测试21"].waitForExistence(timeout: 3))
    }
}
