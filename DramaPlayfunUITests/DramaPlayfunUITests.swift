//
//  DramaPlayfunUITests.swift
//  DramaPlayfunUITests
//
//  Created by KungFu on 2026/9/20.
//

import XCTest

final class DramaPlayfunUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testHomeHeaderFadesAndCategoriesStickOnScroll() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-FeedUITestFixture")
        app.launch()

        let header = app.otherElements["home-top-controls"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue((header.value as? String)?.hasPrefix("0%") == true)

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: end)

        let opaque = NSPredicate(format: "value BEGINSWITH %@", "100%")
        expectation(for: opaque, evaluatedWith: header)
        waitForExpectations(timeout: 5)
        for _ in 0..<4 where header.frame.height <= 120 {
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        let scrolledScreen = XCTAttachment(screenshot: app.screenshot())
        scrolledScreen.name = "首页上滑后"
        scrolledScreen.lifetime = .keepAlways
        add(scrolledScreen)
        XCTAssertGreaterThan(header.frame.height, 120, "分类栏应出现在固定顶部：\(header.value ?? "无状态")")
        XCTAssertTrue(app.buttons["真人剧"].exists)

        for _ in 0..<4 where (header.value as? String)?.hasPrefix("0%") != true {
            end.press(forDuration: 0.05, thenDragTo: start)
        }
        let clear = NSPredicate(format: "value BEGINSWITH %@", "0%")
        expectation(for: clear, evaluatedWith: header)
        waitForExpectations(timeout: 5)
        XCTAssertLessThan(header.frame.height, 110, "下滑回顶部后分类栏应回到内容流")
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testHomeCategoryPagesAndButtonsStayInSync() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-FeedUITestFixture")
        app.launch()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: end)
        let live = app.buttons["真人剧"].firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 5))
        live.tap()
        let pages = app.scrollViews["home-category-pages"]
        expectation(for: NSPredicate(format: "value == %@", "真人剧"), evaluatedWith: pages)
        waitForExpectations(timeout: 5)
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        right.press(forDuration: 0.05, thenDragTo: left)
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.buttons["剧情"].firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(pages.value as? String, "剧情")
        app.buttons["古装"].firstMatch.tap()
        expectation(for: NSPredicate(format: "value == %@", "古装"), evaluatedWith: pages)
        waitForExpectations(timeout: 5)
        left.press(forDuration: 0.05, thenDragTo: right)
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.buttons["剧情"].firstMatch)
        waitForExpectations(timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "首页分类双向联动"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testFeaturedSwipeSelectsLiveAction() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-FeedUITestFixture")
        app.launch()
        let heading = app.staticTexts["热播剧集"].firstMatch
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        for _ in 0..<5 {
            if heading.isHittable && heading.frame.maxY < 400 { break }
            bottom.press(forDuration: 0.05, thenDragTo: top)
        }
        XCTAssertTrue(heading.isHittable)
        XCTAssertTrue(app.buttons["精选"].firstMatch.isSelected)
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.65))
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.65))
        right.press(forDuration: 0.05, thenDragTo: left)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "精选左滑到真人剧"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.buttons["真人剧"].firstMatch)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testTheaterPagesVerticallyAndOpensEpisodes() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-TheaterUITestFixture")
        app.launch()
        app.tabBars.buttons["剧场"].tap()
        let first = app.buttons["更多剧集，剧场测试甲"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.8))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.15))
        start.press(forDuration: 0.05, thenDragTo: end)
        let second = app.buttons["更多剧集，剧场测试乙"]
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: second)
        waitForExpectations(timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "剧场上滑切换后"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        second.tap()
        XCTAssertTrue(app.navigationBars["选集"].waitForExistence(timeout: 5))
        app.buttons["第1集"].tap()
        XCTAssertTrue(app.buttons["关闭播放"].waitForExistence(timeout: 5))
        app.buttons["关闭播放"].tap()
        end.press(forDuration: 0.05, thenDragTo: start)
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: first)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testRankingsUseServerTabsAndReplaceListOnSelection() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-FeedUITestFixture")
        app.launch()
        app.tabBars.buttons["排行榜"].tap()
        XCTAssertTrue(app.staticTexts["榜单测试21"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["日榜"].isSelected)
        XCTAssertFalse(app.buttons["精选"].exists)
        app.buttons["周榜"].tap()
        XCTAssertTrue(app.staticTexts["榜单测试22"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["周榜"].isSelected)
        XCTAssertFalse(app.staticTexts["榜单测试21"].exists)
        let pages = app.scrollViews["ranking-category-pages"]
        XCTAssertEqual(pages.value as? String, "周榜")
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.6))
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.6))
        right.press(forDuration: 0.05, thenDragTo: left)
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.buttons["月榜"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.staticTexts["榜单测试23"].waitForExistence(timeout: 5))
        XCTAssertEqual(pages.value as? String, "月榜")
        left.press(forDuration: 0.05, thenDragTo: right)
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.buttons["周榜"])
        waitForExpectations(timeout: 5)
        app.buttons["日榜"].tap()
        expectation(for: NSPredicate(format: "value == %@", "日榜"), evaluatedWith: pages)
        waitForExpectations(timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "排行榜设计还原"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.staticTexts["榜单测试21"].tap()
        XCTAssertTrue(app.navigationBars["剧集详情"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testHomeContinueWatchingUsesServerHistoryAndHidesWhenEmpty() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HistoryUITestFixture"]
        app.launch()
        let title = app.staticTexts["历史测试剧"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["第3集 · 已观看 1:05"].exists)
        let section = app.otherElements["home-continue-watching"]
        XCTAssertTrue(section.exists)
        app.buttons["history-111"].tap()
        XCTAssertTrue(app.navigationBars["剧集详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["历史测试剧"].firstMatch.exists)
        app.terminate()
        app.launchArguments = ["-FeedUITestFixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["最新发布"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["home-continue-watching"].exists)
    }

    @MainActor
    func testFeaturedMomentsLayoutAndNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-FeedUITestFixture"]
        app.launch()
        let heading = app.staticTexts["今日片刻"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        for _ in 0..<4 where !heading.isHittable { start.press(forDuration: 0.05, thenDragTo: end) }
        let first = app.buttons["home-moment-41"]
        let second = app.buttons["home-moment-42"]
        let third = app.buttons["home-moment-43"]
        XCTAssertTrue(first.exists && second.exists && third.exists)
        XCTAssertFalse(app.buttons["home-moment-44"].exists)
        XCTAssertGreaterThan(first.frame.height, second.frame.height * 1.8)
        XCTAssertGreaterThan(second.frame.minX, first.frame.minX)
        XCTAssertGreaterThan(third.frame.minY, second.frame.minY)
        app.buttons["home-moments-refresh"].tap()
        XCTAssertTrue(app.buttons["home-moment-51"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home-moment-52"].exists)
        XCTAssertTrue(app.buttons["home-moment-53"].exists)
        XCTAssertFalse(app.buttons["home-moment-41"].exists)
        XCTAssertFalse(app.navigationBars["剧集详情"].exists, "换一换只能刷新数据，不能跳转页面")
        XCTAssertTrue(app.buttons["home-moments-refresh"].isHittable)
        XCTAssertTrue(app.tabBars.buttons["首页"].isSelected)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "首页今日片刻"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["home-moment-51"].tap()
        XCTAssertTrue(app.navigationBars["剧集详情"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTheaterSummaryExpandsUpwardWithoutUnusedHeight() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TheaterUITestFixture"]
        app.launch()
        app.tabBars.buttons["剧场"].tap()
        let page = app.otherElements["theater-video-101"]
        let expand = page.buttons["展开"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        let collapsed = page.staticTexts["theater-summary-text"]
        let originalBottom = collapsed.frame.maxY
        let originalHeight = collapsed.frame.height
        expand.tap()
        let scroll = page.scrollViews["theater-summary-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let text = page.staticTexts["theater-summary-text"]
        XCTAssertGreaterThan(text.frame.height, originalHeight)
        XCTAssertLessThan(scroll.frame.height, 140)
        XCTAssertEqual(scroll.frame.height, text.frame.height, accuracy: 2)
        XCTAssertEqual(text.frame.maxY, originalBottom, accuracy: 3)
        page.buttons["收起"].tap()
        XCTAssertEqual(page.staticTexts["theater-summary-text"].frame.height, originalHeight, accuracy: 2)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
