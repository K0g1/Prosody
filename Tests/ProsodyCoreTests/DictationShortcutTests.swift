#if canImport(XCTest)
import ApplicationServices
@preconcurrency import Carbon.HIToolbox
import IOKit.hidsystem
import XCTest
@testable import ProsodyCore

final class DictationShortcutTests: XCTestCase {
    private typealias Decision = DictationShortcutInput.Decision
    private let chord: CGEventFlags = [.maskControl, .maskAlternate]

    func testRightReleaseIsReportedWhenTheLeftModifierStaysDown() {
        for keys in [ModifierKeys.command, .option] {
            var input = DictationShortcutInput(shortcut: keys.shortcut)
            XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.leftKey, flags: keys.leftOnly), Decision())
            XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.both), Decision(changed: true))
            XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.both), Decision())
            XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.leftOnly), Decision(changed: false))
            XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.leftKey, flags: []), Decision())
            // A fresh press must still work, including when only the right key is held.
            XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.rightOnly), Decision(changed: true))
            XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: []), Decision(changed: false))
        }
    }

    func testLeftPressAndReleaseDoNotChangeAHeldRightShortcut() {
        for keys in [ModifierKeys.command, .option] {
            var input = DictationShortcutInput(shortcut: keys.shortcut)
            XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.rightOnly), Decision(changed: true))
            XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.leftKey, flags: keys.both), Decision())
            XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.leftKey, flags: keys.rightOnly), Decision())
            XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: []), Decision(changed: false))
        }
    }

    func testAggregateOnlyEventsFallBackToTheRightKeyState() {
        for keys in [ModifierKeys.command, .option] {
            var input = DictationShortcutInput(shortcut: keys.shortcut)
            XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.combined,
                                          shortcutKeyDown: true), Decision(changed: true))
            XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.combined,
                                          shortcutKeyDown: false), Decision(changed: false))
        }
    }

    func testAttachingWhileRightKeyIsHeldDoesNotStartOrFinishDictation() {
        let keys = ModifierKeys.option
        var input = DictationShortcutInput(shortcut: keys.shortcut)
        input.resynchronize(shortcutKeyDown: true)
        XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.both), Decision())
        XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.leftOnly), Decision())
        XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.both), Decision(changed: true))
    }

    func testSpaceOnlyClaimsMatchingChordsAndRepeatNeverToggles() {
        let space = Int64(kVK_Space)
        var input = DictationShortcutInput(shortcut: .controlOptionSpace)
        XCTAssertEqual(input.keyEvent(.keyDown, key: space, flags: [.maskControl]), Decision())
        XCTAssertEqual(input.keyEvent(.keyDown, key: space, flags: chord, repeating: true), Decision())
        XCTAssertEqual(input.keyEvent(.keyUp, key: space, flags: chord), Decision())
        XCTAssertEqual(input.keyEvent(.keyDown, key: space, flags: chord.union(.maskCommand)), Decision())
        XCTAssertEqual(input.keyEvent(.keyUp, key: space, flags: []), Decision())
        for _ in 0..<2 {
            XCTAssertEqual(input.keyEvent(.keyDown, key: space, flags: chord), Decision(changed: true, consumed: true))
            XCTAssertEqual(input.keyEvent(.keyDown, key: space, flags: chord, repeating: true), Decision(consumed: true))
            XCTAssertEqual(input.keyEvent(.keyUp, key: space, flags: chord), Decision(changed: false, consumed: true))
        }
    }

    func testReleasingEitherRequiredModifierFinishesAHoldAndStillOwnsSpaceUp() {
        let space = Int64(kVK_Space)
        let releases: [(Int, CGEventFlags)] = [
            (kVK_Control, .maskAlternate), (kVK_RightControl, .maskAlternate),
            (kVK_Option, .maskControl), (kVK_RightOption, .maskControl)
        ]
        for (key, remaining) in releases {
            var input = DictationShortcutInput(shortcut: .controlOptionSpace)
            XCTAssertEqual(input.keyEvent(.keyDown, key: space, flags: chord), Decision(changed: true, consumed: true))
            // Releasing one side of a modifier does not break a chord when
            // the other side still keeps the aggregate flag set.
            XCTAssertEqual(input.keyEvent(.flagsChanged, key: Int64(key), flags: chord), Decision())
            XCTAssertEqual(input.keyEvent(.flagsChanged, key: Int64(key), flags: remaining), Decision(changed: false))
            XCTAssertEqual(input.keyEvent(.flagsChanged, key: Int64(key), flags: chord), Decision())
            XCTAssertEqual(input.keyEvent(.keyDown, key: space, flags: chord, repeating: true), Decision(consumed: true))
            XCTAssertEqual(input.keyEvent(.keyUp, key: space, flags: []), Decision(consumed: true))
            XCTAssertEqual(input.keyEvent(.keyDown, key: space, flags: chord), Decision(changed: true, consumed: true))
        }
    }

    func testEscapePassesThroughWhenIdleAndRepeatDoesNotCancelALaterDictation() {
        let escape = Int64(kVK_Escape)
        var input = DictationShortcutInput(shortcut: .rightCommand)
        XCTAssertEqual(input.keyEvent(.keyDown, key: escape, flags: [], cancel: { false }), Decision())
        XCTAssertEqual(input.keyEvent(.keyDown, key: escape, flags: [], repeating: true, cancel: {
            XCTFail("A repeat is not a new Escape press")
            return true
        }), Decision())
        XCTAssertEqual(input.keyEvent(.keyUp, key: escape, flags: []), Decision())
    }

    func testEscapeCancelsOnceAndConsumesMatchingKeyEventsWithoutFinishing() {
        let space = Int64(kVK_Space)
        let escape = Int64(kVK_Escape)
        var input = DictationShortcutInput(shortcut: .controlOptionSpace)
        var cancellations = 0
        _ = input.keyEvent(.keyDown, key: space, flags: chord)
        XCTAssertEqual(input.keyEvent(.keyDown, key: escape, flags: chord, cancel: {
            cancellations += 1
            return true
        }), Decision(consumed: true))
        XCTAssertEqual(input.keyEvent(.keyDown, key: escape, flags: chord, repeating: true, cancel: {
            cancellations += 1
            return false
        }), Decision(consumed: true))
        XCTAssertEqual(input.keyEvent(.keyUp, key: escape, flags: chord), Decision(consumed: true))
        XCTAssertEqual(input.keyEvent(.keyDown, key: space, flags: chord, repeating: true), Decision(consumed: true))
        XCTAssertEqual(input.keyEvent(.keyUp, key: space, flags: []), Decision(consumed: true))
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(input.keyEvent(.keyDown, key: space, flags: chord), Decision(changed: true, consumed: true))
    }

    func testTapInterruptionCancelsAnActiveHoldWithoutDeliveringARelease() {
        let keys = ModifierKeys.command
        var input = DictationShortcutInput(shortcut: keys.shortcut)
        XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.both), Decision(changed: true))
        var cancelled = false
        input.tapInterrupted(shortcutKeyDown: true, escapeKeyDown: false) { cancelled = true; return true }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.both), Decision())
        XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.leftOnly), Decision())
        XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.both), Decision(changed: true))
    }

    func testTapInterruptionCancelsAToggleEvenWhenTheKeyIsAlreadyUp() {
        let keys = ModifierKeys.option
        var input = DictationShortcutInput(shortcut: keys.shortcut)
        XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.rightOnly), Decision(changed: true))
        XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: []), Decision(changed: false))
        var cancelled = false
        input.tapInterrupted(shortcutKeyDown: false, escapeKeyDown: false) { cancelled = true; return true }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.rightOnly), Decision(changed: true))
    }

    func testTapInterruptionKeepsOnlyTheSpacePressItActuallyClaimed() {
        let space = Int64(kVK_Space)
        var input = DictationShortcutInput(shortcut: .controlOptionSpace)
        input.tapInterrupted(shortcutKeyDown: true, escapeKeyDown: false, cancel: { false })
        XCTAssertEqual(input.keyEvent(.keyUp, key: space, flags: []), Decision())
        _ = input.keyEvent(.keyDown, key: space, flags: chord)
        input.tapInterrupted(shortcutKeyDown: true, escapeKeyDown: false, cancel: { true })
        XCTAssertEqual(input.keyEvent(.keyDown, key: space, flags: chord, repeating: true), Decision(consumed: true))
        XCTAssertEqual(input.keyEvent(.keyUp, key: space, flags: []), Decision(consumed: true))
        XCTAssertEqual(input.keyEvent(.keyDown, key: space, flags: chord), Decision(changed: true, consumed: true))
        // If Space was released while the tap was disabled, the next press
        // starts a new cycle without needing to see the missing Space up.
        input.tapInterrupted(shortcutKeyDown: false, escapeKeyDown: false, cancel: { true })
        XCTAssertEqual(input.keyEvent(.keyDown, key: space, flags: chord), Decision(changed: true, consumed: true))
    }

    func testMissedSpaceReleaseClearsAnOutstandingGesture() {
        let space = Int64(kVK_Space)
        var input = DictationShortcutInput(shortcut: .controlOptionSpace)
        _ = input.keyEvent(.keyDown, key: space, flags: chord)
        XCTAssertTrue(input.tracksRelease)
        XCTAssertFalse(input.recoverMissingReleases(shortcutKeyDown: true, escapeKeyDown: false, flags: chord))
        XCTAssertTrue(input.recoverMissingReleases(shortcutKeyDown: false, escapeKeyDown: false, flags: chord))
        XCTAssertFalse(input.tracksRelease)
        XCTAssertEqual(input.keyEvent(.keyDown, key: space, flags: chord), Decision(changed: true, consumed: true))
    }

    func testMissedModifierReleaseStillConsumesTheClaimedSpaceUp() {
        let space = Int64(kVK_Space)
        var input = DictationShortcutInput(shortcut: .controlOptionSpace)
        _ = input.keyEvent(.keyDown, key: space, flags: chord)
        XCTAssertTrue(input.recoverMissingReleases(shortcutKeyDown: true, escapeKeyDown: false, flags: .maskAlternate))
        XCTAssertFalse(input.recoverMissingReleases(shortcutKeyDown: true, escapeKeyDown: false, flags: .maskAlternate))
        XCTAssertEqual(input.keyEvent(.keyUp, key: space, flags: []), Decision(consumed: true))
        XCTAssertFalse(input.tracksRelease)
    }

    func testMissingRightModifierReleaseRearmsTheShortcut() {
        let keys = ModifierKeys.command
        var input = DictationShortcutInput(shortcut: keys.shortcut)
        XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.both), Decision(changed: true))
        XCTAssertTrue(input.recoverMissingReleases(shortcutKeyDown: false, escapeKeyDown: false, flags: keys.leftOnly))
        XCTAssertEqual(input.keyEvent(.flagsChanged, key: keys.rightKey, flags: keys.both), Decision(changed: true))
    }

    private struct ModifierKeys {
        let shortcut: DictationShortcut
        let leftKey: Int64
        let rightKey: Int64
        let left: UInt64
        let right: UInt64
        let combined: CGEventFlags

        var leftOnly: CGEventFlags { combined.union(CGEventFlags(rawValue: left)) }
        var rightOnly: CGEventFlags { combined.union(CGEventFlags(rawValue: right)) }
        var both: CGEventFlags { leftOnly.union(rightOnly) }

        static let command = Self(shortcut: .rightCommand, leftKey: Int64(kVK_Command), rightKey: Int64(kVK_RightCommand),
                                  left: UInt64(NX_DEVICELCMDKEYMASK), right: UInt64(NX_DEVICERCMDKEYMASK), combined: .maskCommand)
        static let option = Self(shortcut: .rightOption, leftKey: Int64(kVK_Option), rightKey: Int64(kVK_RightOption),
                                 left: UInt64(NX_DEVICELALTKEYMASK), right: UInt64(NX_DEVICERALTKEYMASK), combined: .maskAlternate)
    }
}

