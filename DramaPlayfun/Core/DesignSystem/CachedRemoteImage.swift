import SwiftUI
import Kingfisher

struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL?
    var source: RemoteImageSource? = nil
    @ViewBuilder let placeholder: () -> Placeholder
    @Environment(\.remoteImageURLRefresher) private var refresher
    @State private var loaded: LoadedImage?

    private struct Request: Equatable {
        let url: URL?
        let source: RemoteImageSource?
        let scope: String?
    }

    private struct LoadedImage {
        let request: Request
        let image: UIImage
    }

    var body: some View {
        let request = Request(url: url, source: source, scope: refresher?.currentScope)
        GeometryReader { geometry in
            Group {
                if let image = image(for: request) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    placeholder()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: request) {
            guard request.url != nil else { return }
            do {
                let image = try await RemoteImageLoader.load(url: request.url, source: request.source, refresher: refresher)
                try Task.checkCancellation()
                loaded = LoadedImage(request: request, image: image)
            } catch { /* Keep the placeholder on failure; a new URL or appearance can retry. */ }
        }
    }

    private func image(for request: Request) -> UIImage? {
        if let loaded, loaded.request == request { return loaded.image }
        // Render a memory hit before the loading task starts, including ImageRenderer/previews.
        return request.url.flatMap { ImageCache.default.retrieveImageInMemoryCache(forKey: RemoteImageResource.cacheKey(for: $0)) }
    }
}
