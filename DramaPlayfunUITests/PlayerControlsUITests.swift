import XCTest

final class PlayerControlsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPlaybackHidesControlsAndTapRevealsWithoutPausing() {
        let app = launchPlayer()
        let progress = app.sliders["player-progress-1"]
        waitForProgress(progress, above: 0)
        tapVideo(in: app)

        let prematureHide = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.buttons["player-back"])
        prematureHide.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [prematureHide], timeout: 3), .completed,
                       "播放未满 5 秒时应保留操作控件")
        waitForControlsToHide(in: app)
        assertControlsHidden(in: app, episode: 1)
        assertBottomControlsAvailable(in: app)
        let immersive = XCTAttachment(screenshot: app.screenshot())
        immersive.name = "播放五秒后仅显示视频与底部选集模块"
        immersive.lifetime = .keepAlways
        add(immersive)

        tapVideo(in: app)
        XCTAssertTrue(app.buttons["player-back"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["player-pause"].isHittable)
        XCTAssertTrue(app.staticTexts["theater-summary-text"].exists)
        let revealedProgress = progressValue(progress)
        waitForProgress(progress, above: revealedProgress)
        XCTAssertFalse(app.buttons["播放影片"].exists, "唤出控件不能同时暂停视频")

        app.buttons["player-pause"].tap()
        XCTAssertTrue(app.buttons["播放影片"].waitForExistence(timeout: 2))
        let hidesWhilePaused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.buttons["player-back"])
        hidesWhilePaused.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [hidesWhilePaused], timeout: 6), .completed,
                       "暂停期间不应继续计算自动隐藏时间")
        app.buttons["播放影片"].tap()
        waitForControlsToHide(in: app)
        assertControlsHidden(in: app, episode: 1)
        assertBottomControlsAvailable(in: app)
    }

    @MainActor
    func testHiddenControlsPersistAcrossAutomaticAndSelectedNextEpisode() {
        let app = launchPlayer()
        let progress = app.sliders["player-progress-1"]
        waitForProgress(progress, above: 0)
        // The bundled video is 60 seconds long. Leave about 12 seconds so
        // controls hide before the video naturally advances to episode 2.
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.8))
            .press(forDuration: 0.1, thenDragTo: progress.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)))
        // Wait for playback to advance beyond the seek preview.
        waitForProgress(progress, above: 82)
        waitForControlsToHide(in: app)
        assertControlsHidden(in: app, episode: 1)

        let feed = app.scrollViews["player-episode-feed"]
        expectation(for: NSPredicate(format: "value == %@", "第2集"), evaluatedWith: feed)
        waitForExpectations(timeout: 15)
        assertControlsHidden(in: app, episode: 2)
        assertBottomControlsAvailable(in: app)

        app.buttons["player-quality"].tap()
        XCTAssertTrue(app.otherElements["player-quality-panel"].waitForExistence(timeout: 2))
        app.buttons["player-quality-720"].tap()
        XCTAssertEqual(app.buttons["player-quality"].value as? String, "720P")
        assertControlsHidden(in: app, episode: 2)

        app.buttons["player-speed"].tap()
        XCTAssertTrue(app.otherElements["player-speed-panel"].waitForExistence(timeout: 2))
        app.buttons["player-speed-1.5"].tap()
        XCTAssertEqual(app.buttons["player-speed"].value as? String, "1.5x")
        assertControlsHidden(in: app, episode: 2)

        app.buttons["player-episodes"].tap()
        XCTAssertTrue(app.buttons["episode-selection-3"].waitForExistence(timeout: 2))
        app.buttons["episode-selection-3"].tap()
        expectation(for: NSPredicate(format: "value == %@", "第3集"), evaluatedWith: feed)
        waitForExpectations(timeout: 5)
        assertControlsHidden(in: app, episode: 3)
        assertBottomControlsAvailable(in: app)

        tapVideo(in: app)
        XCTAssertTrue(app.buttons["player-back"].waitForExistence(timeout: 2))
        waitForProgress(app.sliders["player-progress-3"], above: 0)
        XCTAssertTrue(app.buttons["player-pause"].isHittable)
    }

    @MainActor
    private func launchPlayer() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-PlayerUnlockUITestFixture", "-PlaybackProgressUITestFixture",
            "-profile.language.v1", "zh-Hant", "-library.progress.v1", "{}"
        ]
        app.launch()
        let banner = app.buttons["推薦劇集，推荐测试"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        banner.tap()
        XCTAssertTrue(app.scrollViews["player-episode-feed"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.scrollViews["player-episode-feed"].value as? String, "第1集")
        return app
    }

    @MainActor
    private func tapVideo(in app: XCUIApplication) {
        app.scrollViews["player-episode-feed"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
    }

    @MainActor
    private func waitForControlsToHide(in app: XCUIApplication) {
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.buttons["player-back"])
        let result = XCTWaiter.wait(for: [hidden], timeout: 8)
        XCTAssertEqual(result, .completed, app.debugDescription)
    }

    @MainActor
    private func assertControlsHidden(in app: XCUIApplication, episode: Int) {
        let page = app.otherElements["player-episode-\(episode)"]
        XCTAssertFalse(app.buttons["player-back"].exists)
        XCTAssertFalse(app.buttons["player-more"].exists)
        XCTAssertFalse(app.buttons["player-pause"].exists)
        XCTAssertFalse(app.sliders["player-progress-\(episode)"].exists)
        XCTAssertFalse(page.staticTexts["theater-summary-text"].exists)
        for prefix in ["drama-detail-title-", "theater-like-", "theater-favorite-", "theater-share-"] {
            XCTAssertEqual(page.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).count, 0)
        }
    }

    @MainActor
    private func assertBottomControlsAvailable(in app: XCUIApplication) {
        for identifier in ["player-episodes", "player-quality", "player-speed"] {
            XCTAssertTrue(app.buttons[identifier].isHittable, "\(identifier) 在沉浸播放时仍应可操作")
        }
    }

    @MainActor
    private func progressValue(_ progress: XCUIElement) -> Double {
        Double((progress.value as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? -1
    }

    @MainActor
    private func waitForProgress(_ progress: XCUIElement, above minimum: Double) {
        expectation(for: NSPredicate { _, _ in
            guard progress.exists else { return false }
            let value = Double((progress.value as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? -1
            return progress.isEnabled && value > minimum
        }, evaluatedWith: progress)
        waitForExpectations(timeout: 5)
    }
}

extension XCUIApplication {
    @MainActor
    func revealPlayerControlsIfNeeded() {
        guard !buttons["player-back"].isHittable else { return }
        scrollViews["player-episode-feed"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        let visible = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: buttons["player-back"])
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 2), .completed)
    }
}
