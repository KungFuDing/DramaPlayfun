import SwiftUI
import StoreKit

struct MembershipView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var category: MembershipCategory
    @State private var selectedCoinID: String?
    @State private var managingSubscription = false
    @State private var documentMessage: String?
    var showsNavigationBar = false

    init(initialCategory: MembershipCategory = .weekly, showsNavigationBar: Bool = false) {
        _category = State(initialValue: initialCategory)
        self.showsNavigationBar = showsNavigationBar
    }

    private var store: MembershipStore { app.membership }
    private var coinPlans: [MembershipPlan] { store.plans.filter { $0.category == .coins } }
    private var selectedCoin: MembershipPlan? {
        coinPlans.first { $0.id == selectedCoinID } ?? coinPlans.first
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = MembershipLayout(width: geometry.size.width)
            VStack(spacing: 0) {
                tabs
                TabView(selection: $category) {
                    ForEach(MembershipCategory.allCases) { item in
                        page(for: item, layout: layout).tag(item)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .foregroundStyle(.white).buttonStyle(.plain)
        .background(MembershipBackground(category: category).ignoresSafeArea())
        .toolbar(showsNavigationBar ? .visible : .hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: category) { _, _ in store.clearMessage() }
        .task { await store.loadPlans() }
        .task { await app.profile.loadSettings() }
        .manageSubscriptionsSheet(isPresented: $managingSubscription)
        .alert(L10n.tr("提示"), isPresented: Binding(get: { documentMessage != nil }, set: { if !$0 { documentMessage = nil } })) {
            Button(L10n.tr("确定"), role: .cancel) { documentMessage = nil }
        } message: { Text(documentMessage ?? "") }
    }

    private func page(for category: MembershipCategory, layout: MembershipLayout) -> some View {
        let plans = store.plans.filter { $0.category == category }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if category == .coins {
                    recharge(layout: layout)
                    status(for: category, plans: plans)
                    MembershipTerms(isRecharge: true).padding(.top, 26)
                } else if layout.hasColumns {
                    HStack(alignment: .top, spacing: 28) {
                        overview(for: category, layout: layout)
                            .frame(width: layout.overviewWidth)
                        VStack(alignment: .leading, spacing: 0) {
                            offer(for: category, plans: plans, topPadding: 0)
                            status(for: category, plans: plans)
                            MembershipTerms(isRecharge: false).padding(.top, 24)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.top, 18)
                } else {
                    overview(for: category, layout: layout)
                    offer(for: category, plans: plans, topPadding: 24)
                    status(for: category, plans: plans)
                    MembershipTerms(isRecharge: false).padding(.top, 16)
                }
                footer.padding(.top, 25).padding(.bottom, 24)
            }
            .frame(width: layout.contentWidth, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("membership-content-\(category.rawValue)")
            .frame(maxWidth: .infinity)
        }.scrollIndicators(.hidden)
            .accessibilityIdentifier("membership-page-\(category.rawValue)")
    }

    private func overview(for category: MembershipCategory, layout: MembershipLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MembershipHero(category: category, entitlement: store.entitlement)
                .frame(maxWidth: layout.heroWidth)
                .frame(maxWidth: .infinity)
                .padding(.top, -10)
            MembershipBenefits(category: category).padding(.top, layout.hasColumns ? 24 : 10)
        }
    }

    private func offer(for category: MembershipCategory, plans: [MembershipPlan], topPadding: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.tr("加入会员")).font(.system(size: 16, weight: .semibold))
                .padding(.top, topPadding).padding(.bottom, 11)
            if let plan = plans.first(where: \.isAvailableForPurchase) ?? plans.first {
                MembershipOffer(plan: plan, active: store.entitlement.isActive(for: category),
                                busy: store.isPurchasing) {
                    Task { await store.purchase(plan) }
                }
            } else { unavailable(for: category) }
        }
    }

    @ViewBuilder private func status(for category: MembershipCategory, plans: [MembershipPlan]) -> some View {
        if category == self.category, let message = store.message {
            Text(message).font(.system(size: 13)).foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
                .accessibilityIdentifier("membership-message")
        }
        if !store.isLoading, plans.contains(where: { !$0.isAvailableForPurchase }) {
            Button(L10n.tr("重新加载商品")) { Task { await store.loadPlans() } }
                .font(.system(size: 13)).foregroundStyle(Theme.accent).padding(.top, 14)
                .accessibilityIdentifier("membership-reload-\(category.rawValue)")
        }
    }

    private var tabs: some View {
        HStack(spacing: 24) {
            ForEach(MembershipCategory.allCases) { item in
                Button { withAnimation(.easeInOut(duration: 0.25)) { category = item } } label: {
                    VStack(spacing: 6) {
                        Text(item.title).font(.system(size: 16, weight: item == category ? .semibold : .regular))
                            .foregroundStyle(item == category ? .white : Color.white.opacity(0.6))
                        Capsule().fill(item == category ? Theme.accent : .clear).frame(width: 18, height: 4)
                    }.padding(.top, 6).frame(minWidth: 44, minHeight: 44)
                }.accessibilityIdentifier("membership-tab-\(item.rawValue)")
                    .accessibilityAddTraits(item == category ? .isSelected : [])
            }
        }.frame(maxWidth: .infinity).padding(.top, 4).padding(.bottom, 2)
    }

    private func unavailable(for category: MembershipCategory) -> some View {
        VStack(spacing: 10) {
            if store.isLoading { ProgressView(L10n.tr("正在加载商品…")) }
            else {
                EmptyStateView(title: category == .coins ? L10n.tr("充值商品暂未开放") : L10n.tr("订阅方案暂未开放"))
                    .padding(.top, 24)
                Button(L10n.tr("重新加载")) { Task { await store.loadPlans() } }.foregroundStyle(Theme.accent)
                    .padding(.bottom, 24)
            }
        }.font(.system(size: 14)).frame(maxWidth: .infinity).frame(minHeight: 94)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }

    private func recharge(layout: MembershipLayout) -> some View {
        VStack(spacing: 0) {
            if coinPlans.isEmpty { unavailable(for: .coins).padding(.top, 16) }
            else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: layout.coinColumnCount), spacing: 11) {
                    ForEach(coinPlans) { plan in
                        MembershipCoinTile(plan: plan, selected: selectedCoin?.id == plan.id) {
                            selectedCoinID = plan.id
                        }.disabled(store.isPurchasing)
                    }
                }.padding(.top, 12)
                    .accessibilityIdentifier("membership-coin-grid")
            }
            Button {
                if let selectedCoin { Task { await store.purchase(selectedCoin) } }
            } label: {
                HStack(spacing: 8) {
                    if store.isPurchasing { ProgressView().tint(Color(red: 0.18, green: 0.12, blue: 0.02)) }
                    Text(selectedCoin.map { L10n.tr("确认购买·%@", $0.displayPrice) } ?? L10n.tr("暂无可购买商品"))
                        .font(.system(size: 15, weight: .semibold))
                }.foregroundStyle(Color(red: 0.18, green: 0.12, blue: 0.02))
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(MembershipPalette.goldButton, in: Capsule())
            }.disabled(selectedCoin?.isAvailableForPurchase != true || store.isPurchasing)
                .opacity(selectedCoin?.isAvailableForPurchase == true ? 1 : 0.5)
                .frame(maxWidth: layout.isWide ? 440 : .infinity)
                .padding(.horizontal, layout.isWide ? 0 : 28).padding(.top, layout.isWide ? 28 : 40)
                .accessibilityIdentifier("membership-buy-coins")
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button(L10n.tr("隐私政策")) { openDocument(app.profile.config.privacyPolicyUrl) }
                Text("|").foregroundStyle(.white.opacity(0.2))
                Button(L10n.tr("用户协议")) { openDocument(app.profile.config.userAgreementUrl) }
                Text("|").foregroundStyle(.white.opacity(0.2))
                Button(L10n.tr("恢复购买")) { Task { await store.restore() } }
                    .disabled(store.isPurchasing).accessibilityIdentifier("membership-restore")
            }.font(.system(size: 11)).foregroundStyle(Color(white: 0.78))
            if store.isActive {
                Button(L10n.tr("管理订阅")) { managingSubscription = true }
                    .font(.system(size: 11)).foregroundStyle(Color(white: 0.6))
            }
        }.frame(maxWidth: .infinity)
    }

    private func openDocument(_ string: String?) {
        guard let string, let url = URL(string: string), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            documentMessage = L10n.tr("文档暂时无法加载，请稍后重试。")
            return
        }
        openURL(url)
    }
}

