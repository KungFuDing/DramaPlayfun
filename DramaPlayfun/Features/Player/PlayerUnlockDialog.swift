import SwiftUI

struct PlayerUnlockDialog: View {
    let episode: Episode
    let isUnlocking: Bool
    let onClose: () -> Void
    let onUnlock: () -> Void
    let onMembership: () -> Void
    private let accent = Color(red: 1, green: 199.0 / 255, blue: 48.0 / 255)

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 0) {
                Image("PlayerUnlockLock").resizable().scaledToFit()
                    .frame(width: 69, height: 69).accessibilityHidden(true)
                Text("本集需要解锁")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(white: 0.9)).padding(.top, 20)
                Text("使用金币解锁，或开通会员畅看")
                    .font(.system(size: 13)).foregroundStyle(Color(white: 0.6))
                    .padding(.top, 8)
                VStack(spacing: 16) {
                    Button(action: onUnlock) {
                        HStack(spacing: 8) {
                            if isUnlocking { ProgressView().tint(Color(white: 0.2)) }
                            Text(isUnlocking ? "正在解锁…" : "金币解锁当前章节")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(white: 0.2))
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(accent, in: Capsule())
                    }
                    .accessibilityIdentifier("player-unlock-coins")
                    .accessibilityHint("使用\(episode.unlockCoin)金币解锁第\(episode.number)集")
                    Button(action: onMembership) {
                        HStack(spacing: 6) {
                            Image("PlayerUnlockCrown").resizable().scaledToFit()
                                .frame(width: 16, height: 16).accessibilityHidden(true)
                            Text("开通VIP")
                        }
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(accent)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .overlay(Capsule().stroke(accent, lineWidth: 0.5))
                        .contentShape(Capsule())
                    }.accessibilityIdentifier("player-unlock-vip")
                }.padding(.top, 24).padding(.horizontal, 42)
            }
            .padding(.vertical, 20)
            .frame(maxWidth: 400)
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.32), lineWidth: 0.5))
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image("PlayerUnlockClose").resizable().scaledToFit()
                        .frame(width: 24, height: 24).frame(width: 44, height: 44)
                }
                .accessibilityLabel("关闭解锁弹窗")
                .accessibilityIdentifier("player-unlock-close")
                .padding(6)
            }
            .disabled(isUnlocking)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player-unlock-dialog")
            .padding(.horizontal, 20)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

#Preview {
    Color.black.overlay {
        PlayerUnlockDialog(episode: Episode(id: "6", number: 6, title: "第6集",
            requiresMembership: false, unlockCoin: 60, isUnlocked: false),
            isUnlocking: false, onClose: {}, onUnlock: {}, onMembership: {})
    }.preferredColorScheme(.dark)
}
