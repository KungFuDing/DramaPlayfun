import SwiftUI
import UIKit
import Kingfisher
import SafariServices

private enum SettingsPanel: String, Identifiable {
    case language, contact, deactivate
    var id: Self { self }
    var title: String {
        switch self {
        case .language: L10n.tr("语言切换")
        case .contact: L10n.tr("联系客服")
        case .deactivate: L10n.tr("确定要注销帐户吗？")
        }
    }
}

struct ProfileSettingsView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var panel: SettingsPanel?
    @State private var cacheBytes: UInt = 0
    @State private var clearingCache = false
    @State private var document: SettingsDocument?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image("SettingsBack").renderingMode(.original).resizable().scaledToFit()
                        .frame(width: 22, height: 22)
                        .frame(width: 22, height: 44)
                }.accessibilityLabel(L10n.tr("返回")).accessibilityIdentifier("settings-back")
                Text(L10n.tr("设置")).font(.system(size: 18, weight: .semibold))
                Spacer()
            }.padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 18)
            ScrollView {
                VStack(spacing: 10) {
                    SettingsRow(title: L10n.tr("清理缓存"), identifier: "清理缓存", icon: "SettingsCache", detail: clearingCache ? L10n.tr("清理中…") : "\(cacheBytes / 1_000_000) MB") {
                        Task { await clearCache() }
                    }.disabled(clearingCache).frame(height: 48)
                        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12))
                    VStack(spacing: 0) {
                        SettingsRow(title: L10n.tr("联系客服"), identifier: "联系客服", icon: "SettingsContact") { panel = .contact }
                        rowDivider
                        SettingsRow(title: L10n.tr("语言切换"), identifier: "语言切换", icon: "SettingsLanguage") { panel = .language }
                        rowDivider
                        SettingsRow(title: L10n.tr("隐私政策"), identifier: "隐私政策", icon: "SettingsPrivacy") { openDocument(app.profile.config.privacyPolicyUrl, title: L10n.tr("隐私政策")) }
                        rowDivider
                        SettingsRow(title: L10n.tr("用户协议"), identifier: "用户协议", icon: "SettingsAgreement") { openDocument(app.profile.config.userAgreementUrl, title: L10n.tr("用户协议")) }
                        rowDivider
                        SettingsRow(title: L10n.tr("注销账号"), identifier: "注销账号", icon: "SettingsDeactivate") { panel = .deactivate }
                    }.background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12))
                }.padding(.horizontal, 12)
            }.scrollIndicators(.hidden)
            Text(L10n.tr("v%@版本", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"))
                .font(.system(size: 12)).foregroundStyle(Color(white: 0.58)).padding(.bottom, 58)
        }
        .foregroundStyle(.white).background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar).toolbar(.hidden, for: .tabBar)
        .navigationBackGesture(isEnabled: panel == nil)
        .buttonStyle(.plain)
        .overlay {
            if let panel {
                SettingsBottomPanel(kind: panel) { self.panel = nil }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.22), value: panel)
        .sheet(item: $document) { SettingsWebDocument(url: $0.url).ignoresSafeArea() }
        .alert(L10n.tr("提示"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(L10n.tr("确定"), role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
        .task {
            await updateCacheSize()
            await app.profile.loadSettings()
        }
    }

    private var rowDivider: some View { Rectangle().fill(Color(white: 0.25)).frame(height: 0.5).padding(.horizontal, 14) }

    private func updateCacheSize() async {
        let imageBytes = (try? await ImageCache.default.diskStorageSize) ?? 0
        let mediaBytes = await Task.detached(priority: .utility) { HLSMediaCache.shared.diskSize }.value
        let detailBytes = await app.playbackDetails.diskSize()
        cacheBytes = imageBytes + mediaBytes + detailBytes
    }

    private func clearCache() async {
        guard !clearingCache else { return }
        clearingCache = true
        app.imageURLs.clear()
        await app.playbackDetails.clear()
        ImageCache.default.clearMemoryCache()
        await withCheckedContinuation { continuation in
            ImageCache.default.clearDiskCache { continuation.resume() }
        }
        await Task.detached(priority: .utility) { HLSMediaCache.shared.clear() }.value
        await updateCacheSize()
        clearingCache = false
    }

    private func openDocument(_ text: String?, title: String) {
        guard let text, let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            message = L10n.tr("暂未配置%@，请联系客服。", title)
            return
        }
        document = SettingsDocument(url: url)
    }
}

