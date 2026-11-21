#if canImport(XCTest)
import AppKit
@preconcurrency import Carbon.HIToolbox
import XCTest
@testable import ProsodyCore

final class DictationClipboardTests: XCTestCase {
    @MainActor
    func testPasteKeyFollowsTheCommandModifiedKeyboardLayout() throws {
        let inputSources = try XCTUnwrap(TISCreateInputSourceList(nil, true)).takeRetainedValue() as NSArray
        func source(_ identifier: String) throws -> TISInputSource {
            for rawInputSource in inputSources {
                let inputSource = rawInputSource as! TISInputSource
                guard let rawID = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID) else { continue }
                if Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String == identifier {
                    return inputSource
                }
            }
            throw XCTSkip("Keyboard layout \(identifier) is unavailable")
        }
        let keyboardType = UInt32(LMGetKbdType())
        XCTAssertEqual(DictationKeyboardInput.pasteKeyCode(in: try source("com.apple.keylayout.US"),
                                                          keyboardType: keyboardType), CGKeyCode(kVK_ANSI_V))
        XCTAssertEqual(DictationKeyboardInput.pasteKeyCode(in: try source("com.apple.keylayout.Dvorak"),
                                                          keyboardType: keyboardType), CGKeyCode(kVK_ANSI_Period))
        XCTAssertEqual(DictationKeyboardInput.pasteKeyCode(in: try source("com.apple.keylayout.DVORAK-QWERTYCMD"),
                                                          keyboardType: keyboardType), CGKeyCode(kVK_ANSI_V))
    }

    func testTypingEventsCarryUnicodeOnlyOnKeyDown() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let text = String(repeating: "👩🏽‍💻e\u{301}", count: 6)
        let events = try XCTUnwrap(DictationKeyboardInput.typingEvents(for: text[...], source: source))
        XCTAssertEqual(events.down.flags, [])
        XCTAssertEqual(events.up.flags, [])
        XCTAssertNotEqual(events.down.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_A))
        XCTAssertEqual(NSEvent(cgEvent: events.down)?.characters?.utf16.map { $0 }, Array(text.utf16))
        XCTAssertEqual(NSEvent(cgEvent: events.up)?.characters, "")
    }

    @MainActor
    func testRestoresMultipleItemsAndRepresentations() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("Original text", forType: .string)
        first.setData(Data("<b>Original text</b>".utf8), forType: .html)
        let second = NSPasteboardItem()
        let binary = NSPasteboard.PasteboardType("com.openai.clippy.tests.binary")
        second.setData(Data([0, 1, 255]), forType: binary)
        XCTAssertTrue(board.writeObjects([first, second]))
        let originalTypes = try XCTUnwrap(board.pasteboardItems).map(\.types)
        let snapshot = DictationClipboardSnapshot(board)
        let generation = board.clearContents()
        XCTAssertTrue(board.setString("Temporary dictation", forType: .string))
        XCTAssertEqual(board.changeCount, generation)
        XCTAssertTrue(snapshot.restore(ifUnchangedSince: generation))

        let items = try XCTUnwrap(board.pasteboardItems)
        XCTAssertEqual(items.map(\.types), originalTypes)
        XCTAssertEqual(items.first?.string(forType: .string), "Original text")
        XCTAssertEqual(items.first?.data(forType: .html), Data("<b>Original text</b>".utf8))
        XCTAssertEqual(items.last?.data(forType: binary), Data([0, 1, 255]))
    }

    @MainActor
    func testNeverOverwritesANewerCopy() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Original", forType: .string)
        let snapshot = DictationClipboardSnapshot(board)
        let generation = board.clearContents()
        board.setString("Temporary dictation", forType: .string)
        board.clearContents()
        board.setString("New copy", forType: .string)

        XCTAssertFalse(snapshot.restore(ifUnchangedSince: generation))
        XCTAssertEqual(board.string(forType: .string), "New copy")
    }

    @MainActor
    func testRestoresAnOriginallyEmptyClipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let snapshot = DictationClipboardSnapshot(board)
        let generation = board.clearContents()
        XCTAssertTrue(board.setString("Temporary dictation", forType: .string))
        XCTAssertTrue(snapshot.restore(ifUnchangedSince: generation))
        XCTAssertTrue(board.pasteboardItems?.isEmpty ?? true)
    }
}
#endif
