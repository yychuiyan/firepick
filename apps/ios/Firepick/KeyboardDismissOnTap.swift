import SwiftUI
import UIKit

struct KeyboardDismissOnTap: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.onWindowChange = { window in
            context.coordinator.install(on: window)
        }
        return view
    }

    func updateUIView(_ uiView: WindowProbeView, context: Context) {}

    static func dismantleUIView(_ uiView: WindowProbeView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?
        private var recognizer: UITapGestureRecognizer?

        func install(on window: UIWindow?) {
            guard self.window !== window || recognizer == nil else { return }
            uninstall()
            guard let window else { return }

            let recognizer = UITapGestureRecognizer(
                target: self,
                action: #selector(dismissKeyboard)
            )
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            self.window = window
            self.recognizer = recognizer
        }

        func uninstall() {
            if let recognizer {
                window?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            window = nil
        }

        @objc private func dismissKeyboard() {
            window?.endEditing(true)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            var candidate = touch.view
            while let view = candidate {
                if view is UITextField || view is UITextView {
                    return false
                }
                candidate = view.superview
            }
            return true
        }
    }
}

final class WindowProbeView: UIView {
    var onWindowChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
    }
}

extension View {
    func dismissKeyboardOnBackgroundTap() -> some View {
        background(KeyboardDismissOnTap())
    }
}
