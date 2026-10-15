import XCTest

final class ProfileUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testProfileSettingsPanelsAndLanguagePersistence() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ProfileUITestFixture"]
        app.launch()
        openProfile(in: app)
        let settings = app.buttons["profile-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["profile-membership"].exists)
        capture(app, "我的-未开通会员")
        app.buttons["profile-likes"].tap()
        XCTAssertTrue(app.buttons["profile-likes"].isSelected)
        settings.tap()
        XCTAssertTrue(app.buttons["settings-语言切换"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        capture(app, "设置")
        app.buttons["settings-语言切换"].tap()
        let english = app.buttons["settings-language-en"]
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        app.buttons["settings-language-zh-Hant"].tap()
        XCTAssertTrue(app.buttons["settings-language-zh-Hant"].isSelected)
        capture(app, "语言切换")
        english.tap()
        XCTAssertTrue(english.isSelected)
        app.buttons["settings-panel-close"].tap()
        app.buttons["settings-语言切换"].tap()
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        XCTAssertTrue(english.isSelected)
        app.buttons["settings-panel-close"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].exists)
        app.terminate()
        app.launch()
        openProfile(in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        app.buttons["settings-语言切换"].tap()
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        XCTAssertTrue(english.isSelected)
        app.buttons["settings-panel-close"].tap()
        app.buttons["settings-联系客服"].tap()
        XCTAssertTrue(app.staticTexts["Email: contact@idoltimeltd.co.uk"].waitForExistence(timeout: 5))
        capture(app, "联系客服")
        app.buttons["settings-contact-close"].tap()
        app.buttons["settings-注销账号"].tap()
        XCTAssertTrue(app.buttons["settings-deactivate-cancel"].waitForExistence(timeout: 5))
        capture(app, "账号注销")
        app.buttons["settings-deactivate-cancel"].tap()
        XCTAssertTrue(app.buttons["settings-注销账号"].isHittable)
        app.buttons["settings-back"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
    }

    @MainActor
    func testActiveMembershipCard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ProfileUITestFixture", "-ProfileVIPUITestFixture", "-profile.language.v1", "zh-Hant"]
        app.launch()
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.staticTexts["已開通，可享所有權益"].waitForExistence(timeout: 10))
        capture(app, "我的-已开通会员")
    }

    @MainActor private func openProfile(in app: XCUIApplication) {
        let profile = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Profile", "我的"])).firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        profile.tap()
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
