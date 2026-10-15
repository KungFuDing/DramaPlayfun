import XCTest

final class LocalizationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testLanguageSwitchUpdatesOpenSettingsTabsAndPersistsAfterRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ProfileUITestFixture"]
        app.launch()
        openSettings(app)
        app.buttons["settings-语言切换"].tap()
        let english = app.buttons["settings-language-en"]
        let chinese = app.buttons["settings-language-zh-Hant"]
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        XCTAssertTrue(chinese.exists)
        XCTAssertFalse(app.buttons["settings-language-ja"].exists)
        XCTAssertFalse(app.buttons["settings-language-zh"].exists)

        english.tap()
        XCTAssertTrue(english.isSelected)
        XCTAssertTrue(app.staticTexts["Language"].exists)
        app.buttons["settings-panel-close"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].exists)
        XCTAssertTrue(app.buttons["settings-清理缓存"].label.contains("Clear Cache"))

        app.buttons["settings-语言切换"].tap()
        chinese.tap()
        XCTAssertTrue(chinese.isSelected)
        XCTAssertTrue(app.staticTexts["語言切換"].exists)
        app.buttons["settings-panel-close"].tap()
        XCTAssertTrue(app.staticTexts["設定"].exists)
        app.buttons["settings-back"].tap()
        XCTAssertTrue(app.tabBars.buttons["首頁"].exists)
        XCTAssertTrue(app.tabBars.buttons["劇場"].exists)
        XCTAssertTrue(app.tabBars.buttons["會員"].exists)

        app.terminate()
        app.launch()
        openSettings(app)
        XCTAssertTrue(app.staticTexts["設定"].exists)
        app.buttons["settings-语言切换"].tap()
        XCTAssertTrue(chinese.waitForExistence(timeout: 5))
        XCTAssertTrue(chinese.isSelected)

        english.tap()
        app.buttons["settings-panel-close"].tap()
        app.buttons["settings-back"].tap()
        XCTAssertTrue(app.tabBars.buttons["Home"].exists)
        XCTAssertTrue(app.tabBars.buttons["Theater"].exists)
        XCTAssertTrue(app.tabBars.buttons["VIP"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "English Profile"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor private func openSettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        let profile = app.tabBars.buttons["Profile"]
        (profile.exists ? profile : app.tabBars.buttons["我的"]).tap()
        let settings = app.buttons["profile-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.buttons["settings-语言切换"].waitForExistence(timeout: 5))
    }
}
