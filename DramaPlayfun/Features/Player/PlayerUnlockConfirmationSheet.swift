import SwiftUI

struct PlayerUnlockConfirmationSheet: View {
    let drama: Drama
    let episode: Episode
    let balanceText: String
    let autoUnlocksNext: Bool
    let isUpdatingAutoUnlock: Bool
    let isUnlocking: Bool
    let onClose: () -> Void
    let onAutoUnlockChange: (Bool) -> Void
    let onConfirm: () -> Void
    let onMembership: () -> Void
    private let accent = Color(red: 1, green: 199.0 / 255, blue: 48.0 / 255)

    var body: some View {
        AdaptiveBottomPanel(onDismiss: onClose) { layout in
            let bottomPadding = max(layout.safeAreaInsets.bottom, 34) + 16
            let availableHeight = max(0, layout.size.height - max(layout.safeAreaInsets.top, 8))
            panel(bottomPadding: bottomPadding,
                width: layout.width,
                height: min(339 + bottomPadding, availableHeight))
                .transition(.move(edge: .bottom))
        }
        .foregroundStyle(Color(white: 0.9))
        .buttonStyle(.plain)
    }

    private func panel(bottomPadding: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    dramaHeader
                    balances.padding(.top, 16)
                    autoUnlockRow.padding(.top, 16)
                    actions.padding(.top, 20)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, bottomPadding)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.top, 30)
        .frame(width: width, height: height)
        .background {
            Image("PlayerUnlockPanelBackground").resizable()
                .accessibilityHidden(true)
        }
        .clipShape(PlayerBottomPanelShape())
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image("PlayerUnlockClose").resizable().scaledToFit()
                    .frame(width: 24, height: 24).frame(width: 44, height: 44)
            }
            .accessibilityLabel(L10n.tr("关闭解锁确认"))
            .accessibilityIdentifier("player-unlock-close")
            .padding(.trailing, 2)
        }
        .overlay(alignment: .top) {
            Capsule().fill(Color(white: 0.56)).frame(width: 43, height: 6)
                .padding(.top, 2).frame(width: 76, height: 20, alignment: .top)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 10).onEnded { value in
                    if value.translation.height > 30 { onClose() }
                })
                .accessibilityLabel(L10n.tr("收起解锁确认"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onClose() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-unlock-confirmation")
    }

    private var dramaHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            DramaPoster(drama: drama, aspectRatio: 72.0 / 92, cornerRadius: 10)
                .frame(width: 72, height: 92)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.7), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 10) {
                Text(drama.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
                Text((drama.tagNames.isEmpty ? [drama.category.title] : Array(drama.tagNames.prefix(3)))
                    .joined(separator: "   "))
                    .font(.system(size: 12)).foregroundStyle(Color(white: 0.6)).lineLimit(1)
                HStack(spacing: 5) {
                    Image("PlayerUnlockEpisodeLock").resizable().scaledToFit()
                        .frame(width: 13, height: 13).accessibilityHidden(true)
                    Text(L10n.tr("解锁第%d集", episode.number)).font(.system(size: 12))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }.padding(.top, 2).padding(.trailing, 20)
            Spacer(minLength: 0)
        }.frame(height: 92, alignment: .top)
    }

    private var balances: some View {
        HStack(spacing: 11) {
            PlayerUnlockCoinAmount(title: L10n.tr("账户余额"), amount: balanceText, amountColor: Color(white: 0.9))
                .accessibilityIdentifier("player-unlock-balance")
            PlayerUnlockCoinAmount(title: L10n.tr("本集价格"), amount: String(episode.unlockCoin), amountColor: accent)
                .accessibilityIdentifier("player-unlock-price")
        }
    }

    private var autoUnlockRow: some View {
        HStack(spacing: 10) {
            Image("PlayerUnlockAutoNext").resizable().scaledToFit()
                .frame(width: 40, height: 40).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(L10n.tr("连续播放时自动解锁下一集"))
                        .font(.system(size: 14)).lineLimit(2).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Toggle(L10n.tr("连续播放时自动解锁下一集"), isOn: Binding(
                        get: { autoUnlocksNext }, set: onAutoUnlockChange
                    ))
                    .labelsHidden().toggleStyle(PlayerUnlockAutoNextToggleStyle(accent: accent))
                    .disabled(isUpdatingAutoUnlock || isUnlocking)
                    .accessibilityIdentifier("player-unlock-autoplay")
                }
                Text(L10n.tr("开启后，下一集将自动使用金币解锁"))
                    .font(.system(size: 12)).foregroundStyle(Color(white: 0.6))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 10).frame(minHeight: 67)
        .background(Color(white: 0.21), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            if isUpdatingAutoUnlock {
                ProgressView().controlSize(.mini).tint(accent)
                    .padding(.top, 2).padding(.trailing, 22)
                    .accessibilityLabel(L10n.tr("正在更新自动解锁设置"))
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: onConfirm) {
                HStack(spacing: 6) {
                    if isUnlocking { ProgressView().tint(Color(white: 0.2)) }
                    Text(isUnlocking ? L10n.tr("正在解锁…") : L10n.tr("确认解锁·%lld金币", episode.unlockCoin))
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(white: 0.2))
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(accent, in: Capsule())
                .contentShape(Capsule())
            }
            .disabled(isUnlocking || isUpdatingAutoUnlock)
            .accessibilityIdentifier("player-unlock-confirm")
            Button(action: onMembership) {
                HStack(spacing: 6) {
                    Image("PlayerUnlockCrown").resizable().scaledToFit()
                        .frame(width: 16, height: 16).accessibilityHidden(true)
                    Text(L10n.tr("开通VIP")).font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(accent).frame(width: 128, height: 46)
                .overlay(Capsule().stroke(accent, lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .disabled(isUnlocking)
            .accessibilityIdentifier("player-unlock-vip")
        }
    }
}

private struct PlayerUnlockCoinAmount: View {
    let title: String
    let amount: String
    let amountColor: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 12)).foregroundStyle(Color(white: 0.6))
                .lineLimit(2).minimumScaleFactor(0.85)
            HStack(spacing: 4) {
                Text(amount).font(.system(size: 20, weight: .medium)).foregroundStyle(amountColor)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Image("PlayerUnlockCoin").resizable().scaledToFit()
                    .frame(width: 16, height: 16).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 52)
        .background(Color(white: 0.21), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("%@：%@金币", title, amount))
    }
}

private struct PlayerUnlockAutoNextToggleStyle: ToggleStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? accent : Color(white: 0.58))
                .frame(width: 42, height: 22)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(Color(white: 0.14)).frame(width: 18, height: 18).padding(2)
                }
                .contentShape(Rectangle().inset(by: -11))
        }
        .accessibilityLabel(L10n.tr("连续播放时自动解锁下一集"))
        .accessibilityValue(configuration.isOn ? L10n.tr("开启") : L10n.tr("关闭"))
    }
}

#Preview {
    Color.black.overlay {
        PlayerUnlockConfirmationSheet(
            drama: Drama(id: "preview", title: "薄情烬处，我自归来耀眼", summary: "", category: .drama,
                episodeCount: 80, heat: 0, badge: nil, coverURL: nil, tagNames: ["剧情", "都市", "甜宠"]),
            episode: Episode(id: "8", number: 8, title: "第8集", requiresMembership: false,
                unlockCoin: 20, isUnlocked: false),
            balanceText: "6400", autoUnlocksNext: true, isUpdatingAutoUnlock: false, isUnlocking: false,
            onClose: {}, onAutoUnlockChange: { _ in }, onConfirm: {}, onMembership: {})
    }.preferredColorScheme(.dark)
}
