import AppKit
import SwiftUI

/// The windowed titlebar geometry stays reserved even when AppKit hides its
/// controls in full screen, so revealing the controls never shifts content.
struct WindowChromeLayout {
    let titlebarHeight: CGFloat
    let controlsInset: CGFloat
    let direction: LayoutDirection

    static let none = Self(titlebarHeight: 0, controlsInset: 0, direction: .leftToRight)
}

extension WindowChromeLayout {
    @MainActor
    init(window: NSWindow) {
        let size = window.frame.size
        let isRightToLeft = window.windowTitlebarLayoutDirection == .rightToLeft
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttonBounds = buttons.reduce(CGRect.null) { bounds, kind in
            guard let button = window.standardWindowButton(kind) else { return bounds }
            return bounds.union(button.convert(button.bounds, to: nil))
        }
        let titlebarHeight = size.height - window.contentLayoutRect.maxY
        let buttonHeight = buttonBounds.isNull ? 0 : size.height - buttonBounds.minY
        let buttonEdge = buttonBounds.isNull ? 0 : (isRightToLeft ? size.width - buttonBounds.minX : buttonBounds.maxX)
        self.init(titlebarHeight: ceil(max(0, titlebarHeight, buttonHeight)),
                  controlsInset: ceil(buttonEdge) + 12,
                  direction: isRightToLeft ? .rightToLeft : .leftToRight)
    }
}

private struct WindowChromeLayoutKey: EnvironmentKey {
    static let defaultValue = WindowChromeLayout.none
}

extension EnvironmentValues {
    var windowChromeLayout: WindowChromeLayout {
        get { self[WindowChromeLayoutKey.self] }
        set { self[WindowChromeLayoutKey.self] = newValue }
    }
}

/// This row belongs inside the sidebar background, at the top of the window.
/// AppKit owns the buttons in the reserved leading space.
struct WindowChromeSidebarHeader<Content: View>: View {
    @Environment(\.windowChromeLayout) private var chrome
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .leading) {
            WindowChromeDragRegion()
            content().padding(.trailing, 12)
        }
        .frame(height: max(28, chrome.titlebarHeight))
        .padding(.leading, chrome.controlsInset)
    }
}

/// Add only to blank header space, outside the native button cluster and fields.
struct WindowChromeDragRegion: View {
    @Environment(\.windowChromeLayout) private var chrome

    var body: some View {
        Color.clear
            .frame(height: chrome.titlebarHeight)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents()
            .accessibilityHidden(true)
    }
}
