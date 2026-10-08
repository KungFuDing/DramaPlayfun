import SwiftUI
import Observation

struct ShortDramaDetailView: View {
    @State private var store: ShortDramaDetailStore
    @State private var scoreIndex = Int.random(in: 0..<5)
    @State private var isExpanded = false
    @State private var recommendedPlayback: PlaybackRequest?
    @Environment(\.dismiss) private var dismiss
    private let onFavoriteChanged: (Drama.ID, Bool, Int?) -> Void

    init(drama: Drama, app: AppContainer,
         onFavoriteChanged: @escaping (Drama.ID, Bool, Int?) -> Void = { _, _, _ in }) {
        _store = State(initialValue: ShortDramaDetailStore(drama: drama, app: app))
        self.onFavoriteChanged = onFavoriteChanged
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    ShortDramaHero(drama: store.drama)
                        .frame(height: geometry.size.width * 0.875)
                    ShortDramaRating(selectedIndex: scoreIndex)
                        .frame(height: 74).padding(.top, 18)
                    followButton.padding(.horizontal, 40).padding(.top, 20).padding(.bottom, 24)
                    if let error = store.detailError {
                        retryMessage(error) { Task { await loadDetail() } }
                            .padding(.horizontal, 12).padding(.bottom, 16)
                    }
                    ShortDramaSummary(drama: store.drama, isExpanded: $isExpanded)
                        .padding(.horizontal, 12)
                    recommendations.padding(.top, 18).padding(.bottom, 32)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left").font(.system(size: 21, weight: .light))
                        Text("详情").font(.system(size: 17, weight: .medium))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 18).frame(height: 44)
                    .shadow(color: .black.opacity(0.5), radius: 5)
                }.accessibilityLabel("返回").accessibilityIdentifier("short-drama-back")
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(.white)
        .toolbar(.hidden, for: .navigationBar, .tabBar)
        .fullScreenCover(item: $recommendedPlayback) { request in
            PlayerView(request: request, app: store.app)
        }
        .task {
            async let detail: Void = loadDetail()
            async let recommendations: Void = store.loadRecommendations()
            _ = await (detail, recommendations)
        }
        .alert("操作失败", isPresented: Binding(get: { store.favoriteError != nil },
            set: { if !$0 { store.favoriteError = nil } })) {
            Button("知道了", role: .cancel) { store.favoriteError = nil }
        } message: { Text(store.favoriteError ?? "") }
    }

    private func loadDetail() async {
        await store.loadDetail()
        if store.hasDetail {
            onFavoriteChanged(store.drama.id, store.isFavorited, store.favoriteCount)
        }
    }

    private var followButton: some View {
        Button {
            Task {
                if await store.toggleFavorite() {
                    onFavoriteChanged(store.drama.id, store.isFavorited, store.favoriteCount)
                }
            }
        } label: {
            HStack(spacing: 6) {
                if store.isFavoriting || store.isLoadingDetail { ProgressView().tint(store.isFavorited ? Theme.accent : Theme.background) }
                else { Image(systemName: "star.fill").font(.system(size: 16)) }
                Text(store.isFavorited ? "已追剧" : "追剧").font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(store.isFavorited ? Theme.accent : Theme.background)
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(store.isFavorited ? Color.clear : Theme.accent, in: Capsule())
            .overlay(Capsule().stroke(Theme.accent.opacity(store.isFavorited ? 0.8 : 0), lineWidth: 1))
        }
        .buttonStyle(.plain).disabled(!store.hasDetail || store.isFavoriting)
        .accessibilityIdentifier("short-drama-follow")
        .accessibilityValue(store.isFavorited ? "已追剧" : "未追剧")
    }

    private var recommendations: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("为你推荐").font(.system(size: 15, weight: .semibold))
                .background(alignment: .trailing) {
                    Image("HomeHeadingGlow").resizable().scaledToFit().frame(width: 38, height: 27).offset(x: 12)
                }.padding(.horizontal, 12)
            if store.isLoadingRecommendations { ProgressView().frame(maxWidth: .infinity).padding(24) }
            else if let error = store.recommendationError {
                retryMessage(error) { Task { await store.loadRecommendations() } }.padding(.horizontal, 12)
            } else if store.recommendations.isEmpty {
                Text("暂无推荐").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 12)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(store.recommendations) { drama in
                            Button {
                                recommendedPlayback = PlaybackRequest(drama: drama,
                                    episode: Episode(id: "", number: 1, title: "第1集", requiresMembership: false))
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    DramaPoster(drama: drama)
                                    Text(drama.title).font(.system(size: 14)).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(drama.tagNames.joined(separator: "   "))
                                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                                }.frame(width: 130)
                            }.buttonStyle(.plain).accessibilityIdentifier("short-drama-recommendation-\(drama.id)")
                        }
                    }.padding(.horizontal, 12)
                }.scrollIndicators(.hidden)
            }
        }.accessibilityIdentifier("short-drama-recommendations")
    }

    private func retryMessage(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("重新加载", action: retry).font(.subheadline).foregroundStyle(Theme.accent)
        }.frame(maxWidth: .infinity)
    }
}

