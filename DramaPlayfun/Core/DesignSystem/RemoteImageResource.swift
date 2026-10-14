import Foundation
import Kingfisher

enum RemoteImageResource {
    static func resource(for url: URL) -> KF.ImageResource {
        KF.ImageResource(downloadURL: url, cacheKey: cacheKey(for: url))
    }

    static func cacheKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.contains(where: { $0.name.lowercased() == "x-media-token" }) else {
            return url.absoluteString
        }
        // The media token authorizes the download; it does not identify the image.
        // Keep every content/version/resize parameter, and retain the signed download URL.
        let contentItems = items.filter { $0.name.lowercased() != "x-media-token" }
        components.queryItems = contentItems.isEmpty ? nil : contentItems
        return components.string ?? url.absoluteString
    }
}
