import XCTest
import AVFoundation
import Network
@testable import DramaPlayfun

final class HLSPlaybackKeyTests: XCTestCase {
    func testRecoveringOneTransferPreservesAnotherTransfersFailure() {
        let state = HLSAuthorizationState()
        let first = UUID()
        let second = UUID()
        state.recordTransientFailure(URLError(.networkConnectionLost), requestID: first)
        state.recordTransientFailure(URLError(.timedOut), requestID: second)
        state.clearTransientFailure(requestID: second)
        XCTAssertEqual(state.recentTransientFailure?.code, URLError.networkConnectionLost.rawValue)
        state.clearTransientFailure(requestID: first)
        XCTAssertNil(state.recentTransientFailure)
    }

    func testRepeatedRetriesReplaceTheirOwnFailureAndClearTogether() {
        let state = HLSAuthorizationState()
        let requestID = UUID()
        state.recordTransientFailure(URLError(.networkConnectionLost), requestID: requestID)
        state.recordTransientFailure(URLError(.timedOut), requestID: requestID)
        state.recordTransientFailure(URLError(.networkConnectionLost), requestID: requestID)
        state.clearTransientFailure(requestID: requestID)
        XCTAssertNil(state.recentTransientFailure, "Recovered retries must not leave stale failure records")
    }