private struct ShortDramaHero: View {
    let drama: Drama
    var body: some View {
        CachedRemoteImage(url: drama.coverURL) {
            LinearGradient(colors: [.indigo.opacity(0.6), Theme.surface], startPoint: .top, endPoint: .bottom)
        }
        .overlay(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
        }
        .clipShape(ShortDramaCoverShape())
        .overlay {
            ShortDramaCoverRim().stroke(LinearGradient(colors: [Color(red: 0.62, green: 0.82, blue: 0.22),
                Color(red: 0.85, green: 0.72, blue: 0.39), Color(red: 0.76, green: 0.39, blue: 0.16)],
                startPoint: .leading, endPoint: .trailing), lineWidth: 7)
        }.accessibilityHidden(true)
    }
}

private struct ShortDramaCoverShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: rect.maxX, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 26))
            path.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - 26), control: CGPoint(x: rect.midX, y: rect.maxY + 26))
            path.closeSubpath()
        }
    }
}

private struct ShortDramaCoverRim: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: rect.maxY - 26))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - 26), control: CGPoint(x: rect.midX, y: rect.maxY + 26))
        }
    }
}

private struct ShortDramaRating: View {
    let selectedIndex: Int
    private let scores = ["7.5", "8.0", "8.5", "9.0", "9.5"]
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - 84
            ZStack(alignment: .topLeading) {
                Ellipse().fill(Color(red: 0.8, green: 0.67, blue: 0.4).opacity(0.3))
                    .frame(width: width, height: 20).blur(radius: 18).offset(x: 42, y: 15)
                Path { path in
                    path.move(to: CGPoint(x: 22, y: 12))
                    path.addQuadCurve(to: CGPoint(x: geometry.size.width - 22, y: 12),
                        control: CGPoint(x: geometry.size.width / 2, y: 50))
                }.stroke(LinearGradient(colors: [.clear, Color(red: 0.84, green: 0.66, blue: 0.28), .clear],
                    startPoint: .leading, endPoint: .trailing), lineWidth: 2)
                ForEach(scores.indices, id: \.self) { index in
                    let fraction = CGFloat(index) / 4
                    let x = 42 + width * fraction
                    let curveFraction = (x - 22) / (geometry.size.width - 44)
                    let y = 12 + 76 * curveFraction * (1 - curveFraction)
                    Circle().fill(index == selectedIndex ? Color(red: 1, green: 0.5, blue: 0.35) : Color.gray)
                        .frame(width: index == selectedIndex ? 12 : (index == 0 || index == 4 ? 6 : 8),
                               height: index == selectedIndex ? 12 : (index == 0 || index == 4 ? 6 : 8))
                        .overlay { if index == selectedIndex { Circle().stroke(.white, lineWidth: 3) } }
                        .position(x: x, y: y)
                    if index != selectedIndex {
                        Text("评分" + scores[index]).font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                            .position(x: x, y: y + 17)
                    } else {
                        Text("评分" + scores[index]).font(.system(size: 14)).foregroundStyle(Color(red: 0.96, green: 0.79, blue: 0.28))
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(LinearGradient(colors: [Color(red: 0.53, green: 0.46, blue: 0.25),
                                Color(red: 0.3, green: 0.22, blue: 0.12)], startPoint: .top, endPoint: .bottom), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                            .position(x: x, y: y + 29)
                            .accessibilityIdentifier("short-drama-score")
                    }
                }
            }
        }
    }
}

