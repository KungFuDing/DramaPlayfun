import AVFoundation
import Network
import UIKit
import Vision
import XCTest
@testable import DramaPlayfun

/// Exercises real decoded frames and playback lifecycle. System capture exclusion
/// itself must also be verified with hardware screenshots and recordings on device.
@MainActor
final class PlaybackCaptureTests: XCTestCase {
    func testProtectedSurfaceRendersWhilePlaybackContinuesAtSelectedRate() async throws {
        let host = PlayerSurfaceTestWindow()
        let surface = CaptureProtectedPlayerView()
        host.mount(surface)
        let player = try makePlayer()
        defer {
            surface.setPlayer(nil)
            player.pause()
            host.close()
        }

        surface.setPlayer(player)
        player.playImmediately(atRate: 1.5)
        let rendered = await waitUntil {
            isRendering(surface)
                && player.currentTime().seconds > 0.1
        }
        XCTAssertTrue(rendered, "The protected layer must actually render decoded video")
        assertCaptureProtectionMatchesPlatform(surface)
        XCTAssertEqual(surface.backgroundColor, .black)
        XCTAssertTrue(surface.isOpaque)

        let start = player.currentTime().seconds
        // Screenshot notification must not alter playback, audio or playback speed.
        NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        let advanced = await waitUntil { player.currentTime().seconds > start + 0.5 }
        XCTAssertTrue(advanced)
        XCTAssertEqual(player.rate, 1.5)
        XCTAssertFalse(player.isMuted)
        XCTAssertEqual(surface.videoLayer.sampleBufferRenderer.status, .rendering)
    }

