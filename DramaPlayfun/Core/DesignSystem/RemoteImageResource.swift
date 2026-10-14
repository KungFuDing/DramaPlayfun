import Foundation
import Kingfisher

enum RemoteImageResource {
    static func resource(for url: URL) -> KF.ImageResource {
        KF.ImageResource(downloadURL: url, cacheKey: cacheKey(for: url))
    }

    static func cacheKey(for url: URL) -> String {
        MediaResourceURL.contentKey(for: url)
    }
}
