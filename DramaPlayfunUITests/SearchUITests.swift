import XCTest

final class SearchUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSearchHistorySuggestionsResultsAndPlayback() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-SearchUITestFixture")
        app.launch()
        XCTAssertTrue(app.buttons["home-search"].waitForExistence(timeout: 10))
        app.buttons["home-search"].tap()
        let field = app.textFields["search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["重生之我和白月光"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        let first = app.buttons["search-hot-31"]
        let second = app.buttons["search-hot-32"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(second.frame.minX - first.frame.maxX, 15, accuracy: 1)
        XCTAssertGreaterThan(second.frame.height, first.frame.height)
        capture(app, name: "搜索页")

        field.tap()
        field.typeText("我以异能斩规则")
        XCTAssertTrue(app.otherElements["search-suggestions"].waitForExistence(timeout: 5))
        app.buttons["search-submit"].tap()
        XCTAssertTrue(app.otherElements["search-results"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["search-result-801"].isHittable)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        capture(app, name: "搜索结果页")

        app.buttons["search-result-801"].tap()
        XCTAssertTrue(app.buttons["player-back"].waitForExistence(timeout: 5))
        app.buttons["player-back"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.buttons["search-back"].tap()
        XCTAssertTrue(app.buttons["home-search"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testRecentSearchCanSearchAgainAndClear() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-SearchUITestFixture")
        app.launch()
        XCTAssertTrue(app.buttons["home-search"].waitForExistence(timeout: 10))
        app.buttons["home-search"].tap()
        let recent = app.buttons["重生之我和白月光"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.tap()
        XCTAssertTrue(app.otherElements["search-results"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["search-input"].value as? String, "重生之我和白月光")
        app.buttons["search-back"].tap()
        app.buttons["home-search"].tap()
        let clear = app.buttons["search-clear-history"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(app.staticTexts["search-history-empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(clear.isEnabled)
        capture(app, name: "清空搜索历史")
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
