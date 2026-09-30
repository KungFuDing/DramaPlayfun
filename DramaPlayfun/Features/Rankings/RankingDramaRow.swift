import SwiftUI

struct RankingDramaRow: View {
    let drama: Drama
    let rank: Int
    let posterWidth: CGFloat

    var body: some View {
        NavigationLink(value: AppRoute.drama(drama)) {
            HStack(alignment: .top, spacing: 10) {
                CachedRemoteImage(url: drama.coverURL) {
                    ZStack {
                        LinearGradient(colors: [.indigo.opacity(0.6), Theme.surface], startPoint: .top, endPoint: .bottom)
                        Image(systemName: "film.stack").font(.title).foregroundStyle(Theme.accent)
                    }
                }
                .frame(width: posterWidth, height: posterWidth / 0.78)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    RankingBadge(rank: rank).offset(x: rank <= 3 ? -6 : 0, y: -7)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 9) {
                    Text(drama.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)
                    if !drama.displayTags.isEmpty {
                        Text(drama.tagNames.joined(separator: "   "))
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                    }
                    if !drama.summary.isEmpty {
                        Text(drama.summary)
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
                            .lineSpacing(3).lineLimit(3).padding(.top, 3)
                    }
                    Spacer(minLength: 0)
                    Rectangle().fill(.white.opacity(0.10)).frame(height: 0.5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: posterWidth / 0.78 + 17, alignment: .top)
            }
            .padding(.top, 7)
        }
        .buttonStyle(.plain)
    }
}

private struct RankingBadge: View {
    let rank: Int

    private var metal: Color {
        switch rank {
        case 1: Color(red: 1, green: 0.77, blue: 0.22)
        case 2: Color(red: 0.77, green: 0.87, blue: 0.92)
        default: Color(red: 0.91, green: 0.59, blue: 0.43)
        }
    }

    var body: some View {
        if rank <= 3 {
            ZStack {
                HStack(spacing: 12) {
                    Image(systemName: "laurel.leading")
                    Image(systemName: "laurel.trailing")
                }.font(.system(size: 30, weight: .bold)).foregroundStyle(metal)
                RoundedRectangle(cornerRadius: 1)
                    .fill(LinearGradient(colors: [.white, metal, .white], startPoint: .top, endPoint: .bottom))
                    .frame(width: 23, height: 5).offset(y: -20)
                RoundedRectangle(cornerRadius: 1).fill(metal).frame(width: 15, height: 10).offset(y: -14)
                Circle().fill(LinearGradient(colors: [.white, metal, metal.opacity(0.7)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                Circle().fill(metal.opacity(0.65)).frame(width: 25, height: 25)
                    .overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 1))
                Text(String(format: "%02d", rank))
                    .font(.system(size: 12, weight: .heavy)).foregroundStyle(Color(red: 0.34, green: 0.24, blue: 0.20))
            }.frame(width: 46, height: 42)
        } else {
            Text(String(format: "%02d", rank))
                .font(.system(size: 15, weight: .heavy)).foregroundStyle(Theme.background)
                .frame(width: 29, height: 22)
                .background(Theme.accent, in: UnevenRoundedRectangle(topLeadingRadius: 8, bottomTrailingRadius: 8))
        }
    }
}
