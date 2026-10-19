import XCTest

final class NavigationBackGestureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testProfilePagesSupportEdgeBackAndSettingsOverlayBlocksIt() throws {
        let app = launchApp(arguments: ["-WelfareUITestFixture", "-ProfileHistoryUITestFixture"])
        try selectTab("我的", in: app)
        waitForHittable(app.buttons["profile-settings"])

        // A root-level swipe must not leave the navigation controller in a
        // transition that prevents the next push.
        edgeSwipeBack(in: app)
        waitForHittable(app.buttons["profile-settings"])

        let destinations = [
            (entry: "profile-settings", back: "settings-back"),
            (entry: "profile-history", back: "profile-history-back"),
            (entry: "profile-wallet", back: "wallet-back"),
            (entry: "profile-welfare", back: "welfare-back")
        ]
        for destination in destinations {
            let entry = app.buttons[destination.entry]
            let back = app.buttons[destination.back]
            waitForHittable(entry)
            entry.tap()
            waitForHittable(back)
            if destination.entry == "profile-settings" {
                app.buttons["settings-语言切换"].tap()
                let closePanel = app.buttons["settings-panel-close"]
                waitForHittable(closePanel)
                edgeSwipeBack(in: app)
                waitForHittable(closePanel)
                XCTAssertFalse(entry.isHittable, "设置浮层打开时，边缘手势不能弹出底层设置页")
                closePanel.tap()
                waitForGone(closePanel)
                waitForHittable(back)
            }
            edgeSwipeBack(in: app)
            waitForGone(back)
            waitForHittable(entry)
        }

