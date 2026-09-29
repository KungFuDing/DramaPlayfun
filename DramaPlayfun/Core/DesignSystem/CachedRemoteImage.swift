import SwiftUI
import Kingfisher

struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let placeholder: () -> Placeholder

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let url {
                    KFImage(url)
                        .placeholder { placeholder() }
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
