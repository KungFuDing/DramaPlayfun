import SwiftUI

struct ContentView: View {
    @Environment(AppContainer.self) private var app
    @State private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack(path: router.path(for: tab)) {
                    tabContent(tab)
                        .navigationDestination(for: AppRoute.self) { route in
                            switch route {
                            case .drama(let drama): DramaDetailView(drama: drama)
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
            PlayerView(request: request, repository: app.repository, library: app.library)
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