private struct ShortDramaSummary: View {
    let drama: Drama
    @Binding var isExpanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(drama.title).font(.system(size: 17, weight: .semibold))
            ViewThatFits(in: .horizontal) {
                tags
                ScrollView(.horizontal) { tags }.scrollIndicators(.hidden)
            }
            Text("剧情简介").font(.system(size: 15, weight: .medium)).padding(.top, 14)
            Text(drama.summary.isEmpty ? "暂无简介" : drama.summary)
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineSpacing(7)
                .lineLimit(isExpanded ? nil : 3).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("short-drama-summary")
            if !drama.summary.isEmpty {
                Button(isExpanded ? "收起" : "展开") { isExpanded.toggle() }
                    .font(.system(size: 12)).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("short-drama-expand")
            }
        }.padding(12).padding(.vertical, 3)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var tags: some View {
        HStack(spacing: 10) {
            ForEach(Array(drama.tagNames.enumerated()), id: \.offset) { _, tag in chip(tag) }
            if drama.episodeCount > 0 { chip("共\(drama.episodeCount)集") }
        }
    }
    private func chip(_ title: String) -> some View {
        Text(title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4)).fixedSize()
    }
}

@MainActor @Observable
final class ShortDramaDetailStore {
    private(set) var drama: Drama
    private(set) var recommendations: [Drama] = []
    private(set) var isFavorited = false
    private(set) var favoriteCount: Int?
    private(set) var hasDetail = false
    private(set) var isLoadingDetail = false
    private(set) var isLoadingRecommendations = false
    private(set) var isFavoriting = false
    private(set) var detailError: String?
    private(set) var recommendationError: String?
    var favoriteError: String?
    let app: AppContainer

    init(drama: Drama, app: AppContainer) { self.drama = drama; self.app = app }

    func loadDetail() async {
        guard !isLoadingDetail else { return }
        isLoadingDetail = true
        detailError = nil
        defer { isLoadingDetail = false }
        do {
            guard let id = Int64(drama.id) else { throw CatalogError.notFound }
            let response = try await app.network.request(AppAPI.v1ClientDramaDetail,
                body: .init(dramaId: id), unwrapEnvelope: true)
            try Task.checkCancellation()
            guard let raw = response.drama else { throw CatalogError.notFound }
            drama = Drama(id: drama.id, title: raw.dramaTitle ?? drama.title,
                summary: raw.dramaDesc ?? drama.summary, category: drama.category,
                episodeCount: raw.episodePassed ?? drama.episodeCount, heat: raw.favoriteCount ?? drama.heat,
                badge: drama.badge, coverURL: raw.coverUrl.flatMap(URL.init(string:)) ?? drama.coverURL,
                tagNames: raw.tagNames ?? drama.tagNames, rootDramaID: raw.rootDramaId ?? drama.rootDramaID)
            isFavorited = raw.isFavorited ?? false
            favoriteCount = raw.favoriteCount
            app.library.setFavorite(drama.id, isFavorite: isFavorited)
            hasDetail = true
        } catch is CancellationError {
        } catch { detailError = error.localizedDescription }
    }

    func loadRecommendations() async {
        guard !isLoadingRecommendations else { return }
        isLoadingRecommendations = true
        recommendationError = nil
        defer { isLoadingRecommendations = false }
        do {
            guard let id = Int64(drama.id) else { throw CatalogError.notFound }
            let response = try await app.network.request(AppAPI.v1ClientDramaGuessLike,
                body: .init(dramaId: id), unwrapEnvelope: true)
            try Task.checkCancellation()
            var seen: Set<String> = []
            recommendations = (response.list ?? []).compactMap { raw in
                guard let id = raw.dramaId ?? raw.id, let title = raw.dramaTitle, !title.isEmpty,
                      seen.insert(String(id)).inserted else { return nil }
                return Drama(id: String(id), title: title, summary: "", category: .all, episodeCount: 0,
                    heat: 0, badge: raw.badge, coverURL: raw.coverUrl.flatMap(URL.init(string:)),
                    tagNames: raw.tagNames ?? [], rootDramaID: raw.rootDramaId)
            }
        } catch is CancellationError {
        } catch { recommendationError = error.localizedDescription }
    }

    func toggleFavorite() async -> Bool {
        guard hasDetail, !isFavoriting, let id = Int64(drama.id) else { return false }
        isFavoriting = true
        favoriteError = nil
        defer { isFavoriting = false }
        do {
            let favorite = !isFavorited
            let response = try await app.network.request(AppAPI.v1ClientDramaFavorite,
                body: .init(dramaId: id, favorite: favorite), unwrapEnvelope: true)
            let value = response.isFavorited ?? favorite
            favoriteCount = response.favoriteCount ?? favoriteCount.map {
                max(0, $0 + (value == isFavorited ? 0 : (value ? 1 : -1)))
            }
            isFavorited = value
            app.library.setFavorite(drama.id, isFavorite: isFavorited)
            return true
        } catch { favoriteError = error.localizedDescription; return false }
    }
}
