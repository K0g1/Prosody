import AppKit
import ApplicationServices
import OSLog

public enum DictationInsertionMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case paste = "Standard paste"
    case typing = "Keyboard typing"
    public var id: String { rawValue }
}

struct DictationInsertionReceipt {
    let destination: DictationTextDestination
    let originalSelection: CFRange?
    let expectedSelection: CFRange?
}

/// Selection rebasing is deliberately a pure decision. The caller supplies
/// identity checks from the live AX objects; a failed check keeps the normal
/// destination guard in force.
enum DictationSelectionRebase {
    static func expectedCaret(after selection: CFRange?, insertedUTF16Count: Int) -> CFRange? {
        guard let selection, selection.location >= 0 else { return nil }
        return CFRange(location: selection.location + insertedUTF16Count, length: 0)
    }

    static func canRebase(
        original: CFRange?,
        captured: CFRange?,
        expected: CFRange?,
        current: CFRange?,
        sameApplication: Bool,
        sameWindow: Bool,
        sameElement: Bool
    ) -> Bool {
        guard matchesCapturedRange(
            original: original, captured: captured,
            sameApplication: sameApplication, sameWindow: sameWindow, sameElement: sameElement
        ), let expected, let current,
              expected.location == current.location,
              expected.length == current.length,
              current.length == 0 else { return false }
        return true
    }

    static func matchesCapturedRange(
        original: CFRange?,
        captured: CFRange?,
        sameApplication: Bool,
        sameWindow: Bool,
        sameElement: Bool
    ) -> Bool {
        guard sameApplication, sameWindow, sameElement,
              let original, let captured,
              original.location == captured.location,
              original.length == captured.length else { return false }
        return true
    }
}

/// Capture focus before the nonactivating HUD appears. AX metadata is optional:
/// custom controls often support paste without exposing a selected-text range.
@MainActor
struct DictationTextDestination {
    let application: NSRunningApplication
    let element: AXUIElement?
    var selection: CFTypeRef?
    let window: AXUIElement?

    static func capture(application app: NSRunningApplication?) -> Self? {
        guard let app, !app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        let element = elementAttribute(appElement, kAXFocusedUIElementAttribute)
        return Self(application: app, element: element,
            selection: element.flatMap { attribute($0, kAXSelectedTextRangeAttribute) },
            window: elementAttribute(appElement, kAXFocusedWindowAttribute))
    }

