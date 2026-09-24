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

        for _ in 0..<4 where header.frame.height >= 110 {
            end.press(forDuration: 0.05, thenDragTo: start)
        }
        let clear = NSPredicate(format: "value BEGINSWITH %@", "0%")
        expectation(for: clear, evaluatedWith: header)
        waitForExpectations(timeout: 5)
        XCTAssertLessThan(header.frame.height, 110, "下滑回顶部后分类栏应回到内容流")
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testTheaterPagesVerticallyAndOpensEpisodes() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["剧场"].tap()
        let first = app.buttons["更多剧集，重生之我逆袭做校花"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.8))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.15))
        start.press(forDuration: 0.05, thenDragTo: end)
        let second = app.buttons["更多剧集，全家抢我神笔许愿，全玩脱了"]
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
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
