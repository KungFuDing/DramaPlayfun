import SwiftUI

enum Theme {
    static let background = Color(red: 0.115, green: 0.115, blue: 0.115)
    static let surface = Color(red: 0.18, green: 0.18, blue: 0.18)
    static let accent = Color(red: 1, green: 0.77, blue: 0.18)
    static let cornerRadius: CGFloat = 14
    static let spacing: CGFloat = 16
}

struct ScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Theme.background).toolbarBackground(Theme.background, for: .navigationBar)
    }
}

extension View {
    func screenBackground() -> some View { modifier(ScreenBackground()) }
}
