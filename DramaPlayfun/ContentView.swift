import SwiftUI

struct ContentView: View {
    @Environment(AppContainer.self) private var app
    @State private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if app.guestSession.isReady {
                appContent
            } else {
                VStack(spacing: 16) {
                    if let message = app.guestSession.errorMessage {
                        Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("重新连接") { Task { await app.guestSession.signInIfNeeded() } }
                            .buttonStyle(.borderedProminent)
                    } else {
                        ProgressView("正在连接…")
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background.ignoresSafeArea())
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
            }
        }
        .task { await app.guestSession.signInIfNeeded() }
    }

    @ViewBuilder
    private var appContent: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack(path: router.path(for: tab)) {
                    tabContent(tab)
                        .navigationDestination(for: AppRoute.self) { route in
                            switch route {
                            case .drama(let drama): DramaDetailView(drama: drama)
                            case .shortDrama(let drama):
                                ShortDramaDetailView(drama: drama, app: app) { id, favorite, count in
                                    app.theaterFeed.applyFavorite(id, isFavorite: favorite, count: count)
                                }
                            }
                        }
                }
                .tabItem {
                    Label {
                        Text(tab.rawValue)
                    } icon: {
                        Image(tab.iconAsset(isSelected: router.selectedTab == tab))
                            .renderingMode(.original)
                    }
                }
                .tag(tab)
                .toolbarBackground(Theme.surface, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
            }
        }
        .environment(router)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $router.playback) { request in
            PlayerView(request: request, app: app)
        }
        .sheet(isPresented: $router.membershipPresented) {
            NavigationStack { MembershipView().toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { router.membershipPresented = false }
                }
            } }
        }
        .task { await app.catalog.loadIfNeeded() }
        .task { await app.membership.observeTransactions() }
        .task(id: scenePhase) {
            if scenePhase == .active { await app.membership.refresh() }
        }
    }

    @ViewBuilder private func tabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .home: HomeView()
        case .theater: TheaterView()
        case .rankings: RankingsView()
        case .membership: MembershipView()
        case .profile: ProfileView()
        }
    }
}

#Preview { ContentView().environment(AppContainer()) }
