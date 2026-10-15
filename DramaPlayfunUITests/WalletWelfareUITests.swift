import XCTest

final class WalletWelfareUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testTheaterPopupClaimDisappearsAndUpdatesWelfare() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-WelfareUITestFixture", "-profile.language.v1", "zh-Hant"]
        app.launch()
        app.tabBars.buttons["劇場"].tap()
        let receive = app.buttons["theater-check-in-receive"]
        XCTAssertTrue(receive.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["+30金幣"].exists)
        receive.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: receive)
        waitForExpectations(timeout: 5)
        app.tabBars.buttons["我的"].tap()
        app.buttons["profile-welfare"].tap()
        XCTAssertTrue(app.staticTexts["20030"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["welfare-sign"].isEnabled)
        app.buttons["welfare-back"].tap()
        app.tabBars.buttons["劇場"].tap()
        XCTAssertTrue(app.buttons["更多劇集，剧场测试甲"].waitForExistence(timeout: 5))
        XCTAssertFalse(receive.exists)
    }

    @MainActor
    func testTheaterPopupIsHiddenForAnAlreadySignedAccount() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-WelfareUITestFixture", "-WelfareSignedUITestFixture", "-profile.language.v1", "zh-Hant"]
        app.launch()
        app.tabBars.buttons["劇場"].tap()
        XCTAssertTrue(app.buttons["更多劇集，剧场测试甲"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["theater-check-in-receive"].exists)
    }

    @MainActor
    func testWalletTabsAutoPlayAndWelfareSignIn() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-WelfareUITestFixture", "-profile.language.v1", "zh-Hant"]
        app.launch()
        app.tabBars.buttons["我的"].tap()
        app.buttons["profile-wallet"].tap()
        XCTAssertTrue(app.staticTexts["wallet-balance"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["wallet-balance"].label, "20000")
        XCTAssertTrue(app.staticTexts["98$"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "钱包-充值")
        app.buttons["wallet-tab-income"].tap()
        XCTAssertTrue(app.staticTexts["+100金幣"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "钱包-获取")
        app.buttons["wallet-tab-expense"].tap()
        XCTAssertTrue(app.staticTexts["−20金幣"].firstMatch.waitForExistence(timeout: 5))
        let toggle = app.descendants(matching: .any)["wallet-autoplay"].firstMatch
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        capture(app, "钱包-消耗-关闭自动播放")
        app.buttons["wallet-back"].tap()
        app.buttons["profile-welfare"].tap()
        let sign = app.buttons["welfare-sign"]
        XCTAssertTrue(sign.waitForExistence(timeout: 5))
        XCTAssertTrue(sign.isEnabled)
        XCTAssertFalse(app.buttons["welfare-task-share_video"].isEnabled)
        capture(app, "福利-待签到")
        sign.tap()
        XCTAssertTrue(app.staticTexts["20030"].waitForExistence(timeout: 5))
        XCTAssertFalse(sign.isEnabled)
        capture(app, "福利-已签到")
        app.buttons["welfare-wallet"].tap()
        XCTAssertTrue(app.staticTexts["wallet-balance"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["wallet-balance"].label, "20030")
        XCTAssertEqual(app.descendants(matching: .any)["wallet-autoplay"].firstMatch.value as? String, "0")
    }

    @MainActor
    func testCompletedWeekAndTaskNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-WelfareUITestFixture", "-WelfareSignedUITestFixture", "-profile.language.v1", "zh-Hant"]
        app.launch()
        app.tabBars.buttons["我的"].tap()
        app.buttons["profile-welfare"].tap()
        XCTAssertTrue(app.buttons["welfare-sign"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["welfare-sign"].isEnabled)
        capture(app, "福利-连续签到7天")
        app.swipeUp()
        app.buttons["welfare-task-watch_drama"].tap()
        app.alerts.buttons["去完成"].tap()
        XCTAssertTrue(app.tabBars.buttons["劇場"].isSelected)
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
