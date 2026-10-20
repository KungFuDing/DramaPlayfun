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
        GeometryReader { geometry in
            let layout = ProfileLayout(width: geometry.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Spacer()
                        NavigationLink(value: AppRoute.settings) {
                            Image(systemName: "gearshape").font(.system(size: 24, weight: .regular))
                                .frame(width: 44, height: 44).foregroundStyle(.white)
                        }.accessibilityLabel(L10n.tr("设置")).accessibilityIdentifier("profile-settings")
                    }
                    .padding(.bottom, 14)
                    if layout.hasSeparateCollectionColumn {
                        HStack(alignment: .top, spacing: layout.sectionSpacing) {
                            profileSummary(layout: layout)
                                .frame(width: layout.profileWidth)
                            collectionSection(layout: layout, emptyStateMinHeight: max(0, geometry.size.height - 120))
                                .frame(width: layout.collectionWidth)
                        }
                    } else {
                        profileSummary(layout: layout).padding(.bottom, 24)
                        collectionSection(layout: layout)
                    }
                }
                .frame(width: layout.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("profile-feed")
            .refreshable {
                await app.profile.reloadProfile()
                await app.profile.load(collection, refresh: true)
            }
        }
        .background(alignment: .top) { ProfileHeaderBackground().frame(height: 330).ignoresSafeArea(edges: .top) }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .buttonStyle(.plain)
        .task { await app.profile.reloadProfile() }
        .task(id: collection) { await app.profile.load(collection, refresh: true) }
        .alert(L10n.tr("修改昵称"), isPresented: $editingNickname) {
            TextField(L10n.tr("昵称"), text: $nickname)
            Button(L10n.tr("取消"), role: .cancel) { }
            Button(L10n.tr("保存")) {
                let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return }
                Task {
                    do { try await app.profile.updateNickname(value) }
                    catch { message = error.appLocalizedDescription }
                }
            }
        }
        .alert(L10n.tr("提示"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(L10n.tr("确定"), role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    private func profileSummary(layout: ProfileLayout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: -12) {
                identity
                membershipCard.frame(width: layout.membershipWidth).frame(maxWidth: .infinity)
            }
            shortcuts
        }
    }

    private func collectionSection(layout: ProfileLayout, emptyStateMinHeight: CGFloat = 0) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ForEach(ProfileCollection.allCases) { item in
                    Button { collection = item } label: {
                        Text(L10n.tr(item.rawValue)).font(.system(size: 14)).padding(.horizontal, 12).frame(height: 32)
                            .foregroundStyle(collection == item ? Color(white: 0.18) : Color(white: 0.7))
                            .background(collection == item ? Theme.accent : Color(white: 0.16), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityIdentifier(item == .favorites ? "profile-favorites" : "profile-likes")
                    .accessibilityAddTraits(collection == item ? .isSelected : [])
                }
            }
            collectionContent(layout: layout, emptyStateMinHeight: emptyStateMinHeight)
        }
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
                        Text(app.profile.nickname).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Image("ProfileEdit").resizable().frame(width: 18, height: 18)
                    }
                }.accessibilityLabel(L10n.tr("修改昵称"))
                Text("ID:\(app.profile.profile.userNo ?? "—")").font(.system(size: 13)).foregroundStyle(Color(white: 0.58)).lineLimit(1)
            }
            Spacer()
        }.accessibilityIdentifier("profile-identity")
    }

    private var membershipCard: some View {
        Button { router.selectedTab = .membership } label: {
            Image(hasVIP ? "ProfileMembershipActive" : "ProfileMembershipInactive")
                .resizable().aspectRatio(351.0 / 148, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    GeometryReader { geometry in
                        // Keep the text inside the artwork's card as its transparent
                        // top area and crown scale with the available width.
                        let artworkScale = geometry.size.width / 351
                        VStack(alignment: .leading, spacing: 7) {
                            Text(L10n.tr("VIP会员")).font(.system(size: 24, weight: .bold))
                                .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.85, blue: 0.45), Color(red: 1, green: 0.57, blue: 0.22)], startPoint: .leading, endPoint: .trailing))
                            Text(hasVIP ? L10n.tr("已开通,可享所有权益") : L10n.tr("未开通,开通可享所有权益"))
                                .font(.system(size: 13)).foregroundStyle(Color(red: 0.82, green: 0.78, blue: 0.65))
                            Spacer(minLength: 0)
                            Text(hasVIP ? app.profile.expiryText.map { L10n.tr("会员有效期至 %@", $0) } ?? L10n.tr("尊享会员权益") : L10n.tr("开通会员，畅享精彩好剧"))
                                .font(.system(size: 11)).foregroundStyle(Color(red: 0.77, green: 0.72, blue: 0.6))
                        }
                        .padding(.leading, 12 * artworkScale)
                        .padding(.top, 50 * artworkScale)
                        .padding(.bottom, 12 * artworkScale)
                    }
                }
        }
        .accessibilityIdentifier("profile-membership")
        .accessibilityLabel(hasVIP ? L10n.tr("VIP会员，已开通") : L10n.tr("VIP会员，未开通"))
    }

    private var shortcuts: some View {
        HStack(spacing: 14) {
            VStack(spacing: 10) {
                welfareShortcut.frame(height: 72).profileShortcutBackground()
                historyShortcut.frame(height: 72).profileShortcutBackground()
            }.frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                NavigationLink(value: AppRoute.wallet) {
                    HStack(spacing: 4) { Text(L10n.tr("我的钱包")).font(.system(size: 14, weight: .medium)); chevron; Spacer() }
                }.accessibilityIdentifier("profile-wallet")
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image("ProfileCoin").resizable().frame(width: 21, height: 21).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    Text(app.profile.profile.coinAmount.map(String.init) ?? "—").font(.system(size: 21, weight: .medium))
                    Text(L10n.tr("金币")).font(.system(size: 12)).foregroundStyle(Color(white: 0.5))
                }.padding(.top, 15)
                Spacer()
                NavigationLink(value: AppRoute.wallet) {
                    Text(L10n.tr("充值")).font(.system(size: 15, weight: .medium)).foregroundStyle(Color(white: 0.2))
                        .frame(maxWidth: .infinity).frame(height: 33).background(Theme.accent, in: Capsule())
                }
            }.padding(12).frame(maxWidth: .infinity).frame(height: 154).profileShortcutBackground()
        }.foregroundStyle(.white)
    }

    private var welfareShortcut: some View {
        NavigationLink(value: AppRoute.welfare) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) {
                    Text(L10n.tr("福利")).font(.system(size: 14, weight: .medium))
                    Image("ProfileGift").resizable().frame(width: 16, height: 16)
                    chevron
                }
                Text(L10n.tr("去领取海量金币")).font(.system(size: 12)).foregroundStyle(Color(white: 0.5))
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(12)
                .contentShape(Rectangle())
        }.accessibilityIdentifier("profile-welfare")
    }

    private var historyShortcut: some View {
        NavigationLink(value: AppRoute.history) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) { Text(L10n.tr("历史记录")).font(.system(size: 14, weight: .medium)); chevron }
                Text(L10n.tr("继续观看")).font(.system(size: 12)).foregroundStyle(Color(white: 0.5))
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(12)
                .contentShape(Rectangle())
        }.accessibilityIdentifier("profile-history")
    }

    private var chevron: some View { Image("ProfileChevron").resizable().frame(width: 16, height: 16) }

    @ViewBuilder private func collectionContent(layout: ProfileLayout, emptyStateMinHeight: CGFloat) -> some View {
        let store = app.profile
        let items = store.collections[collection] ?? []
        if items.isEmpty, store.loading.contains(collection) {
            ProgressView().frame(maxWidth: .infinity).padding(40)
        } else if items.isEmpty, let error = store.errors[collection] {
            VStack(spacing: 12) {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Button(L10n.tr("重新加载")) { Task { await store.load(collection, refresh: true) } }
            }.frame(maxWidth: .infinity).padding(.vertical, 40)
        } else if items.isEmpty {
            ContentUnavailableView(collection == .favorites ? L10n.tr("还没有收藏") : L10n.tr("还没有点赞"), systemImage: collection == .favorites ? "star" : "hand.thumbsup", description: Text(L10n.tr("在剧场发现喜欢的故事")))
                .frame(minHeight: emptyStateMinHeight)
        } else {
            HStack(alignment: .top, spacing: layout.browse.columnSpacing) {
                ForEach(0..<layout.collectionColumnCount, id: \.self) { column in
                    LazyVStack(spacing: 16) {
                        ForEach(items.enumerated().filter { $0.offset % layout.collectionColumnCount == column }.map(\.element)) { item in
                            ProfileDramaCard(item: item)
                        }
                    }.frame(maxWidth: .infinity)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("profile-collection-grid")
            if store.hasMore[collection] == true {
                Button(L10n.tr("加载更多")) { Task { await store.load(collection) } }.frame(maxWidth: .infinity).padding()
                    .disabled(store.loading.contains(collection))
            }
            if let error = store.errors[collection] { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

private struct ProfileLayout {
    let browse: BrowseLayout

    init(width: CGFloat) { browse = BrowseLayout(width: width) }

    var contentWidth: CGFloat {
        browse.isWide ? browse.contentWidth : max(0, browse.availableWidth - 24)
    }
    var hasSeparateCollectionColumn: Bool { browse.availableWidth >= 700 }
    var sectionSpacing: CGFloat { 32 }
    var profileWidth: CGFloat {
        hasSeparateCollectionColumn ? min(380, max(320, contentWidth * 0.42)) : contentWidth
    }
    var collectionWidth: CGFloat {
        hasSeparateCollectionColumn ? contentWidth - profileWidth - sectionSpacing : contentWidth
    }
    var membershipWidth: CGFloat { min(profileWidth, 440) }
    var collectionColumnCount: Int {
        max(2, min(6, Int((collectionWidth + browse.columnSpacing) / (180 + browse.columnSpacing))))
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
    let item: ProfileCollectionItem
    private var drama: Drama { item.drama }

    var body: some View {
        Button { router.openPlayback(item.drama, position: item.playbackPosition) } label: {
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
