import XCTest
import UIKit
import Kingfisher
import Moya
@testable import DramaPlayfun

@MainActor
final class RemoteImageRenewalTests: XCTestCase {
    func testCacheHitsAcrossTokenRotationDoNotDownloadOrRefresh() async throws {
        let fixture = ImageDownloads { _ in (500, Data()) }
        let manager = manager(fixture)
        defer { manager.cache.clearMemoryCache(); manager.cache.clearDiskCache(); fixture.remove() }
        let old = imageURL("cover.png?x-media-token=old")
        let rotated = imageURL("cover.png?x-media-token=new")
        let image = makeImage()
        try await manager.cache.store(image, forKey: RemoteImageResource.cacheKey(for: old))
        var metadataRequests = 0
        let network = try network { _ in metadataRequests += 1; return #"{"code":200,"data":{}}"# }
        let refresher = RemoteImageURLRefresher(network: network)
        _ = try await RemoteImageLoader.load(url: rotated, source: .dramaCover("101"), refresher: refresher, manager: manager)
        manager.cache.clearMemoryCache()
        _ = try await RemoteImageLoader.load(url: rotated, source: .dramaCover("101"), refresher: refresher, manager: manager)
        XCTAssertEqual(metadataRequests, 0)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testAuthorizationFailuresRefreshOnceAndUseTheServerURL() async throws {
        for status in [401, 403] {
            let data = try XCTUnwrap(makeImage().pngData())
            let fixture = ImageDownloads { url in
                url.query?.contains("old") == true ? (status, Data()) : (200, data)
            }
            let manager = manager(fixture)
            defer { manager.cache.clearMemoryCache(); manager.cache.clearDiskCache(); fixture.remove() }
            let old = imageURL("cover-\(status).png?width=100&x-media-token=old")
            let fresh = imageURL("cover-\(status).png?width=100&x-media-token=fresh")
            var metadataRequests = 0
            let network = try network { target in
                metadataRequests += 1
                XCTAssertEqual(target.path, AppAPI.v1ClientDramaDetail.path)
                return self.detail(cover: fresh)
            }
            _ = try await RemoteImageLoader.load(url: old, source: .dramaCover("101"),
                refresher: RemoteImageURLRefresher(network: network), manager: manager)
            XCTAssertEqual(metadataRequests, 1)
            XCTAssertEqual(fixture.requests, [old, fresh])
            XCTAssertNotNil(manager.cache.retrieveImageInMemoryCache(forKey: RemoteImageResource.cacheKey(for: old)))
        }
    }

    func testRenewedDifferentContentKeepsItsOwnCacheKey() async throws {
        let data = try XCTUnwrap(makeImage().pngData())
        let old = imageURL("old-cover.png?v=1&x-media-token=old")
        let fresh = imageURL("new-cover.png?v=2&x-media-token=new")
        let fixture = ImageDownloads { $0 == old ? (403, Data()) : (200, data) }
        let manager = manager(fixture)
        defer { manager.cache.clearMemoryCache(); manager.cache.clearDiskCache(); fixture.remove() }
        let network = try network { _ in self.detail(cover: fresh) }
        _ = try await RemoteImageLoader.load(url: old, source: .dramaCover("101"),
            refresher: RemoteImageURLRefresher(network: network), manager: manager)
        XCTAssertNil(manager.cache.retrieveImageInMemoryCache(forKey: RemoteImageResource.cacheKey(for: old)))
        XCTAssertNotNil(manager.cache.retrieveImageInMemoryCache(forKey: RemoteImageResource.cacheKey(for: fresh)))
        XCTAssertEqual(fixture.requests, [old, fresh])
    }

    func testOrdinaryErrorsAndUnsignedForbiddenImagesDoNotRefresh() async throws {
        for (status, suffix) in [(500, "?x-media-token=old"), (404, "?x-media-token=old"), (403, "")] {
            let fixture = ImageDownloads { _ in (status, Data()) }
            let manager = manager(fixture)
            defer { fixture.remove() }
            var metadataRequests = 0
            let network = try network { _ in metadataRequests += 1; return #"{"code":200,"data":{}}"# }
            do {
                _ = try await RemoteImageLoader.load(url: imageURL("failure-\(status).png" + suffix),
                    source: .dramaCover("101"), refresher: RemoteImageURLRefresher(network: network), manager: manager)
                XCTFail("Expected the image request to fail")
            } catch { }
            XCTAssertEqual(metadataRequests, 0)
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testRejectedReplacementDoesNotLoopAndRepeatedOldURLBacksOff() async throws {
        let fixture = ImageDownloads { _ in (403, Data()) }
        let manager = manager(fixture)
        defer { fixture.remove() }
        let old = imageURL("cover.png?x-media-token=old")
        let fresh = imageURL("cover.png?x-media-token=new")
        var metadataRequests = 0
        let network = try network { _ in metadataRequests += 1; return self.detail(cover: fresh) }
        let refresher = RemoteImageURLRefresher(network: network)
        for _ in 0..<3 {
            do {
                _ = try await RemoteImageLoader.load(url: old, source: .dramaCover("101"),
                    refresher: refresher, manager: manager)
                XCTFail("Expected the image request to fail")
            } catch { }
        }
        XCTAssertEqual(metadataRequests, 1)
        XCTAssertEqual(fixture.requests.filter { $0 == fresh }.count, 1)
        XCTAssertEqual(fixture.requests.count, 4)
    }

    func testPortraitAndLandscapeShareOneMetadataRequest() async throws {
        let cover = imageURL("portrait.png?x-media-token=new")
        let landscape = imageURL("landscape.png?x-media-token=new")
        var metadataRequests = 0
        let network = try network(delay: 0.05) { _ in
            metadataRequests += 1
            return self.detail(cover: cover, landscape: landscape)
        }
        let refresher = RemoteImageURLRefresher(network: network)
        async let portraitURL = refresher.refreshedURL(for: .dramaCover("101"), replacing: nil)
        async let landscapeURL = refresher.refreshedURL(for: .dramaLandscape("101"), replacing: nil)
        let values = await (portraitURL, landscapeURL)
        XCTAssertEqual(values.0, cover)
        XCTAssertEqual(values.1, landscape)
        XCTAssertEqual(metadataRequests, 1)
    }

    func testMissingCoverRefreshesBeforeDownload() async throws {
        let fresh = imageURL("missing-cover.png?x-media-token=new")
        let data = try XCTUnwrap(makeImage().pngData())
        let fixture = ImageDownloads { _ in (200, data) }
        let manager = manager(fixture)
        defer { manager.cache.clearMemoryCache(); manager.cache.clearDiskCache(); fixture.remove() }
        let network = try network { _ in self.detail(cover: fresh) }
        _ = try await RemoteImageLoader.load(url: nil, source: .dramaCover("101"),
            refresher: RemoteImageURLRefresher(network: network), manager: manager)
        XCTAssertEqual(fixture.requests, [fresh])
    }

    func testInvalidRenewedURLIsRejectedAndMetadataFailureBacksOff() async throws {
        var requests = 0
        let network = try network { _ in
            requests += 1
            return #"{"code":200,"data":{"drama":{"coverUrl":"http://images.example.invalid/unsafe.jpg"}}}"#
        }
        let refresher = RemoteImageURLRefresher(network: network)
        let old = imageURL("cover.png?x-media-token=old")
        let first = await refresher.refreshedURL(for: .dramaCover("101"), replacing: old)
        let second = await refresher.refreshedURL(for: .dramaCover("101"), replacing: old)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(requests, 1)
        XCTAssertNil(RemoteImageResource.validRefreshedURL("https://user:password@images.example.invalid/a.png"))
    }

    func testDifferentVersionDoesNotReuseAnEarlierReplacement() async throws {
        var requests = 0
        let network = try network { _ in
            requests += 1
            return self.detail(cover: self.imageURL("cover.png?v=\(requests)&x-media-token=new"))
        }
        let refresher = RemoteImageURLRefresher(network: network)
        let first = await refresher.refreshedURL(for: .dramaCover("101"),
            replacing: imageURL("cover.png?v=1&x-media-token=old"))
        let second = await refresher.refreshedURL(for: .dramaCover("101"),
            replacing: imageURL("cover.png?v=2&x-media-token=old"))
        XCTAssertEqual(first, imageURL("cover.png?v=1&x-media-token=new"))
        XCTAssertEqual(second, imageURL("cover.png?v=2&x-media-token=new"))
        XCTAssertEqual(requests, 2)
    }

    func testFailedMetadataCanRetryAfterCooldown() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        var requests = 0
        let fresh = imageURL("cover.png?x-media-token=new")
        let network = try network { _ in
            requests += 1
            return requests == 1 ? #"{"code":500,"data":null}"# : self.detail(cover: fresh)
        }
        let refresher = RemoteImageURLRefresher(network: network, now: { now })
        let old = imageURL("cover.png?x-media-token=old")
        let first = await refresher.refreshedURL(for: .dramaCover("101"), replacing: old)
        let blocked = await refresher.refreshedURL(for: .dramaCover("101"), replacing: old)
        XCTAssertNil(first)
        XCTAssertNil(blocked)
        XCTAssertEqual(requests, 1)
        now.addTimeInterval(61)
        let retried = await refresher.refreshedURL(for: .dramaCover("101"), replacing: old)
        XCTAssertEqual(retried, fresh)
        XCTAssertEqual(requests, 2)
    }

    func testAccountSwitchDiscardsOldResponseAndDoesNotReuseIt() async throws {
        var requests = 0
        let firstStarted = expectation(description: "Old account metadata request began")
        let network = try network(delay: 0.08) { _ in
            requests += 1
            if requests == 1 { firstStarted.fulfill() }
            return self.detail(cover: self.imageURL("account-\(requests).png?x-media-token=new"))
        }
        network.setAccessToken("a", accountID: "account-a")
        let refresher = RemoteImageURLRefresher(network: network)
        let oldTask = _Concurrency.Task { await refresher.refreshedURL(for: .dramaCover("101"), replacing: nil) }
        await fulfillment(of: [firstStarted], timeout: 1)
        network.setAccessToken("b", accountID: "account-b")
        let oldResult = await oldTask.value
        XCTAssertNil(oldResult)
        let newResult = await refresher.refreshedURL(for: .dramaCover("101"), replacing: nil)
        XCTAssertEqual(newResult, imageURL("account-2.png?x-media-token=new"))
        XCTAssertEqual(requests, 2)
    }

    func testBannerAndAvatarRefreshFromTheirOwningEndpoints() async throws {
        let banner = imageURL("banner.png?x-media-token=new")
        let avatar = imageURL("avatar.png?x-media-token=new")
        var paths: [String] = []
        let network = try network { target in
            paths.append(target.path)
            if target.path == AppAPI.v1TheaterHome.path {
                return #"{"code":200,"data":{"banners":[{"id":9,"bannerImage":"\#(banner.absoluteString)","coverUrl":"https://images.example.invalid/wrong.jpg"}]}}"#
            }
            return #"{"code":200,"data":{"avatarUrl":"\#(avatar.absoluteString)"}}"#
        }
        let refresher = RemoteImageURLRefresher(network: network)
        let newBanner = await refresher.refreshedURL(for: .homeBanner("9"), replacing: nil)
        let newAvatar = await refresher.refreshedURL(for: .profileAvatar, replacing: nil)
        XCTAssertEqual(newBanner, banner)
        XCTAssertEqual(newAvatar, avatar)
        XCTAssertEqual(paths, [AppAPI.v1TheaterHome.path, AppAPI.v1ClientMe.path])
    }

    func testShareCoverUsesSameStableKeyAsBrowseCards() async throws {
        let path = "share-\(UUID().uuidString).png"
        let old = imageURL(path + "?x-media-token=old")
        let new = imageURL(path + "?x-media-token=new")
        let key = RemoteImageResource.cacheKey(for: old)
        let image = makeImage()
        try await ImageCache.default.store(image, forKey: key, toDisk: false)
        defer { ImageCache.default.removeImage(forKey: key, fromMemory: true, fromDisk: false) }
        var paths: [String] = []
        let network = try network { target in
            paths.append(target.path)
            return #"{"code":200,"data":{"text":"https://example.invalid/share/1001"}}"#
        }
        let drama = Drama(id: "101", title: "分享缓存", summary: "", category: .drama,
                          episodeCount: 1, heat: 0, badge: nil, coverURL: new)
        let item = TheaterFeedItem(drama: drama,
            firstEpisode: Episode(id: "1001", number: 1, title: "", requiresMembership: false),
            videoURL: nil, firstEpisodeLikeCount: 0, isFirstEpisodeLiked: false, isFavorited: false)
        let content = try await DramaShareContent.load(item: item, network: network,
            imageURLs: RemoteImageURLRefresher(network: network))
        XCTAssertEqual(content.cover.size, image.size)
        XCTAssertEqual(paths, [AppAPI.v1ClientDramaShareText.path])
    }

    private func imageURL(_ path: String) -> URL { URL(string: "https://images.example.invalid/" + path)! }

    private func detail(cover: URL, landscape: URL? = nil) -> String {
        #"{"code":200,"data":{"drama":{"coverUrl":"\#(cover.absoluteString)","coverFourThreeUrl":"\#(landscape?.absoluteString ?? "")"}}}"#
    }

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 12, height: 16)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 16))
        }
    }

    private func network(delay: TimeInterval = 0, response: @escaping (APITarget) -> String) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let json = response(target)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in delay > 0 ? .delayed(seconds: delay) : .immediate })
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://api.example.invalid")!),
                         provider: provider)
    }

    private func manager(_ fixture: ImageDownloads) -> KingfisherManager {
        let downloader = ImageDownloader(name: UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageDownloadProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Image-Test": fixture.id]
        downloader.sessionConfiguration = configuration
        return KingfisherManager(downloader: downloader, cache: ImageCache(name: UUID().uuidString))
    }
}

nonisolated private final class ImageDownloads: @unchecked Sendable {
    let id = UUID().uuidString
    private let lock = NSLock()
    private var urls: [URL] = []
    private let response: @Sendable (URL) -> (Int, Data)
    var requests: [URL] { lock.withLock { urls } }

    init(response: @escaping @Sendable (URL) -> (Int, Data)) {
        self.response = response
        ImageDownloadProtocol.register(self)
    }

    func receive(_ url: URL) -> (Int, Data) {
        lock.withLock { urls.append(url) }
        return response(url)
    }

    func remove() { ImageDownloadProtocol.remove(id) }
}

nonisolated private final class ImageDownloadProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: ImageDownloads] = [:]

    static func register(_ fixture: ImageDownloads) { lock.withLock { fixtures[fixture.id] = fixture } }
    static func remove(_ id: String) { lock.withLock { fixtures[id] = nil } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Image-Test") ?? ""
        guard let url = request.url, let fixture = Self.lock.withLock({ Self.fixtures[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, data) = fixture.receive(url)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
