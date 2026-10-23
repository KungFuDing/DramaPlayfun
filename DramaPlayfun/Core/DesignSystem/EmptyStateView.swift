import SwiftUI

struct EmptyStateView: View {
    let title: String
    var description: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image("SearchEmpty")
                .renderingMode(.original)
                .resizable().scaledToFit()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title)
                if let description {
                    Text(description)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Color(white: 0.6))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview("数据为空") {
    EmptyStateView(title: L10n.tr("暂无更多内容"))
        .padding(.vertical, 24)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
