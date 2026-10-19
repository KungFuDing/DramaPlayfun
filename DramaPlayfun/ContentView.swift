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
                LaunchScreenView(errorMessage: app.guestSession.errorMessage) {
                    Task { await app.guestSession.signInIfNeeded() }
                }
            }
        }
        .task { await app.guestSession.signInIfNeeded() }
        .onChange(of: LocalizationStore.shared.language) { _, language in
            router.resetForLanguageChange()
            app.reloadLocalizedContent(for: language)
            Task { await app.appUpdate.checkForUpdates() }
        }
        .onChange(of: app.guestSession.isReady && scenePhase == .active, initial: true) { _, shouldCheck in
            guard shouldCheck else { return }
            // Let an in-flight check finish across brief inactive/active transitions.
            Task { await app.appUpdate.checkForUpdates() }
        }
        .background {
            AppUpdatePresentation(notice: app.appUpdate.notice,
                                  isOpening: app.appUpdate.isOpening,
                                  errorMessage: app.appUpdate.errorMessage,
                                  onLater: { app.appUpdate.dismiss() },
                                  onUpdate: {
                Task {
                    await app.appUpdate.openUpdate { url in
                        await UIApplication.shared.open(url, options: [:])
                    }
                }
            })
        }
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
                            case .playback(let request): PlayerView(request: request, app: app)
                            case .shortDrama(let drama):
                                ShortDramaDetailView(drama: drama, app: app) { id, favorite, count in
                                    app.theaterFeed.applyFavorite(id, isFavorite: favorite, count: count)
                                }
                            case .search: SearchView(network: app.network)
                            case .welfare: WelfareView()
                            case .settings: ProfileSettingsView()
                            case .wallet: WalletView()
                            case .history: ProfileHistoryView()
                            }
                        }
                }
                .tabItem {
                    Label {
                        Text(tab.title)
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
        .id(app.contentRevision)
        .environment(router)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $router.membershipPresented) {
            NavigationStack { MembershipView(showsNavigationBar: true).toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("完成")) { router.membershipPresented = false }
                }
            } }
        }
        .task(id: app.contentRevision) { await app.catalog.loadIfNeeded() }
        .task(id: app.contentRevision) { await app.profile.reloadProfile() }
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