private struct MembershipLayout {
    let availableWidth: CGFloat

    init(width: CGFloat) {
        availableWidth = max(0, width)
    }

    var isWide: Bool { availableWidth >= 600 }
    var contentWidth: CGFloat { min(max(0, availableWidth - (isWide ? 48 : 24)), 1_040) }
    var hasColumns: Bool { contentWidth >= 720 }
    var overviewWidth: CGFloat { min(440, max(351, (contentWidth - 28) * 0.44)) }
    var heroWidth: CGFloat { min(contentWidth, 440) }
    var coinColumnCount: Int {
        isWide ? max(3, min(6, Int((contentWidth + 10) / 150))) : 3
    }
}

private enum MembershipPalette {
    static let blueButton = LinearGradient(colors: [Color(red: 0.70, green: 0.78, blue: 0.94), Color(red: 0.53, green: 0.63, blue: 0.81)], startPoint: .leading, endPoint: .trailing)
    static let goldButton = LinearGradient(colors: [Color(red: 0.94, green: 0.85, blue: 0.60), Color(red: 0.87, green: 0.66, blue: 0.37)], startPoint: .leading, endPoint: .trailing)
}

private struct MembershipBackground: View {
    let category: MembershipCategory
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Theme.background
                LinearGradient(colors: [category == .weekly ? Color(red: 0.035, green: 0.08, blue: 0.15) : Color(red: 0.15, green: 0.10, blue: 0.02), Theme.background], startPoint: .top, endPoint: .bottom)
                    .frame(height: geometry.size.height * 0.76)
                RadialGradient(colors: [category == .weekly ? Color(red: 0.075, green: 0.19, blue: 0.39) : Color(red: 0.43, green: 0.31, blue: 0.04), .clear], center: .topTrailing, startRadius: 0, endRadius: geometry.size.width * 0.94)
            }
        }
    }
}

