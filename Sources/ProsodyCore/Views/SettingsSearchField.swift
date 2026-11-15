import AppKit
import SwiftUI

/// AppKit handles the field editor so the search commands work while typing.
struct SettingsSearchField: NSViewRepresentable {
    @Binding var query: String
    let move: (Int) -> Bool
    let open: () -> Bool
    let cancel: () -> Bool

    func makeNSView(context: Context) -> NSSearchField {
        let field = SearchField()
        field.placeholderString = "Search Settings"
        field.toolTip = "Search Settings (⌘F)"
        field.setAccessibilityLabel("Search Settings")
        field.setAccessibilityHelp("Use the Up and Down Arrow keys to choose a result, then press Return.")
        field.setAccessibilityIdentifier("clippy.settings.search")
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        let editor = field.currentEditor()
        guard (editor?.string ?? field.stringValue) != query else { return }
        field.stringValue = query
        editor?.string = query
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SettingsSearchField

        init(parent: SettingsSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            searchChanged(field)
        }

        @objc func searchChanged(_ field: NSSearchField) {
            let value = field.stringValue
            if parent.query != value { parent.query = value }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Let the input method finish composing before taking any keys.
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): return parent.move(-1)
            case #selector(NSResponder.moveDown(_:)): return parent.move(1)
            case #selector(NSResponder.insertNewline(_:)): return parent.open()
            case #selector(NSResponder.cancelOperation(_:)): return parent.cancel()
            default: return false
            }
        }
    }

    private final class SearchField: NSSearchField {
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.subtracting(.capsLock) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "f",
               window?.isKeyWindow == true {
                selectText(nil)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}
