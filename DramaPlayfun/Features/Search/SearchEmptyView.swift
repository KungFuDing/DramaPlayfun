import SwiftUI

struct SearchEmptyView: View {
    var body: some View {
        EmptyStateView(title: L10n.tr("暂无更多内容"))
            .padding(.top, 10)
            .padding(.bottom, 5)
            .accessibilityIdentifier("search-empty")
    }
}

#Preview("搜索结果为空") {
    SearchEmptyView()
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
