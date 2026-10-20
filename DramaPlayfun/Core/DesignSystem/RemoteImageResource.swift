import Foundation
import Kingfisher

enum RemoteImageResource {
    static func resource(for url: URL) -> KF.ImageResource {
        KF.ImageResource(downloadURL: url, cacheKey: cacheKey(for: url))
    }

    static func cacheKey(for url: URL) -> String {
        MediaResourceURL.contentKey(for: url)
    }

    static func hasMediaToken(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name.lowercased() == "x-media-token" } == true
    }

    static func validRefreshedURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}
