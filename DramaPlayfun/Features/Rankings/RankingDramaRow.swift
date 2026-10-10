import SwiftUI

struct RankingDramaRow: View {
    let drama: Drama
    let rank: Int
    let posterWidth: CGFloat

    private var scale: CGFloat { posterWidth / 95 }

    var body: some View {
        NavigationLink(value: AppRoute.drama(drama)) {
            HStack(alignment: .top, spacing: 10 * scale) {
                CachedRemoteImage(url: drama.coverURL) {
                    ZStack {
                        LinearGradient(colors: [.indigo.opacity(0.6), Theme.surface], startPoint: .top, endPoint: .bottom)
                        Image(systemName: "film.stack").font(.title).foregroundStyle(Theme.accent)
                    }
                }
                .frame(width: posterWidth, height: 123 * scale)
                .clipShape(RoundedRectangle(cornerRadius: 10 * scale))
                .overlay(alignment: .topLeading) {
                    RankingBadge(rank: rank, scale: scale).offset(y: -4 * scale)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 9 * scale) {
                    Text(drama.title)
                        .font(.system(size: 14 * scale))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)
                    if !drama.displayTags.isEmpty {
                        Text(drama.tagNames.joined(separator: "   "))
                            .font(.system(size: 11 * scale)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }
                    if !drama.summary.isEmpty {
                        Text(drama.summary)
                            .font(.system(size: 12 * scale)).foregroundStyle(.white.opacity(0.5))
                            .lineSpacing(3 * scale).lineLimit(2).padding(.top, 3 * scale)
                    }
                    Spacer(minLength: 0)
                    Rectangle().fill(.white.opacity(0.10)).frame(height: 0.5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2 * scale)
                .frame(height: 135 * scale, alignment: .top)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct RankingBadge: View {
    let rank: Int
    let scale: CGFloat

    private var asset: String {
        switch rank {
        case 1: "RankingFirst"
        case 2: "RankingSecond"
        default: "RankingThird"
        }
    }

    var body: some View {
        if rank <= 3 {
            Image(asset).resizable().scaledToFit().frame(width: 26 * scale, height: 22 * scale)
        } else {
            Text(String(rank))
                .font(.system(size: 12 * scale, weight: .bold)).foregroundStyle(Theme.background)
                .frame(minWidth: 26 * scale, minHeight: 19 * scale)
                .background {
                    Image("RankingNumberBackground").resizable()
                }
        }
    }
}
