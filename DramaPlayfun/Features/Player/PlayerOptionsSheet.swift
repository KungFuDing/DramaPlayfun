import SwiftUI

enum PlayerOptionsKind: String, Identifiable {
    case quality, speed, subtitles
    var id: String { rawValue }
    var title: String {
        switch self {
        case .quality: L10n.tr("清晰度")
        case .speed: L10n.tr("倍速")
        case .subtitles: L10n.tr("字幕")
        }
    }
}

struct PlayerOption: Identifiable {
    let id: String
    let title: String
    var isVIP = false
}

struct PlayerOptionsSheet: View {
    let kind: PlayerOptionsKind
    let options: [PlayerOption]
    let selectedID: String?
    var isLoading = false
    var emptyMessage: String? = nil
    let onClose: () -> Void
    let onSelect: (PlayerOption) -> Void
    private let accent = Color(red: 1, green: 199.0 / 255, blue: 48.0 / 255)
    private var columns: Int { kind == .subtitles ? 2 : 1 }
    private var rowCount: Int { max(4, (options.count + columns - 1) / columns) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.25).contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .accessibilityLabel(L10n.tr("关闭%@弹窗", kind.title))
                VStack(spacing: 22) {
                    Text(kind.title).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white).frame(height: 22)
                    ScrollView {
                        if isLoading {
                            ProgressView(L10n.tr("正在加载字幕…")).tint(.white).padding(.top, 40)
                        } else if options.isEmpty {
                            Text(emptyMessage ?? L10n.tr("本集暂无可切换字幕")).font(.system(size: 14))
                                .foregroundStyle(Color(white: 0.7)).padding(.top, 40)
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 11), count: columns), spacing: 10) {
                                ForEach(options) { option in
                                    PlayerOptionButton(option: option, kind: kind,
                                        isSelected: selectedID == option.id, accent: accent) {
                                            onSelect(option)
                                        }
                                }
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
                .padding(.horizontal, 12).padding(.top, 32).padding(.bottom, 64)
                .frame(height: min(CGFloat(rowCount * 56 + 130), geometry.size.height * 0.85))
                .frame(maxWidth: .infinity)
                .background(Color(white: 0.16))
                .clipShape(PlayerBottomPanelShape())
                .overlay(alignment: .top) {
                    Button(action: onClose) {
                        Capsule().fill(Color(white: 0.56)).frame(width: 43, height: 6)
                            .frame(width: 76, height: 24, alignment: .top).padding(.top, 2)
                            .contentShape(Rectangle())
                    }
                    .gesture(DragGesture(minimumDistance: 10).onEnded { value in
                        if value.translation.height > 30 { onClose() }
                    })
                    .accessibilityLabel(L10n.tr("收起%@", kind.title))
                    .accessibilityIdentifier("player-options-close")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("player-\(kind.rawValue)-panel")
            }
        }
        .buttonStyle(.plain)
        .ignoresSafeArea()
    }
}

private struct PlayerOptionButton: View {
    let option: PlayerOption
    let kind: PlayerOptionsKind
    let isSelected: Bool
    let accent: Color
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                if option.isVIP {
                    Image(isSelected ? "PlayerQualityVIPSelected" : "PlayerQualityVIPNormal")
                        .renderingMode(.original).resizable().scaledToFit()
                        .frame(width: 16, height: 16).accessibilityHidden(true)
                }
                Text(option.title).font(.system(size: 14))
                    .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color(white: 0.2) : Color(white: 0.88))
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(isSelected ? accent : Color(white: 0.23), in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityIdentifier("player-\(kind.rawValue)-\(option.id)")
        .accessibilityLabel(option.title)
        .accessibilityValue(option.isVIP ? L10n.tr("会员专享") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("1080P 已选中") {
    Color.black.overlay {
        PlayerOptionsSheet(kind: .quality,
            options: [PlayerOption(id: "0", title: "自动"), PlayerOption(id: "480", title: "480P"),
                PlayerOption(id: "720", title: "720P"), PlayerOption(id: "1080", title: "1080P", isVIP: true)],
            selectedID: "1080", onClose: {}, onSelect: { _ in })
    }.preferredColorScheme(.dark)
}
