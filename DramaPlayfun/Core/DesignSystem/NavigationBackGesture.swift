import SwiftUI
import UIKit

extension View {
    /// Retains UIKit's interactive edge transition on pages with a custom header.
    func navigationBackGesture(isEnabled: Bool = true) -> some View {
        background {
            NavigationBackGestureBridge(isEnabled: isEnabled)
                .frame(width: 0, height: 0)
        }
    }
}

private struct NavigationBackGestureBridge: UIViewControllerRepresentable {
    let isEnabled: Bool

    func makeUIViewController(context: Context) -> NavigationBackGestureController {
        NavigationBackGestureController()
    }

    func updateUIViewController(_ controller: NavigationBackGestureController, context: Context) {
        controller.allowsBackGesture = isEnabled
        controller.scheduleGestureRefresh()
    }

    static func dismantleUIViewController(_ controller: NavigationBackGestureController, coordinator: ()) {
        controller.restoreGesture()
    }
}

private final class NavigationBackGestureController: UIViewController, UIGestureRecognizerDelegate {
    var allowsBackGesture = true
    private weak var installedGesture: UIGestureRecognizer?
    private weak var originalDelegate: (any UIGestureRecognizerDelegate)?
    private var originalIsEnabled = false

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        installGesture()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // SwiftUI can update the navigation bar during the appearance transition.
        installGesture()
        scheduleGestureRefresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshVisibleGesture()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Wait for completion: a cancelled interactive pop must keep its delegate.
        restoreGesture()
    }

    func scheduleGestureRefresh() {
        // SwiftUI can apply hidden-toolbar preferences after appearance callbacks
        // when a value-based destination is popped. Reapply after that update.
        DispatchQueue.main.async { [weak self] in self?.refreshVisibleGesture() }
    }

    private func refreshVisibleGesture() {
        guard viewIfLoaded?.window != nil, isTopPage,
              navigationController?.transitionCoordinator == nil else { return }
        installGesture()
    }

    private var isTopPage: Bool {
        guard let top = navigationController?.topViewController else { return false }
        var ancestor: UIViewController? = self
        while let controller = ancestor {
            if controller === top { return true }
            ancestor = controller.parent
        }
        return false
    }

    private func installGesture() {
        guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
        if installedGesture !== gesture {
            restoreGesture()
            installedGesture = gesture
        }
        if gesture.delegate !== self {
            if let previous = gesture.delegate as? NavigationBackGestureController {
                // The outgoing page may still be visible during a push/pop.
                // Restore UIKit's delegate, never a delegate belonging to that page.
                originalDelegate = previous.originalDelegate
                originalIsEnabled = previous.originalIsEnabled
            } else {
                originalDelegate = gesture.delegate
                originalIsEnabled = gesture.isEnabled
            }
            // The original delegate can reject hidden bars before shouldBegin.
            // Keep it for restoration; eligibility is checked by this page.
            gesture.delegate = self
        }
        gesture.isEnabled = true
    }

    func restoreGesture() {
        if let gesture = installedGesture, gesture.delegate === self {
            gesture.delegate = originalDelegate
            gesture.isEnabled = originalIsEnabled
        }
        installedGesture = nil
        originalDelegate = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard allowsBackGesture,
              let navigationController,
              navigationController.viewControllers.count > 1,
              navigationController.transitionCoordinator == nil,
              navigationController.presentedViewController == nil,
              let top = navigationController.topViewController,
              top.presentedViewController == nil else { return false }

        // Local detail/recommendation destinations aren't recorded in AppRouter.paths.
        return isTopPage
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === installedGesture,
              otherGestureRecognizer !== gestureRecognizer,
              allowsBackGesture, isTopPage,
              let contentView = navigationController?.topViewController?.view,
              let otherView = otherGestureRecognizer.view else { return false }
        // Give the system edge transition priority over content scrolling and taps.
        return otherView.isDescendant(of: contentView)
    }
}
