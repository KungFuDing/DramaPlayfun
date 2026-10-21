import XCTest
import UIKit

/// Checks playback and interaction around capture. Simulator screenshots do not
/// establish that the device compositor excludes protected video pixels.
@MainActor
final class PlaybackCaptureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTheaterContinuesAfterScreenshotPauseResumeAndPageChange() throws {
        let app = launchTheater()
        let firstProgress = app.sliders["theater-progress-101"]
        waitForPlayableProgress(firstProgress)
        try assertContinuesAfterScreenshot(firstProgress, app: app, name: "Theater capture")

        let firstPage = app.otherElements["theater-video-101"]
        firstPage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        let resume = firstPage.buttons["Play video"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        try assertProgressStaysPaused(firstProgress)
        resume.tap()
        try assertProgressAdvances(firstProgress)

        let feed = app.scrollViews["theater-feed"]
        XCTAssertTrue(feed.exists)
        feed.swipeUp()
        let secondProgress = app.sliders["theater-progress-102"]
        waitForPlayableProgress(secondProgress)
        try assertContinuesAfterScreenshot(secondProgress, app: app, name: "Theater next video capture")
    }

    func testDetailContinuesAfterScreenshotPauseResumeAndReentry() throws {
        let app = launchTheater()
        waitForPlayableProgress(app.sliders["theater-progress-101"])
        openDetailPlayer(app)

        let progress = app.sliders["player-progress-1"]
        waitForPlayableProgress(progress)
        try assertContinuesAfterScreenshot(progress, app: app, name: "Detail capture") {
            self.revealDetailControls(app)
        }

        revealDetailControls(app)
        let pause = app.buttons["player-pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        let resume = app.otherElements["player-episode-1"].buttons["Play video"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        try assertProgressStaysPaused(progress)
        resume.tap()
        try assertProgressAdvances(progress) { self.revealDetailControls(app) }

        revealDetailControls(app)
        app.buttons["player-back"].tap()
        waitForPlayableProgress(app.sliders["theater-progress-101"])
        openDetailPlayer(app)
        waitForPlayableProgress(progress)
        try assertContinuesAfterScreenshot(progress, app: app, name: "Detail reentry capture") {
            self.revealDetailControls(app)
        }
    }

    private func launchTheater() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-TheaterUITestFixture", "-PlaybackProgressUITestFixture",
            "-profile.language.v1", "en",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            // Ignore persisted watch history from an earlier test run.
            "-library.progress.v1", "reset-for-ui-tests"
        ]
        app.launch()
        let theater = app.tabBars.buttons["Theater"]
        XCTAssertTrue(theater.waitForExistence(timeout: 15))
        theater.tap()
        return app
    }

    private func openDetailPlayer(_ app: XCUIApplication) {
        let episodes = app.buttons["More episodes, 剧场测试甲"]
        XCTAssertTrue(episodes.waitForExistence(timeout: 5))
        episodes.tap()
        XCTAssertTrue(app.buttons["player-episodes"].waitForExistence(timeout: 10))
        revealDetailControls(app)
    }

    private func revealDetailControls(_ app: XCUIApplication) {
        // The upper video area avoids both the central pause button and metadata.
        app.scrollViews["player-episode-feed"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
    }

    private func waitForPlayableProgress(_ slider: XCUIElement,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            slider.exists && slider.isEnabled && self.progressFraction(slider) != nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed,
                       "The local fixture must be ready for playback", file: file, line: line)
    }

    private func assertContinuesAfterScreenshot(_ slider: XCUIElement, app: XCUIApplication,
                                                name: String, revealControls: (() -> Void)? = nil,
                                                file: StaticString = #filePath, line: UInt = #line) throws {
        try assertProgressAdvances(slider, revealControls: revealControls, file: file, line: line)
        revealControls?()
        let before = try XCTUnwrap(progressFraction(slider), file: file, line: line)
        let screenshot = app.screenshot()
        let capture = XCTAttachment(screenshot: screenshot)
        capture.name = name
        capture.lifetime = .keepAlways
        add(capture)
        try assertVideoPixelsMatchRuntime(screenshot, file: file, line: line)
        assertProgressAdvances(slider, after: before, revealControls: revealControls, file: file, line: line)
    }

    private func assertVideoPixelsMatchRuntime(_ screenshot: XCUIScreenshot,
                                              file: StaticString, line: UInt) throws {
        let image = try XCTUnwrap(screenshot.image.cgImage, file: file, line: line)
        // Both portrait pages show video here, away from their controls. Sample
        // real captured pixels; a screenshot attachment alone is not a check.
        let sampleRect = CGRect(x: CGFloat(image.width) * 0.5 - 8,
                                y: CGFloat(image.height) * 0.3 - 8,
                                width: 16, height: 16).integral
        let sample = try XCTUnwrap(image.cropping(to: sampleRect), file: file, line: line)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB), file: file, line: line)
        let context = try XCTUnwrap(CGContext(data: nil, width: sample.width, height: sample.height,
            bitsPerComponent: 8, bytesPerRow: sample.width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            file: file, line: line)
        context.draw(sample, in: CGRect(x: 0, y: 0, width: CGFloat(sample.width), height: CGFloat(sample.height)))
        let data = try XCTUnwrap(context.data, file: file, line: line)
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var darkestChannel: UInt8 = .max
        var brightestChannel: UInt8 = 0
        for offset in stride(from: 0, to: sample.width * sample.height * 4, by: 4) {
            darkestChannel = min(darkestChannel,
                min(pixels[offset], min(pixels[offset + 1], pixels[offset + 2])))
            brightestChannel = max(brightestChannel,
                max(pixels[offset], max(pixels[offset + 1], pixels[offset + 2])))
        }
        #if targetEnvironment(simulator)
        // The gray fixture is RGB 47–56 before the controls' slight shading.
        // A running media clock or a ready renderer alone cannot establish that
        // the Simulator host actually displays video instead of a black surface.
        XCTAssertGreaterThan(darkestChannel, 25,
            "The Simulator must visibly render the gray video fixture", file: file, line: line)
        #else
        XCTAssertLessThanOrEqual(brightestChannel, 16,
            "Captured video pixels must be near black on a physical device", file: file, line: line)
        #endif
    }

    private func assertProgressAdvances(_ slider: XCUIElement, revealControls: (() -> Void)? = nil,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        revealControls?()
        let before = try XCTUnwrap(progressFraction(slider), file: file, line: line)
        assertProgressAdvances(slider, after: before, revealControls: revealControls, file: file, line: line)
    }

    private func assertProgressAdvances(_ slider: XCUIElement, after before: Double,
                                        revealControls: (() -> Void)?,
                                        file: StaticString, line: UInt) {
        // Detail controls fade after five seconds. Refresh them between bounded
        // waits without pausing the player or seeking to manufacture progress.
        for _ in 0..<3 {
            revealControls?()
            let advances = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard slider.exists, let current = self.progressFraction(slider) else { return false }
                return current > before + 0.005
            }, object: nil)
            if XCTWaiter.wait(for: [advances], timeout: 3) == .completed { return }
        }
        XCTFail("Playback progress did not advance", file: file, line: line)
    }

    private func assertProgressStaysPaused(_ slider: XCUIElement,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        let paused = try XCTUnwrap(progressFraction(slider), file: file, line: line)
        let advances = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard slider.exists, let current = self.progressFraction(slider) else { return false }
            return current > paused + 0.01
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advances], timeout: 2), .timedOut,
                       "User pause must remain effective", file: file, line: line)
        XCTAssertTrue(slider.exists, file: file, line: line)
    }

    private func progressFraction(_ slider: XCUIElement) -> Double? {
        guard let value = slider.value as? String else { return nil }
        let number = value.replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(number) else { return nil }
        return value.contains("%") ? parsed / 100 : parsed
    }
}
