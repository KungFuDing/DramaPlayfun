import XCTest

final class HomeSearchAdaptiveUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHomeAndSearchAtCurrentWindowSize() {
        let app = launchApp()
        exerciseHome(in: app, screenshotPrefix: "当前窗口")
        exerciseSearch(in: app, screenshotPrefix: "当前窗口")
    }

    @MainActor
    func testHomeAndSearchRemainUsableAfterRotation() {
        let originalOrientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = originalOrientation }

        XCUIDevice.shared.orientation = .portrait
        let app = launchApp()
        XCUIDevice.shared.orientation = .landscapeLeft
        // Duo displays and resizable iPad windows can retain their dimensions
        // after rotation. Assertions use the resulting window and feed frames.
        waitForHittable(app.buttons["home-search"])
        exerciseHome(in: app, screenshotPrefix: "横屏")
        exerciseSearch(in: app, screenshotPrefix: "横屏")

        XCUIDevice.shared.orientation = .portrait
        waitForHittable(app.buttons["home-search"])
        scrollHomeToTop(in: app)
        assertHomeHeaderAndBanner(in: app)
        capture(app, "回到竖屏-首页")
        openSearch(in: app)
        assertSearchControls(in: app)
        scrollToHotCards(in: app, feedIdentifier: "search-feed", cardPrefix: "search-hot-")
        assertHotGrid(in: app, feedIdentifier: "search-feed", cardPrefix: "search-hot-", gap: 15)
        capture(app, "回到竖屏-搜索热播")
        app.buttons["search-back"].tap()
        waitForHittable(app.buttons["home-search"])
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-SearchUITestFixture", "-BrowseAdaptiveUITestFixture",
            "-profile.language.v1", "zh-Hant"
        ]
        app.launch()
        waitForHittable(app.buttons["home-search"])
        return app
    }

    @MainActor
    private func exerciseHome(in app: XCUIApplication, screenshotPrefix: String) {
        assertHomeHeaderAndBanner(in: app)
        capture(app, "\(screenshotPrefix)-首页顶部")

        app.buttons["home-welfare"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForHittable(app.buttons["welfare-back"])
        app.buttons["welfare-back"].tap()
        waitForHittable(app.buttons["home-search"])

        scrollToHotCards(in: app, feedIdentifier: "home-feed", cardPrefix: "home-drama-item-")
        assertHotGrid(in: app, feedIdentifier: "home-feed", cardPrefix: "home-drama-item-", gap: 14)
        assertFitsWindow(app.buttons["home-search"], in: app)
        assertFitsWindow(app.buttons["home-welfare"], in: app)
        capture(app, "\(screenshotPrefix)-首页热播")

        let header = app.otherElements["home-top-controls"]
        let liveCategory = header.buttons["真人剧"].firstMatch
        waitForHittable(liveCategory)
        assertFitsWindow(liveCategory, in: app)
        liveCategory.tap()
        let pages = app.scrollViews["home-category-pages"]
        waitForValue("真人剧", on: pages)

        let visiblePage = pages.frame.intersection(app.windows.firstMatch.frame)
        let contentTop = max(visiblePage.minY, header.frame.maxY)
        XCTAssertGreaterThan(visiblePage.maxY - contentTop, 50)
        let swipeY = ((contentTop + visiblePage.maxY) / 2 - pages.frame.minY) / pages.frame.height
        pages.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: swipeY))
            .press(forDuration: 0.05, thenDragTo: pages.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: swipeY)))
        waitForValue("剧情", on: pages)
        let plot = visibleButton("剧情", in: app)
        XCTAssertTrue(plot.isSelected, "滑动分类页面后，分类按钮应同步选中")
        capture(app, "\(screenshotPrefix)-首页分类联动")
        visibleButton("精選", in: app).tap()
        waitForValue("精選", on: pages)
    }

    @MainActor
    private func exerciseSearch(in app: XCUIApplication, screenshotPrefix: String) {
        openSearch(in: app)
        assertSearchControls(in: app)
        let recent = app.buttons["重生之我和白月光"]
        assertFitsWindow(recent, in: app)
        capture(app, "\(screenshotPrefix)-搜索历史")
        recent.tap()
        waitForHittable(app.buttons["search-result-801"])
        XCTAssertEqual(app.textFields["search-input"].value as? String, "重生之我和白月光")
        app.buttons["search-back"].tap()

        openSearch(in: app)
        let input = app.textFields["search-input"]
        input.tap()
        input.typeText("Adaptive layout")
        XCTAssertTrue(app.otherElements["search-suggestions"].waitForExistence(timeout: 5))
        assertFitsWindow(app.buttons["search-submit"], in: app)
        app.buttons["search-submit"].tap()
        let results = app.otherElements["search-results"]
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let first = app.buttons["search-result-801"]
        let second = app.buttons["search-result-802"]
        assertFitsWindow(first, in: app)
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertEqual(first.frame.width, second.frame.width, accuracy: 1)
        if results.frame.width >= 700 {
            XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 1)
            XCTAssertGreaterThan(second.frame.minX, first.frame.maxX,
                "宽窗口中的搜索结果应并排展示")
            assertFitsWindow(second, in: app)
        } else {
            XCTAssertEqual(first.frame.minX, second.frame.minX, accuracy: 1)
            XCTAssertGreaterThan(second.frame.minY, first.frame.maxY,
                "窄窗口中的搜索结果应纵向排列")
        }
        capture(app, "\(screenshotPrefix)-搜索结果")

        app.buttons["search-back"].tap()
        openSearch(in: app)
        assertFitsWindow(app.buttons["Adaptive layout"], in: app)
        scrollToHotCards(in: app, feedIdentifier: "search-feed", cardPrefix: "search-hot-")
        assertHotGrid(in: app, feedIdentifier: "search-feed", cardPrefix: "search-hot-", gap: 15)
        assertSearchControls(in: app)
        capture(app, "\(screenshotPrefix)-搜索热播")
        app.buttons["search-back"].tap()
        waitForHittable(app.buttons["home-search"])
    }

    @MainActor
    private func assertHomeHeaderAndBanner(in app: XCUIApplication) {
        assertFitsWindow(app.buttons["home-search"], in: app)
        assertFitsWindow(app.buttons["home-welfare"], in: app)
        let banner = app.otherElements["home-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(banner.frame.height, 0)
        XCTAssertGreaterThan(banner.frame.intersection(window).height, 0)
        XCTAssertGreaterThanOrEqual(banner.frame.minX, window.minX - 1)
        XCTAssertLessThanOrEqual(banner.frame.maxX, window.maxX + 1)
    }

    @MainActor
    private func openSearch(in app: XCUIApplication) {
        waitForHittable(app.buttons["home-search"])
        // Validate a physical touch: some simulator displays cannot calculate
        // an AX hit point for the overlaid header despite its visible bounds.
        app.buttons["home-search"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForHittable(app.textFields["search-input"])
    }

    @MainActor
    private func assertSearchControls(in app: XCUIApplication) {
        for control in [app.buttons["search-back"], app.textFields["search-input"], app.buttons["search-submit"]] {
            assertFitsWindow(control, in: app)
        }
    }

    @MainActor
    private func scrollToHotCards(in app: XCUIApplication, feedIdentifier: String, cardPrefix: String) {
        let feed = app.scrollViews[feedIdentifier]
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        let firstCard = app.buttons["\(cardPrefix)31"]
        for _ in 0..<12 {
            if firstCard.isHittable && firstCard.frame.minY < app.windows.firstMatch.frame.midY { break }
            feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        }
        waitForHittable(firstCard)
    }

    @MainActor
    private func assertHotGrid(in app: XCUIApplication, feedIdentifier: String, cardPrefix: String, gap: CGFloat) {
        let feed = app.scrollViews[feedIdentifier]
        let frames = (31...42).map { app.buttons["\(cardPrefix)\($0)"] }
            .filter { $0.exists && $0.frame.width > 0 }.map(\.frame)
        XCTAssertGreaterThanOrEqual(frames.count, 2)
        guard let first = frames.first else { return }
        for frame in frames {
            XCTAssertEqual(frame.width, first.width, accuracy: 1)
            XCTAssertGreaterThanOrEqual(frame.minX, feed.frame.minX - 1)
            XCTAssertLessThanOrEqual(frame.maxX, feed.frame.maxX + 1)
        }
        let columns = Dictionary(grouping: frames) { Int($0.minX.rounded()) }
            .values.sorted { $0[0].minX < $1[0].minX }
        XCTAssertGreaterThanOrEqual(columns.count, 2)
        if feed.frame.width >= 700 {
            XCTAssertGreaterThan(columns.count, 2, "宽窗口的热播内容应利用额外空间增加列数")
        }
        for pair in zip(columns, columns.dropFirst()) {
            XCTAssertEqual(pair.1[0].minX - pair.0[0].maxX, gap, accuracy: 1)
        }
        for column in columns {
            let ordered = column.sorted { $0.minY < $1.minY }
            for pair in zip(ordered, ordered.dropFirst()) {
                XCTAssertEqual(pair.1.minY - pair.0.maxY, 16, accuracy: 1)
            }
        }
    }

    @MainActor
    private func scrollHomeToTop(in app: XCUIApplication) {
        let feed = app.scrollViews["home-feed"]
        let header = app.otherElements["home-top-controls"]
        for _ in 0..<12 where (header.value as? String)?.hasPrefix("0%") != true {
            feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        }
        expectation(for: NSPredicate(format: "value BEGINSWITH %@", "0%"), evaluatedWith: header)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func visibleButton(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
        expectation(for: NSPredicate { _, _ in matches.allElementsBoundByIndex.contains(where: \.isHittable) }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        return matches.allElementsBoundByIndex.first(where: \.isHittable) ?? matches.firstMatch
    }

    @MainActor
    private func assertFitsWindow(_ element: XCUIElement, in app: XCUIApplication) {
        waitForHittable(element)
        XCTAssertTrue(app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1).contains(element.frame),
            "\(element.identifier) 应完整位于当前窗口内")
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        if ["home-search", "home-welfare"].contains(element.identifier) {
            XCTAssertTrue(element.isEnabled)
            return // Their bounds and physical center taps are verified separately.
        }
        expectation(for: NSPredicate(format: "hittable == true AND enabled == true"), evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func waitForValue(_ value: String, on element: XCUIElement) {
        expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