    /// Reports when all insertion events have been posted, before clipboard
    /// restoration or any remaining typing delay. The target may handle them later.
    func insert(
        _ text: String,
        keepOnClipboard: Bool,
        method: DictationInsertionMethod = .paste,
        onDispatched: () -> Void = {},
        waitForGestureRelease: () async -> Void = {},
        gestureIsHeld: () -> Bool = { false },
        onReceipt: (DictationInsertionReceipt) -> Void = { _ in }
    ) async -> Bool {
        let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "dictation-insertion")
        guard !text.isEmpty, AXIsProcessTrusted() else {
            logger.info("Insertion deferred: empty text or Accessibility unavailable")
            return false
        }
        if gestureIsHeld() {
            await waitForGestureRelease()
            guard !Task.isCancelled else { return false }
        }
        // A toggle shortcut can finish while Command/Option is still held.
        // Wait for release rather than sending Command+Option+V or modifying
        // the user's physical modifier state.
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        if !CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty {
            // Check the destination before suspending and again after the wait.
            guard destinationIsCurrent() else {
                logger.info("Insertion deferred: destination changed")
                return false
            }
            for _ in 0..<30 {
                if CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty { break }
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return false }
            }
        }
        // A second physical hold may begin while the unrelated-modifier wait is
        // in progress. Wait for that gesture edge too before applying the short
        // safety timeout; never synthesize a paste over held flags.
        if gestureIsHeld() {
            await waitForGestureRelease()
            guard !Task.isCancelled else { return false }
        }
        guard CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty else { return false }
        let originalSelection = selectedRange
        let expectedSelection = DictationSelectionRebase.expectedCaret(
            after: originalSelection, insertedUTF16Count: text.utf16.count)
        let receipt = DictationInsertionReceipt(
            destination: self, originalSelection: originalSelection, expectedSelection: expectedSelection)
        if method == .typing {
            guard destinationIsCurrent() else { return false }
            let inserted = await typeText(
                text,
                waitForGestureRelease: waitForGestureRelease,
                gestureIsHeld: gestureIsHeld
            ) {
                onDispatched()
                onReceipt(receipt)
            }
            if inserted && keepOnClipboard { Self.copy(text) }
            return inserted
        }
        guard let source = CGEventSource(stateID: .privateState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false) else { return false }
        guard applicationIsCurrent else { return false }
        let pasteboard = NSPasteboard.general
        let previous = keepOnClipboard ? nil : DictationClipboardSnapshot(pasteboard)
        // A clipboard owner may be slow to provide its data. Do the focus and
        // selection check after that work, as close to dispatch as possible.
        guard CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty,
              destinationIsCurrent() else {
            logger.info("Insertion deferred: destination or keyboard state changed")
            return false
        }
        let ourChange = pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string), pasteboard.changeCount == ourChange,
              applicationIsCurrent else {
            previous?.restore(ifUnchangedSince: ourChange)
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        commandDown.type = .flagsChanged
        commandDown.flags = .maskCommand
        commandUp.type = .flagsChanged
        commandUp.flags = []
        // Enter the normal event routing path. Posting directly to a PID skips
        // routing used by some AppKit, Electron, and remote/custom controls.
        for event in [commandDown, down, up, commandUp] { event.post(tap: .cghidEventTap) }
        onDispatched()
        onReceipt(receipt)
        logger.info("Paste dispatched to \(application.bundleIdentifier ?? "unknown", privacy: .public)")
        guard let previous else { return true }
        try? await Task.sleep(for: .seconds(1))
        // Do not overwrite clipboard changes made while the destination reads
        // the paste. Never retry a dispatched paste: that can duplicate text.
        previous.restore(ifUnchangedSince: ourChange)
        return true
    }

    /// A queued destination was captured before an earlier paste moved the
    /// caret. Only a dispatched receipt for this exact field, captured at the
    /// same range, permits replacing that stale range with the verified live
    /// post-insertion caret. Every other mismatch is left for the ordinary
    /// destination guard to reject. A third destination captured at the
    /// original range is intentionally not chained through two receipts; it
    /// takes the conservative fallback.
    func rebased(after receipts: [DictationInsertionReceipt]) -> Self? {
        guard let element, let window else { return nil }
        let candidates = matchingReceipts(after: receipts)
        guard !candidates.isEmpty else { return nil }
        guard applicationIsCurrent,
              let app = Self.applicationElement(application),
              let focused = Self.elementAttribute(app, kAXFocusedUIElementAttribute),
              CFEqual(focused, element),
              let currentWindow = Self.elementAttribute(app, kAXFocusedWindowAttribute),
              CFEqual(currentWindow, window),
              !Self.isSecure(element), !Self.isSecure(focused),
              let currentSelection = Self.selectionRange(element) else { return nil }
        for receipt in candidates {
            guard let expected = receipt.expectedSelection,
                  expected.location == currentSelection.location,
                  expected.length == currentSelection.length else { continue }
            var rebased = self
            rebased.selection = Self.axValue(currentSelection)
            return rebased
        }
        return nil
    }

    /// Local-only receipt filtering. This deliberately runs before any AX
    /// query so the common first-dictation path has no extra IPC.
    func hasMatchingReceipt(after receipts: [DictationInsertionReceipt]) -> Bool {
        !matchingReceipts(after: receipts).isEmpty
    }

    private func matchingReceipts(after receipts: [DictationInsertionReceipt]) -> [DictationInsertionReceipt] {
        guard let element, let window else { return [] }
        let captured = selectedRange
        return receipts.reversed().filter { receipt in
            let predecessor = receipt.destination
            guard let predecessorElement = predecessor.element,
                  let predecessorWindow = predecessor.window else { return false }
            return DictationSelectionRebase.matchesCapturedRange(
                original: receipt.originalSelection,
                captured: captured,
                sameApplication: predecessor.application.processIdentifier == application.processIdentifier,
                sameWindow: CFEqual(predecessorWindow, window),
                sameElement: CFEqual(predecessorElement, element)
            )
        }
    }

    private var selectedRange: CFRange? { Self.range(from: selection) }

    private func typeText(
        _ text: String,
        waitForGestureRelease: () async -> Void,
        gestureIsHeld: () -> Bool,
        onDispatched: () -> Void
    ) async -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        // Chunk by Character, never split a UTF-16 surrogate pair or a composed
        // character. This is opt-in for fields that do not handle standard paste.
        var start = text.startIndex
        while start < text.endIndex {
            if gestureIsHeld() {
                await waitForGestureRelease()
                guard !Task.isCancelled else { return false }
            }
            guard !Task.isCancelled, destinationIsCurrent(checkSelection: false) else { return false }
            let end = text.index(start, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
            let units = Array(text[start..<end].utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            down.flags = []; up.flags = []
            units.withUnsafeBufferPointer { buffer in
                guard let pointer = buffer.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: pointer)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: pointer)
            }
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            if end == text.endIndex { onDispatched(); return true }
            start = end
            do { try await Task.sleep(for: .milliseconds(12)) } catch { return false }
        }
        return true
    }

    private var applicationIsCurrent: Bool {
        !application.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
    }

    private func destinationIsCurrent(checkSelection: Bool = true) -> Bool {
        guard applicationIsCurrent else { return false }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        if let window, let currentWindow = Self.elementAttribute(app, kAXFocusedWindowAttribute),
           !CFEqual(window, currentWindow) { return false }
        let focused = Self.elementAttribute(app, kAXFocusedUIElementAttribute)
        if let element, Self.isSecure(element) { return false }
        if let focused, Self.isSecure(focused) { return false }
        if let element, let focused {
            // Two different known text fields are a real focus change. Web
            // areas and custom accessibility proxies can be recreated while
            // the same editor keeps focus; do not require proxy identity there.
            if !CFEqual(element, focused), Self.isTextControl(element), Self.isTextControl(focused) { return false }
            if checkSelection, CFEqual(element, focused), let selection,
               let current = Self.attribute(focused, kAXSelectedTextRangeAttribute),
               !CFEqual(selection, current) { return false }
        }
        return true
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func applicationElement(_ application: NSRunningApplication) -> AXUIElement? {
        guard !application.isTerminated else { return nil }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }
    private static func selectionRange(_ element: AXUIElement) -> CFRange? {
        range(from: attribute(element, kAXSelectedTextRangeAttribute))
    }
    private static func range(from value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetType(value as! AXValue) == .cfRange,
              AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }
    private static func axValue(_ range: CFRange) -> CFTypeRef? {
        var range = range
        return AXValueCreate(.cfRange, &range)
    }
    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func isTextControl(_ element: AXUIElement) -> Bool {
        let role = attribute(element, kAXRoleAttribute) as? String
        return role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole
    }
    private static func isSecure(_ element: AXUIElement) -> Bool {
        attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
    }
}

/// Preserves item boundaries and type order. Restoring only our own change
/// keeps a user's newer copy intact while the destination handles the paste.
@MainActor
struct DictationClipboardSnapshot {
    private let pasteboard: NSPasteboard
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        items = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
    }

    @discardableResult
    func restore(ifUnchangedSince generation: Int) -> Bool {
        guard pasteboard.changeCount == generation else { return false }
        pasteboard.clearContents()
        let restored = items.filter { !$0.isEmpty }.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        return restored.isEmpty || pasteboard.writeObjects(restored)
    }
}
