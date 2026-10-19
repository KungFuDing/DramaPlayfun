import XCTest

final class ProfileMembershipAdaptiveUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testProfileCollectionsAndHistoryAdaptAfterRotation() {
        let originalOrientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = originalOrientation }
        XCUIDevice.shared.orientation = .portrait
        let app = launchApp()
        openProfile(in: app)
        assertProfileHeader(in: app)

        let feed = app.scrollViews["profile-feed"]
        reveal(app.buttons["profile-likes"], in: feed, app: app)
        app.buttons["profile-likes"].tap()
        assertProfileCollection(in: app)
        capture("我的-当前窗口")

        XCUIDevice.shared.orientation = .landscapeLeft
        // A Duo display or a resizable iPad window may keep its dimensions.
        // Check the resulting content frames instead of requiring a size change.
        waitForSelected(app.buttons["profile-likes"])
        scrollToTop(feed, anchor: app.buttons["profile-settings"])
        assertProfileHeader(in: app)
        assertProfileCollection(in: app)
        capture("我的-旋转后")

        scrollToTop(feed, anchor: app.buttons["profile-settings"])
        reveal(app.buttons["profile-history"], in: feed, app: app)
        app.buttons["profile-history"].tap()
        assertHistory(in: app)
        capture("观看记录-旋转后")

        XCUIDevice.shared.orientation = .portrait
        assertHistory(in: app)
        assertFitsWindow(app.buttons["profile-history-back"], in: app)
        app.buttons["profile-history-back"].tap()
        waitForSelected(app.buttons["profile-likes"])
        scrollToTop(feed, anchor: app.buttons["profile-settings"])
        assertProfileHeader(in: app)
    }

    @MainActor
    func testMembershipPagingAndCoinSelectionSurviveRotation() {
        let originalOrientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = originalOrientation }
        XCUIDevice.shared.orientation = .portrait
        let app = launchApp()
        openProfile(in: app)
        reveal(app.buttons["profile-membership"], in: app.scrollViews["profile-feed"], app: app)
        app.buttons["profile-membership"].tap()
        assertMembership(category: "weekly", in: app)
        capture("周会员-当前窗口")

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForSelected(app.buttons["membership-tab-weekly"])
        assertMembership(category: "weekly", in: app)
        capture("周会员-旋转后")
        app.scrollViews["membership-page-weekly"].swipeLeft()
        waitForSelected(app.buttons["membership-tab-yearly"])
        assertMembership(category: "yearly", in: app)
        capture("年会员-旋转后")

        app.scrollViews["membership-page-yearly"].swipeLeft()
        waitForSelected(app.buttons["membership-tab-coins"])
        let coins = app.scrollViews["membership-page-coins"]
        let selectedCoin = app.buttons["membership-coin-fixture.coins.1"]
        reveal(selectedCoin, in: coins, app: app)
        selectedCoin.tap()
        assertCoinGrid(in: app)
        capture("充值-旋转后")

        XCUIDevice.shared.orientation = .portrait
        waitForSelected(app.buttons["membership-tab-coins"])
        waitForSelected(selectedCoin)
        assertCoinGrid(in: app)
        let purchase = app.buttons["membership-buy-coins"]
        reveal(purchase, in: coins, app: app)
        XCTAssertTrue(purchase.label.contains("$8.99"), "窗口变化后应保留已选充值档位")
        assertFitsWindow(purchase, in: app)
        capture("充值-回到竖屏")
        purchase.tap()
        let message = app.staticTexts["membership-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(message.label, "儲值成功，金幣已到帳")
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ProfileUITestFixture", "-ProfileHistoryUITestFixture",
                               "-MembershipUITestFixture", "-profile.language.v1", "zh-Hant"]
        app.launch()
        return app
    }

    @MainActor
    private func openProfile(in app: XCUIApplication) {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", "我的"))
        expectation(for: NSPredicate { _, _ in matches.allElementsBoundByIndex.contains(where: \.isHittable) },
                    evaluatedWith: app)
        waitForExpectations(timeout: 10)
        (matches.allElementsBoundByIndex.first(where: \.isHittable) ?? matches.firstMatch).tap()
        XCTAssertTrue(app.scrollViews["profile-feed"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func assertProfileHeader(in app: XCUIApplication) {
        assertFitsWindow(app.buttons["profile-settings"], in: app)
        let card = app.buttons["profile-membership"]
        let feed = app.scrollViews["profile-feed"]
        reveal(card, in: feed, app: app)
        assertFitsWindow(card, in: app)
        XCTAssertLessThanOrEqual(card.frame.width, 441, "会员卡插画应保持适合阅读的尺寸")
        XCTAssertLessThanOrEqual(card.frame.height, 187)
    }

    @MainActor
    private func assertProfileCollection(in app: XCUIApplication) {
        let feed = app.scrollViews["profile-feed"]
        reveal(app.buttons["profile-drama-101"], in: feed, app: app, fullyVisible: false)
        let grid = app.otherElements["profile-collection-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        let cards = (101...104).map { app.buttons["profile-drama-\($0)"] }
        assertGrid(cards, within: grid.frame, minimumColumns: grid.frame.width >= 700 ? 3 : 2)
        waitForSelected(app.buttons["profile-likes"])
    }

    @MainActor
    private func assertHistory(in app: XCUIApplication) {
        let grid = app.scrollViews["profile-history-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["profile-history-111"].waitForExistence(timeout: 5))
        let cards = (111...116).map { app.buttons["profile-history-\($0)"] }
        assertGrid(cards, within: grid.frame, minimumColumns: grid.frame.width >= 850 ? 4 : 3)
        XCTAssertFalse(app.buttons["profile-history-116"].isEnabled)
    }

    @MainActor
    private func assertMembership(category: String, in app: XCUIApplication) {
        for value in ["weekly", "yearly", "coins"] {
            assertFitsWindow(app.buttons["membership-tab-\(value)"], in: app)
        }
        let page = app.scrollViews["membership-page-\(category)"]
        let hero = page.descendants(matching: .any)["membership-hero-\(category)-inactive"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        scrollToTop(page, anchor: hero, topOverlap: 12)
        assertHorizontalBounds(hero.frame, within: page.frame)
        XCTAssertLessThanOrEqual(hero.frame.width, 441, "会员插画不应随平板窗口无限放大")
        XCTAssertLessThanOrEqual(hero.frame.height, 187)
        XCTAssertGreaterThan(hero.frame.intersection(page.frame).height, 0)
        let purchase = app.buttons["membership-buy-\(category)"]
        reveal(purchase, in: page, app: app)
        assertFitsWindow(purchase, in: app)
    }

    @MainActor
    private func assertCoinGrid(in app: XCUIApplication) {
        let grid = app.otherElements["membership-coin-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        let cards = (0..<6).map { app.buttons["membership-coin-fixture.coins.\($0)"] }
        assertGrid(cards, within: grid.frame, minimumColumns: grid.frame.width >= 700 ? 4 : 3)
        waitForSelected(app.buttons["membership-coin-fixture.coins.1"])
    }

    @MainActor
    private func assertGrid(_ cards: [XCUIElement], within bounds: CGRect, minimumColumns: Int) {
        let frames = cards.filter { $0.exists && $0.frame.width > 0 }.map(\.frame)
        XCTAssertGreaterThanOrEqual(frames.count, minimumColumns)
        guard let first = frames.first else { return }
        for frame in frames {
            XCTAssertEqual(frame.width, first.width, accuracy: 1)
            assertHorizontalBounds(frame, within: bounds)
        }
        let columns = Set(frames.map { Int($0.minX.rounded()) })
        XCTAssertGreaterThanOrEqual(columns.count, minimumColumns, "宽窗口应利用额外空间增加内容列数")
    }

    @MainActor
    private func assertHorizontalBounds(_ frame: CGRect, within bounds: CGRect) {
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX - 1)
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + 1)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in scroll: XCUIElement, app: XCUIApplication,
                        fullyVisible: Bool = true) {
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        for _ in 0..<10 {
            let visible = scroll.frame.intersection(app.windows.firstMatch.frame)
            if element.exists, element.isHittable,
               !fullyVisible || visible.insetBy(dx: -1, dy: -1).contains(element.frame) { return }
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        }
        XCTAssertTrue(element.isHittable, "\(element.identifier) 应能滚动到可操作位置")
    }

    @MainActor
    private func scrollToTop(_ scroll: XCUIElement, anchor: XCUIElement, topOverlap: CGFloat = 0) {
        for _ in 0..<10 {
            if anchor.exists, anchor.frame.minY >= scroll.frame.minY - topOverlap - 1 { return }
            scroll.swipeDown()
        }
        XCTAssertGreaterThanOrEqual(anchor.frame.minY, scroll.frame.minY - topOverlap - 1)
    }

    @MainActor
    private func assertFitsWindow(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "hittable == true AND enabled == true"), evaluatedWith: element)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1).contains(element.frame),
                      "\(element.identifier) 应完整位于当前窗口内")
    }

    @MainActor
    private func waitForSelected(_ element: XCUIElement) {
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func capture(_ name: String) {
        for (index, screen) in XCUIScreen.screens.enumerated() {
            let attachment = XCTAttachment(screenshot: screen.screenshot())
            attachment.name = "\(name)-screen-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
