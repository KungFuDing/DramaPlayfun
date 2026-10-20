import SwiftUI

struct AppUpdatePanel: View {
    let notice: AppUpdateNotice
    let isOpening: Bool
    let errorMessage: String?
    let onLater: () -> Void
    let onUpdate: () -> Void

    @State private var contentHeight: CGFloat = 0
    @AccessibilityFocusState private var isTitleFocused: Bool
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var bodySize: CGFloat = 13
    @ScaledMetric(relativeTo: .headline) private var buttonSize: CGFloat = 16

    private let accent = Color(red: 1, green: 197.0 / 255, blue: 49.0 / 255)

    var body: some View {
        AdaptiveBottomPanel(background: .black.opacity(0.65),
                            dismissIdentifier: "app-update-backdrop",
                            onDismiss: dismissIfAllowed) { layout in
            let insets = layout.safeAreaInsets
            let bottomPadding = insets.bottom + 24
            let defaultHeight: CGFloat = notice.isForced ? 315 : 337
            let panelHeight = min(
                (contentHeight > 0 ? contentHeight : defaultHeight) + bottomPadding,
                max(0, layout.size.height - max(insets.top, 20))
            )

            panel(width: layout.width, height: panelHeight, bottomPadding: bottomPadding)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .accessibilityAction(.escape, dismissIfAllowed)
        .onAppear { isTitleFocused = true }
    }

    private func panel(width: CGFloat, height: CGFloat, bottomPadding: CGFloat) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                header
                Text(notice.content)
                    .font(.system(size: bodySize))
                    .foregroundStyle(Color(white: 0.6))
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .padding(.top, 26)
                    .accessibilityIdentifier("app-update-message")

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: bodySize))
                        .foregroundStyle(accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                        .accessibilityIdentifier("app-update-error")
                }

                actions(width: width - 24)
                    .padding(.top, 22)
            }
            .padding(.horizontal, 12)
            .padding(.top, 34)
            .background {
                GeometryReader { contentGeometry in
                    Color.clear.preference(key: AppUpdateContentHeightKey.self, value: contentGeometry.size.height)
                }
            }
            .padding(.bottom, bottomPadding)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(AppUpdateContentHeightKey.self) { contentHeight = $0 }
        .frame(width: width, height: height)
        .background {
            Image("AppUpdatePanelBackground")
                .resizable(capInsets: EdgeInsets(top: 20, leading: 0, bottom: 1, trailing: 0))
                .accessibilityHidden(true)
        }
        .overlay(alignment: .top) { handle }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app-update-panel")
    }

    private var header: some View {
        VStack(spacing: 0) {
            Text(notice.title)
                .font(.system(size: titleSize, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 20)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("app-update-title")
                .accessibilityFocused($isTitleFocused)

            if !notice.version.isEmpty {
                Text(displayVersion)
                    .font(.system(size: bodySize))
                    .foregroundStyle(Color(white: 0.8))
                    .frame(minHeight: 16)
                    .padding(.top, 9)
                    .accessibilityLabel(L10n.tr("新版本 %@", notice.version))
                    .accessibilityIdentifier("app-update-version")
            }

            Image("AppUpdateRocket")
                .resizable()
                .scaledToFit()
                .frame(width: 109, height: 109)
                .padding(.top, 11)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }

    private func actions(width: CGFloat) -> some View {
        HStack(spacing: 16) {
            if !notice.isForced {
                Button(action: onLater) {
                    Text(L10n.tr("稍后"))
                        .font(.system(size: buttonSize, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(Color(white: 0.6))
                        .frame(width: (width - 16) / 3, height: 46)
                        .overlay(Capsule().stroke(Color(white: 0.6), lineWidth: 0.5))
                        .contentShape(Capsule())
                }
                .accessibilityIdentifier("app-update-later")
            }

            Button(action: onUpdate) {
                HStack(spacing: 8) {
                    if isOpening {
                        ProgressView().tint(Color(white: 0.2))
                    }
                    Text(isOpening ? L10n.tr("正在前往…") : L10n.tr("前往更新"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .font(.system(size: buttonSize, weight: .medium))
                .foregroundStyle(Color(white: 0.2))
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(accent, in: Capsule())
                .contentShape(Capsule())
            }
            .disabled(isOpening)
            .accessibilityIdentifier("app-update-confirm")
        }
    }

    private var handle: some View {
        Capsule()
            .fill(Color(white: 0.56))
            .frame(width: 43, height: 6)
            .padding(.top, 2)
            .frame(width: 76, height: 24, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture(perform: dismissIfAllowed)
            .gesture(DragGesture(minimumDistance: 10).onEnded { value in
                if value.translation.height > 30 { dismissIfAllowed() }
            })
            .accessibilityLabel(L10n.tr("稍后更新"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { dismissIfAllowed() }
            .accessibilityIdentifier("app-update-handle")
            .accessibilityHidden(notice.isForced)
    }

    private var displayVersion: String {
        notice.version.lowercased().hasPrefix("v") ? notice.version : "v\(notice.version)"
    }

    private func dismissIfAllowed() {
        guard !notice.isForced else { return }
        onLater()
    }
}

private struct AppUpdateContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
