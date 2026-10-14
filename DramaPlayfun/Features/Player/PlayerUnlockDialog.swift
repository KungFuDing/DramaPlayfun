import SwiftUI

struct PlayerUnlockDialog: View {
    let episode: Episode
    let isUnlocking: Bool
    let onUnlock: () -> Void
    private let accent = Color(red: 1, green: 199.0 / 255, blue: 48.0 / 255)

    var body: some View {
        VStack(spacing: 0) {
            Image("PlayerUnlockLock").resizable().scaledToFit()
                .frame(width: 69, height: 69)
                .accessibilityHidden(true).allowsHitTesting(false)
            Text("本集需要解锁")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(white: 0.9)).padding(.top, 20)
                .allowsHitTesting(false)
            Text("使用金币解锁，或开通会员畅看")
                .font(.system(size: 13)).foregroundStyle(Color(white: 0.6))
                .padding(.top, 8).allowsHitTesting(false)
            Button(action: onUnlock) {
                HStack(spacing: 8) {
                    if isUnlocking { ProgressView().tint(Color(white: 0.2)) }
                    Text(isUnlocking ? "正在解锁…" : "解锁当前章节")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(white: 0.2))
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(accent, in: Capsule())
                .contentShape(Capsule())
            }
            .disabled(isUnlocking)
            .accessibilityIdentifier("player-unlock-coins")
            .accessibilityHint("查看第\(episode.number)集的解锁信息")
            .padding(.top, 24).padding(.horizontal, 62)
        }
        .frame(maxWidth: 500)
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-unlock-dialog")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -30)
    }
}

#Preview {
    Color.black.overlay {
        PlayerUnlockDialog(episode: Episode(id: "6", number: 6, title: "第6集",
            requiresMembership: false, unlockCoin: 60, isUnlocked: false),
            isUnlocking: false, onUnlock: {})
    }.preferredColorScheme(.dark)
}
