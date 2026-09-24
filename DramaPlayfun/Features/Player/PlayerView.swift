import SwiftUI
import AVKit

struct PlayerView: View {
    let request: PlaybackRequest
    @State private var session: PlaybackSession
    @State private var attempt = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(request: PlaybackRequest, repository: any DramaRepository, library: LibraryStore) {
        self.request = request
        _session = State(initialValue: PlaybackSession(request: request, repository: repository, library: library))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: session.player)
            if session.isLoading { ProgressView("视频加载中…").padding().background(.ultraThinMaterial, in: Capsule()) }
            if let message = session.errorMessage {
                VStack(spacing: 20) {
                    ContentUnavailableView("暂时无法播放", systemImage: "play.slash", description: Text(message))
                    Button("重试") { attempt += 1 }.buttonStyle(.borderedProminent)
                }.background(.black)
            }
            if session.hasEnded {
                Button("重新播放", systemImage: "arrow.counterclockwise") { session.replay() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Button { session.stop(); dismiss() } label: { Image(systemName: "xmark").padding(12) }
                    .accessibilityLabel("关闭播放")
                Text(request.drama.title).lineLimit(1)
                Spacer()
                Text("第\(request.episode.number)集").font(.caption)
            }.padding(.horizontal).background(.black)
        }
        .task(id: attempt) { await session.run() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.pause() } }
        .onDisappear { session.stop() }
    }
}
