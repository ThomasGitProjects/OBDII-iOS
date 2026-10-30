import SwiftUI
import UIKit

/// Blendet die Tastatur aus, sobald irgendwo außerhalb eines Eingabefelds getippt wird. Die Ziffernblöcke haben
/// keine Return-Taste, und die offene Tastatur verdeckt sonst die Tab-Leiste. Der Tap wird nur mitgelesen
/// (cancelsTouchesInView = false), Buttons und Listen reagieren also weiterhin normal.
struct KeyboardDismissOnTap: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView, UIGestureRecognizerDelegate {
        private var recognizer: UITapGestureRecognizer?
        private weak var installedWindow: UIWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let recognizer, window !== installedWindow {
                installedWindow?.removeGestureRecognizer(recognizer)
                self.recognizer = nil
            }
            guard let window, recognizer == nil else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            recognizer = tap
            installedWindow = window
        }

        @objc private func dismissKeyboard() {
            installedWindow?.endEditing(true)
        }

        // Taps in ein Eingabefeld nicht abfangen, sonst springt die Tastatur beim Feldwechsel zu und wieder auf
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

extension View {
    /// „Fertig“-Taste über der Tastatur, für Ziffernblöcke ohne Return-Taste.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Fertig") { hideKeyboard() }
            }
        }
    }
}

@MainActor
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
