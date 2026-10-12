import SwiftUI

struct ProfileView: View {
    @Environment(AppContainer.self) private var app
    @Environment(AppRouter.self) private var router
    @State private var collection: ProfileCollection = .favorites
    @State private var editingNickname = false
    @State private var nickname = ""
    @State private var message: String?

    private var hasVIP: Bool { app.profile.hasVIP || app.membership.isActive }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    NavigationLink { ProfileSettingsView() } label: {
                        Image(systemName: "gearshape").font(.system(size: 24, weight: .regular))
                            .frame(width: 44, height: 44).foregroundStyle(.white)
                    }.accessibilityLabel("设置").accessibilityIdentifier("profile-settings")
                }
                .padding(.bottom, 14)
                identity.padding(.bottom, -12)
                membershipCard.padding(.bottom, 10)
                shortcuts.padding(.bottom, 24)
                HStack(spacing: 12) {
                    ForEach(ProfileCollection.allCases) { item in
                        Button { collection = item } label: {
                            Text(item.rawValue).font(.system(size: 14)).padding(.horizontal, 12).frame(height: 32)
                                .foregroundStyle(collection == item ? Color(white: 0.18) : Color(white: 0.7))
                                .background(collection == item ? Theme.accent : Color(white: 0.16), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .accessibilityIdentifier(item == .favorites ? "profile-favorites" : "profile-likes")
                        .accessibilityAddTraits(collection == item ? .isSelected : [])
                    }
                }.padding(.bottom, 10)
                collectionContent
            }
            .padding(.horizontal, 12).padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .background(alignment: .top) { ProfileHeaderBackground().frame(height: 330).ignoresSafeArea(edges: .top) }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .buttonStyle(.plain)
        .task { await app.profile.reloadProfile() }
        .task(id: collection) { await app.profile.load(collection, refresh: true) }
        .refreshable {
            await app.profile.reloadProfile()
            await app.profile.load(collection, refresh: true)
        }
        .alert("修改昵称", isPresented: $editingNickname) {
            TextField("昵称", text: $nickname)
            Button("取消", role: .cancel) { }
            Button("保存") {
                let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return }
                Task {
                    do { try await app.profile.updateNickname(value) }
                    catch { message = error.localizedDescription }
                }
            }
        }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    private var identity: some View {
        HStack(spacing: 10) {
            CachedRemoteImage(url: app.profile.profile.avatarUrl.flatMap(URL.init(string:))) {
                Image("ProfileAvatar").resizable().scaledToFit()
            }.frame(width: 50, height: 50).clipShape(Circle())
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    nickname = app.profile.nickname
                    editingNickname = true
                } label: {
                    HStack(spacing: 8) {
                        Text(app.profile.nickname).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        Image("ProfileEdit").resizable().frame(width: 18, height: 18)
                    }
                }.accessibilityLabel("修改昵称")
                Text("ID:\(app.profile.profile.userNo ?? "—")").font(.system(size: 13)).foregroundStyle(Color(white: 0.58))
            }
            Spacer()
        }
    }

    private var membershipCard: some View {
        Button { router.selectedTab = .membership } label: {
            Image(hasVIP ? "ProfileMembershipActive" : "ProfileMembershipInactive")
                .resizable().aspectRatio(351.0 / 148, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("VIP会员").font(.system(size: 24, weight: .bold))
                            .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.85, blue: 0.45), Color(red: 1, green: 0.57, blue: 0.22)], startPoint: .leading, endPoint: .trailing))
                        Text(hasVIP ? "已开通,可享所有权益" : "未开通,开通可享所有权益")
                            .font(.system(size: 13)).foregroundStyle(Color(red: 0.82, green: 0.78, blue: 0.65))
                        Spacer(minLength: 0)
                        Text(hasVIP ? app.profile.expiryText.map { "会员有效期至 \($0)" } ?? "尊享会员权益" : "开通会员，畅享精彩好剧")
                            .font(.system(size: 11)).foregroundStyle(Color(red: 0.77, green: 0.72, blue: 0.6))
                    }.padding(.leading, 12).padding(.top, 50).padding(.bottom, 12)
                }
        }
        .accessibilityIdentifier("profile-membership")
        .accessibilityLabel(hasVIP ? "VIP会员，已开通" : "VIP会员，未开通")
    }

    private var shortcuts: some View {
        HStack(spacing: 14) {
            VStack(spacing: 10) {
                NavigationLink { WelfareView() } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 4) {
                            Text("福利").font(.system(size: 14, weight: .medium))
                            Image("ProfileGift").resizable().frame(width: 16, height: 16)
                            chevron
                        }
                        Text("去领取海量金币").font(.system(size: 12)).foregroundStyle(Color(white: 0.5))
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(height: 72).profileShortcutBackground().accessibilityIdentifier("profile-welfare")
                NavigationLink { ProfileHistoryView() } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 4) { Text("历史记录").font(.system(size: 14, weight: .medium)); chevron }
                        Text("继续观看").font(.system(size: 12)).foregroundStyle(Color(white: 0.5))
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(height: 72).profileShortcutBackground().accessibilityIdentifier("profile-history")
            }
            VStack(alignment: .leading, spacing: 0) {
                NavigationLink { WalletView() } label: {
                    HStack(spacing: 4) { Text("我的钱包").font(.system(size: 14, weight: .medium)); chevron; Spacer() }
                }.accessibilityIdentifier("profile-wallet")
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image("ProfileCoin").resizable().frame(width: 21, height: 21).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    Text(app.profile.profile.coinAmount.map(String.init) ?? "—").font(.system(size: 21, weight: .medium))
                    Text("金币").font(.system(size: 12)).foregroundStyle(Color(white: 0.5))
                }.padding(.top, 15)
                Spacer()
                NavigationLink { WalletView() } label: {
                    Text("充值").font(.system(size: 15, weight: .medium)).foregroundStyle(Color(white: 0.2))
                        .frame(maxWidth: .infinity).frame(height: 33).background(Theme.accent, in: Capsule())
                }
            }.padding(12).frame(maxWidth: .infinity).frame(height: 154).profileShortcutBackground()
        }.foregroundStyle(.white)
    }

    private var chevron: some View { Image("ProfileChevron").resizable().frame(width: 16, height: 16) }

    @ViewBuilder private var collectionContent: some View {
        let store = app.profile
        let dramas = store.collections[collection] ?? []
        if dramas.isEmpty, store.loading.contains(collection) {
            ProgressView().frame(maxWidth: .infinity).padding(40)
        } else if dramas.isEmpty, let error = store.errors[collection] {
            VStack(spacing: 12) {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Button("重新加载") { Task { await store.load(collection, refresh: true) } }
            }.frame(maxWidth: .infinity).padding(.vertical, 40)
        } else if dramas.isEmpty {
            ContentUnavailableView(collection == .favorites ? "还没有收藏" : "还没有点赞", systemImage: collection == .favorites ? "star" : "hand.thumbsup", description: Text("在剧场发现喜欢的故事"))
        } else {
            HStack(alignment: .top, spacing: 14) {
                ForEach(0..<2) { column in
                    LazyVStack(spacing: 16) {
                        ForEach(dramas.enumerated().filter { $0.offset % 2 == column }.map(\.element)) { drama in
                            ProfileDramaCard(drama: drama)
                        }
                    }.frame(maxWidth: .infinity)
                }
            }
            if store.hasMore[collection] == true {
                Button("加载更多") { Task { await store.load(collection) } }.frame(maxWidth: .infinity).padding()
                    .disabled(store.loading.contains(collection))
            }
            if let error = store.errors[collection] { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

private struct ProfileHeaderBackground: View {
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let gold = Color(red: 0.68, green: 0.44, blue: 0.1)
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(Gradient(colors: [gold.opacity(0.28), .clear]), center: CGPoint(x: size.width, y: 0), startRadius: 0, endRadius: size.width * 0.8))
                for offset in [0.28, 0.78] {
                    var beam = Path()
                    beam.move(to: CGPoint(x: size.width * offset, y: 0))
                    beam.addLine(to: CGPoint(x: size.width * (offset + 0.12), y: 0))
                    beam.addLine(to: CGPoint(x: size.width * (offset - 0.48), y: size.height))
                    beam.addLine(to: CGPoint(x: size.width * (offset - 0.6), y: size.height))
                    beam.closeSubpath()
                    context.fill(beam, with: .linearGradient(Gradient(colors: [gold.opacity(0.12), gold.opacity(0.01)]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
                }
                for index in 0..<900 {
                    let x = CGFloat((index * 137 + 29) % 997) / 997 * size.width
                    let y = CGFloat((index * 79 + 17) % 991) / 991 * size.height
                    let radius: CGFloat = index % 9 == 0 ? 1.5 : 0.6
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius, height: radius)), with: .color(gold.opacity(x > size.width * 0.7 ? 0.38 : 0.16)))
                }
            }
            .frame(width: geometry.size.width)
            .mask(LinearGradient(colors: [.white, .white, .clear], startPoint: .top, endPoint: .bottom))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private extension View {
    func profileShortcutBackground() -> some View {
        background(LinearGradient(colors: [Color(red: 0.31, green: 0.27, blue: 0.14), Color(red: 0.20, green: 0.14, blue: 0.10), Color(red: 0.36, green: 0.22, blue: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color(white: 0.55).opacity(0.4), lineWidth: 1) }
    }
}

struct ProfileDramaCard: View {
    @Environment(AppRouter.self) private var router
    let drama: Drama
    var body: some View {
        Button { router.openPlayback(drama) } label: {
            VStack(alignment: .leading, spacing: 0) {
                CachedRemoteImage(url: drama.coverURL) {
                    Rectangle().fill(Theme.surface).overlay { Image(systemName: "film").foregroundStyle(Theme.accent) }
                }.aspectRatio(0.77, contentMode: .fit)
                VStack(alignment: .leading, spacing: 7) {
                    Text(drama.title).font(.system(size: 14)).lineLimit(2).foregroundStyle(Color(white: 0.86))
                    let subtitle = drama.displayTags.isEmpty ? drama.summary : drama.displayTags
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11)).foregroundStyle(Color(white: 0.5)).lineLimit(1) }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityIdentifier("profile-drama-\(drama.id)")
    }
}

struct ProfileHistoryView: View {
    @Environment(AppContainer.self) private var app
    @Environment(AppRouter.self) private var router
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(app.watchHistory.items) { item in
                    Button {
                        item.prepareResume(in: app.library)
                        router.openPlayback(item.drama)
                    } label: {
                        HStack(spacing: 12) {
                            DramaPoster(drama: item.drama).frame(width: 72)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.drama.title).font(.headline)
                                Text(item.isOnline ? item.subtitle : "已下架").font(.footnote).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).disabled(!item.isOnline)
                }
                if app.watchHistory.isLoading { ProgressView().padding() }
                if let error = app.watchHistory.errorMessage { Text(error).font(.footnote); Button("重试") { Task { await app.watchHistory.reload() } } }
                if !app.watchHistory.isLoading, app.watchHistory.errorMessage == nil, app.watchHistory.items.isEmpty {
                    ContentUnavailableView("还没有观看记录", systemImage: "clock")
                }
                if app.watchHistory.hasMore { Button("加载更多") { Task { await app.watchHistory.loadMore() } } }
            }.padding(12)
        }.screenBackground().navigationTitle("历史记录").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar).toolbar(.hidden, for: .tabBar)
            .task { await app.watchHistory.reload() }.refreshable { await app.watchHistory.reload() }
    }
}