private struct SettingsRow: View {
    let title: String
    let identifier: String
    let icon: String
    var detail: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(icon).renderingMode(.original).resizable().scaledToFit()
                    .frame(width: 16, height: 16).frame(width: 20).accessibilityHidden(true)
                Text(title).font(.system(size: 16))
                Spacer()
                if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(Color(white: 0.58)) }
                Image("ProfileChevron").resizable().frame(width: 16, height: 16)
            }.padding(.horizontal, 14).frame(minHeight: 51.5).contentShape(Rectangle())
        }.accessibilityIdentifier("settings-\(identifier)")
    }
}

private struct SettingsBottomPanel: View {
    @Environment(AppContainer.self) private var app
    let kind: SettingsPanel
    let onClose: () -> Void
    @State private var localization = LocalizationStore.shared
    @State private var isDeactivating = false
    @State private var error: String?
    @State private var copiedEmail: String?

    var body: some View {
        AdaptiveBottomPanel(background: .black.opacity(0.45),
                            dismissLabel: L10n.tr("关闭%@弹窗", kind.title),
                            dismissIdentifier: "settings-panel-dismiss",
                            onDismiss: { if !isDeactivating { onClose() } }) { layout in
            VStack(spacing: 0) {
                Text(kind.title).font(.system(size: 16, weight: .semibold)).frame(height: 24)
                    .padding(.top, 32)
                switch kind {
                case .language: languageOptions.padding(.top, 20)
                case .contact: contact.padding(.top, 12)
                case .deactivate: deactivation.padding(.top, 18)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, max(layout.safeAreaInsets.bottom, 20))
            .frame(maxWidth: .infinity)
            .frame(height: min(panelHeight(bottomInset: layout.safeAreaInsets.bottom), layout.size.height * 0.9))
            .background(Color(white: 0.16)).clipShape(PlayerBottomPanelShape())
            .overlay(alignment: .top) {
                Button { if !isDeactivating { onClose() } } label: {
                    Capsule().fill(Color(white: 0.55)).frame(width: 43, height: 6)
                        .padding(.top, 2).frame(width: 76, height: 24, alignment: .top).contentShape(Rectangle())
                }.accessibilityLabel(L10n.tr("收起%@", kind.title))
                    .accessibilityIdentifier("settings-panel-close")
                    .gesture(DragGesture(minimumDistance: 10).onEnded { value in
                        if value.translation.height > 30, !isDeactivating { onClose() }
                    })
            }
            .overlay(alignment: .topTrailing) {
                if kind == .contact {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 23, weight: .regular))
                            .foregroundStyle(Color(white: 0.7)).frame(width: 44, height: 44)
                    }.padding(.top, 2).padding(.trailing, 2).accessibilityLabel(L10n.tr("关闭联系客服"))
                        .accessibilityIdentifier("settings-contact-close")
                }
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("settings-\(kind.rawValue)-panel")
        }
        .buttonStyle(.plain)
        .alert(L10n.tr("注销失败"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.tr("确定"), role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func panelHeight(bottomInset: CGFloat) -> CGFloat {
        switch kind {
        case .language: max(354, CGFloat((AppLanguage.allCases.count + 1) / 2) * 56 + 122)
        case .contact: 124 + max(bottomInset, 34)
        case .deactivate: 320 + max(bottomInset, 34)
        }
    }

    private var languageOptions: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 11), GridItem(.flexible(), spacing: 11)], spacing: 10) {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        onClose()
                        localization.select(language)
                    } label: {
                        Text(language.title).font(.system(size: 14)).frame(maxWidth: .infinity).frame(height: 46)
                            .foregroundStyle(language == localization.language ? Color(white: 0.18) : Color(white: 0.87))
                            .background(language == localization.language ? Theme.accent : Color(white: 0.23), in: RoundedRectangle(cornerRadius: 8))
                    }.accessibilityIdentifier("settings-language-\(language.id)")
                        .accessibilityAddTraits(language == localization.language ? .isSelected : [])
                }
            }
        }.scrollIndicators(.hidden)
    }

    private var contact: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("邮箱:%@", app.profile.config.customerServiceEmail))
                .font(.system(size: 14)).foregroundStyle(Color(white: 0.7))
                .lineLimit(1).minimumScaleFactor(0.75).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: copyContactEmail) {
                Text(copiedEmail == app.profile.config.customerServiceEmail ? L10n.tr("已复制") : L10n.tr("复制"))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
                    .frame(width: 52, height: 44).contentShape(Rectangle())
            }.accessibilityIdentifier("settings-copy-email")
        }
            .padding(.horizontal, 12).frame(height: 46)
            .background(Color(white: 0.23), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 30)
            .task(id: copiedEmail) {
                guard copiedEmail != nil else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                copiedEmail = nil
            }
    }

    private func copyContactEmail() {
        let email = app.profile.config.customerServiceEmail
        UIPasteboard.general.string = email
        copiedEmail = email
    }

    private var deactivation: some View {
        VStack(spacing: 20) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(LocalizedStringKey(L10n.tr("注销后，您将放弃以下权益且**无法找回**：")))
                    Text(LocalizedStringKey(L10n.tr("1. **虚拟财产清空：** 帐户内剩余的**看剧金币、充值余额及未过期的会员VIP权益**将自动失效。")))
                    Text(LocalizedStringKey(L10n.tr("2. **观看记录清除：** 您的追剧历史、收藏列表、点赞数据将被永久删除。")))
                    Text(LocalizedStringKey(L10n.tr("3. **帐号关系解除：** 帐号绑定关系及个人资料将全部清空。")))
                    Text(L10n.tr("请确保所有订单已完成，注销后将无法处理相关售后问题。"))
                        .italic()
                }
                .font(.system(size: 14)).foregroundStyle(Color(white: 0.7)).lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.hidden)
            HStack(spacing: 16) {
                Button(L10n.tr("我再想想"), action: onClose).font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(white: 0.7)).frame(maxWidth: .infinity).frame(height: 46)
                    .overlay { Capsule().strokeBorder(Color(white: 0.58), lineWidth: 0.5) }
                    .disabled(isDeactivating).accessibilityIdentifier("settings-deactivate-cancel")
                Button { Task { await deactivateAccount() } } label: {
                    Group {
                        if isDeactivating { ProgressView().tint(Color(white: 0.18)) }
                        else { Text(L10n.tr("确认注销")).font(.system(size: 16, weight: .medium)) }
                    }.foregroundStyle(Color(white: 0.18)).frame(maxWidth: .infinity).frame(height: 46)
                        .background(Theme.accent, in: Capsule())
                }.disabled(isDeactivating).accessibilityIdentifier("settings-deactivate-confirm")
            }
        }
    }

    private func deactivateAccount() async {
        guard !isDeactivating else { return }
        isDeactivating = true
        defer { isDeactivating = false }
        do {
            try await app.profile.deactivate()
            app.library.clearAccountData()
            app.watchHistory.clearAccountData()
            onClose()
            await app.guestSession.startNewSession()
        } catch { self.error = error.appLocalizedDescription }
    }
}

private struct SettingsDocument: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct SettingsWebDocument: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) { }
}
