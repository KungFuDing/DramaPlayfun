import SwiftUI

/// Fills a page's content area while leaving its navigation controls available.
struct NetworkFailureView: View {
    let onRetry: () async -> Void

    var body: some View {
        NetworkFailureContent(onRetry: onRetry)
            .padding(.horizontal, 24)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("network-failure-screen")
    }
}

/// The same failure state can be embedded in a section without covering loaded content.
struct NetworkFailureContent: View {
    let onRetry: () async -> Void
    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 0) {
            Image("NetworkFailure")
                .resizable().scaledToFit()
                .frame(width: 92, height: 92)
                .accessibilityHidden(true)
            Text(L10n.tr("网络不稳定,请重试"))
                .font(.system(size: 13))
                .foregroundStyle(Color(white: 0.6))
                .multilineTextAlignment(.center)
                .padding(.top, 12)
            Button {
                guard !isRetrying else { return }
                isRetrying = true
                Task {
                    await onRetry()
                    isRetrying = false
                }
            } label: {
                ZStack {
                    Text(L10n.tr("重试")).opacity(isRetrying ? 0 : 1)
                    if isRetrying { ProgressView().tint(Theme.accent) }
                }
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
                .frame(width: 78, height: 34)
                .overlay { Capsule().strokeBorder(Theme.accent, lineWidth: 0.5) }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRetrying)
            .accessibilityLabel(isRetrying ? L10n.tr("正在重试") : L10n.tr("重试"))
            .accessibilityIdentifier("network-failure-retry")
            .padding(.top, 21)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview("网络请求失败") {
    NetworkFailureView(onRetry: {})
        .preferredColorScheme(.dark)
}
