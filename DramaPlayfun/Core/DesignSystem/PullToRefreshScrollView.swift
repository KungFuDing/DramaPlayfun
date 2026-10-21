import SwiftUI

/// Shares the home feed's refresh gesture and indicator without adding scroll targets or a footer.
struct PullToRefreshScrollView<Content: View>: View {
    private static var refreshThreshold: CGFloat { 82 }

    private enum RefreshPhase {
        case idle, refreshing, finished
    }

    let coordinateSpaceName: String
    var refreshIndicatorTop: CGFloat = 16
    let onRefresh: () async -> Void
    @ViewBuilder let content: Content

    @State private var pullDistance: CGFloat = 0
    @State private var peakPullDistance: CGFloat = 0
    @State private var isTrackingPullGesture = false
    @State private var refreshPhase: RefreshPhase = .idle

    var body: some View {
        ScrollView(.vertical) {
            content
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.frame(in: .named(coordinateSpaceName)).minY
                } action: { y in
                    guard refreshPhase == .idle else { return }
                    pullDistance = max(0, y)
                    peakPullDistance = max(peakPullDistance, pullDistance)
                }
        }
        .coordinateSpace(name: coordinateSpaceName)
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { _ in
                    if !isTrackingPullGesture {
                        isTrackingPullGesture = true
                        peakPullDistance = pullDistance
                    }
                }
                .onEnded { _ in
                    if max(peakPullDistance, pullDistance) >= Self.refreshThreshold {
                        beginRefresh()
                    }
                    isTrackingPullGesture = false
                    peakPullDistance = 0
                }
        )
        .overlay(alignment: .top) {
            if pullDistance > 8 || refreshPhase != .idle {
                refreshStatus
                    .padding(.top, refreshIndicatorTop)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    private var refreshStatus: some View {
        let progress = min(pullDistance / Self.refreshThreshold, 1)
        return HStack(spacing: 10) {
            if refreshPhase == .refreshing {
                ProgressView().tint(Theme.accent)
            } else if refreshPhase == .finished {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
            } else {
                ZStack {
                    Circle().stroke(.white.opacity(0.3), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: progress >= 1 ? "checkmark" : "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .frame(width: 22, height: 22)
            }
            Text(refreshPhase == .refreshing ? L10n.tr("正在刷新…") :
                 refreshPhase == .finished ? L10n.tr("刷新完成") :
                 progress >= 1 ? L10n.tr("松开立即刷新") : L10n.tr("继续下拉刷新 %d%%", Int(progress * 100)))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.86), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("refresh-status")
        .accessibilityLabel(refreshPhase == .refreshing ? L10n.tr("正在刷新") :
                            refreshPhase == .finished ? L10n.tr("刷新完成") :
                            progress >= 1 ? L10n.tr("松开立即刷新") : L10n.tr("继续下拉刷新"))
        .accessibilityValue(refreshPhase == .idle ? "\(Int(progress * 100))%" : "")
    }

    private func beginRefresh() {
        guard refreshPhase == .idle else { return }
        refreshPhase = .refreshing
        pullDistance = 0
        Task {
            let minimumDisplay = Task { try? await Task.sleep(for: .milliseconds(500)) }
            await onRefresh()
            await minimumDisplay.value
            refreshPhase = .finished
            try? await Task.sleep(for: .seconds(2))
            refreshPhase = .idle
        }
    }
}
