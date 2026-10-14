import XCTest

final class MembershipUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testMembershipFiveDesignStatesAndRechargeSelection() {
        let app = XCUIApplication()
        app.launchArguments.append("-MembershipUITestFixture")
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["会员"].waitForExistence(timeout: 10))
        app.tabBars.buttons["会员"].tap()
        let weekly = app.buttons["membership-buy-weekly"]
        XCTAssertTrue(weekly.waitForExistence(timeout: 10))
        XCTAssertTrue(weekly.isEnabled)
        capture(app, "周会员-未开通")
        weekly.tap()
        XCTAssertTrue(app.staticTexts["membership-message"].waitForExistence(timeout: 5))
        XCTAssertFalse(weekly.isEnabled)
        capture(app, "周会员-已开通")
        app.buttons["membership-tab-yearly"].tap()
        let yearly = app.buttons["membership-buy-yearly"]
        XCTAssertTrue(yearly.waitForExistence(timeout: 5))
        XCTAssertTrue(yearly.isEnabled)
        capture(app, "年会员-未开通")
        yearly.tap()
        XCTAssertFalse(yearly.isEnabled)
        capture(app, "年会员-已开通")
        app.buttons["membership-tab-coins"].tap()
        let coin = app.buttons["membership-coin-fixture.coins.1"]
        XCTAssertTrue(coin.waitForExistence(timeout: 5))
        coin.tap()
        XCTAssertTrue(coin.isSelected)
        XCTAssertTrue(app.buttons["membership-buy-coins"].label.contains("$8.99"))
        capture(app, "充值")
        app.buttons["membership-buy-coins"].tap()
        XCTAssertEqual(app.staticTexts["membership-message"].label, "充值成功，金币已到账")
    }

    @MainActor
    func testWalletOpensRechargeAndCanDismiss() {
        let app = XCUIApplication()
        app.launchArguments.append("-MembershipUITestFixture")
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 10))
        app.tabBars.buttons["我的"].tap()
        app.buttons["profile-wallet"].tap()
        let recharge = app.buttons["wallet-recharge"]
        XCTAssertTrue(recharge.waitForExistence(timeout: 5))
        recharge.tap()
        XCTAssertTrue(app.buttons["membership-buy-coins"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["membership-tab-coins"].isSelected)
        app.buttons["完成"].tap()
        XCTAssertTrue(recharge.waitForExistence(timeout: 5))
    }

    @MainActor
    func testHorizontalPagingKeepsTabsAndCoinSelectionInSync() {
        let app = XCUIApplication()
        app.launchArguments.append("-MembershipUITestFixture")
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["会员"].waitForExistence(timeout: 10))
        app.tabBars.buttons["会员"].tap()
        let weekly = app.scrollViews["membership-page-weekly"]
        let yearly = app.scrollViews["membership-page-yearly"]
        let coins = app.scrollViews["membership-page-coins"]
        XCTAssertTrue(weekly.waitForExistence(timeout: 5))
        weekly.swipeLeft()
        XCTAssertTrue(app.buttons["membership-tab-yearly"].isSelected)
        XCTAssertTrue(app.buttons["membership-buy-yearly"].isHittable)
        yearly.swipeLeft()
        XCTAssertTrue(app.buttons["membership-tab-coins"].isSelected)
        let coin = app.buttons["membership-coin-fixture.coins.1"]
        coin.tap()
        coins.swipeUp()
        XCTAssertTrue(app.buttons["membership-tab-coins"].isSelected)
        coins.swipeDown()
        coins.swipeLeft()
        XCTAssertTrue(app.buttons["membership-tab-coins"].isSelected)
        coins.swipeRight()
        XCTAssertTrue(app.buttons["membership-tab-yearly"].isSelected)
        yearly.swipeRight()
        XCTAssertTrue(app.buttons["membership-tab-weekly"].isSelected)
        weekly.swipeRight()
        XCTAssertTrue(app.buttons["membership-tab-weekly"].isSelected)
        app.buttons["membership-tab-coins"].tap()
        XCTAssertTrue(coin.isSelected)
        XCTAssertTrue(app.buttons["membership-buy-coins"].label.contains("$8.99"))
        coins.swipeRight()
        XCTAssertTrue(app.buttons["membership-tab-yearly"].isSelected)
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