private struct MembershipHero: View {
    let category: MembershipCategory
    let entitlement: MembershipEntitlement
    private var active: Bool { entitlement.isActive(for: category) }
    var body: some View {
        Image(category.assetPrefix + (active ? "Active" : "Inactive"))
            .resizable().aspectRatio(351.0 / 148, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                GeometryReader { geometry in
                    // Insets use the same 351-point canvas as the background asset;
                    // typography stays readable without growing with tablet widths.
                    let artworkScale = geometry.size.width / 351
                    VStack(alignment: .leading, spacing: 7) {
                        Text(category.title).font(.system(size: 24, weight: .bold))
                            .foregroundStyle(LinearGradient(colors: category == .weekly ?
                                [Color(red: 0.87, green: 0.92, blue: 1), Color(red: 0.52, green: 0.63, blue: 0.83)] :
                                [Color(red: 1, green: 0.96, blue: 0.72), Color(red: 1, green: 0.67, blue: 0)], startPoint: .top, endPoint: .bottom))
                        Text(active ? L10n.tr("已开通,可享所有权益") : L10n.tr("开通会员立享所有权益"))
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                        if active, let expiry = entitlement.expirationDate {
                            Text(L10n.tr("会员有效期至 %@", expiry.formatted(.iso8601.year().month().day().dateSeparator(.dash))))
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).padding(.top, 16)
                                .accessibilityIdentifier("membership-expiry")
                        }
                    }
                    .padding(.leading, 12 * artworkScale)
                    .padding(.top, 45 * artworkScale)
                }
            }.accessibilityElement(children: .combine)
            .accessibilityIdentifier("membership-hero-\(category.rawValue)-\(active ? "active" : "inactive")")
    }
}

private struct MembershipBenefits: View {
    let category: MembershipCategory
    private var items: [(String, String, String)] { [("HD", L10n.tr("高清1080P"), L10n.tr("享高清画面")), ("Unlimited", L10n.tr("无限制观看"), L10n.tr("随意观看任意剧集")),
                         ("Exclusive", L10n.tr("会员专享剧"), L10n.tr("享高质量短剧")), ("Cache", L10n.tr("加速缓存"), L10n.tr("流畅看剧更方便"))] }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("会员权益")).font(.system(size: 16, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 10) {
                ForEach(items, id: \.0) { item in
                    HStack(spacing: 12) {
                        Image(category.assetPrefix + item.0).resizable().frame(width: 44, height: 44).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.1).font(.system(size: 15)).foregroundStyle(Color(white: 0.9))
                            Text(item.2).font(.system(size: 12)).foregroundStyle(Color(white: 0.46))
                        }.lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
        }
    }
}