        // A destination remains pushable after both blocked and completed pops.
        app.buttons["profile-settings"].tap()
        waitForHittable(app.buttons["settings-back"])
        edgeSwipeBack(in: app)
        waitForGone(app.buttons["settings-back"])
        waitForHittable(app.buttons["profile-settings"])
    }

    @MainActor
    func testCancelledWalletSwipeKeepsThirdLevelAndCompletedSwipePopsOneLevel() throws {
        let app = launchApp(arguments: ["-WelfareUITestFixture"])
        try selectTab("我的", in: app)
        let welfareEntry = app.buttons["profile-welfare"]
        waitForHittable(welfareEntry)
        welfareEntry.tap()
        let walletEntry = app.buttons["welfare-wallet"]
        waitForHittable(walletEntry)
        walletEntry.tap()
        let walletBack = app.buttons["wallet-back"]
        waitForHittable(walletBack)

        cancelEdgeSwipeBack(in: app)
        waitForHittable(walletBack)
        XCTAssertFalse(walletEntry.isHittable, "取消返回手势后应仍停留在钱包页")

        edgeSwipeBack(in: app)
        waitForGone(walletBack)
        waitForHittable(walletEntry)
        XCTAssertFalse(welfareEntry.isHittable, "三级钱包页返回时只能弹出一层，不能跳过福利页")

        // The same destination must still be pushable after a cancelled and
        // then completed interactive transition.
        walletEntry.tap()
        waitForHittable(walletBack)
        edgeSwipeBack(in: app)
        waitForGone(walletBack)
        waitForHittable(app.buttons["welfare-back"])
        edgeSwipeBack(in: app)
        waitForGone(app.buttons["welfare-back"])
        waitForHittable(welfareEntry)
    }

    @MainActor
    func testSearchCancelledSwipePreservesResultsAndRootRemainsUsable() {
        let app = launchApp(arguments: ["-SearchUITestFixture"])
        let entry = waitForHomeSearch(in: app)
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let field = app.textFields["search-input"]
        waitForHittable(field)
        field.tap()
        field.typeText("我以异能斩规则")
        app.buttons["search-submit"].tap()
        let result = app.buttons["search-result-801"]
        waitForHittable(result)

        result.tap()
        let playerBack = app.buttons["player-back"]
        waitForHittable(playerBack)
        cancelEdgeSwipeBack(in: app)
        waitForHittable(playerBack)
        XCTAssertFalse(result.isHittable, "播放器取消返回时应留在播放页")
        edgeSwipeBack(in: app)
        waitForGone(playerBack)
        waitForHittable(result)
        XCTAssertEqual(field.value as? String, "我以异能斩规则", "播放器返回搜索时应保留原搜索词和结果")

        cancelEdgeSwipeBack(in: app)
        waitForHittable(result)
        XCTAssertEqual(field.value as? String, "我以异能斩规则")
        waitForHittable(app.buttons["search-back"])

        edgeSwipeBack(in: app)
        waitForGone(app.buttons["search-back"])
        _ = waitForHomeSearch(in: app)
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForHittable(field)
        edgeSwipeBack(in: app)
        waitForGone(app.buttons["search-back"])
        _ = waitForHomeSearch(in: app)
    }

    @MainActor
    func testTheaterDetailSupportsEdgeBackAndCanBeOpenedAgain() throws {
        let app = launchApp(arguments: ["-TheaterUITestFixture"])
        try selectTab("劇場", in: app)
        let title = app.buttons["drama-detail-title-101"]
        waitForHittable(title)
        edgeSwipeBack(in: app)
        waitForHittable(title)

        for _ in 0..<2 {
            title.tap()
            let back = app.buttons["short-drama-back"]
            waitForHittable(back)
            XCTAssertTrue(app.staticTexts["详情测试101"].waitForExistence(timeout: 5))
            edgeSwipeBack(in: app)
            waitForGone(back)
            waitForHittable(title)
            waitForHittable(app.buttons["theater-favorite-101"])
        }
    }

    @MainActor
    func testRecommendedPlayerAndDetailsPopOneLevelAndPreserveOriginalEpisode() throws {
        let app = launchApp(arguments: ["-TheaterUITestFixture"])
        try selectTab("劇場", in: app)
        let episodesEntry = app.buttons["更多劇集，剧场测试甲"]
        waitForHittable(episodesEntry)
        episodesEntry.tap()
        waitForHittable(app.buttons["player-episodes"])
        app.buttons["player-episodes"].tap()
        let thirdEpisode = app.buttons["episode-selection-3"]
        waitForHittable(thirdEpisode)
        thirdEpisode.tap()
        try assertPlayer(dramaID: 101, episode: 3, in: app)
        try visibleElement(in: app.buttons.matching(identifier: "drama-detail-title-101")).tap()
        try assertDetail(dramaID: 101, in: app)

        let recommended = app.buttons["short-drama-recommendation-201"]
        for _ in 0..<3 where !recommended.isHittable { app.swipeUp() }
        waitForHittable(recommended)
        recommended.tap()
        try assertPlayer(dramaID: 201, episode: 1, in: app)
        try visibleElement(in: app.buttons.matching(identifier: "drama-detail-title-201")).tap()
        try assertDetail(dramaID: 201, in: app)

        // Unwind detail 201 → player 201 → detail 101 → player 101.
        // Duplicate controls can remain in the accessibility tree, so match
        // visible controls and the current drama at each level.
        edgeSwipeBack(in: app)
        try assertPlayer(dramaID: 201, episode: 1, in: app)
        edgeSwipeBack(in: app)
        try assertDetail(dramaID: 101, in: app)
        waitForHittable(recommended)
        edgeSwipeBack(in: app)
        try assertPlayer(dramaID: 101, episode: 3, in: app)

        cancelEdgeSwipeBack(in: app)
        try assertPlayer(dramaID: 101, episode: 3, in: app)
        XCTAssertFalse(episodesEntry.isHittable)
        edgeSwipeBack(in: app)
        waitForHittable(episodesEntry)
        XCTAssertFalse(app.buttons["player-back"].isHittable)

        episodesEntry.tap()
        waitForHittable(app.buttons["player-episodes"])
        edgeSwipeBack(in: app)
        waitForHittable(episodesEntry)
    }

    @MainActor
    private func assertPlayer(dramaID: Int, episode: Int, in app: XCUIApplication) throws {
        _ = try visibleElement(in: app.buttons.matching(identifier: "drama-detail-title-\(dramaID)"))
        _ = try visibleElement(in: app.buttons.matching(identifier: "player-episodes"))
        let feed = try visibleElement(in: app.scrollViews.matching(identifier: "player-episode-feed"))
        waitForValue("第\(episode)集", on: feed)
    }

    @MainActor
    private func assertDetail(dramaID: Int, in app: XCUIApplication) throws {
        _ = try visibleElement(in: app.buttons.matching(identifier: "short-drama-back"))
        XCTAssertTrue(app.staticTexts["详情测试\(dramaID)"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchApp(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + [
            "-profile.language.v1", "zh-Hant",
            "-library.progress.v1", "{}"
        ]
        app.launch()
        return app
    }

    @MainActor
    private func waitForHomeSearch(in app: XCUIApplication) -> XCUIElement {
        let search = app.buttons["home-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(search.isEnabled)
        XCTAssertGreaterThan(search.frame.width, 0)
        XCTAssertGreaterThan(search.frame.height, 0)
        XCTAssertTrue(app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1).contains(search.frame))
        // The overlaid header can lack an AX hit point on some simulators;
        // the test validates its physical center tap by opening the search page.
        return search
    }

    @MainActor
    private func selectTab(_ title: String, in app: XCUIApplication) throws {
        // On iPad the tab may live in the top bar or sidebar.
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", title))
        try visibleElement(in: matches).tap()
    }

    @MainActor
    private func visibleElement(in query: XCUIElementQuery) throws -> XCUIElement {
        expectation(for: NSPredicate { _, _ in
            query.allElementsBoundByIndex.contains(where: \.isHittable)
        }, evaluatedWith: query)
        waitForExpectations(timeout: 10)
        return try XCTUnwrap(query.allElementsBoundByIndex.first(where: \.isHittable))
    }

    @MainActor
    private func edgeSwipeBack(in app: XCUIApplication) {
        dragFromLeadingEdge(in: app, to: 0.85, holdAtEnd: 0)
    }

    @MainActor
    private func cancelEdgeSwipeBack(in app: XCUIApplication) {
        // Release below the completion threshold with no forward velocity.
        dragFromLeadingEdge(in: app, to: 0.15, holdAtEnd: 0.5)
    }

    @MainActor
    private func dragFromLeadingEdge(in app: XCUIApplication, to fraction: CGFloat, holdAtEnd: TimeInterval) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.45))
            .withOffset(CGVector(dx: 2, dy: 0))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: holdAtEnd)
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "hittable == true AND enabled == true"), evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func waitForGone(_ element: XCUIElement) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func waitForValue(_ value: String, on element: XCUIElement) {
        expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }
}