    @MainActor
    func testGatewayReusesEncryptedSegmentAfterTokenRotationAndServesCachedRange() async throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "master", withExtension: "m3u8")).deletingLastPathComponent()
        let server = try HLSFixtureServer(directory: directory,
            acceptedTokens: ["fixture-token", "renewed-token"], signedMediaReferences: true)
        let ready = expectation(description: "Rotating-token fixture ready")
        server.listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.listener.port).rawValue
        let identity = HLSKeyIdentity(rootDramaID: 107, episodeID: 2531)
        let secret = Data("test-secret".utf8)
        func assetAndSegment(token: String) async throws -> (AVURLAsset, URL) {
            let asset = try await HLSLocalGateway.shared.asset(
                remoteURL: URL(string: "http://127.0.0.1:\(port)/master.m3u8?X-Media-Token=\(token)")!,
                identity: identity, secret: secret)
            let (master, _) = try await URLSession.shared.data(from: asset.url)
            let playlistURL = try XCTUnwrap(String(decoding: master, as: UTF8.self).components(separatedBy: .newlines)
                .first { $0.hasPrefix("http://") }.flatMap(URL.init(string:)))
            let (playlist, _) = try await URLSession.shared.data(from: playlistURL)
            let segmentURL = try XCTUnwrap(String(decoding: playlist, as: UTF8.self).components(separatedBy: .newlines)
                .first { $0.hasPrefix("http://") }.flatMap(URL.init(string:)))
            return (asset, segmentURL)
        }
        let (firstAsset, firstURL) = try await assetAndSegment(token: "fixture-token")
        defer { withExtendedLifetime(firstAsset) {} }
        let (firstBody, _) = try await URLSession.shared.data(from: firstURL)
        let expected = try Data(contentsOf: directory.appendingPathComponent("seg_00000.mpegts"))
        XCTAssertEqual(firstBody, expected)
        let scope = identity.material.base64EncodedString() + ":" + (try HLSPlaybackKey.derive(identity, secret: secret)).base64EncodedString()
        let remoteSegment = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/seg_00000.ts?X-Media-Token=renewed-token")!)
        // The final CDN delegate completion commits after the player's last chunk arrives.
        var committed = false
        for _ in 0..<100 {
            if let reader = HLSMediaCache.shared.reader(for: remoteSegment, scope: scope) {
                reader.close(); committed = true; break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(committed)
        let (secondAsset, secondURL) = try await assetAndSegment(token: "renewed-token")
        defer { withExtendedLifetime(secondAsset) {} }
        let (secondBody, _) = try await URLSession.shared.data(from: secondURL)
        XCTAssertEqual(secondBody, expected)
        var range = URLRequest(url: secondURL)
        range.setValue("bytes=17-63", forHTTPHeaderField: "Range")
        let (rangeBody, response) = try await URLSession.shared.data(for: range)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 17-63/\(expected.count)")
        XCTAssertEqual(rangeBody, Data(expected[17...63]))
        XCTAssertEqual(server.requestedPaths.filter { $0.hasPrefix("/seg_00000.ts") }.count, 1,
            "New token and range playback must reuse the already downloaded encrypted segment")
        XCTAssertTrue(server.requestedPaths.contains("/master.m3u8?X-Media-Token=renewed-token"),
            "Manifests must still fetch using current authorization")
        XCTAssertTrue(server.unauthorizedPaths.isEmpty)
    }

    @MainActor
    func testEncryptedHLSReopensAfterOriginalRoutesAreReleasedAndTokenChanges() async throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "master", withExtension: "m3u8"))
            .deletingLastPathComponent()
        let server = try HLSFixtureServer(directory: directory,
            acceptedTokens: ["fixture-token", "renewed-token"], signedMediaReferences: true)
        let ready = expectation(description: "Replay fixture ready")
        server.listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.listener.port).rawValue
        let identity = HLSKeyIdentity(rootDramaID: 107, episodeID: 2531)
        let secret = Data("test-secret".utf8)
        let expectedKey = try HLSPlaybackKey.derive(identity, secret: secret)
        let scope = identity.material.base64EncodedString() + ":" + expectedKey.base64EncodedString()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }

        func makeAsset(token: String) async throws -> AVURLAsset {
            try await HLSLocalGateway.shared.asset(
                remoteURL: URL(string: "http://127.0.0.1:\(port)/master.m3u8?X-Media-Token=\(token)")!,
                identity: identity, secret: secret)
        }
        func keyURL(for asset: AVURLAsset) async throws -> URL {
            let (master, _) = try await client.data(from: asset.url)
            let playlistURL = try XCTUnwrap(String(decoding: master, as: UTF8.self).components(separatedBy: .newlines)
                .first { $0.hasPrefix("http://") }.flatMap(URL.init(string:)))
            let (playlist, _) = try await client.data(from: playlistURL)
            let keyLine = try XCTUnwrap(String(decoding: playlist, as: UTF8.self).components(separatedBy: .newlines)
                .first { $0.hasPrefix("#EXT-X-KEY:") })
            return try XCTUnwrap(keyLine.components(separatedBy: "\"").dropFirst().first.flatMap(URL.init(string:)))
        }
        func hasCachedSegment(_ name: String) -> Bool {
            let request = URLRequest(url: URL(string:
                "http://127.0.0.1:\(port)/\(name)?X-Media-Token=renewed-token")!)
            guard let reader = HLSMediaCache.shared.reader(for: request, scope: scope) else { return false }
            reader.close()
            return true
        }
        func assertPlaybackAdvances(_ player: AVPlayer) async throws {
            let item = try XCTUnwrap(player.currentItem)
            // Simulator audio devices may have no usable clock. Drive this
            // fixture from the host clock so elapsed media time is deterministic.
            player.sourceClock = CMClockGetHostTimeClock()
            player.automaticallyWaitsToMinimizeStalling = false
            for _ in 0..<100 {
                if item.status != .unknown { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            player.playImmediately(atRate: 1)
            for _ in 0..<200 {
                if item.status == .failed || player.currentTime().seconds > 1 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(item.status, .readyToPlay,
                "Encrypted replay must decode successfully: \(String(describing: item.error))")
            XCTAssertGreaterThan(player.currentTime().seconds, 1,
                "Playback must advance into the second encrypted segment, not merely become ready")
        }

        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try AVAudioSession.sharedInstance().setActive(true)
        let layer = AVPlayerLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 160, height: 240)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow))
        window.layer.addSublayer(layer)
        defer {
            layer.player?.pause()
            layer.player?.replaceCurrentItem(with: nil)
            layer.player = nil
            layer.removeFromSuperlayer()
        }

        var firstAsset: AVURLAsset? = try await makeAsset(token: "fixture-token")
        weak let releasedAsset = firstAsset
        let originalManifestURL = try XCTUnwrap(firstAsset?.url)
        let originalKeyURL = try await keyURL(for: XCTUnwrap(firstAsset))
        var firstPlayer: AVPlayer? = AVPlayer(playerItem: AVPlayerItem(asset: try XCTUnwrap(firstAsset)))
        weak let releasedPlayer = firstPlayer
        layer.player = firstPlayer
        try await assertPlaybackAdvances(XCTUnwrap(firstPlayer))
        // Transport completion commits the cache after delivering its final bytes.
        for _ in 0..<100 {
            if hasCachedSegment("seg_00000.ts") && hasCachedSegment("seg_00001.ts") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(hasCachedSegment("seg_00000.ts"))
        XCTAssertTrue(hasCachedSegment("seg_00001.ts"))
        let downloadedSegments = server.requestedPaths.filter { $0.contains(".ts") }
        XCTAssertTrue(downloadedSegments.contains { $0.hasPrefix("/seg_00000.ts") })
        XCTAssertTrue(downloadedSegments.contains { $0.hasPrefix("/seg_00001.ts") })

        firstPlayer?.pause()
        firstPlayer?.replaceCurrentItem(with: nil)
        layer.player = nil
        firstPlayer = nil
        firstAsset = nil
        for _ in 0..<100 {
            if releasedPlayer == nil && releasedAsset == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(releasedPlayer, "Reopening must not rely on the first AVPlayer")
        XCTAssertNil(releasedAsset, "Reopening must not retain the first gateway lease")
        let (_, releasedManifestResponse) = try await client.data(from: originalManifestURL)
        let (_, releasedKeyResponse) = try await client.data(from: originalKeyURL)
        XCTAssertEqual((releasedManifestResponse as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual((releasedKeyResponse as? HTTPURLResponse)?.statusCode, 404,
            "The previous session's local key route must actually be gone before replay")

        let requestsBeforeReplay = server.requestedPaths.count
        let secondAsset = try await makeAsset(token: "renewed-token")
        let renewedKeyURL = try await keyURL(for: secondAsset)
        XCTAssertNotEqual(secondAsset.url, originalManifestURL)
        XCTAssertNotEqual(renewedKeyURL, originalKeyURL)
        let (renewedKey, renewedKeyResponse) = try await client.data(from: renewedKeyURL)
        XCTAssertEqual((renewedKeyResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(renewedKey, expectedKey, "Each playback session must recreate its own local key route")
        let secondPlayer = AVPlayer(playerItem: AVPlayerItem(asset: secondAsset))
        layer.player = secondPlayer
        try await assertPlaybackAdvances(secondPlayer)

        let replayRequests = Array(server.requestedPaths.dropFirst(requestsBeforeReplay))
        XCTAssertTrue(replayRequests.contains("/master.m3u8?X-Media-Token=renewed-token"),
            "Reopening must fetch a fresh manifest with current authorization")
        XCTAssertTrue(replayRequests.contains("/index.m3u8"))
        XCTAssertEqual(server.requestedPaths.filter { $0.contains(".ts") }, downloadedSegments,
            "A new player and token must reuse the complete encrypted media already on disk")
        XCTAssertFalse(server.requestedPaths.contains("/key.key"))
        XCTAssertTrue(server.unauthorizedPaths.isEmpty)
    }

    @MainActor
    func testExpiredManifestRenewsAndPreservesPositionAndPauseState() async throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "master", withExtension: "m3u8")).deletingLastPathComponent()
        let server = try HLSFixtureServer(directory: directory)
        let ready = expectation(description: "Renewal fixture ready")
        server.listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.listener.port).rawValue
        let drama = Drama(id: "107", title: "续期测试", summary: "", category: .drama,
            episodeCount: 1, heat: 0, badge: nil, coverURL: nil, rootDramaID: 107)
        let feedItem = TheaterFeedItem(drama: drama,
            firstEpisode: Episode(id: "2531", number: 1, title: "", requiresMembership: false),
            videoURL: URL(string: "http://127.0.0.1:\(port)/master.m3u8?X-Media-Token=expired"),
            firstEpisodeLikeCount: 0, isFirstEpisodeLiked: false, isFavorited: false)
        var renewals = 0
        let pool = TheaterPlayerPool(library: LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            cache: .shared, assetLoader: { item in
                try await HLSLocalGateway.shared.asset(remoteURL: item.videoURL!,
                    identity: item.keyIdentity!, secret: Data("test-secret".utf8))
            }, refreshURLs: { item in
                renewals += 1
                var renewed = item
                renewed.videoURL = URL(string: "http://127.0.0.1:\(port)/master.m3u8?X-Media-Token=fixture-token")
                return [renewed]
            })
        defer { pool.reset() }
        pool.update(items: [feedItem], selectedID: feedItem.id, visible: true)
        for _ in 0..<200 where pool.states[feedItem.id] != .ready { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(pool.states[feedItem.id], .ready)
        XCTAssertEqual(renewals, 1)
        XCTAssertTrue(server.unauthorizedPaths.contains(where: { $0.contains("expired") }))
        let player = try XCTUnwrap(pool.player(for: feedItem.id))
        let layer = AVPlayerLayer(player: player)
        layer.frame = CGRect(x: 0, y: 0, width: 160, height: 240)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow))
        window.layer.addSublayer(layer)
        defer { layer.removeFromSuperlayer(); layer.player = nil }
        pool.toggle()
        XCTAssertTrue(pool.beginScrubbing(feedItem.id))
        pool.endScrubbing(feedItem.id, fraction: 0.25)
        for _ in 0..<200 where pool.isScrubbing { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(pool.isScrubbing)
        let position = player.currentTime().seconds
        pool.retry(feedItem.id)
        for _ in 0..<200 where pool.states[feedItem.id] != .ready { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(renewals, 2)
        XCTAssertEqual(pool.states[feedItem.id], .ready)
        XCTAssertTrue(pool.player(for: feedItem.id) === player)
        XCTAssertEqual(player.currentTime().seconds, position, accuracy: 0.1)
        XCTAssertTrue(pool.isPaused)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(pool.playerCount, 1)
    }

    @MainActor
    func testExpiredSegmentIsRecordedBeforeAVPlayerReportsFailure() async throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "master", withExtension: "m3u8")).deletingLastPathComponent()
        let server = try HLSFixtureServer(directory: directory, rejectMedia: true)
        let ready = expectation(description: "Expired segment fixture ready")
        server.listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.listener.port).rawValue
        let asset = try await HLSLocalGateway.shared.asset(
            remoteURL: URL(string: "http://127.0.0.1:\(port)/master.m3u8?X-Media-Token=fixture-token")!,
            identity: HLSKeyIdentity(rootDramaID: 107, episodeID: 2531), secret: Data("test-secret".utf8))
        let (master, _) = try await URLSession.shared.data(from: asset.url)
        let playlistURL = try XCTUnwrap(String(decoding: master, as: UTF8.self).components(separatedBy: .newlines)
            .first { $0.hasPrefix("http://") }.flatMap(URL.init(string:)))
        let (playlist, _) = try await URLSession.shared.data(from: playlistURL)
        let segmentURL = try XCTUnwrap(String(decoding: playlist, as: UTF8.self).components(separatedBy: .newlines)
            .first { $0.hasPrefix("http://") }.flatMap(URL.init(string:)))
        XCTAssertFalse(HLSLocalGateway.authorizationExpired(for: asset))
        let (_, response) = try await URLSession.shared.data(from: segmentURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertTrue(HLSLocalGateway.authorizationExpired(for: asset))
        XCTAssertNil(HLSLocalGateway.transientTransportFailure(for: asset),
                     "An authorization failure must not trigger ordinary network recovery")
    }
    @MainActor
    func testScrubbingSeeksSavesProgressAndPreservesPauseState() async throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "master", withExtension: "m3u8")).deletingLastPathComponent()
        let server = try HLSFixtureServer(directory: directory)
        let ready = expectation(description: "Scrubbing fixture ready")
        server.listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.listener.port)
        let remote = URL(string: "http://127.0.0.1:\(port.rawValue)/master.m3u8?X-Media-Token=fixture-token")!
        let drama = Drama(id: "107", title: "拖动测试", summary: "", category: .drama,
            episodeCount: 1, heat: 0, badge: nil, coverURL: nil, rootDramaID: 107)
        let feedItem = TheaterFeedItem(drama: drama,
            firstEpisode: Episode(id: "2531", number: 1, title: "", requiresMembership: false), videoURL: remote,
            firstEpisodeLikeCount: 0, isFirstEpisodeLiked: false, isFavorited: false)
        let library = LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let pool = TheaterPlayerPool(library: library, cache: .shared, assetLoader: { _ in
            try await HLSLocalGateway.shared.asset(remoteURL: remote,
                identity: HLSKeyIdentity(rootDramaID: 107, episodeID: 2531), secret: Data("test-secret".utf8))
        })
        defer { pool.reset() }
        pool.update(items: [feedItem], selectedID: feedItem.id, visible: true)
        for _ in 0..<100 where pool.states[feedItem.id] != .ready { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(pool.states[feedItem.id], .ready)
        let player = try XCTUnwrap(pool.player(for: feedItem.id))
        let layer = AVPlayerLayer(player: player)
        layer.frame = CGRect(x: 0, y: 0, width: 160, height: 240)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow))
        window.layer.addSublayer(layer)
        defer { layer.removeFromSuperlayer(); layer.player = nil }
        let duration = try XCTUnwrap(player.currentItem).duration.seconds
        XCTAssertFalse(pool.beginScrubbing("another-episode"))
        pool.toggle()
        XCTAssertTrue(pool.isPaused)
        XCTAssertTrue(pool.beginScrubbing(feedItem.id))
        XCTAssertEqual(player.rate, 0)
        pool.endScrubbing(feedItem.id, fraction: 0.75)
        for _ in 0..<500 where pool.isScrubbing { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(pool.isScrubbing)
        XCTAssertTrue(pool.isPaused, "Dragging must preserve a user's paused playback")
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(player.currentTime().seconds, duration * 0.75, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(library.progress[drama.id]).seconds, duration * 0.75, accuracy: 0.05)

        pool.toggle()
        XCTAssertFalse(pool.isPaused)
        XCTAssertTrue(pool.beginScrubbing(feedItem.id))
        pool.endScrubbing(feedItem.id, fraction: 0.25)
        for _ in 0..<500 where pool.isScrubbing { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(pool.isScrubbing)
        XCTAssertFalse(pool.isPaused)
        XCTAssertNotEqual(player.timeControlStatus, .paused, "An initially playing video must resume after seeking")

        XCTAssertTrue(pool.beginScrubbing(feedItem.id))
        pool.suspend()
        pool.endScrubbing(feedItem.id, fraction: 0.5)
        XCTAssertFalse(pool.isScrubbing)
        XCTAssertEqual(player.rate, 0, "A late gesture completion must not restart a hidden player")
    }

    @MainActor
    func testGatewayResumesInterruptedSegmentWithoutDuplicatingBytes() async throws {
        try await assertInterruptedSegment(prefixCount: 4096)
    }

    @MainActor
    func testGatewayRetriesSegmentInterruptedBeforeBody() async throws {
        try await assertInterruptedSegment(prefixCount: 0)
    }

    @MainActor
    func testGatewayResumesTwiceWithoutDuplicatingBytes() async throws {
        try await assertInterruptedSegment(prefixCount: 4096, disconnectCount: 2)
    }

    @MainActor
    private func assertInterruptedSegment(prefixCount: Int, disconnectCount: Int = 1) async throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "master", withExtension: "m3u8")).deletingLastPathComponent()
        let server = try HLSFixtureServer(directory: directory, disconnectMediaCount: disconnectCount,
                                         disconnectMediaPrefix: prefixCount)
        let ready = expectation(description: "Interrupted segment fixture ready")
        server.listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.listener.port)
        let remote = URL(string: "http://127.0.0.1:\(port.rawValue)/master.m3u8?X-Media-Token=fixture-token")!
        let asset = try await HLSLocalGateway.shared.asset(remoteURL: remote,
            identity: HLSKeyIdentity(rootDramaID: 107, episodeID: 2531), secret: Data("test-secret".utf8))
        defer { withExtendedLifetime(asset) {} }
        let (master, _) = try await URLSession.shared.data(from: asset.url)
        let playlistURL = try XCTUnwrap(String(decoding: master, as: UTF8.self).components(separatedBy: .newlines)
            .first { $0.hasPrefix("http://") }.flatMap(URL.init(string:)))
        let (playlist, _) = try await URLSession.shared.data(from: playlistURL)
        let mediaURL = try XCTUnwrap(String(decoding: playlist, as: UTF8.self).components(separatedBy: .newlines)
            .first { $0.hasPrefix("http://") }.flatMap(URL.init(string:)))
        let body: Data
        let response: URLResponse
        do { (body, response) = try await URLSession.shared.data(from: mediaURL) }
        catch {
            XCTFail("Interrupted media failed: \(error); paths=\(server.requestedPaths); events=\(HLSLocalGateway.shared.debugEvents)")
            return
        }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let expected = try Data(contentsOf: directory.appendingPathComponent("seg_00000.mpegts"))
        XCTAssertEqual(body, expected)
        XCTAssertEqual(server.requestedPaths.filter { $0.contains("seg_00000.ts") }.count, disconnectCount + 1)
        XCTAssertTrue(server.unauthorizedPaths.isEmpty)
        for _ in 0..<50 where HLSLocalGateway.transientTransportFailure(for: asset) != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(HLSLocalGateway.transientTransportFailure(for: asset),
                     "A completed Range recovery must clear its failure signal")
    }

    @MainActor
    func testGatewayRetriesTransientManifestAndMediaResponsesBeforeForwardingHeaders() async throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "master", withExtension: "m3u8"))
            .deletingLastPathComponent()
        let server = try HLSFixtureServer(directory: directory,
            mediaFailureStatuses: [503], manifestFailureStatuses: [503])
        let (asset, segmentURL) = try await segmentFromFixture(server)
        defer { server.listener.cancel(); withExtendedLifetime(asset) {} }
        let (body, response) = try await URLSession.shared.data(from: segmentURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(body, try Data(contentsOf: directory.appendingPathComponent("seg_00000.mpegts")))
        XCTAssertEqual(server.requestedPaths.filter { $0.hasPrefix("/master.m3u8") }.count, 2)
        XCTAssertEqual(server.requestedPaths.filter { $0 == "/seg_00000.ts" }.count, 2)
        XCTAssertFalse(HLSLocalGateway.authorizationExpired(for: asset))
    }

    @MainActor
    func testGatewayRetriesMediaConnectionLostBeforeHeaders() async throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "master", withExtension: "m3u8"))
            .deletingLastPathComponent()
        let server = try HLSFixtureServer(directory: directory, disconnectBeforeMediaHeadersCount: 1)
        let (asset, segmentURL) = try await segmentFromFixture(server)
        defer { server.listener.cancel(); withExtendedLifetime(asset) {} }
        let (body, response) = try await URLSession.shared.data(from: segmentURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(body, try Data(contentsOf: directory.appendingPathComponent("seg_00000.mpegts")))
        XCTAssertGreaterThanOrEqual(server.requestedPaths.filter { $0 == "/seg_00000.ts" }.count, 2)
    }

    @MainActor
    func testGatewayLimitsTransientRetriesAndReportsFailureForPlayerRecovery() async throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "master", withExtension: "m3u8"))
            .deletingLastPathComponent()
        let server = try HLSFixtureServer(directory: directory, mediaFailureStatuses: [503, 503, 503, 503])
        let (asset, segmentURL) = try await segmentFromFixture(server)
        defer { server.listener.cancel(); withExtendedLifetime(asset) {} }
        let (body, response) = try await URLSession.shared.data(from: segmentURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertTrue(body.isEmpty)
        XCTAssertEqual(server.requestedPaths.filter { $0 == "/seg_00000.ts" }.count, 3)
        XCTAssertEqual(HLSLocalGateway.transientTransportFailure(for: asset)?.userInfo["HTTPStatusCode"] as? Int, 503)
        XCTAssertFalse(HLSLocalGateway.authorizationExpired(for: asset))
    }

    @MainActor
    func testGatewayReportsRepeatedInterruptedSegmentAfterRetryBudgetIsExhausted() async throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "master", withExtension: "m3u8"))
            .deletingLastPathComponent()
        let server = try HLSFixtureServer(directory: directory,
            disconnectMediaCount: 3, disconnectMediaPrefix: 4096)
        let (asset, segmentURL) = try await segmentFromFixture(server)
        defer { server.listener.cancel(); withExtendedLifetime(asset) {} }
        do {
            _ = try await URLSession.shared.data(from: segmentURL)
            XCTFail("An incomplete segment must fail after the bounded Range retries")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSURLErrorDomain)
        }
        XCTAssertEqual(server.requestedPaths.filter { $0 == "/seg_00000.ts" }.count, 3)
        XCTAssertEqual(HLSLocalGateway.transientTransportFailure(for: asset)?.code,
                       URLError.networkConnectionLost.rawValue)
        XCTAssertFalse(HLSLocalGateway.authorizationExpired(for: asset))
    }

    @MainActor
    func testCancellingGroupDuringManifestRetryDelayDoesNotStartAnotherRequest() async throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "master", withExtension: "m3u8"))
            .deletingLastPathComponent()
        let server = try HLSFixtureServer(directory: directory, manifestFailureStatuses: [503])
        let ready = expectation(description: "Manifest cancellation fixture ready")
        server.listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.listener.port).rawValue
        let transport = HLSMediaTransport()
        let group = UUID()
        transport.register(group: group)
        defer { transport.cancel(group: group) }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/master.m3u8")!)
        request.setValue("fixture-token", forHTTPHeaderField: "X-Media-Token")
        let loading = Task { try await transport.data(for: request, group: group) }
        for _ in 0..<500 where !transport.debugEvents.contains("manifest retry attempt=1") {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(transport.debugEvents.contains("manifest retry attempt=1"))
        transport.cancel(group: group)
        do {
            _ = try await loading.value
            XCTFail("A released asset must cancel its pending manifest retry")
        } catch {
            XCTAssertEqual((error as NSError).code, URLError.cancelled.rawValue)
        }
        XCTAssertEqual(server.requestedPaths, ["/master.m3u8"])
    }

    @MainActor
    private func segmentFromFixture(_ server: HLSFixtureServer) async throws -> (AVURLAsset, URL) {
        let ready = expectation(description: "Retry fixture ready")
        server.listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        server.listener.start(queue: server.queue)
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.listener.port).rawValue
        let asset = try await HLSLocalGateway.shared.asset(
            remoteURL: URL(string: "http://127.0.0.1:\(port)/master.m3u8?X-Media-Token=fixture-token")!,
            identity: HLSKeyIdentity(rootDramaID: 107, episodeID: 2531), secret: Data("test-secret".utf8))
        let (master, _) = try await URLSession.shared.data(from: asset.url)
        let playlistURL = try XCTUnwrap(String(decoding: master, as: UTF8.self).components(separatedBy: .newlines)
            .first { $0.hasPrefix("http://") }.flatMap(URL.init(string:)))
        let (playlist, _) = try await URLSession.shared.data(from: playlistURL)
        let segmentURL = try XCTUnwrap(String(decoding: playlist, as: UTF8.self).components(separatedBy: .newlines)
            .first { $0.hasPrefix("http://") }.flatMap(URL.init(string:)))
        return (asset, segmentURL)
    }

    func testGatewayPreservesRangesWithChunkedMediaResponses() async throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "master", withExtension: "m3u8")).deletingLastPathComponent()
        let server = try HLSFixtureServer(directory: directory, chunkedMedia: true)
        let ready = expectation(description: "Byte-range fixture ready")
        server.listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.listener.port)
        let remote = URL(string: "http://127.0.0.1:\(port.rawValue)/master.m3u8?X-Media-Token=fixture-token")!
        let asset = try await HLSLocalGateway.shared.asset(remoteURL: remote,
            identity: HLSKeyIdentity(rootDramaID: 107, episodeID: 2531), secret: Data("test-secret".utf8))
        defer { withExtendedLifetime(asset) {} }
        let (master, _) = try await URLSession.shared.data(from: asset.url)
        let playlistURL = try XCTUnwrap(String(decoding: master, as: UTF8.self).components(separatedBy: .newlines)
            .first { $0.hasPrefix("http://") }.flatMap(URL.init(string:)))
        let (playlist, _) = try await URLSession.shared.data(from: playlistURL)
        let mediaURL = try XCTUnwrap(String(decoding: playlist, as: UTF8.self).components(separatedBy: .newlines)
            .first { $0.hasPrefix("http://") }.flatMap(URL.init(string:)))
        var request = URLRequest(url: mediaURL)
        request.setValue("bytes=17-63", forHTTPHeaderField: "Range")
        let (body, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        let original = try Data(contentsOf: directory.appendingPathComponent("seg_00000.mpegts"))
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 17-63/\(original.count)")
        XCTAssertEqual(body, Data(original[17...63]))
        XCTAssertTrue(server.unauthorizedPaths.isEmpty)
    }

    func testGatewayForwardsMediaBeforeUpstreamFinishes() async throws {
        let bundle = Bundle(for: Self.self)
        let directory = try XCTUnwrap(bundle.url(forResource: "master", withExtension: "m3u8")).deletingLastPathComponent()
        let server = try HLSFixtureServer(directory: directory, mediaTailDelay: 2)
        let ready = expectation(description: "Streaming fixture ready")
        server.listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.listener.port)
        let remote = URL(string: "http://127.0.0.1:\(port.rawValue)/master.m3u8?X-Media-Token=fixture-token")!
        let asset = try await HLSLocalGateway.shared.asset(remoteURL: remote,
            identity: HLSKeyIdentity(rootDramaID: 107, episodeID: 2531), secret: Data("test-secret".utf8))
        defer { withExtendedLifetime(asset) {} }
        let (master, _) = try await URLSession.shared.data(from: asset.url)
        let playlistURL = try XCTUnwrap(String(decoding: master, as: UTF8.self).components(separatedBy: .newlines)
            .first { $0.hasPrefix("http://") }.flatMap(URL.init(string:)))
        let (playlist, _) = try await URLSession.shared.data(from: playlistURL)
        let mediaURL = try XCTUnwrap(String(decoding: playlist, as: UTF8.self).components(separatedBy: .newlines)
            .first { $0.hasPrefix("http://") }.flatMap(URL.init(string:)))
        let (bytes, response) = try await URLSession.shared.bytes(from: mediaURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        var iterator = bytes.makeAsyncIterator()
        let firstByte = try await iterator.next()
        XCTAssertNotNil(firstByte)
        XCTAssertFalse(server.hasSentMediaTail, "The player must receive the first bytes while the CDN is still downloading the remainder")
        var received = Data()
        if let firstByte { received.append(firstByte) }
        while let byte = try await iterator.next() { received.append(byte) }
        let expected = try Data(contentsOf: directory.appendingPathComponent("seg_00000.mpegts"))
        XCTAssertEqual(received, expected, "Streaming must preserve the encrypted segment bytes")
        XCTAssertTrue(server.unauthorizedPaths.isEmpty)
    }

    @MainActor
    func testPausedNeighborBackpressureDoesNotBlockForegroundManifestOrMedia() async throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "master", withExtension: "m3u8"))
            .deletingLastPathComponent()
        // A body larger than the loopback socket buffers makes the proxy wait
        // when this consumer stops reading, just as a paused neighbor can do.
        let neighbor = try HLSFixtureServer(directory: directory,
            mediaBodyOverride: Data(repeating: 0x5A, count: 32 * 1024 * 1024))
        let foreground = try HLSFixtureServer(directory: directory)
        let serversReady = expectation(description: "Both upstream fixtures ready")
        serversReady.expectedFulfillmentCount = 2
        for server in [neighbor, foreground] {
            server.listener.stateUpdateHandler = { if case .ready = $0 { serversReady.fulfill() } }
            server.listener.start(queue: server.queue)
        }
        defer { neighbor.listener.cancel(); foreground.listener.cancel() }
        await fulfillment(of: [serversReady], timeout: 5)

        func makeAsset(server: HLSFixtureServer, episodeID: Int64) async throws -> AVURLAsset {
            let port = try XCTUnwrap(server.listener.port).rawValue
            return try await HLSLocalGateway.shared.asset(
                remoteURL: URL(string: "http://127.0.0.1:\(port)/master.m3u8?X-Media-Token=fixture-token")!,
                identity: HLSKeyIdentity(rootDramaID: 107, episodeID: episodeID),
                secret: Data("test-secret".utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        func firstReference(in url: URL) async throws -> URL {
            let (body, response) = try await client.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return try XCTUnwrap(String(decoding: body, as: UTF8.self).components(separatedBy: .newlines)
                .first { $0.hasPrefix("http://") }.flatMap(URL.init(string:)))
        }
        let neighborAsset = try await makeAsset(server: neighbor, episodeID: 2531)
        defer { withExtendedLifetime(neighborAsset) {} }
        let neighborPlaylist = try await firstReference(in: neighborAsset.url)
        let neighborMedia = try await firstReference(in: neighborPlaylist)
        let port = try XCTUnwrap(neighborMedia.port.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) })
        let slowConsumer = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        defer { slowConsumer.cancel() }
        let consumerReady = expectation(description: "Nonreading consumer connected")
        slowConsumer.stateUpdateHandler = { if case .ready = $0 { consumerReady.fulfill() } }
        slowConsumer.start(queue: DispatchQueue(label: "test.hls.slow-consumer"))
        await fulfillment(of: [consumerReady], timeout: 5)
        let requestSent = expectation(description: "Neighbor media requested")
        let request = "GET \(neighborMedia.path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        slowConsumer.send(content: Data(request.utf8), completion: .contentProcessed { error in
            XCTAssertNil(error)
            requestSent.fulfill()
        })
        await fulfillment(of: [requestSent], timeout: 5)
        // Deliberately never receive from slowConsumer. Confirm actual socket
        // backpressure instead of relying on an arbitrary startup delay.
        for _ in 0..<250 {
            if HLSLocalGateway.shared.debugHasBlockedMediaWrite(for: neighborAsset) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(HLSLocalGateway.shared.debugHasBlockedMediaWrite(for: neighborAsset))

        let foregroundAsset = try await makeAsset(server: foreground, episodeID: 2532)
        defer { withExtendedLifetime(foregroundAsset) {} }
        let foregroundPlaylist = try await firstReference(in: foregroundAsset.url)
        let foregroundMedia = try await firstReference(in: foregroundPlaylist)
        let (body, response) = try await client.data(from: foregroundMedia)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(body, try Data(contentsOf: directory.appendingPathComponent("seg_00000.mpegts")))
        XCTAssertTrue(HLSLocalGateway.shared.debugHasBlockedMediaWrite(for: neighborAsset),
            "The foreground must finish while the neighbor is still blocked")
        XCTAssertTrue(foreground.unauthorizedPaths.isEmpty)
    }

    func testHMACDerivationMatchesServerContract() throws {
        let identity = HLSKeyIdentity(rootDramaID: 107, episodeID: 2531)
        let key = try HLSPlaybackKey.derive(identity, secret: Data("test-secret".utf8))
        XCTAssertEqual(key.count, 16)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(),
                       "d35bb865716089e931e936d85763c133")
        XCTAssertThrowsError(try HLSPlaybackKey.derive(
            HLSKeyIdentity(rootDramaID: 0, episodeID: 2531), secret: Data("test-secret".utf8)))
        XCTAssertThrowsError(try HLSPlaybackKey.derive(identity, secret: Data()))
    }

    @MainActor
    func testHLSSubtitleTracksAreReadAndSelectedThroughGateway() async throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "subtitle-master", withExtension: "m3u8"))
        let server = try HLSFixtureServer(directory: url.deletingLastPathComponent())
        let ready = expectation(description: "Subtitle HLS fixture server ready")
        server.listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.listener.port)
        let streamURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port.rawValue)/subtitle-master.m3u8?X-Media-Token=fixture-token"))
        let asset = try await HLSLocalGateway.shared.asset(remoteURL: streamURL,
            identity: HLSKeyIdentity(rootDramaID: 107, episodeID: 2531), secret: Data("test-secret".utf8))
        let loadedGroup = try await asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(loadedGroup)
        XCTAssertEqual(group.options.count, 2, "Only subtitle renditions declared by the m3u8 should appear")
        XCTAssertTrue(group.options.allSatisfy { $0.mediaType == .subtitle })
        XCTAssertEqual(Set(group.options.compactMap(\.extendedLanguageTag)), ["zh", "en"])
        let english = try XCTUnwrap(group.options.first(where: { $0.extendedLanguageTag == "en" }))
        let item = AVPlayerItem(asset: asset)
        item.select(english, in: group)
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: group), english)

        let noSubtitleURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port.rawValue)/master.m3u8?X-Media-Token=fixture-token"))
        let noSubtitleAsset = try await HLSLocalGateway.shared.asset(remoteURL: noSubtitleURL,
            identity: HLSKeyIdentity(rootDramaID: 107, episodeID: 2531), secret: Data("test-secret".utf8))
        let noSubtitleGroup = try await noSubtitleAsset.loadMediaSelectionGroup(for: .legible)
        XCTAssertFalse(noSubtitleGroup?.options.contains { $0.mediaType == .subtitle } ?? false,
            "AVFoundation may expose a default CC entry, but this manifest declares no subtitle files")
        XCTAssertTrue(server.unauthorizedPaths.isEmpty)
    }

    @MainActor
    func testEncryptedHLSFixtureUsesTokenHeaderAndLocalKey() async throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "master", withExtension: "m3u8"))
        let server = try HLSFixtureServer(directory: url.deletingLastPathComponent())
        let ready = expectation(description: "HLS fixture server ready")
        server.listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        server.listener.start(queue: server.queue)
        defer { server.listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.listener.port)
        let streamURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port.rawValue)/master.m3u8?X-Media-Token=fixture-token"))
        let asset = try await HLSLocalGateway.shared.asset(remoteURL: streamURL,
            identity: HLSKeyIdentity(rootDramaID: 107, episodeID: 2531),
            secret: Data("test-secret".utf8))
        let gatewayMaster: Data
        let gatewayResponse: URLResponse
        do { (gatewayMaster, gatewayResponse) = try await URLSession.shared.data(from: asset.url) }
        catch {
            XCTFail("Gateway connection failed; events=\(HLSLocalGateway.shared.debugEvents), "
                + "upstream=\(server.requestedPaths)")
            return
        }
        XCTAssertEqual((gatewayResponse as? HTTPURLResponse)?.statusCode, 200,
                       "Gateway master request failed; upstream=\(server.requestedPaths)")
        XCTAssertTrue(String(decoding: gatewayMaster, as: UTF8.self).contains("#EXTM3U"))
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.play()
        defer { player.pause() }
        for _ in 0..<50 {
            if item.status == .failed {
                let errors = item.errorLog()?.events.map { "\($0.errorDomain):\($0.errorStatusCode):\($0.uri ?? "")" } ?? []
                XCTFail("Encrypted HLS playback failed: \(item.error?.localizedDescription ?? "unknown"), "
                    + "upstream=\(server.requestedPaths), unauthorized=\(server.unauthorizedPaths), errors=\(errors)")
                return
            }
            if item.status == .readyToPlay,
               !item.loadedTimeRanges.isEmpty,
               server.requestedPaths.contains("/seg_00000.ts"),
               HLSLocalGateway.shared.debugEvents.contains("key request") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(item.status, .readyToPlay)
        XCTAssertFalse(item.loadedTimeRanges.isEmpty)
        XCTAssertTrue(server.requestedPaths.contains("/master.m3u8?X-Media-Token=fixture-token"))
        XCTAssertTrue(server.requestedPaths.contains("/index.m3u8"))
        XCTAssertTrue(server.requestedPaths.contains("/seg_00000.ts"))
        XCTAssertFalse(server.requestedPaths.contains("/key.key"))
        XCTAssertTrue(server.unauthorizedPaths.isEmpty)
        XCTAssertTrue(HLSLocalGateway.shared.debugEvents.contains("key request"))
    }
}

