#if canImport(Testing)
import AppKit
import SwiftUI
import Testing
@testable import ProsodyCore

@Suite("Tray popup layout")
struct MenuBarLayoutTests {
    @Test @MainActor
    func popupUsesIntrinsicHeightAndScrollsOverflow() throws {
        _ = NSApplication.shared
        try #require(!NSScreen.screens.isEmpty)

        let suite = "Prosody-Tray-Layout-Tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Prosody-Tray-Layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(
            preferences: ProsodyPreferences(defaults: defaults),
            demoMode: false,
            supportRootURL: root,
            registerHotkey: false,
            loadStoredState: false
        )

        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let anchor = NSView(frame: NSRect(x: 100, y: 100, width: 20, height: 20))
        window.contentView = anchor
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let compact = popoverSize(model: model, sections: [], anchor: anchor)
        let oneRow = popoverSize(model: model, sections: [.source], anchor: anchor)
        let allRows = popoverSize(model: model, sections: MainScreenSection.allCases, anchor: anchor)

        #expect(compact.content.height < 160)
        #expect(oneRow.content.height > compact.content.height)
        #expect(oneRow.content.height < 220)
        #expect(allRows.content.height > oneRow.content.height)
        #expect(allRows.content.height < 330)
        #expect(compact.window.width == 374)
        #expect(oneRow.window.width == 374)
        #expect(allRows.window.width == 374)

        model.recentSessions = (0..<3).map { index in
            SessionSummary(id: UUID(), title: "Sample \(index)", createdAt: Date(), duration: 30)
        }
        model.lastNotice = "A sample notice that must stay inside the scrollable details area."
        model.userFacingError = UserFacingError(
            title: "Sample error",
            message: "A sample error message for layout testing.",
            recoveryAction: "Try again"
        )
        let overflow = popoverSize(model: model, sections: [.source, .recents], anchor: anchor)

        #expect(overflow.content.height > allRows.content.height)
        #expect(overflow.content.height <= 410)
        #expect(overflow.window.width == 374)
    }

    @MainActor
    private func popoverSize(
        model: AppModel,
        sections: [MainScreenSection],
        anchor: NSView
    ) -> (content: NSSize, window: NSSize) {
        model.preferences.hiddenMainScreenSections = Set(MainScreenSection.allCases).subtracting(sections)
        let view = ThemedRoot(preferences: model.preferences, expands: false, backdrop: .systemPopover) {
            MenuBarRootView(model: model)
        }
        let controller = NSHostingController(rootView: view)
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.contentViewController = controller
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let size = (controller.view.frame.size, controller.view.window?.frame.size ?? .zero)
        popover.performClose(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        return size
    }
}
#endif
