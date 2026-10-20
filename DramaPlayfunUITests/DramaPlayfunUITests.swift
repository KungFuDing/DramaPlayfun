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
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
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
        let pinnedCategory = header.buttons["真人剧"].firstMatch
        for _ in 0..<4 where !pinnedCategory.isHittable {
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        let scrolledScreen = XCTAttachment(screenshot: app.screenshot())
        scrolledScreen.name = "首页上滑后"
        scrolledScreen.lifetime = .keepAlways
        add(scrolledScreen)
        XCTAssertTrue(pinnedCategory.isHittable, "分类栏应出现在固定顶部：\(header.value ?? "无状态")")
        XCTAssertTrue(header.frame.contains(pinnedCategory.frame))

        for _ in 0..<4 where (header.value as? String)?.hasPrefix("0%") != true {
            end.press(forDuration: 0.05, thenDragTo: start)
        }
        let clear = NSPredicate(format: "value BEGINSWITH %@", "0%")
        expectation(for: clear, evaluatedWith: header)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(pinnedCategory.exists, "下滑回顶部后分类栏应回到内容流")
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testHomeCategoryPagesAndButtonsStayInSync() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-FeedUITestFixture")
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
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
    func testHomeWaterfallKeepsEqualWidthsAndFixedGaps() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-FeedUITestFixture", "-WaterfallUITestFixture"]
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        let heading = app.staticTexts["熱播劇集"].firstMatch
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        for _ in 0..<6 {
            if heading.isHittable && heading.frame.maxY < 250 { break }
            bottom.press(forDuration: 0.05, thenDragTo: top)
        }
        for id in 31...34 {
            XCTAssertTrue(app.buttons["home-drama-item-\(id)"].waitForExistence(timeout: 5))
        }
        let cards = (31...36).map { app.buttons["home-drama-item-\($0)"] }.filter(\.exists)
        let frames = cards.map(\.frame)
        for frame in frames { XCTAssertEqual(frame.width, frames[0].width, accuracy: 1) }
        let columns = Dictionary(grouping: frames) { Int($0.minX.rounded()) }
            .values.sorted { $0[0].minX < $1[0].minX }
        XCTAssertGreaterThanOrEqual(columns.count, 2)
        for pair in zip(columns, columns.dropFirst()) {
            XCTAssertEqual(pair.1[0].minX - pair.0[0].maxX, 14, accuracy: 1)
        }
        for column in columns {
            let ordered = column.sorted { $0.minY < $1.minY }
            for pair in zip(ordered, ordered.dropFirst()) {
                XCTAssertEqual(pair.1.minY - pair.0.maxY, 16, accuracy: 1)
            }
        }
        XCTAssertGreaterThan(frames[1].height, frames[0].height,
            "A wrapped title should change card height without changing its column width or gap")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "热播瀑布流固定间距"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testFeaturedSwipeSelectsLiveAction() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-FeedUITestFixture")
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        let heading = app.staticTexts["熱播劇集"].firstMatch
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        for _ in 0..<5 {
            if heading.isHittable && heading.frame.maxY < 400 { break }
            bottom.press(forDuration: 0.05, thenDragTo: top)
        }
        XCTAssertTrue(heading.isHittable)
        XCTAssertTrue(app.buttons["精選"].firstMatch.isSelected)
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
    func testTheaterServerActionsAndSharePoster() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TheaterUITestFixture"]
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["劇場"].waitForExistence(timeout: 10))
        app.tabBars.buttons["劇場"].tap()
        let like = app.buttons["theater-like-101"]
        XCTAssertTrue(like.waitForExistence(timeout: 10))
        like.tap()
        expectation(for: NSPredicate(format: "label == %@", "取消按讚"), evaluatedWith: like)
        waitForExpectations(timeout: 5)
        like.tap()
        expectation(for: NSPredicate(format: "label == %@", "按讚"), evaluatedWith: like)
        waitForExpectations(timeout: 5)
        let favorite = app.buttons["theater-favorite-101"]
        favorite.tap()
        expectation(for: NSPredicate(format: "label == %@", "取消收藏"), evaluatedWith: favorite)
        waitForExpectations(timeout: 5)
        app.buttons["theater-share-101"].tap()
        XCTAssertTrue(app.buttons["儲存至相簿"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["分享至"].isHittable)
        XCTAssertTrue(app.images["短劇分享 QR Code"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "剧场分享海报"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["儲存至相簿"].tap()
        XCTAssertTrue(app.alerts["提示"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.alerts["提示"].staticTexts["已儲存至相簿"].exists)
        app.alerts["提示"].buttons["知道了"].tap()
        app.buttons["分享至"].tap()
        let systemShare = app.otherElements["ActivityListView"]
        XCTAssertTrue(systemShare.waitForExistence(timeout: 5), app.debugDescription)
        let systemScreenshot = XCTAttachment(screenshot: app.screenshot())
        systemScreenshot.name = "系统图片分享"
        systemScreenshot.lifetime = .keepAlways
        add(systemScreenshot)
        let close = app.buttons["Close"]
        if close.exists { close.tap() }
        else if app.buttons["关闭"].exists { app.buttons["关闭"].tap() }
        else { app.swipeDown() }
        XCTAssertTrue(app.buttons["關閉分享"].waitForExistence(timeout: 5))
        app.buttons["關閉分享"].tap()
        XCTAssertTrue(app.buttons["theater-share-101"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTheaterFinishedPreviewOpensSecondEpisodeAndReturnsToFirstEpisodeStart() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TheaterUITestFixture", "-PlaybackProgressUITestFixture"]
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        app.tabBars.buttons["劇場"].tap()
        let theaterProgress = app.sliders["theater-progress-101"]
        XCTAssertTrue(theaterProgress.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: theaterProgress)
        waitForExpectations(timeout: 10)

        // Leave history halfway through episode 2 before finishing the preview.
        app.buttons["更多劇集，剧场测试甲"].tap()
        app.buttons["player-episodes"].tap()
        app.buttons["episode-selection-2"].tap()
        let secondProgress = app.sliders["player-progress-2"]
        XCTAssertTrue(secondProgress.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: secondProgress)
        waitForExpectations(timeout: 10)
        secondProgress.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25))
            .press(forDuration: 0.1, thenDragTo: secondProgress.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        expectation(for: NSPredicate { _, _ in
            let value = Double((secondProgress.value as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? -1
            return value > 45 && value < 65
        }, evaluatedWith: secondProgress)
        waitForExpectations(timeout: 10)
        app.buttons["player-back"].tap()
        XCTAssertTrue(theaterProgress.waitForExistence(timeout: 10))
        expectation(for: NSPredicate { _, _ in
            let value = Double((theaterProgress.value as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? -1
            return theaterProgress.isEnabled && value >= 0 && value < 20
        }, evaluatedWith: theaterProgress)
        waitForExpectations(timeout: 10)

        // Use the lower part of the control so the introduction's expand button
        // above the track cannot intercept this gesture. Let the final seconds play.
        theaterProgress.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.8))
            .press(forDuration: 0.1, thenDragTo: theaterProgress.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.8)))
        let feed = app.scrollViews["player-episode-feed"]
        let opened = feed.waitForExistence(timeout: 15)
        if !opened {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "首集完成跳转状态"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(opened, app.debugDescription)
        expectation(for: NSPredicate(format: "value == %@", "第2集"), evaluatedWith: feed)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(secondProgress.waitForExistence(timeout: 10))
        XCTAssertTrue(secondProgress.isEnabled, "The preloaded second episode must be ready when its page opens")
        expectation(for: NSPredicate { _, _ in
            let value = Double((secondProgress.value as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? -1
            return secondProgress.isEnabled && value > 0 && value < 25
        }, evaluatedWith: secondProgress)
        waitForExpectations(timeout: 10)
        app.buttons["player-back"].tap()
        XCTAssertTrue(app.otherElements["theater-video-101"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate { _, _ in
            let value = Double((theaterProgress.value as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? -1
            return theaterProgress.isEnabled && value > 0 && value < 20
        }, evaluatedWith: theaterProgress)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(feed.exists, "Returning must not immediately open episode 2 again")
        XCTAssertTrue(app.tabBars.buttons["劇場"].isSelected)
    }

    @MainActor
    func testTheaterAndPlayerProgressCanScrubAboveTheVisibleTrack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TheaterUITestFixture", "-PlaybackProgressUITestFixture"]
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        let theater = app.buttons["劇場"].firstMatch
        XCTAssertTrue(theater.waitForExistence(timeout: 10))
        theater.tap()
        let theaterProgress = app.sliders["theater-progress-101"]
        XCTAssertTrue(theaterProgress.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: theaterProgress)
        waitForExpectations(timeout: 10)
        app.scrollViews["theater-feed"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(app.buttons["播放影片"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(theaterProgress.frame.height, 44)
        let theaterPage = app.otherElements["theater-video-101"]
        XCTAssertLessThanOrEqual(theaterProgress.frame.maxY - 10 - theaterPage.staticTexts["theater-summary-text"].frame.maxY, 18,
            "The expanded touch area must not add space below the drama introduction")
        theaterProgress.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25))
            .press(forDuration: 0.1, thenDragTo: theaterProgress.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.25)))
        expectation(for: NSPredicate { _, _ in
            let value = Double((theaterProgress.value as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? -1
            return value > 65 && value < 85
        }, evaluatedWith: theaterProgress)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["播放影片"].exists, "Scrubbing must preserve the paused state")
        theaterPage.buttons["展開"].tap()
        XCTAssertTrue(theaterPage.buttons["收起"].waitForExistence(timeout: 5))
        theaterPage.buttons["收起"].tap()
        let episodes = app.buttons["更多劇集，剧场测试甲"]
        XCTAssertTrue(episodes.isHittable, "Horizontal scrubbing must not change the feed page")
        episodes.tap()

        let playerProgress = app.sliders["player-progress-1"]
        XCTAssertTrue(playerProgress.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: playerProgress)
        waitForExpectations(timeout: 10)
        app.scrollViews["player-episode-feed"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(app.buttons["播放影片"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(playerProgress.frame.height, 44)
        let playerPage = app.otherElements["player-episode-1"]
        XCTAssertLessThanOrEqual(playerProgress.frame.maxY - 10 - playerPage.staticTexts["theater-summary-text"].frame.maxY, 18)
        // Start above the track, away from the introduction's expand button.
        playerProgress.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.25))
            .press(forDuration: 0.1, thenDragTo: playerProgress.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25)))
        expectation(for: NSPredicate { _, _ in
            let value = Double((playerProgress.value as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? -1
            return value > 20 && value < 40
        }, evaluatedWith: playerProgress)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["播放影片"].exists)
        playerPage.buttons["展開"].tap()
        XCTAssertTrue(playerPage.buttons["收起"].waitForExistence(timeout: 5))
        playerPage.buttons["收起"].tap()
        XCTAssertEqual(app.scrollViews["player-episode-feed"].value as? String, "第1集")
    }

    @MainActor
    func testTheaterPagesVerticallyAndOpensEpisodes() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-TheaterUITestFixture")
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        app.tabBars.buttons["劇場"].tap()
        let first = app.buttons["更多劇集，剧场测试甲"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.8))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.15))
        start.press(forDuration: 0.05, thenDragTo: end)
        let second = app.buttons["更多劇集，剧场测试乙"]
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: second)
        waitForExpectations(timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "剧场上滑切换后"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        second.tap()
        XCTAssertTrue(app.scrollViews["player-episode-feed"].waitForExistence(timeout: 5))
        app.buttons["player-episodes"].tap()
        XCTAssertTrue(app.otherElements["player-episodes-panel"].waitForExistence(timeout: 5))
        app.buttons["第1集"].tap()
        app.buttons["返回"].tap()
        end.press(forDuration: 0.05, thenDragTo: start)
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: first)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testRankingsUseServerTabsAndReplaceListOnSelection() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-FeedUITestFixture")
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        // The system can move tabs into a sidebar on wide displays.
        let rankingTabs = app.buttons.matching(NSPredicate(format: "label == %@", "排行榜"))
        expectation(for: NSPredicate { _, _ in
            rankingTabs.allElementsBoundByIndex.contains(where: \.isHittable)
        }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        let rankingTab = try XCTUnwrap(rankingTabs.allElementsBoundByIndex.first(where: \.isHittable))
        rankingTab.tap()
        XCTAssertTrue(app.staticTexts["榜单测试21"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["日榜"].isSelected)
        XCTAssertFalse(app.buttons["精選"].exists)
        app.buttons["周榜"].tap()
        XCTAssertTrue(app.staticTexts["榜单测试22"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["周榜"].isSelected)
        XCTAssertFalse(app.staticTexts["榜单测试21"].exists)
        let pages = app.scrollViews["ranking-category-pages"]
        XCTAssertEqual(pages.value as? String, "周榜")
        pages.swipeLeft()
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.buttons["月榜"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.staticTexts["榜单测试23"].waitForExistence(timeout: 5))
        XCTAssertEqual(pages.value as? String, "月榜")
        pages.swipeRight()
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
        XCTAssertTrue(app.scrollViews["player-episode-feed"].waitForExistence(timeout: 5))
        app.buttons["返回"].tap()
        XCTAssertTrue(app.staticTexts["榜单测试21"].waitForExistence(timeout: 5))
        app.staticTexts["榜单测试21"].tap()
        XCTAssertTrue(app.scrollViews["player-episode-feed"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testHomeContinueWatchingUsesServerHistoryAndHidesWhenEmpty() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HistoryUITestFixture"]
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        let title = app.staticTexts["历史测试剧"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["第3集 · 已觀看 1:05"].exists)
        let section = app.otherElements["home-continue-watching"]
        XCTAssertTrue(section.exists)
        app.buttons["history-111"].tap()
        XCTAssertTrue(app.scrollViews["player-episode-feed"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == %@", "第3集"), evaluatedWith: app.scrollViews["player-episode-feed"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.otherElements["player-episode-3"].isHittable)
        XCTAssertTrue(app.staticTexts["历史测试剧"].firstMatch.exists)
        app.terminate()
        app.launchArguments = ["-FeedUITestFixture"]
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        XCTAssertTrue(app.staticTexts["最新发布"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["home-continue-watching"].exists)
    }

    @MainActor
    func testFeaturedMomentsLayoutAndNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-FeedUITestFixture", "-PlaybackProgressUITestFixture"]
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
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
        if app.scrollViews["home-feed"].frame.width >= 600 {
            for card in [second, third] {
                XCTAssertEqual(card.frame.width, first.frame.width, accuracy: 1)
                XCTAssertEqual(card.frame.height, first.frame.height, accuracy: 1)
                XCTAssertEqual(card.frame.minY, first.frame.minY, accuracy: 1)
            }
            XCTAssertGreaterThan(second.frame.minX, first.frame.maxX)
            XCTAssertGreaterThan(third.frame.minX, second.frame.maxX)
        } else {
            XCTAssertGreaterThan(first.frame.height, second.frame.height * 1.8)
            XCTAssertGreaterThan(second.frame.minX, first.frame.minX)
            XCTAssertGreaterThan(third.frame.minY, second.frame.minY)
        }
        app.buttons["home-moments-refresh"].tap()
        XCTAssertTrue(app.buttons["home-moment-51"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home-moment-52"].exists)
        XCTAssertTrue(app.buttons["home-moment-53"].exists)
        XCTAssertFalse(app.buttons["home-moment-41"].exists)
        XCTAssertFalse(app.navigationBars["劇集詳情"].exists, "换一换只能刷新数据，不能跳转页面")
        XCTAssertTrue(app.buttons["home-moments-refresh"].isHittable)
        let homeTabs = app.buttons.matching(NSPredicate(format: "label == %@", "首頁"))
        XCTAssertTrue(homeTabs.allElementsBoundByIndex.contains { $0.isHittable && $0.isSelected })
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "首页今日片刻"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["home-moment-51"].tap()
        let feed = app.scrollViews["player-episode-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == %@", "第4集"), evaluatedWith: feed)
        waitForExpectations(timeout: 5)
        let progress = app.sliders["player-progress-4"]
        expectation(for: NSPredicate { _, _ in
            let percent = Double((progress.value as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? -1
            return progress.isEnabled && percent >= 38 && percent < 60
        }, evaluatedWith: progress)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testTheaterSummaryExpandsUpwardWithoutUnusedHeight() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TheaterUITestFixture"]
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        app.tabBars.buttons["劇場"].tap()
        let page = app.otherElements["theater-video-101"]
        let expand = page.buttons["展開"]
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
    func testPlayerPagesThroughDramaAndSelectsEpisode() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-FeedUITestFixture"]
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        let banner = app.buttons["推薦劇集，推荐测试"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        banner.tap()
        let feed = app.scrollViews["player-episode-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        let first = app.otherElements["player-episode-1"]
        XCTAssertTrue(first.isHittable)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.7))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: end)
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: app.otherElements["player-episode-2"])
        waitForExpectations(timeout: 5)
        app.buttons["player-episodes"].tap()
        XCTAssertTrue(app.otherElements["player-episodes-panel"].waitForExistence(timeout: 5))
        app.buttons["第5集"].tap()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: app.otherElements["player-episode-5"])
        waitForExpectations(timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "播放详情页第5集"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["返回"].tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        let shelf = app.buttons["home-shelf-item-31"]
        for _ in 0..<5 where !shelf.isHittable { start.press(forDuration: 0.05, thenDragTo: end) }
        XCTAssertTrue(shelf.isHittable)
        shelf.tap()
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        app.buttons["返回"].tap()
        let hot = app.buttons["home-drama-item-32"]
        for _ in 0..<5 where !hot.isHittable { start.press(forDuration: 0.05, thenDragTo: end) }
        XCTAssertTrue(hot.isHittable)
        hot.tap()
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        app.buttons["返回"].tap()
    }

    @MainActor
    func testEpisodeSheetRangesAndUnlockStates() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PlayerUnlockUITestFixture", "-EpisodesUITestFixture"]
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        let banner = app.buttons["推薦劇集，推荐测试"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        banner.tap()
        app.buttons["player-episodes"].tap()
        let panel = app.otherElements["player-episodes-panel"]
        let initialScreenshot = XCTAttachment(screenshot: app.screenshot())
        initialScreenshot.name = "选集弹窗初始状态"
        initialScreenshot.lifetime = .keepAlways
        add(initialScreenshot)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["episode-range-1"].isSelected)
        XCTAssertEqual(app.buttons["episode-selection-2"].value as? String, "已觀看")
        XCTAssertEqual(app.buttons["episode-selection-3"].value as? String, "可播放")
        XCTAssertEqual(app.buttons["episode-selection-11"].value as? String, "已解鎖")
        XCTAssertEqual(app.buttons["episode-selection-17"].value as? String, "需10金幣解鎖")
        app.buttons["episode-selection-3"].tap()
        XCTAssertFalse(panel.exists)
        app.buttons["player-episodes"].tap()
        XCTAssertEqual(app.buttons["episode-selection-3"].value as? String, "正在播放")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "选集弹窗设计还原"
        image.lifetime = .keepAlways
        add(image)
        app.buttons["episode-range-31"].tap()
        XCTAssertTrue(app.buttons["episode-selection-31"].exists)
        XCTAssertFalse(app.buttons["episode-selection-1"].exists)
        app.buttons["episode-range-61"].tap()
        XCTAssertTrue(app.buttons["episode-selection-80"].exists)
        app.buttons["episode-range-1"].tap()
        app.buttons["episode-selection-17"].tap()
        XCTAssertTrue(app.otherElements["player-unlock-dialog"].waitForExistence(timeout: 5))
        XCTAssertFalse(panel.exists, "选中付费集后应退出选集并定位到该集")
        XCTAssertTrue(app.buttons["player-unlock-coins"].exists)
        app.buttons["player-unlock-coins"].tap()
        XCTAssertTrue(app.otherElements["player-unlock-confirmation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["player-unlock-confirm"].exists)
        XCTAssertTrue(app.buttons["player-unlock-vip"].exists)
        app.buttons["player-unlock-close"].tap()
        XCTAssertFalse(app.otherElements["player-unlock-confirmation"].exists)
        XCTAssertFalse(panel.exists)
        XCTAssertTrue(app.otherElements["player-unlock-dialog"].exists)
        XCTAssertTrue(app.scrollViews["player-episode-feed"].exists)
        XCTAssertEqual(app.scrollViews["player-episode-feed"].value as? String, "第17集")
    }

    @MainActor
    func testSwipingToPaidEpisodeShowsUnlockDialogAndOpensMembership() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PlayerUnlockUITestFixture"]
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        let banner = app.buttons["推薦劇集，推荐测试"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        banner.tap()
        app.buttons["player-episodes"].tap()
        app.buttons["episode-selection-5"].tap()
        let feed = app.scrollViews["player-episode-feed"]
        expectation(for: NSPredicate(format: "value == %@", "第5集"), evaluatedWith: feed)
        waitForExpectations(timeout: 5)
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.75))
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.2))
        let dialog = app.otherElements["player-unlock-dialog"]
        bottom.press(forDuration: 0.05, thenDragTo: top)
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "余额不足时滑到付费集应显示浮层")
        XCTAssertTrue(app.staticTexts["本集需要解鎖"].exists)
        XCTAssertTrue(app.buttons["player-unlock-coins"].isHittable)
        XCTAssertTrue(app.buttons["player-back"].isHittable, "一级浮层不能遮挡左上角返回按钮")
        XCTAssertFalse(app.otherElements["player-unlock-confirmation"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "滑到付费集自动显示解锁弹窗"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertEqual(feed.value as? String, "第6集")
        top.press(forDuration: 0.05, thenDragTo: bottom)
        expectation(for: NSPredicate(format: "value == %@", "第5集"), evaluatedWith: feed)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(dialog.exists, "免费集不应弹出解锁弹窗")
        bottom.press(forDuration: 0.05, thenDragTo: top)
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "重新滑入未解锁付费集时应再次弹出")
        app.buttons["player-unlock-coins"].tap()
        let confirmation = app.otherElements["player-unlock-confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        app.buttons["player-unlock-vip"].tap()
        XCTAssertTrue(app.buttons["membership-tab-weekly"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["membership-tab-weekly"].isSelected)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["player-unlock-coins"].waitForExistence(timeout: 5))
        app.buttons["player-unlock-coins"].tap()
        XCTAssertTrue(app.buttons["player-unlock-confirm"].waitForExistence(timeout: 5))
        app.buttons["player-unlock-confirm"].tap()
        XCTAssertTrue(app.buttons["membership-tab-coins"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["membership-tab-coins"].isSelected, "余额不足确认解锁应直接打开充值页签")
        app.buttons["完成"].tap()
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        XCTAssertEqual(feed.value as? String, "第6集", "浏览会员页不会直接授予付费集权限")
        XCTAssertTrue(dialog.exists)
        app.buttons["player-back"].tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
    }

    @MainActor
    func testPlayerQualityAndSpeedSheetsRememberSelections() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-FeedUITestFixture"]
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        let banner = app.buttons["推薦劇集，推荐测试"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        banner.tap()
        XCTAssertTrue(app.scrollViews["player-episode-feed"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["player-subtitles"].exists, "片源没有字幕轨道时隐藏字幕入口")

        let quality = app.buttons["player-quality"]
        quality.tap()
        let qualityPanel = app.otherElements["player-quality-panel"]
        XCTAssertTrue(qualityPanel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["player-quality-0"].isSelected)
        XCTAssertTrue(app.buttons["player-quality-480"].exists)
        XCTAssertTrue(app.buttons["player-quality-720"].exists)
        let vip = app.buttons["player-quality-1080"]
        XCTAssertEqual(vip.value as? String, "會員專享")
        vip.tap()
        XCTAssertFalse(qualityPanel.exists)
        XCTAssertEqual(quality.value as? String, "1080P")
        XCTAssertFalse(app.navigationBars["會員"].exists, "1080P 暂不校验会员权限")
        quality.tap()
        XCTAssertTrue(vip.isSelected)
        let selectedQuality = XCTAttachment(screenshot: app.screenshot())
        selectedQuality.name = "1080P 选中及黑色皇冠"
        selectedQuality.lifetime = .keepAlways
        add(selectedQuality)
        app.buttons["player-quality-720"].tap()
        quality.tap()
        XCTAssertTrue(app.buttons["player-quality-720"].isSelected)
        XCTAssertFalse(vip.isSelected)
        let normalQuality = XCTAttachment(screenshot: app.screenshot())
        normalQuality.name = "720P 选中及金色皇冠"
        normalQuality.lifetime = .keepAlways
        add(normalQuality)
        app.buttons["player-options-close"].tap()

        let speed = app.buttons["player-speed"]
        speed.tap()
        let speedPanel = app.otherElements["player-speed-panel"]
        XCTAssertTrue(speedPanel.waitForExistence(timeout: 5))
        for value in ["0.75", "1", "1.5", "2", "3"] {
            XCTAssertTrue(app.buttons["player-speed-\(value)"].exists)
        }
        XCTAssertTrue(app.buttons["player-speed-1"].isSelected)
        app.buttons["player-speed-3"].tap()
        XCTAssertFalse(speedPanel.exists)
        XCTAssertEqual(speed.value as? String, "3x")
        speed.tap()
        XCTAssertTrue(app.buttons["player-speed-3"].isSelected)
        app.buttons["player-options-close"].tap()
        XCTAssertFalse(speedPanel.exists)
    }

    @MainActor
    func testShortDramaDetailFromTheaterLoadsAndFollows() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TheaterUITestFixture"]
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        app.tabBars.buttons["劇場"].tap()
        let title = app.buttons["drama-detail-title-101"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        XCTAssertTrue(app.staticTexts["详情测试101"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["共68集"].exists)
        let score = app.staticTexts["short-drama-score"]
        XCTAssertTrue(score.exists)
        XCTAssertTrue(["評分7.5", "評分8.0", "評分8.5", "評分9.0", "評分9.5"].contains(score.label))
        let initialScore = score.label
        let follow = app.buttons["short-drama-follow"]
        follow.tap()
        expectation(for: NSPredicate(format: "value == '已追劇'"), evaluatedWith: follow)
        waitForExpectations(timeout: 5)
        follow.tap()
        expectation(for: NSPredicate(format: "value == '未追劇'"), evaluatedWith: follow)
        waitForExpectations(timeout: 5)
        let collapsedHeight = app.staticTexts["short-drama-summary"].frame.height
        app.buttons["short-drama-expand"].tap()
        XCTAssertGreaterThan(app.staticTexts["short-drama-summary"].frame.height, collapsedHeight)
        XCTAssertEqual(app.staticTexts["short-drama-score"].label, initialScore)
        app.buttons["short-drama-expand"].tap()
        let recommended = app.buttons["short-drama-recommendation-202"]
        for _ in 0..<3 where !recommended.isHittable { app.swipeUp() }
        XCTAssertTrue(recommended.isHittable)
        recommended.tap()
        XCTAssertTrue(app.scrollViews["player-episode-feed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["drama-detail-title-202"].waitForExistence(timeout: 5))
        try XCTUnwrap(app.buttons.matching(identifier: "player-back").allElementsBoundByIndex.first(where: \.isHittable)).tap()
        XCTAssertTrue(app.buttons["short-drama-back"].waitForExistence(timeout: 5))
        app.buttons["short-drama-back"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["劇場"].isHittable)
    }

    @MainActor
    func testShortDramaDetailFromPlayerPreservesEpisodeAndFavorite() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TheaterUITestFixture"]
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        app.tabBars.buttons["劇場"].tap()
        let episodes = app.buttons["更多劇集，剧场测试甲"]
        XCTAssertTrue(episodes.waitForExistence(timeout: 10))
        episodes.tap()
        let feed = app.scrollViews["player-episode-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        app.buttons["player-episodes"].tap()
        app.buttons["第3集"].tap()
        XCTAssertEqual(feed.value as? String, "第3集")
        try XCTUnwrap(app.buttons.matching(identifier: "drama-detail-title-101").allElementsBoundByIndex.first(where: \.isHittable)).tap()
        XCTAssertTrue(app.staticTexts["详情测试101"].waitForExistence(timeout: 5))
        app.buttons["short-drama-follow"].tap()
        expectation(for: NSPredicate(format: "value == '已追劇'"), evaluatedWith: app.buttons["short-drama-follow"])
        waitForExpectations(timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "短剧详情已追剧"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let recommended = app.buttons["short-drama-recommendation-201"]
        for _ in 0..<3 where !recommended.isHittable { app.swipeUp() }
        XCTAssertTrue(recommended.isHittable)
        recommended.tap()
        XCTAssertTrue(app.buttons["drama-detail-title-201"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["player-episode-feed"].exists)
        try XCTUnwrap(app.buttons.matching(identifier: "player-back").allElementsBoundByIndex.first(where: \.isHittable)).tap()
        XCTAssertTrue(app.buttons["short-drama-back"].waitForExistence(timeout: 5))
        app.buttons["short-drama-back"].tap()
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        XCTAssertEqual(feed.value as? String, "第3集")
        XCTAssertTrue(app.buttons.matching(identifier: "取消收藏").allElementsBoundByIndex.contains(where: \.isHittable))
        app.buttons["返回"].tap()
        XCTAssertTrue(episodes.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(identifier: "取消收藏").allElementsBoundByIndex.contains(where: \.isHittable))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
            app.launch()
        }
    }
}
