import XCTest

final class AppUpdateUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testOptionalUpdateCanBeDeferredAndDoesNotReturnOnForeground() {
        let app = launch()
        let panel = app.otherElements["app-update-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["新版本已就绪"].exists)
        XCTAssertEqual(app.staticTexts["app-update-version"].label, "新版本 1.1.6")
        XCTAssertTrue(app.buttons["app-update-confirm"].isHittable)
        let later = app.buttons["app-update-later"]
        XCTAssertTrue(later.isHittable)
        capture(app, "版本更新-非强制")

        later.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: panel)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(app.tabBars.buttons["我的"].isHittable)

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 5))
        let reappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: panel)
        reappeared.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [reappeared], timeout: 2), .completed,
                       "稍后更新的同一版本在本次运行回到前台时不应再次打扰")
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.buttons["profile-settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testForcedUpdateCannotBeDismissedAndInvalidURLKeepsItVisible() {
        let app = launch(arguments: ["-AppUpdateForced", "-AppUpdateInvalidURL"])
        let panel = app.otherElements["app-update-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["版本升级提醒"].exists)
        XCTAssertEqual(app.staticTexts["app-update-version"].label, "新版本 1.1.6")
        XCTAssertFalse(app.buttons["app-update-later"].exists)
        let confirm = app.buttons["app-update-confirm"]
        XCTAssertTrue(confirm.isHittable)
        capture(app, "版本更新-强制")

        // Tap the dimmed area above the panel, then attempt to drag it down.
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: app.frame.midX, dy: panel.frame.minY / 2)).tap()
        XCTAssertTrue(panel.exists)
        panel.swipeDown()
        XCTAssertTrue(panel.exists)
        XCTAssertTrue(confirm.isHittable)
        XCTAssertFalse(app.tabBars.buttons["我的"].isHittable)

        confirm.tap()
        XCTAssertTrue(app.staticTexts["更新地址暂不可用，请稍后重试。"].waitForExistence(timeout: 5))
        XCTAssertTrue(panel.exists)
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertFalse(app.buttons["app-update-later"].exists)
        XCTAssertEqual(app.state, .runningForeground, "无效地址不得离开 App 或放行强制更新")
    }

    @MainActor
    func testForcedUpdateAppearsAboveMembershipSheetWhenReturningToForeground() {
        let app = launch(arguments: ["-AppUpdateForced", "-AppUpdateAfterForeground", "-MembershipUITestFixture"])
        let profile = app.tabBars.buttons["我的"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["app-update-panel"].exists)
        profile.tap()
        app.buttons["profile-wallet"].tap()
        let recharge = app.buttons["wallet-recharge"]
        XCTAssertTrue(recharge.waitForExistence(timeout: 5))
        recharge.tap()
        let buyCoins = app.buttons["membership-buy-coins"]
        XCTAssertTrue(buyCoins.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["完成"].isHittable)

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.otherElements["app-update-panel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["版本升级提醒"].exists)
        XCTAssertTrue(app.buttons["app-update-confirm"].isHittable,
                      "强制更新应覆盖已经打开的充值弹窗")
        XCTAssertFalse(app.buttons["app-update-later"].exists)
        XCTAssertFalse(app.buttons["完成"].isHittable)
        XCTAssertFalse(buyCoins.isHittable)
    }

    @MainActor
    func testForcedUpdateAppearsAboveFullScreenPlayback() {
        let app = launch(arguments: ["-AppUpdateForced", "-AppUpdateAfterForeground", "-PlayerUnlockUITestFixture"])
        let banner = app.buttons["推荐剧集，推荐测试"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        banner.tap()
        let back = app.buttons["player-back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(back.isHittable)

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.otherElements["app-update-panel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["app-update-confirm"].isHittable)
        XCTAssertFalse(back.isHittable)
        XCTAssertFalse(app.buttons["app-update-later"].exists)
    }

    @MainActor
    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppUpdateUITestFixture"] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
