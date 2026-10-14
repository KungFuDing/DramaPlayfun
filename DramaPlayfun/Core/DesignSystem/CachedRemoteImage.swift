import SwiftUI
import Kingfisher

struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let placeholder: () -> Placeholder

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let url {
                    let resource = RemoteImageResource.resource(for: url)
                    KFImage(source: .network(resource))
                        .placeholder {
                            // A recreated KFImage starts with its placeholder before onAppear
                            // retrieves the cache. Render the memory hit in that first frame too.
                            if let image = ImageCache.default.retrieveImageInMemoryCache(forKey: resource.cacheKey) {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                placeholder()
                            }
                        }
                        .cancelOnDisappear(true)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }
}
