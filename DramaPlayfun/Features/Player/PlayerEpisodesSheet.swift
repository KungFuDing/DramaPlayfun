import SwiftUI

struct EpisodePageRange: Identifiable, Equatable {
    let start: Int
    let end: Int
    var id: Int { start }
    var title: String { "\(start)–\(end)" }
    func contains(_ number: Int) -> Bool { (start...end).contains(number) }

    static func pages(for episodes: [Episode]) -> [Self] {
        guard let last = episodes.map(\.number).max(), last > 0 else { return [] }
        return stride(from: 1, through: last, by: 30).map { Self(start: $0, end: min($0 + 29, last)) }
    }
}

struct PlayerEpisodesSheet: View {
    let drama: Drama
    let episodes: [Episode]
    let selectedID: Episode.ID?
    let onClose: () -> Void
    let onSelect: (Episode) -> Void
    @State private var rangeStart: Int
    private let accent = Color(red: 1, green: 199.0 / 255, blue: 48.0 / 255)
    private var ranges: [EpisodePageRange] { EpisodePageRange.pages(for: episodes) }
    private var visibleEpisodes: [Episode] {
        guard let range = ranges.first(where: { $0.start == rangeStart }) else { return [] }
        return episodes.filter { range.contains($0.number) }.sorted { $0.number < $1.number }
    }

    init(drama: Drama, episodes: [Episode], selectedID: Episode.ID?,
         onClose: @escaping () -> Void, onSelect: @escaping (Episode) -> Void) {
        self.drama = drama
        self.episodes = episodes
        self.selectedID = selectedID
        self.onClose = onClose
        self.onSelect = onSelect
        let number = episodes.first(where: { $0.id == selectedID })?.number ?? 1
        _rangeStart = State(initialValue: ((max(number, 1) - 1) / 30) * 30 + 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: onClose)
                    .accessibilityLabel("关闭选集弹窗")
                panel
                    .frame(height: geometry.size.height * 0.602)
                    .transition(.move(edge: .bottom))
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
    }

    private var panel: some View {
        ZStack(alignment: .top) {
            Color(red: 34.0 / 255, green: 35.0 / 255, blue: 35.0 / 255)
            LinearGradient(colors: [Color(red: 0.67, green: 0.58, blue: 0.2),
                                    Color(red: 0.42, green: 0.27, blue: 0.14),
                                    Color(red: 0.34, green: 0.07, blue: 0.09)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 180)
                .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 16) {
                dramaHeader
                rangeTabs
                episodeGrid
            }
            .padding(.horizontal, 12)
            .padding(.top, 30)
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color(white: 0.72)).frame(width: 36, height: 36)
                }.accessibilityLabel("关闭选集")
            }.padding(.top, 4).padding(.trailing, 6)
        }
        .clipShape(EpisodePanelShape())
        .overlay(alignment: .top) {
            Capsule().fill(Color(white: 0.56)).frame(width: 43, height: 6)
                .padding(.top, 2).frame(width: 76, height: 20, alignment: .top)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 10).onEnded { value in
                    if value.translation.height > 30 { onClose() }
                })
                .accessibilityLabel("收起选集")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-episodes-panel")
        .onChange(of: selectedID) { _, id in
            if let number = episodes.first(where: { $0.id == id })?.number {
                rangeStart = ((number - 1) / 30) * 30 + 1
            }
        }
    }

    private var dramaHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            DramaPoster(drama: drama).frame(width: 72, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.7), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 10) {
                Text(drama.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Text((drama.tagNames.isEmpty ? [drama.category.rawValue] : Array(drama.tagNames.prefix(3)))
                    .joined(separator: "   "))
                    .font(.system(size: 12)).foregroundStyle(Color(white: 0.6)).lineLimit(1)
                Text("更新至第\(episodes.map(\.number).max() ?? 0)集")
                    .font(.system(size: 12)).foregroundStyle(Color(white: 0.84))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }.padding(.top, 2).padding(.trailing, 20)
            Spacer(minLength: 0)
        }.frame(height: 92, alignment: .top)
    }

    private var rangeTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(ranges) { range in
                    Button { rangeStart = range.start } label: {
                        Text(range.title).font(.system(size: 14))
                            .foregroundStyle(rangeStart == range.start ? accent : Color(white: 0.76))
                            .padding(.horizontal, 9).frame(height: 33)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(rangeStart == range.start ? accent : .clear, lineWidth: 1))
                    }
                    .accessibilityIdentifier("episode-range-\(range.start)")
                    .accessibilityAddTraits(rangeStart == range.start ? .isSelected : [])
                }
            }
        }.frame(height: 33)
    }

    private var episodeGrid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 10) {
                ForEach(visibleEpisodes) { episode in
                    EpisodeSelectionCell(episode: episode, isSelected: selectedID == episode.id,
                        accent: accent) { onSelect(episode) }
                }
            }.padding(.top, 1).padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .id(rangeStart)
        .accessibilityIdentifier("episode-selection-grid")
    }
}

private struct EpisodeSelectionCell: View {
    let episode: Episode
    let isSelected: Bool
    let accent: Color
    let onSelect: () -> Void
    private var watched: Bool { episode.looked == true && !episode.requiresCoinUnlock }

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? accent : Color(white: watched ? 0.17 : 0.22))
                VStack(spacing: 3) {
                    Text(String(format: "%02d", episode.number)).font(.system(size: 14))
                    if isSelected {
                        Image("EpisodePlaying").resizable().scaledToFit().frame(width: 12, height: 12)
                    }
                }.foregroundStyle(isSelected ? Color(white: 0.2) : Color(white: watched ? 0.6 : 0.76))
                if !isSelected {
                    if watched {
                        Image("EpisodeWatched").resizable().scaledToFit().frame(width: 16, height: 16)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .offset(x: 3, y: -3)
                    }
                    if episode.unlockCoin > 0 {
                        Image(episode.isUnlocked ? "EpisodeUnlocked" : "EpisodeLocked").renderingMode(.original)
                            .resizable().scaledToFit().frame(width: 12, height: 12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(4)
                    }
                }
            }.aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第\(episode.number)集")
        .accessibilityValue(isSelected ? "正在播放" : episode.requiresCoinUnlock ? "需\(episode.unlockCoin)金币解锁" : watched ? "已观看" : episode.unlockCoin > 0 && episode.isUnlocked ? "已解锁" : "可播放")
        .accessibilityIdentifier("episode-selection-\(episode.number)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct EpisodePanelShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        let mid = rect.midX
        var path = Path()
        path.move(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
        path.addLine(to: CGPoint(x: mid - 38, y: 0))
        path.addQuadCurve(to: CGPoint(x: mid - 32, y: 6), control: CGPoint(x: mid - 32, y: 0))
        path.addQuadCurve(to: CGPoint(x: mid - 26, y: 12), control: CGPoint(x: mid - 32, y: 12))
        path.addLine(to: CGPoint(x: mid + 26, y: 12))
        path.addQuadCurve(to: CGPoint(x: mid + 32, y: 6), control: CGPoint(x: mid + 32, y: 12))
        path.addQuadCurve(to: CGPoint(x: mid + 38, y: 0), control: CGPoint(x: mid + 32, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: radius), control: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: 0, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
