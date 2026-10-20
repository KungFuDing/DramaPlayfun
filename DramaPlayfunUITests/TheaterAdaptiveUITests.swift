import XCTest

final class TheaterAdaptiveUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHomeStartupEntersTheaterWithPlayableFirstEpisode() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TheaterUITestFixture", "-PlaybackProgressUITestFixture",
            "-profile.language.v1", "zh-Hant"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["home-search"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["home-banner"].exists)
        XCTAssertFalse(app.buttons["theater-favorite-101"].isHittable,
                       "Startup should remain on the home tab while theater playback is prepared")

        let theaterButtons = app.buttons.matching(NSPredicate(format: "label == %@", "劇場"))
        guard let theater = theaterButtons.allElementsBoundByIndex.first(where: \.isHittable) else {
            XCTFail("The theater tab must be available from home")
            return
        }
        theater.tap()
        let progress = app.sliders["theater-progress-101"]
        XCTAssertTrue(progress.waitForExistence(timeout: 2))
        XCTAssertTrue(progress.isEnabled, "The prepared first episode should be playable upon entry")
        XCTAssertFalse(app.activityIndicators.firstMatch.exists)
        expectation(for: NSPredicate { _, _ in
            ((progress.value as? NSString)?.doubleValue ?? 0) > 0
        }, evaluatedWith: progress)
        waitForExpectations(timeout: 3)
    }

    @MainActor
    func testTheaterControlsRespondAtCurrentDeviceSize() {
        let app = launchTheater()
        exerciseControls(in: app, dramaID: 101, title: "剧场测试甲")
        capture(app, "剧场当前尺寸点击回归")
    }

    @MainActor
    func testLoadedShareClosesFromCenterAndHitTargetEdges() {
        let app = launchTheater()
        let share = app.buttons["theater-share-101"]
        let close = app.buttons["關閉分享"]
        let qrCode = app.images["短劇分享 QR Code"]
        let save = app.buttons["儲存至相簿"]
        let tapPoints: [(String, CGVector)] = [
            ("中心", CGVector(dx: 0.5, dy: 0.5)),
            ("左边缘", CGVector(dx: 0.05, dy: 0.5)),
            ("右边缘", CGVector(dx: 0.95, dy: 0.5)),
            ("上边缘", CGVector(dx: 0.5, dy: 0.05)),
            ("下边缘", CGVector(dx: 0.5, dy: 0.95))
        ]

        for (name, point) in tapPoints {
            waitForHittable(share)
            share.tap()
            XCTAssertTrue(qrCode.waitForExistence(timeout: 10), "应等海报二维码加载完成后测试关闭")
            XCTAssertTrue(save.waitForExistence(timeout: 5), "应显示加载完成后的保存按钮")
            waitForHittable(close)
            XCTAssertGreaterThanOrEqual(close.frame.width, 44)
            XCTAssertGreaterThanOrEqual(close.frame.height, 44)
            if name == "中心" { capture(app, "分享海报加载后关闭按钮位置") }

            // Coordinate taps verify the visible button and its padded hit area;
            // an accessibility-directed tap can choose another hittable point.
            close.coordinate(withNormalizedOffset: point).tap()
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: close)
            waitForExpectations(timeout: 5)
            XCTAssertFalse(qrCode.exists, "点击关闭按钮\(name)后海报二维码应消失")
            waitForHittable(share)
        }
    }

    @MainActor
    func testTheaterControlsRespondAfterLandscapeAndPortraitRotation() {
        let originalOrientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = originalOrientation }

        XCUIDevice.shared.orientation = .portrait
        let app = launchTheater()

        XCUIDevice.shared.orientation = .landscapeLeft
        // A window or a secondary display can retain its size when the device
        // rotates. Verify the controls in the resulting scene in either case.
        waitForHittable(app.buttons["theater-favorite-101"])
        exerciseControls(in: app, dramaID: 101, title: "剧场测试甲")
        capture(app, "剧场横屏点击回归")

        XCUIDevice.shared.orientation = .portrait
        waitForHittable(app.buttons["theater-favorite-101"])
        exerciseControls(in: app, dramaID: 101, title: "剧场测试甲")
        capture(app, "剧场旋转回竖屏点击回归")
    }

    @MainActor
    func testAdjacentArtworkDoesNotInterceptControlsAfterPaging() {
        let app = launchTheater()
        let feed = app.scrollViews["theater-feed"]
        let dramas = [(101, "剧场测试甲"), (102, "剧场测试乙"), (103, "剧场测试丙")]

        for (index, drama) in dramas.enumerated() {
            if index > 0 { swipeFeed(feed, upward: true) }
            let favorite = app.buttons["theater-favorite-\(drama.0)"]
            waitForHittable(favorite)
            for other in dramas where other.0 != drama.0 {
                XCTAssertFalse(app.buttons["theater-favorite-\(other.0)"].isHittable,
                    "相邻剧集的封面及按钮不应侵入当前页的点击区域")
            }

            assertControlsFit(in: feed, app: app, dramaID: drama.0, title: drama.1)
            toggleLike(in: app, dramaID: drama.0)
            favorite.tap()
            waitForLabel("取消收藏", on: favorite)
            openAndCloseShare(in: app, dramaID: drama.0)
            openEpisodesAndReturn(in: app, title: drama.1)
        }

        // Return through both cached pages. Their actions must still target the
        // corresponding drama after another page and the player were presented.
        for drama in dramas.dropLast().reversed() {
            swipeFeed(feed, upward: false)
            let favorite = app.buttons["theater-favorite-\(drama.0)"]
            waitForHittable(favorite)
            XCTAssertEqual(favorite.label, "取消收藏")
            favorite.tap()
            waitForLabel("收藏", on: favorite)
        }
        capture(app, "剧场上下翻页后点击回归")
    }

    @MainActor
    private func launchTheater() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TheaterUITestFixture", "-TheaterArtworkUITestFixture",
            "-profile.language.v1", "zh-Hant"
        ]
        app.launch()

        // UIKit may place these buttons in a bottom tab bar, a top tab bar, or
        // the sidebar. Query the visible button rather than a tab-bar ancestor.
        let theaterButtons = app.buttons.matching(NSPredicate(format: "label == %@", "劇場"))
        expectation(for: NSPredicate { _, _ in
            theaterButtons.allElementsBoundByIndex.contains(where: \.isHittable)
        }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        guard let theater = theaterButtons.allElementsBoundByIndex.first(where: \.isHittable) else {
            XCTFail("应能找到当前位置可点击的剧场入口")
            return app
        }
        theater.tap()
        waitForHittable(app.buttons["theater-favorite-101"])
        return app
    }

    @MainActor
    private func exerciseControls(in app: XCUIApplication, dramaID: Int, title: String) {
        let feed = app.scrollViews["theater-feed"]
        assertControlsFit(in: feed, app: app, dramaID: dramaID, title: title)
        toggleLike(in: app, dramaID: dramaID)

        let favorite = app.buttons["theater-favorite-\(dramaID)"]
        favorite.tap()
        waitForLabel("取消收藏", on: favorite)
        favorite.tap()
        waitForLabel("收藏", on: favorite)

        let page = app.otherElements["theater-video-\(dramaID)"]
        let expand = page.buttons["展開"]
        waitForHittable(expand)
        expand.tap()
        XCTAssertTrue(page.scrollViews["theater-summary-scroll"].waitForExistence(timeout: 5))
        let collapse = page.buttons["收起"]
        waitForHittable(collapse)
        collapse.tap()
        waitForHittable(expand)

        openAndCloseShare(in: app, dramaID: dramaID)
        openEpisodesAndReturn(in: app, title: title)
    }

    @MainActor
    private func toggleLike(in app: XCUIApplication, dramaID: Int) {
        let like = app.buttons["theater-like-\(dramaID)"]
        waitForHittable(like)
        like.tap()
        waitForLabel("取消按讚", on: like)
        like.tap()
        waitForLabel("按讚", on: like)
    }

    @MainActor
    private func openAndCloseShare(in app: XCUIApplication, dramaID: Int) {
        let share = app.buttons["theater-share-\(dramaID)"]
        waitForHittable(share)
        share.tap()
        let close = app.buttons["關閉分享"]
        waitForHittable(close)
        close.tap()
        waitForHittable(share)
    }

    @MainActor
    private func openEpisodesAndReturn(in app: XCUIApplication, title: String) {
        let moreEpisodes = app.buttons["更多劇集，\(title)"]
        waitForHittable(moreEpisodes)
        moreEpisodes.tap()
        let episodes = app.buttons["player-episodes"]
        waitForHittable(episodes)
        episodes.tap()
        let panel = app.otherElements["player-episodes-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        waitForHittable(app.buttons["episode-selection-1"])
        let close = panel.buttons["關閉選集"]
        waitForHittable(close)
        close.tap()
        waitForHittable(episodes)
        let back = app.buttons["player-back"]
        waitForHittable(back)
        back.tap()
        waitForHittable(moreEpisodes)
    }

    @MainActor
    private func assertControlsFit(in feed: XCUIElement, app: XCUIApplication, dramaID: Int, title: String) {
        let controls = [
            app.buttons["theater-like-\(dramaID)"],
            app.buttons["theater-favorite-\(dramaID)"],
            app.buttons["theater-share-\(dramaID)"],
            app.buttons["更多劇集，\(title)"]
        ]
        for control in controls {
            waitForHittable(control)
            XCTAssertTrue(feed.frame.insetBy(dx: -1, dy: -1).contains(control.frame),
                "\(control.identifier) 应位于当前剧场可见区域内")
        }
    }

    @MainActor
    private func swipeFeed(_ feed: XCUIElement, upward: Bool) {
        // Avoid the right-side actions, bottom metadata, and the central
        // playback retry UI used by the offline network fixture.
        let upper = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.2))
        let lower = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.75))
        let start = upward ? lower : upper
        let end = upward ? upper : lower
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "hittable == true AND enabled == true"), evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func waitForLabel(_ label: String, on element: XCUIElement) {
        expectation(for: NSPredicate(format: "label == %@ AND enabled == true", label), evaluatedWith: element)
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
