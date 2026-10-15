import SwiftUI

struct SearchEmptyView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image("SearchEmpty")
                .resizable().scaledToFit()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            Text("暂无更多内容")
                .font(.system(size: 13))
                .foregroundStyle(Color(white: 0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 5)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search-empty")
    }
}

#Preview("搜索结果为空") {
    SearchEmptyView()
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
