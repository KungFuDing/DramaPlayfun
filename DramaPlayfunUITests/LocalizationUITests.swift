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
        assertLanguagePanelClosed(app, settingsTitle: "Settings")
        XCTAssertTrue(app.buttons["settings-清理缓存"].label.contains("Clear Cache"))

        // Selecting the current language must also dismiss the panel.
        app.buttons["settings-语言切换"].tap()
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        XCTAssertTrue(english.isSelected)
        english.tap()
        assertLanguagePanelClosed(app, settingsTitle: "Settings")

        app.buttons["settings-语言切换"].tap()
        XCTAssertTrue(chinese.waitForExistence(timeout: 5))
        chinese.tap()
        assertLanguagePanelClosed(app, settingsTitle: "設定")
        XCTAssertTrue(app.buttons["settings-清理缓存"].label.contains("清除快取"))
        app.buttons["settings-back"].tap()
        XCTAssertTrue(app.tabBars.buttons["首頁"].exists)
        XCTAssertTrue(app.tabBars.buttons["劇場"].exists)
        XCTAssertTrue(app.tabBars.buttons["會員"].exists)
        XCTAssertTrue(app.tabBars.buttons["我的"].isSelected)

        app.terminate()
        app.launch()
        openSettings(app)
        XCTAssertTrue(app.staticTexts["設定"].exists)
        app.buttons["settings-语言切换"].tap()
        XCTAssertTrue(chinese.waitForExistence(timeout: 5))
        XCTAssertTrue(chinese.isSelected)

        english.tap()
        assertLanguagePanelClosed(app, settingsTitle: "Settings")
        app.buttons["settings-back"].tap()
        XCTAssertTrue(app.tabBars.buttons["Home"].exists)
        XCTAssertTrue(app.tabBars.buttons["Theater"].exists)
        XCTAssertTrue(app.tabBars.buttons["VIP"].exists)
        XCTAssertTrue(app.tabBars.buttons["Profile"].isSelected)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "English Profile"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testLanguageSwitchReloadsPreviouslyLoadedHomeCategoriesAndTheater() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ProfileUITestFixture", "-LocalizationUITestFixture"]
        app.launch()

        // Set the initial language through the UI so no launch-argument override can mask persistence.
        openSettings(app)
        selectLanguage("en", in: app, settingsTitle: "Settings")
        app.buttons["settings-back"].tap()

        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["Featured series, English Home Story"].waitForExistence(timeout: 10))
        openCategory("English Category", in: app)
        let categoryStory = app.buttons["home-drama-item-11"]
        assertLabel("English Category Story", on: categoryStory)

        app.tabBars.buttons["Theater"].tap()
        let theaterStory = app.buttons["drama-detail-title-101"]
        assertLabel("English Theater Story", on: theaterStory)

        openSettings(app)
        selectLanguage("zh-Hant", in: app, settingsTitle: "設定")
        XCTAssertTrue(app.buttons["settings-清理缓存"].label.contains("清除快取"))
        app.buttons["settings-back"].tap()
        XCTAssertTrue(app.tabBars.buttons["我的"].isSelected)

        // Revisit stores that had already loaded: both the request header and cached data must change.
        app.tabBars.buttons["首頁"].tap()
        XCTAssertTrue(app.buttons["推薦劇集，繁體首頁故事"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["English Home Story"].exists)
        openCategory("繁體分類", in: app)
        XCTAssertFalse(app.buttons["English Category"].exists)
        assertLabel("繁體分類故事", on: categoryStory)
        XCTAssertFalse(app.staticTexts["English Category Story"].exists)

        app.tabBars.buttons["劇場"].tap()
        assertLabel("繁體劇場故事", on: theaterStory)
        XCTAssertFalse(app.staticTexts["English Theater Story"].exists)
        XCTAssertEqual(app.buttons["theater-like-101"].label, "按讚")
    }

    @MainActor
    func testContinueWatchingProgressSurvivesLanguageChangesWithDifferentDramaIDs() {
        let app = XCUIApplication()
        app.launchArguments = ["-ProfileUITestFixture", "-LocalizationUITestFixture", "-HistoryProgressUITestFixture"]
        app.launch()

        // Only the Traditional Chinese drama has local progress. Both localized
        // drama IDs refer to the same episode and must share its known duration.
        for (language, settingsTitle, homeTitle, dramaID, watchedText) in [
            ("en", "Settings", "Home", "9101", "Episode 1 · Watched 0:28"),
            ("zh-Hant", "設定", "首頁", "9102", "第1集 · 已觀看 0:28"),
            ("en", "Settings", "Home", "9101", "Episode 1 · Watched 0:28")
        ] {
            openSettings(app)
            selectLanguage(language, in: app, settingsTitle: settingsTitle)
            app.buttons["settings-back"].tap()
            app.tabBars.buttons[homeTitle].tap()

            let card = app.buttons["history-\(dramaID)"]
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts[watchedText].exists)
            let progress = app.progressIndicators["history-progress-\(dramaID)"]
            XCTAssertTrue(progress.waitForExistence(timeout: 10), "Continue Watching must show progress in \(language)")
            XCTAssertGreaterThan(progress.frame.width, 0)
            XCTAssertGreaterThan(progress.frame.height, 0)
            XCTAssertTrue(card.frame.contains(progress.frame), "The progress bar must fit inside the history card")

            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Continue Watching progress — \(language)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    @MainActor private func selectLanguage(_ identifier: String, in app: XCUIApplication, settingsTitle: String) {
        app.buttons["settings-语言切换"].tap()
        let language = app.buttons["settings-language-\(identifier)"]
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        language.tap()
        assertLanguagePanelClosed(app, settingsTitle: settingsTitle)
    }

    @MainActor private func assertLanguagePanelClosed(_ app: XCUIApplication, settingsTitle: String) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["settings-panel-close"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["settings-language-en"].exists)
        XCTAssertFalse(app.buttons["settings-language-zh-Hant"].exists)
        XCTAssertTrue(app.staticTexts[settingsTitle].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings-back"].isHittable, "Language changes must preserve the open Settings page")
    }

    @MainActor private func openCategory(_ title: String, in app: XCUIApplication) {
        let category = app.buttons[title].firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 10))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        for _ in 0..<4 where !category.isHittable {
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(category.isHittable)
        category.tap()
    }

    @MainActor private func assertLabel(_ text: String, on element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: element)
        waitForExpectations(timeout: 10)
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
