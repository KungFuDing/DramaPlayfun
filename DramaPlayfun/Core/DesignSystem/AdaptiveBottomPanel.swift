import SwiftUI

/// Keeps bottom panels full-width in compact windows and inset in expanded ones.
struct BottomPanelLayout {
    let size: CGSize
    let safeAreaInsets: EdgeInsets
    let width: CGFloat
    let isWide: Bool

    init(size: CGSize, safeAreaInsets: EdgeInsets) {
        self.size = size
        self.safeAreaInsets = safeAreaInsets
        let safeWidth = max(0, size.width - safeAreaInsets.leading - safeAreaInsets.trailing)
        isWide = safeWidth >= 600
        width = min(640, max(0, safeWidth - (isWide ? 48 : 0)))
    }
}

struct AdaptiveBottomPanel<Content: View>: View {
    var background: Color = .clear
    var dismissLabel: String? = nil
    var dismissIdentifier = ""
    let onDismiss: () -> Void
    @ViewBuilder let content: (BottomPanelLayout) -> Content

    var body: some View {
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let fullSize = CGSize(width: geometry.size.width + insets.leading + insets.trailing,
                                  height: geometry.size.height + insets.top + insets.bottom)
            let layout = BottomPanelLayout(size: fullSize, safeAreaInsets: insets)
            ZStack(alignment: .bottom) {
                background.contentShape(Rectangle()).onTapGesture(perform: onDismiss)
                    .accessibilityLabel(dismissLabel ?? "")
                    .accessibilityIdentifier(dismissIdentifier)
                    .accessibilityHidden(dismissLabel == nil)
                content(layout)
                    .frame(width: layout.width)
                    .padding(.leading, insets.leading)
                    .padding(.trailing, insets.trailing)
            }
            .frame(width: fullSize.width, height: fullSize.height)
            .offset(x: -insets.leading, y: -insets.top)
        }
    }
}
