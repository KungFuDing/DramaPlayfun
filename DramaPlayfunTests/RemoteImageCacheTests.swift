import XCTest
import UIKit
import SwiftUI
import Kingfisher
@testable import DramaPlayfun

@MainActor
final class RemoteImageCacheTests: XCTestCase {
    func testRotatedMediaTokenKeepsCacheIdentityAndSignedDownloadURL() throws {
        let first = try url("https://images.example.invalid/cover/a.jpg?x-media-token=old")
        let second = try url("https://images.example.invalid/cover/a.jpg?x-media-token=new")
        let resource = RemoteImageResource.resource(for: second)
        XCTAssertEqual(resource.cacheKey, RemoteImageResource.cacheKey(for: first))
        XCTAssertEqual(resource.downloadURL, second)
        XCTAssertEqual(resource.cacheKey, "https://images.example.invalid/cover/a.jpg")
    }

    func testContentParametersAndOtherImageIdentitiesRemainDistinct() throws {
        let first = try url("https://images.example.invalid/cover/a.jpg?v=1&width=100&x-media-token=old")
        let rotated = try url("https://images.example.invalid/cover/a.jpg?v=1&width=100&x-media-token=new")
        XCTAssertEqual(RemoteImageResource.cacheKey(for: first), RemoteImageResource.cacheKey(for: rotated))
        for string in [
            "https://images.example.invalid/cover/a.jpg?v=2&width=100&x-media-token=new",
            "https://images.example.invalid/cover/a.jpg?v=1&width=200&x-media-token=new",
            "https://images.example.invalid/cover/b.jpg?v=1&width=100&x-media-token=new",
            "https://other.example.invalid/cover/a.jpg?v=1&width=100&x-media-token=new"
        ] {
            XCTAssertNotEqual(RemoteImageResource.cacheKey(for: first), RemoteImageResource.cacheKey(for: try url(string)))
        }
        let unsigned = try url("https://images.example.invalid/cover/a.jpg?custom=a%2Fb&v=3")
        XCTAssertEqual(RemoteImageResource.cacheKey(for: unsigned), unsigned.absoluteString)
    }

    func testRotatedTokenHitsMemoryAndDiskWithoutAnyDownload() async throws {
        let cache = ImageCache(name: "RemoteImageCacheTests-" + UUID().uuidString)
        defer { cache.clearMemoryCache(); cache.clearDiskCache() }
        let first = RemoteImageResource.resource(for: try url("https://images.example.invalid/cover/a.jpg?x-media-token=old"))
        let second = RemoteImageResource.resource(for: try url("https://images.example.invalid/cover/a.jpg?x-media-token=new"))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 16), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 16))
        }
        let stored: CacheStoreResult = await withCheckedContinuation { continuation in
            cache.store(image, forKey: first.cacheKey) { continuation.resume(returning: $0) }
        }
        try stored.diskCacheResult.get()
        // This is also the synchronous lookup used during the placeholder's first frame.
        XCTAssertNotNil(cache.retrieveImageInMemoryCache(forKey: second.cacheKey))
        let memory = try await retrieve(second, cache: cache)
        XCTAssertEqual(memory.cacheType, .memory)
        cache.clearMemoryCache()
        let disk = try await retrieve(second, cache: cache)
        XCTAssertEqual(disk.cacheType, .disk)
        XCTAssertEqual(disk.image.size, image.size)
        XCTAssertNotNil(cache.retrieveImageInMemoryCache(forKey: second.cacheKey))
    }

    func testRecreatedCoverRendersCachedImageInItsFirstFrame() throws {
        let path = "https://images.example.invalid/cover/\(UUID().uuidString).jpg"
        let first = try url(path + "?x-media-token=old")
        let key = RemoteImageResource.cacheKey(for: first)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        ImageCache.default.store(image, forKey: key, toDisk: false)
        defer { ImageCache.default.removeImage(forKey: key, fromMemory: true, fromDisk: false) }
        // ImageRenderer evaluates the view before its loading/onAppear lifecycle runs.
        // An ordinary placeholder would be green here even though the image is cached.
        for token in ["old", "new"] {
            let renderer = ImageRenderer(content: CachedRemoteImage(url: try url(path + "?x-media-token=" + token)) {
                Color.green
            }.frame(width: 20, height: 20))
            let rendered = try XCTUnwrap(renderer.uiImage?.cgImage)
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(rendered, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTAssertGreaterThan(pixel[0], 240, "Cached cover must be visible in the first frame")
            XCTAssertLessThan(pixel[1], 10, "The green loading placeholder must not flash")
        }
    }

    private func url(_ string: String) throws -> URL { try XCTUnwrap(URL(string: string)) }

    private func retrieve(_ resource: KF.ImageResource, cache: ImageCache) async throws -> RetrieveImageResult {
        try await withCheckedThrowingContinuation { continuation in
            KingfisherManager.shared.retrieveImage(with: resource,
                options: [.targetCache(cache), .onlyFromCache, .loadDiskFileSynchronously]) {
                    continuation.resume(with: $0)
                }
        }
    }
}