    func testPauseSeekAndResumeKeepProtectedRenderingAvailable() async throws {
        let host = PlayerSurfaceTestWindow()
        let surface = CaptureProtectedPlayerView()
        host.mount(surface)
        let player = try makePlayer()
        defer {
            surface.setPlayer(nil)
            player.pause()
            host.close()
        }
        surface.setPlayer(player)
        player.play()
        let rendered = await waitUntil {
            isRendering(surface)
                && player.currentTime().seconds > 0.2
        }
        XCTAssertTrue(rendered)

        player.pause()
        let pausedTime = player.currentTime().seconds
        try await _Concurrency.Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(player.currentTime().seconds, pausedTime, accuracy: 0.08)
        XCTAssertEqual(surface.videoLayer.sampleBufferRenderer.status, .rendering,
                       "Pausing retains the last protected frame")

        let sought = await player.seek(to: CMTime(seconds: 3, preferredTimescale: 600),
                                       toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(sought)
        XCTAssertEqual(player.currentTime().seconds, 3, accuracy: 0.1)
        XCTAssertEqual(player.rate, 0, "The surface must not resume a paused seek")
        player.playImmediately(atRate: 2)
        let resumed = await waitUntil {
            player.currentTime().seconds > 3.5
                && isRendering(surface)
        }
        XCTAssertTrue(resumed, "The display link must wake after a paused seek")
        XCTAssertEqual(player.rate, 2)
        assertCaptureProtectionMatchesPlatform(surface)
    }

    func testReplacingCurrentItemKeepsPreparedOutputsAndRendersReplacement() async throws {
        let host = PlayerSurfaceTestWindow()
        let surface = CaptureProtectedPlayerView()
        host.mount(surface)
        let player = try makePlayer()
        let original = try XCTUnwrap(player.currentItem)
        let originalOutput = try XCTUnwrap(original.outputs.first)
        defer {
            surface.setPlayer(nil)
            player.pause()
            host.close()
        }
        surface.setPlayer(player)
        surface.setPlayer(player)
        player.play()
        let firstRendered = await waitUntil { isRendering(surface) }
        XCTAssertTrue(firstRendered)
        XCTAssertEqual(original.outputs.count, 2, "SwiftUI updates must not duplicate outputs")

        let replacement = AVPlayerItem(url: try fixtureURL())
        CaptureProtectedVideoOutput.prepare(replacement)
        let replacementOutput = try XCTUnwrap(replacement.outputs.first)
        player.replaceCurrentItem(with: replacement)
        XCTAssertTrue(original.outputs.first === originalOutput)
        XCTAssertEqual(original.outputs.count, 2, "The output belongs to its item, not the view")
        XCTAssertTrue(surface.player === player)
        player.play()
        let replacementRendered = await waitUntil {
            isRendering(surface)
                && player.currentTime().seconds > 0.2
        }
        XCTAssertTrue(replacementRendered)
        surface.setPlayer(nil)
        XCTAssertEqual(replacement.outputs.count, 2)
        XCTAssertTrue(replacement.outputs.first === replacementOutput)
        XCTAssertNil(surface.player)
    }

    func testRemovingAndRemountingSurfacePreservesPlayerAndReleasesView() async throws {
        let host = PlayerSurfaceTestWindow()
        var surface: CaptureProtectedPlayerView? = CaptureProtectedPlayerView()
        weak let releasedSurface = surface
        let player = try makePlayer()
        let item = try XCTUnwrap(player.currentItem)
        let output = try XCTUnwrap(item.outputs.first)
        defer {
            surface?.setPlayer(nil)
            surface?.removeFromSuperview()
            player.pause()
            host.close()
        }
        host.mount(try XCTUnwrap(surface))
        surface?.setPlayer(player)
        player.play()
        let initialRender = await waitUntil { surface.map(isRendering) == true }
        XCTAssertTrue(initialRender)

        surface?.removeFromSuperview()
        XCTAssertEqual(item.outputs.count, 2)
        XCTAssertTrue(item.outputs.first === output, "Detaching a page must not reset the item's video destination")
        let detachedTime = player.currentTime().seconds
        let keptPlaying = await waitUntil { player.currentTime().seconds > detachedTime + 0.3 }
        XCTAssertTrue(keptPlaying, "The rendering view must not pause the shared player")

        host.mount(try XCTUnwrap(surface))
        let remounted = await waitUntil {
            item.outputs.count == 2 && surface.map(isRendering) == true
        }
        XCTAssertTrue(remounted, "A recycled page must recover rendering on remount")
        XCTAssertTrue(item.outputs.first === output)
        surface?.setPlayer(nil)
        surface?.removeFromSuperview()
        surface = nil
        let released = await waitUntil { releasedSurface == nil }
        XCTAssertTrue(released, "CADisplayLink and video-output callbacks must not retain the view")
        XCTAssertEqual(item.outputs.count, 2)
        XCTAssertTrue(item.outputs.first === output)
    }

    func testPreparedOutputIsReleasedWithItsItem() async throws {
        var item: AVPlayerItem? = AVPlayerItem(url: try fixtureURL())
        weak let releasedItem = item
        CaptureProtectedVideoOutput.prepare(try XCTUnwrap(item))
        weak let releasedOutput = item?.outputs.first
        weak let releasedSubtitleOutput = item?.outputs.last
        CaptureProtectedVideoOutput.prepare(try XCTUnwrap(item))
        XCTAssertEqual(item?.outputs.count, 2)
        XCTAssertTrue(item?.outputs.first === releasedOutput)
        item = nil
        let released = await waitUntil {
            releasedItem == nil && releasedOutput == nil && releasedSubtitleOutput == nil
        }
        XCTAssertTrue(released, "The persistent output must not keep its owning item alive")
    }

    func testEncryptedHLSRendersAndRecoversAfterPausedSeek() async throws {
        try await withHLS { server, url in
            let host = PlayerSurfaceTestWindow()
            let surface = CaptureProtectedPlayerView()
            host.mount(surface)
            let player = try makePlayer(url: url)
            let item = try XCTUnwrap(player.currentItem)
            let output = try XCTUnwrap(item.outputs.first)
            defer {
                surface.setPlayer(nil)
                player.pause()
                host.close()
            }
            surface.setPlayer(player)
            let ready = await waitUntil(timeout: 15) { item.status == .readyToPlay }
            guard ready else {
                XCTFail("AES-128 HLS did not become ready. \(renderingDiagnostics(player: player, surface: surface))")
                return
            }
            player.playImmediately(atRate: 1)
            let rendered = await waitUntil(timeout: 15) {
                isRendering(surface) && player.currentTime().seconds > 0.1
            }
            guard rendered else {
                XCTFail("AES-128 HLS did not display video. \(renderingDiagnostics(player: player, surface: surface)); requests: \(server.servedPaths.sorted())")
                return
            }
            XCTAssertTrue(server.servedPaths.contains("CaptureTestKey.bin"))
            XCTAssertTrue(server.servedPaths.contains("EncryptedCapture0.ts"))
            assertCaptureProtectionMatchesPlatform(surface)

            player.pause()
            try await _Concurrency.Task.sleep(for: .milliseconds(700))
            // Recycled pages clear their displayed image, but retain the item's output.
            // A ready layer after the seek must contain a newly decoded frame.
            surface.removeFromSuperview()
            let clearedBeforeSeek = await waitUntil { !isRendering(surface) }
            XCTAssertTrue(clearedBeforeSeek, "Detach must clear the old displayed frame")
            XCTAssertEqual(item.outputs.count, 2)
            XCTAssertTrue(item.outputs.first === output)
            let sought = await player.seek(to: CMTime(seconds: 3, preferredTimescale: 600),
                                           toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(sought)
            XCTAssertEqual(player.currentTime().seconds, 3, accuracy: 0.15)
            XCTAssertEqual(player.rate, 0)
            host.mount(surface)
            let pausedSeekFrame = await waitUntil { isRendering(surface) }
            XCTAssertTrue(pausedSeekFrame, "The seek result must display after remount without resuming playback. \(renderingDiagnostics(player: player, surface: surface))")
            XCTAssertEqual(player.rate, 0)
            XCTAssertEqual(player.currentTime().seconds, 3, accuracy: 0.15)

            // Reacquire the same paused frame after it has already been consumed.
            // No seek, rate change or newly decoded frame may be needed to repaint it.
            surface.removeFromSuperview()
            let clearedAgain = await waitUntil { !isRendering(surface) }
            XCTAssertTrue(clearedAgain)
            host.mount(surface)
            let pausedFrameRepainted = await waitUntil { isRendering(surface) }
            XCTAssertTrue(pausedFrameRepainted, "Remount must repaint an already-acquired paused frame. \(renderingDiagnostics(player: player, surface: surface))")
            XCTAssertEqual(player.rate, 0)
            XCTAssertEqual(player.currentTime().seconds, 3, accuracy: 0.15)

            player.playImmediately(atRate: 1)
            let resumed = await waitUntil(timeout: 10) {
                isRendering(surface) && player.currentTime().seconds > 3.4
            }
            XCTAssertTrue(resumed, "Encrypted HLS must render fresh video after seek and remount. \(renderingDiagnostics(player: player, surface: surface))")
            XCTAssertEqual(item.outputs.count, 2)
            XCTAssertTrue(item.outputs.first === output)
            assertCaptureProtectionMatchesPlatform(surface)
        }
    }

    func testEncryptedHLSPrewarmingBeforeLateSurfaceMountKeepsPlaybackWorking() async throws {
        try await withHLS { _, url in
            let player = try makePlayer(url: url)
            let item = try XCTUnwrap(player.currentItem)
            let output = try XCTUnwrap(item.outputs.first)
            defer { player.pause() }
            let ready = await waitUntil(timeout: 15) { item.status == .readyToPlay }
            XCTAssertTrue(ready, "Prewarming must become ready before any surface is mounted")
            guard ready else { return }
            let warmed = await player.preroll(atRate: 1)
            XCTAssertTrue(warmed)
            XCTAssertEqual(player.rate, 0)
            XCTAssertEqual(player.currentTime().seconds, 0, accuracy: 0.05)

            let host = PlayerSurfaceTestWindow()
            let surface = CaptureProtectedPlayerView()
            host.mount(surface)
            defer {
                surface.setPlayer(nil)
                host.close()
            }
            surface.setPlayer(player)
            player.playImmediately(atRate: 1)
            let rendered = await waitUntil(timeout: 15) {
                isRendering(surface) && player.currentTime().seconds > 0.2
            }
            XCTAssertTrue(rendered, "Late mounting must reuse the prewarmed HLS output without resetting playback. \(renderingDiagnostics(player: player, surface: surface))")
            XCTAssertEqual(item.outputs.count, 2)
            XCTAssertTrue(item.outputs.first === output)
            assertCaptureProtectionMatchesPlatform(surface)
        }
    }

    func testMountedEmptyPlayerPlaysPreparedEncryptedHLSItemOnceReady() async throws {
        try await withHLS { _, url in
            let host = PlayerSurfaceTestWindow()
            let surface = CaptureProtectedPlayerView()
            host.mount(surface)
            let player = AVPlayer()
            CaptureProtectedVideoOutput.configure(player)
            player.automaticallyWaitsToMinimizeStalling = false
            surface.setPlayer(player)
            defer {
                surface.setPlayer(nil)
                player.pause()
                host.close()
            }
            let item = AVPlayerItem(url: url)
            CaptureProtectedVideoOutput.prepare(item)
            let output = try XCTUnwrap(item.outputs.first)
            player.replaceCurrentItem(with: item)
            // Match TheaterPlayerPool: wait for readyToPlay, then start immediately
            // in the same actor turn without waiting on view rendering or KVO tasks.
            let ready = await waitUntil(timeout: 15) { item.status == .readyToPlay }
            guard ready else {
                XCTFail("Replacement HLS item did not become ready. \(renderingDiagnostics(player: player, surface: surface))")
                return
            }
            player.playImmediately(atRate: 1)
            let rendered = await waitUntil(timeout: 15) {
                isRendering(surface) && player.currentTime().seconds > 0.2
            }
            XCTAssertTrue(rendered, "An already-mounted player must start a prepared HLS item as soon as it is ready. \(renderingDiagnostics(player: player, surface: surface))")
            XCTAssertEqual(item.outputs.count, 2)
            XCTAssertTrue(item.outputs.first === output)
            assertCaptureProtectionMatchesPlatform(surface)
        }
    }

    func testSeparateFMP4RenditionsDisplayNonblackVideoAndResumeAfterSeek() async throws {
        try await withHLS(manifest: "SeparateCapture.m3u8") { server, url in
            let host = PlayerSurfaceTestWindow()
            let surface = CaptureProtectedPlayerView()
            host.mount(surface)
            let player = try makePlayer(url: url)
            let item = try XCTUnwrap(player.currentItem)
            defer {
                surface.setPlayer(nil)
                player.pause()
                host.close()
            }
            surface.setPlayer(player)
            let ready = await waitUntil(timeout: 15) { item.status == .readyToPlay }
            guard ready else {
                XCTFail("Separate fMP4 renditions did not become ready. \(renderingDiagnostics(player: player, surface: surface))")
                return
            }
            player.playImmediately(atRate: 1)
            let rendered = await waitUntil(timeout: 15) {
                isRendering(surface) && player.currentTime().seconds > 0.3
            }
            guard rendered else {
                XCTFail("Separate fMP4 renditions advanced without displaying video. \(renderingDiagnostics(player: player, surface: surface)); requests: \(server.servedPaths.sorted())")
                return
            }
            assertCaptureProtectionMatchesPlatform(surface)
            XCTAssertTrue(server.servedPaths.contains("SeparateCaptureVideo.mp4"))
            XCTAssertTrue(server.servedPaths.contains("SeparateCaptureAudio.m4a"))

            // Time and renderer readiness alone can pass while video is black.
            // Reacquire the paused decoded image and inspect its luminance plane.
            player.pause()
            let output = try XCTUnwrap(item.outputs.first as? AVPlayerItemVideoOutput)
            let pixels = try XCTUnwrap(output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil),
                                       "A rendered fMP4 frame must have real decoded pixels")
            let levels = try sampledLuminance(pixels)
            XCTAssertGreaterThan(levels.maximum, 80, "The synthetic color pattern must not decode as black")
            XCTAssertGreaterThan(Int(levels.maximum) - Int(levels.minimum), 32,
                                 "The synthetic color pattern must contain distinct light and dark regions")

            let sought = await player.seek(to: CMTime(seconds: 3, preferredTimescale: 600),
                                           toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(sought)
            XCTAssertEqual(player.rate, 0)
            player.playImmediately(atRate: 1.5)
            let resumed = await waitUntil {
                isRendering(surface) && player.currentTime().seconds > 3.5
            }
            XCTAssertTrue(resumed, "Separate audio and video renditions must continue rendering after a seek")
            XCTAssertEqual(player.rate, 1.5)
        }
    }

    func testHLSSubtitlesRemainVisibleAcrossPauseSeekRemountAndItemReplacement() async throws {
        #if targetEnvironment(simulator)
        try await withHLS(manifest: "SeparateCapture.m3u8") { server, url in
            let host = PlayerSurfaceTestWindow()
            let surface = CaptureProtectedPlayerView()
            host.mount(surface)
            let player = try makePlayer(url: url)
            let item = try XCTUnwrap(player.currentItem)
            let output = try XCTUnwrap(item.outputs.first as? AVPlayerItemVideoOutput)
            defer {
                surface.setPlayer(nil)
                player.pause()
                host.close()
            }
            surface.setPlayer(player)
            let ready = await waitUntil(timeout: 15) { item.status == .readyToPlay }
            XCTAssertTrue(ready)
            guard ready else { return }
            let loadedGroup = try await item.asset.loadMediaSelectionGroup(for: .legible)
            let group = try XCTUnwrap(loadedGroup)
            item.select(try XCTUnwrap(group.defaultOption ?? group.options.first), in: group)
            player.playImmediately(atRate: 1)
            let advanced = await waitUntil { player.currentTime().seconds > 0.5 }
            XCTAssertTrue(advanced)
            player.pause()
            try await assertSubtitle("Synthetic playback fixture", in: surface, name: "Paused first subtitle")
            try assertUpperVideoArea(captureSurface(surface), isBlack: false)
            XCTAssertTrue(server.servedPaths.contains("SeparateCaptureSubtitles.vtt"))
            XCTAssertTrue(output.suppressesPlayerRendering)

            // The subtitle layer must contain text only, with a transparent background.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.videoLayer.isHidden = true
            CATransaction.commit()
            try await assertSubtitle("Synthetic playback fixture", in: surface, name: "Subtitle without protected video")
            try assertUpperVideoArea(captureSurface(surface), isBlack: true)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.videoLayer.isHidden = false
            CATransaction.commit()

            let soughtGap = await player.seek(to: CMTime(seconds: 3, preferredTimescale: 600),
                                              toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(soughtGap)
            try await assertSubtitle(nil, in: surface, name: "Paused subtitle gap")
            XCTAssertEqual(player.rate, 0)

            player.playImmediately(atRate: 1)
            let reachedSecondCue = await waitUntil { player.currentTime().seconds > 4 }
            XCTAssertTrue(reachedSecondCue)
            player.pause()
            try await assertSubtitle("Second subtitle cue", in: surface, name: "Subtitle after seek and resume")
            let pausedTime = player.currentTime().seconds
            surface.removeFromSuperview()
            host.mount(surface)
            try await assertSubtitle("Second subtitle cue", in: surface, name: "Paused subtitle after remount")
            XCTAssertEqual(player.rate, 0)
            XCTAssertEqual(player.currentTime().seconds, pausedTime, accuracy: 0.05)
            XCTAssertEqual(item.outputs.count, 2)
            XCTAssertTrue(item.outputs.first === output)

            let replacement = AVPlayerItem(url: try fixtureURL())
            CaptureProtectedVideoOutput.prepare(replacement)
            player.replaceCurrentItem(with: replacement)
            player.playImmediately(atRate: 1)
            let replacementRendered = await waitUntil {
                replacement.status == .readyToPlay && player.currentTime().seconds > 0.2 && isRendering(surface)
            }
            XCTAssertTrue(replacementRendered)
            player.pause()
            try await assertSubtitle(nil, in: surface, name: "Replacement without subtitles")
            XCTAssertEqual(replacement.outputs.count, 2)
            assertCaptureProtectionMatchesPlatform(surface)
        }
        #else
        throw XCTSkip("Protected subtitles are excluded from device captures; verify local visibility on device")
        #endif
    }

    private func captureSurface(_ surface: UIView) throws -> CGImage {
        let image = UIGraphicsImageRenderer(bounds: surface.bounds).image { _ in
            surface.drawHierarchy(in: surface.bounds, afterScreenUpdates: true)
        }
        return try XCTUnwrap(image.cgImage)
    }

    private func assertSubtitle(_ expected: String?, in surface: UIView, name: String,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        var actual = ""
        repeat {
            // Allow the render server to commit a pause, seek, or remount first.
            try await _Concurrency.Task.sleep(for: .milliseconds(150))
            let image = try captureSurface(surface)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            actual = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ").lowercased()
            let matches = expected.map { actual.contains($0.lowercased()) }
                ?? (!actual.contains("synthetic") && !actual.contains("subtitle"))
            if matches || Date() >= deadline {
                let attachment = XCTAttachment(image: UIImage(cgImage: image))
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertTrue(matches, "Expected subtitle \(expected ?? "<none>"), recognized: \(actual)",
                              file: file, line: line)
                return
            }
        } while Date() < deadline
        XCTFail("Subtitle rendering timed out; recognized: \(actual)", file: file, line: line)
    }

    private func assertUpperVideoArea(_ image: CGImage, isBlack: Bool,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let sampleRect = CGRect(x: CGFloat(image.width) * 0.4, y: CGFloat(image.height) * 0.25,
                                width: CGFloat(image.width) * 0.2, height: CGFloat(image.height) * 0.1).integral
        let sample = try XCTUnwrap(image.cropping(to: sampleRect), file: file, line: line)
        let context = try XCTUnwrap(CGContext(data: nil, width: sample.width, height: sample.height,
            bitsPerComponent: 8, bytesPerRow: sample.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            file: file, line: line)
        context.draw(sample, in: CGRect(x: 0, y: 0, width: CGFloat(sample.width), height: CGFloat(sample.height)))
        let pixels = try XCTUnwrap(context.data, file: file, line: line).assumingMemoryBound(to: UInt8.self)
        let maximum = stride(from: 0, to: sample.width * sample.height * 4, by: 4).reduce(UInt8(0)) {
            max($0, max(pixels[$1], max(pixels[$1 + 1], pixels[$1 + 2])))
        }
        if isBlack {
            XCTAssertLessThanOrEqual(maximum, 16,
                "The subtitle layer must not display any video pixels", file: file, line: line)
        } else {
            #if targetEnvironment(simulator)
            XCTAssertGreaterThan(maximum, 80,
                "The transparent subtitle layer must not cover the visible video", file: file, line: line)
            #endif
        }
    }

    private func sampledLuminance(_ pixels: CVPixelBuffer) throws -> (minimum: UInt8, maximum: UInt8) {
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(pixels), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixels, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels, 0))
            .assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        var minimum = UInt8.max
        var maximum = UInt8.min
        for y in stride(from: 0, to: height, by: max(1, height / 16)) {
            for x in stride(from: 0, to: width, by: max(1, width / 16)) {
                let value = base[y * bytesPerRow + x]
                minimum = min(minimum, value)
                maximum = max(maximum, value)
            }
        }
        return (minimum, maximum)
    }

    private func withHLS(manifest: String = "EncryptedCapture.m3u8",
                         _ body: (HLSCaptureFixtureServer, URL) async throws -> Void) async throws {
        let server = try HLSCaptureFixtureServer(bundle: Bundle(for: Self.self), manifest: manifest)
        let url = try await server.start()
        let audioSession = AVAudioSession.sharedInstance()
        let previousCategory = audioSession.category
        let previousMode = audioSession.mode
        let previousOptions = audioSession.categoryOptions
        defer {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            try? audioSession.setCategory(previousCategory, mode: previousMode, options: previousOptions)
            server.stop()
        }
        try audioSession.setCategory(.playback, mode: .moviePlayback)
        try audioSession.setActive(true)
        try await body(server, url)
    }

    private func renderingDiagnostics(player: AVPlayer, surface: CaptureProtectedPlayerView) -> String {
        let item = player.currentItem
        let renderer = surface.videoLayer.sampleBufferRenderer
        let ready: String
        if #available(iOS 17.4, *) { ready = String(surface.videoLayer.isReadyForDisplay) }
        else { ready = "unavailable" }
        let captureAllowed: String
        if #available(iOS 26.4, *) { captureAllowed = String(player.allowsCaptureOfClearKeyVideo) }
        else { captureAllowed = "unavailable" }
        let bufferRanges = item?.loadedTimeRanges.map { value in
            let range = value.timeRangeValue
            return "\(range.start.seconds)...\(CMTimeRangeGetEnd(range).seconds)"
        } ?? []
        return "player.status=\(player.status.rawValue), item.status=\(item?.status.rawValue ?? -1), "
            + "time=\(player.currentTime().seconds), outputs=\(item?.outputs.count ?? 0), "
            + "rate=\(player.rate), timeControlStatus=\(player.timeControlStatus.rawValue), "
            + "reasonForWaiting=\(player.reasonForWaitingToPlay?.rawValue ?? "nil"), bufferRanges=\(bufferRanges), "
            + "renderer.status=\(renderer.status.rawValue), isReadyForDisplay=\(ready), "
            + "allowsCaptureOfClearKeyVideo=\(captureAllowed), "
            + "player.error=\(String(describing: item?.error)), renderer.error=\(String(describing: renderer.error))"
    }

    private func assertCaptureProtectionMatchesPlatform(_ surface: CaptureProtectedPlayerView,
                                                        file: StaticString = #filePath, line: UInt = #line) {
        #if targetEnvironment(simulator)
        XCTAssertFalse(surface.videoLayer.preventsCapture,
                       "Simulator cannot present a capture-protected layer; keep local playback visible",
                       file: file, line: line)
        XCTAssertFalse(surface.subtitleLayer.preventsCapture, file: file, line: line)
        #else
        XCTAssertTrue(surface.videoLayer.preventsCapture,
                      "Physical devices must keep video capture protection enabled",
                      file: file, line: line)
        XCTAssertTrue(surface.subtitleLayer.preventsCapture, file: file, line: line)
        #endif
    }

    private func isRendering(_ surface: CaptureProtectedPlayerView) -> Bool {
        guard surface.videoLayer.sampleBufferRenderer.status == .rendering else { return false }
        if #available(iOS 17.4, *) { return surface.videoLayer.isReadyForDisplay }
        return true
    }

    private func makePlayer(url: URL? = nil) throws -> AVPlayer {
        let player = AVPlayer()
        CaptureProtectedVideoOutput.configure(player)
        let item = AVPlayerItem(url: try url ?? fixtureURL())
        CaptureProtectedVideoOutput.prepare(item)
        player.replaceCurrentItem(with: item)
        player.automaticallyWaitsToMinimizeStalling = false
        return player
    }

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: "PlaybackProgressFixture", withExtension: "mp4"))
    }

    private func waitUntil(timeout: TimeInterval = 8, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(25))
        }
        return predicate()
    }
}

