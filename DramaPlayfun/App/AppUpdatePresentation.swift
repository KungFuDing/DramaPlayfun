import SwiftUI
import UIKit

/// A scene-local window keeps mandatory updates above sheets and full-screen playback.
struct AppUpdatePresentation: UIViewRepresentable {
    let notice: AppUpdateNotice?
    let isOpening: Bool
    let errorMessage: String?
    let onLater: () -> Void
    let onUpdate: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WindowAnchor {
        let anchor = WindowAnchor()
        anchor.isUserInteractionEnabled = false
        anchor.windowDidChange = { [weak coordinator = context.coordinator] anchor in
            coordinator?.updateWindow(from: anchor)
        }
        return anchor
    }

    func updateUIView(_ anchor: WindowAnchor, context: Context) {
        context.coordinator.presentation = self
        context.coordinator.updateWindow(from: anchor)
    }

    static func dismantleUIView(_ anchor: WindowAnchor, coordinator: Coordinator) {
        anchor.windowDidChange = nil
        coordinator.hide()
    }

    final class WindowAnchor: UIView {
        var windowDidChange: ((WindowAnchor) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            windowDidChange?(self)
        }
    }

    final class Coordinator {
        var presentation: AppUpdatePresentation?
        private var window: UIWindow?
        private var host: UIHostingController<AppUpdatePanel>?
        private weak var previousKeyWindow: UIWindow?
        private weak var windowScene: UIWindowScene?

        func updateWindow(from anchor: WindowAnchor) {
            // A full-screen cover may detach the anchor before an update is discovered.
            if let scene = anchor.window?.windowScene { windowScene = scene }
            guard let presentation, let notice = presentation.notice else {
                hide()
                return
            }
            guard let scene = windowScene else { return }
            let panel = AppUpdatePanel(notice: notice, isOpening: presentation.isOpening,
                                       errorMessage: presentation.errorMessage,
                                       onLater: presentation.onLater, onUpdate: presentation.onUpdate)
            if let host, window?.windowScene === scene {
                host.rootView = panel
                return
            }
            hide()
            previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let host = UIHostingController(rootView: panel)
            host.view.backgroundColor = .clear
            host.view.accessibilityViewIsModal = true
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.backgroundColor = .clear
            window.overrideUserInterfaceStyle = .dark
            window.rootViewController = host
            self.host = host
            self.window = window
            anchor.window?.endEditing(true)
            window.makeKeyAndVisible()
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }

        func hide() {
            guard let window else { return }
            let wasKeyWindow = window.isKeyWindow
            window.isHidden = true
            window.rootViewController = nil
            self.window = nil
            host = nil
            if wasKeyWindow { previousKeyWindow?.makeKey() }
            previousKeyWindow = nil
        }
    }
}