private final class HLSFixtureServer {
    let listener: NWListener
    let queue = DispatchQueue(label: "test.hls.fixture")
    private let directory: URL
    private let lock = NSLock()
    private var paths: [String] = []
    private var unauthorized: [String] = []
    private let mediaTailDelay: TimeInterval
    private let chunkedMedia: Bool
    private var remainingMediaDisconnects: Int
    private var disconnectBeforeMediaHeadersCount: Int
    private var mediaFailureStatuses: [Int]
    private var manifestFailureStatuses: [Int]
    private var sentMediaTail = false
    private let rejectMedia: Bool
    private let acceptedTokens: Set<String>
    private let signedMediaReferences: Bool
    private let disconnectMediaPrefix: Int?
    private let mediaBodyOverride: Data?

    var hasSentMediaTail: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sentMediaTail
    }

    var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    var unauthorizedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return unauthorized
    }

    init(directory: URL, mediaTailDelay: TimeInterval = 0, chunkedMedia: Bool = false,
         disconnectMediaCount: Int = 0, rejectMedia: Bool = false,
         acceptedTokens: Set<String> = ["fixture-token"], signedMediaReferences: Bool = false,
         disconnectMediaPrefix: Int? = nil, mediaBodyOverride: Data? = nil,
         mediaFailureStatuses: [Int] = [], manifestFailureStatuses: [Int] = [],
         disconnectBeforeMediaHeadersCount: Int = 0) throws {
        self.directory = directory
        self.mediaTailDelay = mediaTailDelay
        self.chunkedMedia = chunkedMedia
        self.remainingMediaDisconnects = disconnectMediaCount
        self.disconnectBeforeMediaHeadersCount = disconnectBeforeMediaHeadersCount
        self.mediaFailureStatuses = mediaFailureStatuses
        self.manifestFailureStatuses = manifestFailureStatuses
        self.rejectMedia = rejectMedia
        self.acceptedTokens = acceptedTokens
        self.signedMediaReferences = signedMediaReferences
        self.disconnectMediaPrefix = disconnectMediaPrefix
        self.mediaBodyOverride = mediaBodyOverride
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let firstLine = String(data: data ?? Data(), encoding: .utf8)?
                    .components(separatedBy: "\r\n").first ?? ""
                let name = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let token = String(data: data ?? Data(), encoding: .utf8)?.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("x-media-token:") }?
                    .dropFirst("x-media-token:".count).trimmingCharacters(in: .whitespaces) ?? ""
                self.lock.lock()
                self.paths.append(name)
                let authorized = firstLine.isEmpty == false &&
                    self.acceptedTokens.contains(token) &&
                    !(self.rejectMedia && name.components(separatedBy: "?")[0].hasSuffix(".ts"))
                if !authorized { self.unauthorized.append(name) }
                self.lock.unlock()
                let allowed = ["master.m3u8", "index.m3u8", "seg_00000.ts", "seg_00001.ts",
                               "subtitle-master.m3u8", "subtitle-zh.m3u8", "subtitle-en.m3u8",
                               "subtitle-zh.vtt", "subtitle-en.vtt"]
                let path = String(name.dropFirst()).components(separatedBy: "?")[0]
                if authorized {
                    self.lock.lock()
                    let disconnectBeforeHeaders = path.hasSuffix(".ts") && self.disconnectBeforeMediaHeadersCount > 0
                    if disconnectBeforeHeaders { self.disconnectBeforeMediaHeadersCount -= 1 }
                    let failureStatus: Int?
                    if path.hasSuffix(".ts"), !self.mediaFailureStatuses.isEmpty {
                        failureStatus = self.mediaFailureStatuses.removeFirst()
                    } else if path.hasSuffix(".m3u8"), !self.manifestFailureStatuses.isEmpty {
                        failureStatus = self.manifestFailureStatuses.removeFirst()
                    } else { failureStatus = nil }
                    self.lock.unlock()
                    if disconnectBeforeHeaders { connection.cancel(); return }
                    if let failureStatus {
                        let header = "HTTP/1.1 \(failureStatus) Temporary Failure\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                }
                let fixtureName = path.hasSuffix(".ts")
                    ? path.replacingOccurrences(of: ".ts", with: ".mpegts") : path
                let file = authorized && allowed.contains(path)
                    ? (path.hasSuffix(".ts") ? self.mediaBodyOverride : nil)
                        ?? (try? Data(contentsOf: self.directory.appendingPathComponent(fixtureName))) : nil
                var body = file ?? Data()
                if self.signedMediaReferences, path == "index.m3u8" {
                    let playlist = String(decoding: body, as: UTF8.self)
                        .replacingOccurrences(of: ".ts\n", with: ".ts?X-Media-Token=\(token)\n")
                    body = Data(playlist.utf8)
                }
                var contentRange: String?
                if let header = String(data: data ?? Data(), encoding: .utf8)?.components(separatedBy: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("range: bytes=") }), file != nil {
                    let bounds = header.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
                    if bounds.count == 2, let start = Int(bounds[0]), let end = bounds[1].isEmpty ? body.count - 1 : Int(bounds[1]), start >= 0, end >= start, end < body.count {
                        contentRange = "bytes \(start)-\(end)/\(body.count)"
                        body = Data(body[start...end])
                    }
                }
                let contentType = path.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl"
                    : path.hasSuffix(".vtt") ? "text/vtt" : "video/mp2t"
                let chunked = self.chunkedMedia && path.hasSuffix(".ts") && file != nil
                let status = !authorized ? "403 Forbidden" : file == nil ? "404 Not Found" : contentRange == nil ? "200 OK" : "206 Partial Content"
                var header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\n"
                header += chunked ? "Transfer-Encoding: chunked\r\n" : "Content-Length: \(body.count)\r\n"
                if let contentRange { header += "Content-Range: \(contentRange)\r\n" }
                header += "Connection: close\r\n\r\n"
                self.lock.lock()
                let disconnect = self.remainingMediaDisconnects > 0 && path.hasSuffix(".ts") && file != nil
                if disconnect { self.remainingMediaDisconnects -= 1 }
                self.lock.unlock()
                if disconnect {
                    let prefix = min(self.disconnectMediaPrefix ?? body.count / 2, body.count - 1)
                    connection.send(content: Data(header.utf8) + body.prefix(prefix), completion: .contentProcessed { _ in connection.cancel() })
                } else if path.hasSuffix(".ts"), file != nil, self.mediaTailDelay > 0 {
                    let split = min(body.count, 4096)
                    connection.send(content: Data(header.utf8) + body.prefix(split), completion: .contentProcessed { _ in
                        self.queue.asyncAfter(deadline: .now() + self.mediaTailDelay) {
                            self.lock.lock()
                            self.sentMediaTail = true
                            self.lock.unlock()
                            connection.send(content: Data(body.dropFirst(split)), completion: .contentProcessed { _ in connection.cancel() })
                        }
                    })
                } else {
                    let payload = chunked ? Data("\(String(body.count, radix: 16))\r\n".utf8) + body + Data("\r\n0\r\n\r\n".utf8) : body
                    connection.send(content: Data(header.utf8) + payload,
                                    completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }
}