/// Serves only checked-in synthetic media on loopback; the test key is bytes 00...0f.
/// All mutable server state is confined to queue. No production keys or network are used.
nonisolated private final class HLSCaptureFixtureServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PlaybackCaptureTests.HTTP")
    private let listener: NWListener
    private let resources: [String: Data]
    private let manifest: String
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var paths: Set<String> = []
    private var startContinuation: CheckedContinuation<URL, Error>?

    init(bundle: Bundle, manifest: String) throws {
        var resources: [String: Data] = [:]
        for name in ["EncryptedCapture.m3u8", "CaptureTestKey.bin", "EncryptedCapture0.bin",
                     "EncryptedCapture1.bin", "EncryptedCapture2.bin", "SeparateCapture.m3u8",
                     "SeparateCaptureVideo.m3u8", "SeparateCaptureVideo.mp4", "SeparateCaptureAudio.m3u8",
                     "SeparateCaptureAudio.m4a", "SeparateCaptureSubtitles.m3u8", "SeparateCaptureSubtitles.vtt"] {
            let file = name as NSString
            let url = try XCTUnwrap(bundle.url(forResource: file.deletingPathExtension,
                                               withExtension: file.pathExtension))
            resources[name] = try Data(contentsOf: url)
        }
        self.resources = resources
        self.manifest = manifest
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var servedPaths: Set<String> { queue.sync { paths } }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.startContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener.port,
                              let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.manifest)") else { return }
                        self.startContinuation?.resume(returning: url)
                        self.startContinuation = nil
                    case .failed(let error):
                        self.startContinuation?.resume(throwing: error)
                        self.startContinuation = nil
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    self.connections[ObjectIdentifier(connection)] = connection
                    connection.start(queue: self.queue)
                    self.receive(connection, request: Data())
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            self.listener.cancel()
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
            self.startContinuation?.resume(throwing: CancellationError())
            self.startContinuation = nil
        }
    }

    private func receive(_ connection: NWConnection, request: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var request = request
            if let data { request.append(data) }
            if let headers = String(data: request, encoding: .utf8), headers.contains("\r\n\r\n") {
                self.respond(connection, headers: headers)
            } else if done || error != nil || request.count > 8192 {
                self.close(connection)
            } else {
                self.receive(connection, request: request)
            }
        }
    }

    private func respond(_ connection: NWConnection, headers: String) {
        let lines = headers.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        let name = request.count > 1 ? String(request[1].dropFirst()) : ""
        let resourceName = name.hasSuffix(".ts") ? String(name.dropLast(3)) + ".bin" : name
        guard let resource = resources[resourceName] else {
            send(connection, status: "404 Not Found", headers: [], data: Data(), isHead: false)
            return
        }
        paths.insert(name)
        var data = resource
        var status = "200 OK"
        let contentType: String
        switch (name as NSString).pathExtension {
        case "m3u8": contentType = "application/vnd.apple.mpegurl"
        case "mp4": contentType = "video/mp4"
        case "m4a": contentType = "audio/mp4"
        case "vtt": contentType = "text/vtt"
        case "ts": contentType = "video/mp2t"
        default: contentType = "application/octet-stream"
        }
        var responseHeaders = ["Accept-Ranges: bytes", "Content-Type: \(contentType)"]
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range: bytes=") }) {
            let bounds = range.dropFirst("Range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            if let first = bounds.first, let start = Int(first), start >= 0, start < resource.count {
                let end = min(bounds.count > 1 ? Int(bounds[1]) ?? resource.count - 1 : resource.count - 1,
                              resource.count - 1)
                if end >= start {
                    data = resource.subdata(in: start..<(end + 1))
                    status = "206 Partial Content"
                    responseHeaders.append("Content-Range: bytes \(start)-\(end)/\(resource.count)")
                }
            }
        }
        send(connection, status: status, headers: responseHeaders, data: data, isHead: request.first == "HEAD")
    }

    private func send(_ connection: NWConnection, status: String, headers: [String], data: Data, isHead: Bool) {
        let lines = ["HTTP/1.1 \(status)", "Content-Length: \(data.count)", "Connection: close"] + headers
        var response = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if !isHead { response.append(data) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.close(connection)
        })
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }
}

@MainActor
private final class PlayerSurfaceTestWindow {
    private let previousKeyWindow: UIWindow?
    private let window: UIWindow

    init() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKeyWindow = scene?.windows.first(where: \.isKeyWindow)
        if let scene { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568)) }
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    func mount(_ surface: UIView) {
        guard let root = window.rootViewController?.view else { return }
        surface.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        root.addSubview(surface)
        surface.setNeedsLayout()
        surface.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }
}
