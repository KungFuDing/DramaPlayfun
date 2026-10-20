import XCTest

final class PlayerUnlockUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSufficientBalanceUnlocksOnlyOnceAndKeepsPlaying() throws {
        let app = launchPlayer(arguments: ["-PlayerUnlockSufficientBalance"])
        selectEpisode(6, in: app)
        let toast = app.staticTexts["player-unlock-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        XCTAssertTrue(toast.label.contains("20金幣"))
        assertPlayable(6, in: app)
        let progress = app.sliders["player-progress-6"]
        let start = Double((progress.value as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? -1
        expectation(for: NSPredicate { _, _ in
            let current = Double((progress.value as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? -1
            return current > start
        }, evaluatedWith: progress)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.otherElements["player-unlock-dialog"].exists)
        XCTAssertFalse(app.otherElements["player-unlock-confirmation"].exists)

        selectEpisode(5, in: app)
        selectEpisode(6, in: app)
        assertPlayable(6, in: app)
        XCTAssertFalse(app.otherElements["player-unlock-dialog"].exists)
        openWallet(fromPlayer: app)
        XCTAssertEqual(app.staticTexts["wallet-balance"].label, "80", "重看已解锁集不能重复扣币")
    }

    @MainActor
    func testContinuousPlaybackUnlocksTheNextPaidEpisode() throws {
        let app = launchPlayer(arguments: ["-PlayerUnlockSufficientBalance"])
        selectEpisode(6, in: app)
        assertPlayable(6, in: app)
        let progress = app.sliders["player-progress-6"]
        scrubNearEnd(progress)
        expectation(for: NSPredicate(format: "value == %@", "第7集"),
                    evaluatedWith: app.scrollViews["player-episode-feed"])
        waitForExpectations(timeout: 15)
        assertPlayable(7, in: app)
        XCTAssertFalse(app.otherElements["player-unlock-dialog"].exists)
        XCTAssertFalse(app.otherElements["player-unlock-confirmation"].exists)
        openWallet(fromPlayer: app)
        XCTAssertEqual(app.staticTexts["wallet-balance"].label, "60", "连续播放只扣除第6、7集各20金币")
    }

    @MainActor
    func testAutoPlayOffRequiresConfirmationAndUnlocksWithSufficientBalance() throws {
        let app = launchPlayer(arguments: ["-PlayerUnlockSufficientBalance", "-PlayerUnlockAutoOff"])
        selectEpisode(6, in: app)
        XCTAssertTrue(app.otherElements["player-unlock-dialog"].waitForExistence(timeout: 5))
        app.buttons["player-unlock-coins"].tap()
        XCTAssertTrue(app.otherElements["player-unlock-confirmation"].waitForExistence(timeout: 5))
        let autoPlay = app.descendants(matching: .any)["player-unlock-autoplay"].firstMatch
        XCTAssertEqual(autoPlay.value as? String, "0")
        app.buttons["player-unlock-confirm"].tap()
        assertPlayable(6, in: app)
        XCTAssertFalse(app.otherElements["player-unlock-confirmation"].exists)
        XCTAssertFalse(app.otherElements["player-unlock-dialog"].exists)
        let progress = app.sliders["player-progress-6"]
        scrubNearEnd(progress)
        XCTAssertTrue(app.buttons["播放影片"].waitForExistence(timeout: 10))
        XCTAssertEqual(progress.value as? String, "100%", "应播放到本集结束，而不是在拖动时暂停")
        XCTAssertEqual(app.scrollViews["player-episode-feed"].value as? String, "第6集",
                       "关闭自动播放后本集结束应停留当前集")
        openWallet(fromPlayer: app)
        XCTAssertEqual(app.staticTexts["wallet-balance"].label, "80")
        XCTAssertEqual(app.descendants(matching: .any)["wallet-autoplay"].firstMatch.value as? String, "0")
    }

    @MainActor
    func testVIPPlaysPaidEpisodesWithoutSpendingCoins() throws {
        let app = launchPlayer(arguments: ["-PlayerUnlockVIP"])
        selectEpisode(6, in: app)
        assertPlayable(6, in: app)
        XCTAssertFalse(app.otherElements["player-unlock-dialog"].exists)
        selectEpisode(7, in: app)
        assertPlayable(7, in: app)
        XCTAssertFalse(app.otherElements["player-unlock-dialog"].exists)
        XCTAssertFalse(app.staticTexts["player-unlock-toast"].exists)
        openWallet(fromPlayer: app)
        XCTAssertEqual(app.staticTexts["wallet-balance"].label, "5", "VIP权益播放不得扣金币")
    }

    @MainActor
    func testConfirmationAndWalletShareAutoPlaySetting() throws {
        let app = launchPlayer()
        selectEpisode(6, in: app)
        XCTAssertTrue(app.buttons["player-unlock-coins"].waitForExistence(timeout: 5))
        let unlockLayer = XCTAttachment(screenshot: app.screenshot())
        unlockLayer.name = "播放详情页-一级解锁浮层"
        unlockLayer.lifetime = .keepAlways
        add(unlockLayer)
        app.buttons["player-unlock-coins"].tap()
        let autoPlay = app.descendants(matching: .any)["player-unlock-autoplay"].firstMatch
        XCTAssertTrue(autoPlay.waitForExistence(timeout: 5))
        let confirmation = XCTAttachment(screenshot: app.screenshot())
        confirmation.name = "播放详情页-二次确认解锁-自动解锁开启"
        confirmation.lifetime = .keepAlways
        add(confirmation)
        XCTAssertEqual(autoPlay.value as? String, "1", "首次使用默认打开自动解锁")
        autoPlay.tap()
        expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: autoPlay)
        waitForExpectations(timeout: 5)
        app.buttons["player-unlock-close"].tap()
        openWallet(fromPlayer: app)
        let walletAutoPlay = app.descendants(matching: .any)["wallet-autoplay"].firstMatch
        XCTAssertEqual(walletAutoPlay.value as? String, "0")
        walletAutoPlay.tap()
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: walletAutoPlay)
        waitForExpectations(timeout: 5)
        app.buttons["wallet-back"].tap()
        app.tabBars.buttons["首頁"].tap()
        let banner = app.buttons["推薦劇集，推荐测试"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        banner.tap()
        selectEpisode(6, in: app)
        XCTAssertTrue(app.buttons["player-unlock-coins"].waitForExistence(timeout: 5))
        app.buttons["player-unlock-coins"].tap()
        XCTAssertTrue(autoPlay.waitForExistence(timeout: 5))
        XCTAssertEqual(autoPlay.value as? String, "1", "钱包设置修改后确认弹窗应读取同一状态")
    }

    @MainActor
    private func launchPlayer(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // Ignore persisted playback history from previous app launches in this suite.
        app.launchArguments = ["-profile.language.v1", "zh-Hant",
                               "-PlayerUnlockUITestFixture", "-PlaybackProgressUITestFixture",
                               "-library.progress.v1", "{}"] + arguments
        app.launch()
        let banner = app.buttons["推薦劇集，推荐测试"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        banner.tap()
        XCTAssertTrue(app.scrollViews["player-episode-feed"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.scrollViews["player-episode-feed"].value as? String, "第1集")
        return app
    }

    @MainActor
    private func selectEpisode(_ number: Int, in app: XCUIApplication) {
        app.buttons["player-episodes"].tap()
        let episode = app.buttons["episode-selection-\(number)"]
        XCTAssertTrue(episode.waitForExistence(timeout: 5))
        episode.tap()
        expectation(for: NSPredicate(format: "value == %@", "第\(number)集"),
                    evaluatedWith: app.scrollViews["player-episode-feed"])
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func assertPlayable(_ number: Int, in app: XCUIApplication) {
        app.revealPlayerControlsIfNeeded()
        let progress = app.sliders["player-progress-\(number)"]
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: progress)
        waitForExpectations(timeout: 10)
    }

    @MainActor
    private func scrubNearEnd(_ progress: XCUIElement) {
        // Use the visible track and leave fewer than 5 seconds, so the replay
        // control is still visible when the auto-play-off scenario finishes.
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.8))
            .press(forDuration: 0.1, thenDragTo: progress.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8)))
        expectation(for: NSPredicate { _, _ in
            guard progress.exists else { return false }
            let value = Double((progress.value as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? -1
            return value >= 85
        }, evaluatedWith: progress)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func openWallet(fromPlayer app: XCUIApplication) {
        app.revealPlayerControlsIfNeeded()
        app.buttons["player-back"].tap()
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 5))
        app.tabBars.buttons["我的"].tap()
        let wallet = app.buttons["profile-wallet"]
        XCTAssertTrue(wallet.waitForExistence(timeout: 5))
        wallet.tap()
        let balance = app.staticTexts["wallet-balance"]
        XCTAssertTrue(balance.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label != %@", "—"), evaluatedWith: balance)
        waitForExpectations(timeout: 5)
    }
}