#if DEBUG
@MainActor
final class CaptureDrainTests: XCTestCase {
    func testConcurrentStopsPreserveQueuedTailPacketsWithoutWaitingForConsumer() async throws {
        let system = DispatchQueue(label: "ProsodyTests.capture.system")
        let microphone = DispatchQueue(label: "ProsodyTests.capture.microphone")
        let capture = ScreenCaptureCoordinator(systemOutputQueue: system, microphoneOutputQueue: microphone)
        let first = CapturedAudioPacket(source: .microphone, presentationTime: 1, sampleRate: 48_000, samples: [0.25])
        let last = CapturedAudioPacket(source: .microphone, presentationTime: 2, sampleRate: 48_000, samples: [0.5])
        let systemTail = CapturedAudioPacket(source: .system, presentationTime: 2, sampleRate: 48_000, samples: [0.75])
        microphone.async { _ = capture.enqueueValidationFixturePacket(first) }
        microphone.async { _ = capture.enqueueValidationFixturePacket(last) }
        system.async { _ = capture.enqueueValidationFixturePacket(systemTail) }

        async let finish: Void = capture.stop()
        async let secondStop: Void = capture.stop()
        _ = await (finish, secondStop)

        var received: [CapturedAudioPacket] = []
        for try await packet in capture.packets {
            received.append(packet)
            capture.acknowledgePacket()
        }
        XCTAssertEqual(received.filter { $0.source == .microphone }, [first, last])
        XCTAssertEqual(received.filter { $0.source == .system }, [systemTail])
        XCTAssertFalse(capture.enqueueValidationFixturePacket(last))
    }

    func testStopDoesNotHideCaptureFailureBehindAnOrdinaryEndOfStream() async throws {
        let capture = ScreenCaptureCoordinator()
        capture.failValidationFixture(ScreenCaptureCoordinatorError.bufferOverrun)
        await capture.stop()
        do {
            for try await _ in capture.packets {}
            XCTFail("A failed capture must not be treated as a completed recording")
        } catch {
            XCTAssertEqual(error as? ScreenCaptureCoordinatorError, .bufferOverrun)
        }
    }
}
#endif
#endif
