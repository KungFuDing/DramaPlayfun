import XCTest
import AVFoundation
import Network
@testable import DramaPlayfun

final class HLSPlaybackKeyTests: XCTestCase {
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

    init(directory: URL) throws {
        self.directory = directory
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let firstLine = String(data: data ?? Data(), encoding: .utf8)?
                    .components(separatedBy: "\r\n").first ?? ""
                let name = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                self.lock.lock()
                self.paths.append(name)
                let authorized = firstLine.isEmpty == false &&
                    String(data: data ?? Data(), encoding: .utf8)?
                        .lowercased().contains("x-media-token: fixture-token") == true
                if !authorized { self.unauthorized.append(name) }
                self.lock.unlock()
                let allowed = ["master.m3u8", "index.m3u8", "seg_00000.ts", "seg_00001.ts",
                               "subtitle-master.m3u8", "subtitle-zh.m3u8", "subtitle-en.m3u8",
                               "subtitle-zh.vtt", "subtitle-en.vtt"]
                let path = String(name.dropFirst()).components(separatedBy: "?")[0]
                let fixtureName = path.hasSuffix(".ts")
                    ? path.replacingOccurrences(of: ".ts", with: ".mpegts") : path
                let file = authorized && allowed.contains(path)
                    ? try? Data(contentsOf: self.directory.appendingPathComponent(fixtureName)) : nil
                let body = file ?? Data()
                let contentType = path.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl"
                    : path.hasSuffix(".vtt") ? "text/vtt" : "video/mp2t"
                let header = "HTTP/1.1 \(!authorized ? "403 Forbidden" : file == nil ? "404 Not Found" : "200 OK")\r\n"
                    + "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + body,
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
