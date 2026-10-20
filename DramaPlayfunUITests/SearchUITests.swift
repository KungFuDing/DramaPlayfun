import XCTest

final class SearchUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSearchHistorySuggestionsResultsAndPlayback() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-SearchUITestFixture", "-PlaybackProgressUITestFixture"]
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
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
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertEqual(first.frame.width, second.frame.width, accuracy: 1)
        XCTAssertEqual(second.frame.minX - first.frame.maxX, 15, accuracy: 1)
        XCTAssertGreaterThanOrEqual(second.frame.height, first.frame.height,
            "长标题可按当前列宽换行，不能改变卡片宽度")
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
        let feed = app.scrollViews["player-episode-feed"]
        expectation(for: NSPredicate(format: "value == %@", "第3集"), evaluatedWith: feed)
        waitForExpectations(timeout: 5)
        let progress = app.sliders["player-progress-3"]
        expectation(for: NSPredicate { _, _ in
            let percent = Double((progress.value as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? -1
            return progress.isEnabled && percent >= 28 && percent < 50
        }, evaluatedWith: progress)
        waitForExpectations(timeout: 5)
        app.buttons["player-back"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.buttons["search-back"].tap()
        XCTAssertTrue(app.buttons["home-search"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testRecentSearchCanSearchAgainAndClear() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-SearchUITestFixture")
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
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
