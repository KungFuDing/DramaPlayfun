import XCTest

final class MembershipUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testMembershipFiveDesignStatesAndRechargeSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["-MembershipUITestFixture", "-profile.language.v1", "zh-Hant"]
        app.launch()
        openTab("會員", in: app)
        let weekly = app.buttons["membership-buy-weekly"]
        XCTAssertTrue(weekly.waitForExistence(timeout: 10))
        XCTAssertTrue(weekly.isEnabled)
        capture(app, "周会员-未开通", membershipCategory: "weekly")
        weekly.tap()
        XCTAssertTrue(app.staticTexts["membership-message"].waitForExistence(timeout: 5))
        XCTAssertFalse(weekly.isEnabled)
        capture(app, "周会员-已开通", membershipCategory: "weekly")
        app.buttons["membership-tab-yearly"].tap()
        let yearly = app.buttons["membership-buy-yearly"]
        XCTAssertTrue(yearly.waitForExistence(timeout: 5))
        XCTAssertTrue(yearly.isEnabled)
        capture(app, "年会员-未开通", membershipCategory: "yearly")
        yearly.tap()
        XCTAssertFalse(yearly.isEnabled)
        capture(app, "年会员-已开通", membershipCategory: "yearly")
        app.buttons["membership-tab-coins"].tap()
        let coin = app.buttons["membership-coin-fixture.coins.1"]
        XCTAssertTrue(coin.waitForExistence(timeout: 5))
        coin.tap()
        XCTAssertTrue(coin.isSelected)
        XCTAssertTrue(app.buttons["membership-buy-coins"].label.contains("$8.99"))
        capture(app, "充值")
        app.buttons["membership-buy-coins"].tap()
        XCTAssertEqual(app.staticTexts["membership-message"].label, "儲值成功，金幣已到帳")
    }

    @MainActor
    func testWalletOpensRechargeAndCanDismiss() {
        let app = XCUIApplication()
        app.launchArguments = ["-MembershipUITestFixture", "-profile.language.v1", "zh-Hant"]
        app.launch()
        openTab("我的", in: app)
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
        app.launchArguments = ["-MembershipUITestFixture", "-profile.language.v1", "zh-Hant"]
        app.launch()
        openTab("會員", in: app)
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

    @MainActor private func openTab(_ label: String, in app: XCUIApplication) {
        let tabs = app.buttons.matching(NSPredicate(format: "label == %@", label))
        expectation(for: NSPredicate { _, _ in
            tabs.allElementsBoundByIndex.contains(where: \.isHittable)
        }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        guard let tab = tabs.allElementsBoundByIndex.first(where: \.isHittable) else {
            XCTFail("应能找到当前位置可点击的\(label)入口")
            return
        }
        tab.tap()
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String, membershipCategory: String? = nil) {
        if let membershipCategory {
            let page = app.scrollViews["membership-page-\(membershipCategory)"]
            let hero = page.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "membership-hero-\(membershipCategory)-"
            )).firstMatch
            XCTAssertTrue(hero.waitForExistence(timeout: 5))
            // Buying a plan can scroll its button into view. Restore the card
            // before capturing, allowing its intentional 10-point top overlap.
            for _ in 0..<6 {
                if hero.frame.minY >= page.frame.minY - 12 { break }
                page.swipeDown()
            }
            XCTAssertGreaterThanOrEqual(hero.frame.minY, page.frame.minY - 12)
        }
        // Capture screens directly: an app-window screenshot can be cropped
        // after rotation or target the inactive display on a foldable device.
        for (index, screen) in XCUIScreen.screens.enumerated() {
            let attachment = XCTAttachment(screenshot: screen.screenshot())
            attachment.name = "\(name)-screen-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