private struct MembershipOffer: View {
    let plan: MembershipPlan
    let active: Bool
    let busy: Bool
    let purchase: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Text(plan.displayPrice).font(.system(size: plan.usesPricePlaceholder ? 13 : 23, weight: .medium))
                .foregroundStyle(plan.category == .weekly ? Color(red: 0.85, green: 0.9, blue: 0.97) : Color(red: 0.95, green: 0.89, blue: 0.77))
                .lineLimit(1).minimumScaleFactor(0.55).frame(maxWidth: 84)
            VStack(alignment: .leading, spacing: 5) {
                Text(plan.category.title).font(.system(size: 16, weight: .semibold))
                Text(L10n.tr("%@以%@自动续费，可随时取消", plan.category.renewalPeriod, plan.displayPrice))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: purchase) {
                Group {
                    if busy { ProgressView().tint(.white) }
                    else { Text(active ? L10n.tr("已开通") : L10n.tr("立即开通")).font(.system(size: 14, weight: .medium)) }
                }.foregroundStyle(active ? Color.white.opacity(0.55) : Color(red: 0.06, green: 0.12, blue: 0.20))
                    .frame(width: 80, height: 32)
                    .background {
                        if active { Capsule().fill(.white.opacity(0.2)) }
                        else { Capsule().fill(plan.category == .weekly ? MembershipPalette.blueButton : MembershipPalette.goldButton) }
                    }
            }.disabled(active || busy || !plan.isAvailableForPurchase)
                .opacity(plan.isAvailableForPurchase ? 1 : 0.5)
                .accessibilityIdentifier("membership-buy-\(plan.category.rawValue)")
        }.padding(.horizontal, 16).padding(.vertical, 18).frame(minHeight: 94)
            .background(plan.category == .weekly ? Color(red: 0.15, green: 0.19, blue: 0.29) : Color(red: 0.30, green: 0.25, blue: 0.16), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(plan.category == .weekly ? Color(red: 0.53, green: 0.63, blue: 0.81) : Color(red: 0.80, green: 0.74, blue: 0.60), lineWidth: 1))
    }
}

private struct MembershipCoinTile: View {
    let plan: MembershipPlan
    let selected: Bool
    let select: () -> Void
    var body: some View {
        Button(action: select) {
            VStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image("WelfareCoin").resizable().frame(width: 21, height: 21)
                    Text("+" + String(plan.coinAmount)).font(.system(size: 18, weight: .medium)).lineLimit(1).minimumScaleFactor(0.6)
                }
                Text(plan.displayPrice).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(.white.opacity(0.1), in: Capsule())
            }.frame(maxWidth: .infinity).frame(height: 110)
                .background(selected ? Theme.accent.opacity(0.08) : .white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.accent : .white.opacity(0.22), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if plan.giftCoinAmount > 0 {
                        Text(L10n.tr("赠%lld金币", plan.giftCoinAmount)).font(.system(size: 11)).foregroundStyle(Color(white: 0.15))
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .padding(.horizontal, 6).frame(height: 19)
                            .background(Image("MembershipPromotion").resizable())
                            .offset(y: -6)
                    }
                }
        }.accessibilityIdentifier("membership-coin-\(plan.id)")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct MembershipTerms: View {
    let isRecharge: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isRecharge ? L10n.tr("充值说明") : L10n.tr("订阅说明")).font(.system(size: 14, weight: .bold))
            VStack(alignment: .leading, spacing: 7) {
                if isRecharge {
                    Text(LocalizedStringKey(L10n.tr("**1、金币用途**：充值获得的虚拟“金币”仅限在本 App 内解锁付费短剧剧集使用，无现金价值，**不支持提现、转让、转赠或在非本 App 渠道交易**。")))
                    Text(LocalizedStringKey(L10n.tr("**2、到账时效**：金币充值成功后通常立即到账。如遇网络延迟，请尝试重新启动 App 或在个人中心联系客服。")))
                    Text(LocalizedStringKey(L10n.tr("**3、退款政策**：鉴于虚拟数字化商品的特殊属性，**金币充值一旦成功即代表服务已完成，除法律明确规定外，不予退款**。")))
                    Text(LocalizedStringKey(L10n.tr("4、**有效期限制**：直接充值购买的金币**永久有效**；通过每日签到、任务活动等方式获赠的“赠送金币/体验金币”可能存在有效期，过期将自动失效，请优先使用。")))
                } else {
                    Text(LocalizedStringKey(L10n.tr("**1、畅享剧集**：订阅生效后，所有 **[DramaPlayfun]** 系列节目均可畅享观看，有效期内不限观看次数。")))
                    Text(LocalizedStringKey(L10n.tr("**2、自动续费**：本订阅采用自动续费方式。若未取消，系统将在当前订阅到期前 **24 小时内**，自动从您的绑定账户扣取下一期费用，续费价格与当期价格一致。")))
                    Text(LocalizedStringKey(L10n.tr("**3、随时管理**：您可随时管理或取消自动续订。如不再续订，请**至少提前 24 小时**操作：**iOS 路径**：通过“设置 > [您的 Apple ID] > 订阅 > [DramaPlayfun]”关闭。")))
                }
            }.font(.system(size: 13)).lineSpacing(7).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(Color(white: 0.46)).frame(maxWidth: .infinity, alignment: .leading)
    }
}
