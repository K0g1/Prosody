import AppKit
import SwiftUI

/// SwiftUI materials blend inside a window. This view samples the desktop
/// behind an owned window and exists only while its root requests glass.
struct ThemeWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView(frame: .zero)
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        // The dictation panel is deliberately nonactivating.
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: BackdropView, context: Context) {}

    static func dismantleNSView(_ nsView: BackdropView, coordinator: ()) {
        nsView.restoreWindowStyle()
    }

    final class BackdropView: NSVisualEffectView {
        private weak var styledWindow: NSWindow?
        private var previousStyle: (background: NSColor, isOpaque: Bool)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, styledWindow !== window else { return }
            styledWindow = window
            previousStyle = (window.backgroundColor, window.isOpaque)
            window.backgroundColor = .clear
            window.isOpaque = false
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if styledWindow !== newWindow { restoreWindowStyle() }
            super.viewWillMove(toWindow: newWindow)
        }

        func restoreWindowStyle() {
            if let styledWindow, let previousStyle {
                styledWindow.backgroundColor = previousStyle.background
                styledWindow.isOpaque = previousStyle.isOpaque
            }
            styledWindow = nil
            previousStyle = nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
