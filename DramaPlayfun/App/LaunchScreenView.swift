import SwiftUI
import UIKit

struct LaunchScreenView: View {
    let errorMessage: String?
    let retry: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                LaunchArtwork()
                    .ignoresSafeArea()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("DramaPlayfun")
                    .accessibilityValue(errorMessage == nil ? "正在连接…" : "连接失败")

                if let errorMessage {
                    ScrollView {
                        VStack(spacing: 16) {
                            Text(errorMessage)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.85))
                            Button("重新连接", action: retry)
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.accent)
                                .foregroundStyle(.black)
                                .accessibilityIdentifier("launch-retry")
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxWidth: 440)
                    .frame(height: min(220, geometry.size.height * 0.4))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .padding(24)
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .accessibilityIdentifier("launch-screen")
    }
}

/// Use the system launch storyboard during sign-in as well, so both phases share
/// exactly the same artwork and adaptive constraints on every window size.
private struct LaunchArtwork: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        UIStoryboard(name: "LaunchScreen", bundle: .main).instantiateInitialViewController()!
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

#Preview("启动页") {
    LaunchScreenView(errorMessage: nil, retry: {})
}

#Preview("连接失败") {
    LaunchScreenView(errorMessage: "网络连接失败，请检查网络后重试。", retry: {})
}
