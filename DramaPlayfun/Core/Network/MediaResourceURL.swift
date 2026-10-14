import Foundation

nonisolated enum MediaResourceURL {
    static func contentKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.contains(where: { $0.name.lowercased() == "x-media-token" }) else {
            return url.absoluteString
        }
        // Authorization is transient; content/version/quality parameters remain part of the identity.
        let contentItems = items.filter { $0.name.lowercased() != "x-media-token" }
        components.queryItems = contentItems.isEmpty ? nil : contentItems
        return components.string ?? url.absoluteString
    }
}
