import SwiftUI
import Kingfisher

struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let placeholder: () -> Placeholder

    var body: some View {
        KFImage(url)
            .placeholder { placeholder() }
            .cancelOnDisappear(true)
            .resizable()
            .scaledToFill()
    }
}
