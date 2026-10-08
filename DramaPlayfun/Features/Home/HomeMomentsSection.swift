import SwiftUI

struct HomeMomentsSection: View {
    let feed: HomeFeedStore

    var body: some View {
        if let first = feed.moments.first {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("今日片刻").font(.system(size: 20, weight: .bold))
                    Spacer()
                    Button {
                        Task { await feed.refreshMoments() }
                    } label: {
                        HStack(spacing: 3) {
                            Text("换一换")
                            if feed.isRefreshingMoments {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.blue)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(feed.isLoading || feed.isRefreshingMoments)
                    .accessibilityIdentifier("home-moments-refresh")
                }
                GeometryReader { geometry in
                    let gap: CGFloat = 10
                    let leftWidth = feed.moments.count > 1 ? (geometry.size.width - gap) * 0.525 : geometry.size.width
                    HStack(spacing: gap) {
                        HomeMomentCard(moment: first, isLarge: true)
                            .frame(width: leftWidth)
                        if feed.moments.count > 1 {
                            VStack(spacing: gap) {
                                ForEach(Array(feed.moments.dropFirst())) { moment in
                                    HomeMomentCard(moment: moment, isLarge: false)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                if feed.moments.count == 2 {
                                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .aspectRatio(390.0 / 260.0, contentMode: .fit)
                if let message = feed.momentsErrorMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-moments")
        }
    }
}

private struct HomeMomentCard: View {
    @Environment(AppRouter.self) private var router
    let moment: HomeMoment
    let isLarge: Bool

    var body: some View {
        Button { router.openPlayback(moment.drama) } label: {
            ZStack(alignment: .bottomLeading) {
                CachedRemoteImage(url: isLarge ? moment.drama.coverURL : moment.landscapeURL ?? moment.drama.coverURL) {
                    ZStack {
                        LinearGradient(colors: [.indigo.opacity(0.6), Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "film.stack").font(.title).foregroundStyle(Theme.accent)
                    }
                }
                LinearGradient(stops: [.init(color: .clear, location: 0.35),
                                       .init(color: .black.opacity(0.25), location: 0.6),
                                       .init(color: .black.opacity(0.88), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text(moment.drama.title).font(.system(size: isLarge ? 17 : 14, weight: .bold))
                        .foregroundStyle(.white).lineLimit(2)
                    if !moment.subtitle.isEmpty {
                        Text(moment.subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    }
                }.padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home-moment-\(moment.id)")
    }
}
