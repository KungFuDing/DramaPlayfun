import XCTest
import AVFoundation
import Network
@testable import DramaPlayfun

final class HLSPlaybackKeyTests: XCTestCase {
    func testGatewayResumesInterruptedSegmentWithoutDuplicatingBytes() async throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "master", withExtension: "m3u8")).deletingLastPathComponent()
        let server = try HLSFixtureServer(directory: directory, disconnectMediaOnce: true)
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
        let (body, response) = try await URLSession.shared.data(from: mediaURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let expected = try Data(contentsOf: directory.appendingPathComponent("seg_00000.mpegts"))
        XCTAssertEqual(body, expected)
        XCTAssertEqual(server.requestedPaths.filter { $0.contains("seg_00000.ts") }.count, 2)
        XCTAssertTrue(server.unauthorizedPaths.isEmpty)
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
    private let disconnectMediaOnce: Bool
    private var disconnectedMedia = false
    private var sentMediaTail = false

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
         disconnectMediaOnce: Bool = false) throws {
        self.directory = directory
        self.mediaTailDelay = mediaTailDelay
        self.chunkedMedia = chunkedMedia
        self.disconnectMediaOnce = disconnectMediaOnce
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
                var body = file ?? Data()
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
                let disconnect = self.disconnectMediaOnce && !self.disconnectedMedia && path.hasSuffix(".ts") && file != nil
                if disconnect { self.disconnectedMedia = true }
                self.lock.unlock()
                if disconnect {
                    connection.send(content: Data(header.utf8) + body.prefix(body.count / 2), completion: .contentProcessed { _ in connection.cancel() })
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
