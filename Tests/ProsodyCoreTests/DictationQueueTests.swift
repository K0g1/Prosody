#if canImport(XCTest)
import Combine
import XCTest
@_spi(Validation) @testable import ProsodyCore

@MainActor
final class DictationQueueTests: XCTestCase {
    func testImmediateSecondCaptureAndReleasePreserveOrderInBothModes() async throws {
        for activation in [DictationActivation.hold, .toggle] {
            let fixture = makeFixture(deliveryCount: 2)
            let first = fixture.captures[0]
            let second = fixture.captures[1]

            switch activation {
            case .hold:
                fixture.controller.handleShortcut(down: true, activation: activation)
                await fulfillment(of: [first.started], timeout: 2)
                fixture.controller.handleShortcut(down: false, activation: activation)
            case .toggle:
                fixture.controller.handleShortcut(down: true, activation: activation)
                await fulfillment(of: [first.started], timeout: 2)
                fixture.controller.handleShortcut(down: false, activation: activation)
                fixture.controller.handleShortcut(down: true, activation: activation)
                fixture.controller.handleShortcut(down: false, activation: activation)
            }

            await fulfillment(of: [fixture.firstSuspended], timeout: 2)

            switch activation {
            case .hold:
                fixture.controller.handleShortcut(down: true, activation: activation)
                fixture.controller.handleShortcut(down: false, activation: activation)
            case .toggle:
                fixture.controller.handleShortcut(down: true, activation: activation)
                fixture.controller.handleShortcut(down: false, activation: activation)
                fixture.controller.handleShortcut(down: true, activation: activation)
                fixture.controller.handleShortcut(down: false, activation: activation)
            }

            await fulfillment(of: [second.started], timeout: 2)
            XCTAssertTrue(fixture.controller.isActive,
                          "The main recorder must stay excluded while a capture or finalization is live.")
            let maximum = await fixture.decoder.maximumConcurrency()
            XCTAssertGreaterThanOrEqual(maximum, 1)

            await fixture.decoder.release("one")
            await fulfillment(of: [fixture.secondSuspended], timeout: 2)
            await fixture.decoder.release("two")
            await fulfillment(of: [fixture.deliveries.fulfilled], timeout: 2)
            await waitForIdle(fixture.controller)

            XCTAssertEqual(fixture.deliveries.events.map(\.target), ["A", "B"])
            XCTAssertEqual(fixture.deliveries.events.map(\.text), ["one ", "two "])
            XCTAssertEqual(fixture.deliveries.events.count, 2)
            let finalMaximum = await fixture.decoder.maximumConcurrency()
            XCTAssertEqual(finalMaximum, 1)
            XCTAssertFalse(fixture.controller.isActive)
        }
    }

    func testGestureHoldDefersFirstDispatchUntilPhysicalRelease() async throws {
        let gestureWaitStarted = expectation(description: "first insertion waits for the second hold")
        let fixture = makeFixture(
            deliveryCount: 2,
            waitForGesture: true,
            gestureWaitStarted: gestureWaitStarted
        )
        let first = fixture.captures[0]
        let second = fixture.captures[1]

        fixture.controller.handleShortcut(down: true, activation: .hold)
        await fulfillment(of: [first.started], timeout: 2)
        fixture.controller.handleShortcut(down: false, activation: .hold)
        await fulfillment(of: [fixture.firstSuspended], timeout: 2)

        fixture.controller.handleShortcut(down: true, activation: .hold)
        await fulfillment(of: [second.started], timeout: 2)
        await fixture.decoder.release("one")
        await fulfillment(of: [gestureWaitStarted], timeout: 2)
        XCTAssertTrue(fixture.deliveries.events.isEmpty,
                      "A held second gesture must defer the first paste without a timeout fallback.")

        fixture.controller.handleShortcut(down: false, activation: .hold)
        await fulfillment(of: [fixture.secondSuspended], timeout: 2)
        await fixture.decoder.release("two")
        await fulfillment(of: [fixture.deliveries.fulfilled], timeout: 2)
        await waitForIdle(fixture.controller)

        XCTAssertEqual(fixture.deliveries.events.map(\.text), ["one ", "two "])
        XCTAssertEqual(fixture.deliveries.events.map(\.target), ["A", "B"])
    }

    func testClipboardRestoreDoesNotBlockSecondCaptureOrRecognition() async throws {
        let restoreGate = DeliveryGate()
        let fixture = makeFixture(
            deliveryCount: 2,
            afterFirstDispatch: { await restoreGate.wait() },
            waitForSecondRecognition: true
        )
        let first = fixture.captures[0]
        let second = fixture.captures[1]

        fixture.controller.handleShortcut(down: true, activation: .hold)
        await fulfillment(of: [first.started], timeout: 2)
        fixture.controller.handleShortcut(down: false, activation: .hold)
        await waitDetached(for: fixture.firstSuspended)
        await fixture.decoder.release("one")

        fixture.controller.handleShortcut(down: true, activation: .hold)
        await fulfillment(of: [second.started], timeout: 2)
        fixture.controller.handleShortcut(down: false, activation: .hold)
        await yieldMainActor()
        let recognitionStarted = try XCTUnwrap(fixture.secondRecognitionStarted)
        await waitDetached(for: recognitionStarted)

        XCTAssertEqual(fixture.deliveries.events.count, 1,
                       "The first insertion is still in clipboard restoration.")
        let maximum = await fixture.decoder.maximumConcurrency()
        XCTAssertEqual(maximum, 1)

        await restoreGate.open()
        await waitDetached(for: fixture.secondSuspended)
        await fixture.decoder.release("two")
        await waitDetached(for: fixture.deliveries.fulfilled)
        await waitForIdle(fixture.controller)
        XCTAssertEqual(fixture.deliveries.events.map(\.text), ["one ", "two "])
    }

    func testCancellationDrainsQueueWithoutDeliveryAndReleasesExclusivity() async throws {
        let fixture = makeFixture(deliveryCount: 2)
        let first = fixture.captures[0]
        let second = fixture.captures[1]

        fixture.controller.handleShortcut(down: true, activation: .hold)
        await fulfillment(of: [first.started], timeout: 2)
        fixture.controller.handleShortcut(down: false, activation: .hold)
        await fulfillment(of: [fixture.firstSuspended], timeout: 2)

        fixture.controller.handleShortcut(down: true, activation: .hold)
        await fulfillment(of: [second.started], timeout: 2)
        XCTAssertTrue(fixture.controller.isActive)
        fixture.secondSuspended.isInverted = true
        fixture.deliveries.fulfilled.isInverted = true

        fixture.controller.cancel()
        await waitForIdle(fixture.controller)
        await fulfillment(of: [fixture.secondSuspended, fixture.deliveries.fulfilled], timeout: 0.1)

        XCTAssertTrue(fixture.deliveries.events.isEmpty)
        XCTAssertFalse(fixture.controller.isActive)
        let maximum = await fixture.decoder.maximumConcurrency()
        XCTAssertEqual(maximum, 1)
    }

    func testPublicStartDoesNotReplaceAnUnreleasedCapture() async throws {
        let fixture = makeFixture(deliveryCount: 2)
        let first = fixture.captures[0]
        let second = fixture.captures[1]

        fixture.controller.start()
        await fulfillment(of: [first.started], timeout: 2)
        second.started.isInverted = true
        fixture.controller.start()
        await waitDetached(for: second.started, timeout: 0.1)

        fixture.firstSuspended.isInverted = true
        fixture.secondSuspended.isInverted = true
        fixture.deliveries.fulfilled.isInverted = true
        fixture.controller.cancel()
        await waitForIdle(fixture.controller)
        await waitDetached(for: fixture.firstSuspended, timeout: 0.1)
        await waitDetached(for: fixture.secondSuspended, timeout: 0.1)
        await waitDetached(for: fixture.deliveries.fulfilled, timeout: 0.1)
        XCTAssertTrue(fixture.deliveries.events.isEmpty)
    }

    func testStartupFailureStopsCaptureBeforeReleasingTheHardwareGate() async throws {
        let fixture = makeFixture(deliveryCount: 1, firstCaptureStartError: TestFailure.start)
        let first = fixture.captures[0]
        let second = fixture.captures[1]
        fixture.firstSuspended.isInverted = true

        fixture.controller.start()
        await fulfillment(of: [first.started], timeout: 2)
        await waitForInactive(fixture.controller)
        XCTAssertEqual(fixture.controller.state, .result)
        fixture.controller.dismiss()
        await waitForIdle(fixture.controller)

        fixture.controller.start()
        await fulfillment(of: [second.started], timeout: 2)
        fixture.controller.finish()
        await fulfillment(of: [fixture.secondSuspended], timeout: 2)
        await fixture.decoder.release("two")
        await fulfillment(of: [fixture.deliveries.fulfilled], timeout: 2)
        await waitForIdle(fixture.controller)
        fixture.firstSuspended.isInverted = true
        XCTAssertEqual(fixture.deliveries.events.map(\.text), ["two "])
        await fulfillment(of: [fixture.firstSuspended], timeout: 0.1)
    }

    func testLaterSuccessKeepsUnacknowledgedFailureCopyable() async throws {
        let fixture = makeFixture(deliveryCount: 2, deliveryResults: [false, true])

        await failFirstDictation(fixture)
        XCTAssertEqual(fixture.controller.state, .result)
        XCTAssertEqual(fixture.controller.resultText, "one ")
        let failure = fixture.controller.message
        XCTAssertTrue(failure.contains("Couldn’t insert"))

        await finishSecondDictation(fixture)

        XCTAssertEqual(fixture.controller.state, .result)
        XCTAssertEqual(fixture.controller.resultText, "one ")
        XCTAssertEqual(fixture.controller.message, failure)
    }

    func testLaterCaptureWarningKeepsCopyableFailureText() async throws {
        let fixture = makeFixture(
            deliveryCount: 1,
            secondCaptureStartError: TestFailure.start,
            deliveryResults: [false]
        )
        let second = fixture.captures[1]
        fixture.secondSuspended.isInverted = true

        await failFirstDictation(fixture)
        await fulfillment(of: [fixture.deliveries.fulfilled], timeout: 2)

        fixture.controller.start()
        await fulfillment(of: [second.started], timeout: 2)
        await waitForInactive(fixture.controller)

        XCTAssertEqual(fixture.controller.state, .result)
        XCTAssertEqual(fixture.controller.resultText, "one ")
        XCTAssertEqual(fixture.controller.message, "A newer dictation failed. Copy the earlier text below.")
        await fulfillment(of: [fixture.secondSuspended], timeout: 0.1)
    }

    func testCancellingLaterDictationKeepsUnacknowledgedFailure() async throws {
        let fixture = makeFixture(deliveryCount: 1, deliveryResults: [false])
        let second = fixture.captures[1]
        fixture.secondSuspended.isInverted = true

        await failFirstDictation(fixture)
        await fulfillment(of: [fixture.deliveries.fulfilled], timeout: 2)

        fixture.controller.start()
        await fulfillment(of: [second.started], timeout: 2)
        fixture.controller.cancel()
        await waitForInactive(fixture.controller)

        XCTAssertEqual(fixture.controller.state, .result)
        XCTAssertEqual(fixture.controller.resultText, "one ")
        await fulfillment(of: [fixture.secondSuspended], timeout: 0.1)
    }

    func testQuietLaterDictationKeepsUnacknowledgedFailure() async throws {
        let fixture = makeFixture(
            deliveryCount: 1,
            secondCaptureEmitsPacket: false,
            deliveryResults: [false]
        )
        let second = fixture.captures[1]
        fixture.secondSuspended.isInverted = true

        await failFirstDictation(fixture)
        await fulfillment(of: [fixture.deliveries.fulfilled], timeout: 2)

        fixture.controller.start()
        await fulfillment(of: [second.started], timeout: 2)
        fixture.controller.finish()
        await waitForInactive(fixture.controller)

        XCTAssertEqual(fixture.controller.state, .result)
        XCTAssertEqual(fixture.controller.resultText, "one ")
        await fulfillment(of: [fixture.secondSuspended], timeout: 0.1)
    }

    func testCopyAcknowledgesFailureAndKeepsConfirmation() async throws {
        var copied: [String] = []
        let fixture = makeFixture(
            deliveryCount: 2,
            deliveryResults: [false, true],
            copyText: { copied.append($0) }
        )

        await failFirstDictation(fixture)

        fixture.controller.copyResult()
        XCTAssertEqual(copied, ["one "])
        XCTAssertEqual(fixture.controller.state, .result)
        XCTAssertEqual(fixture.controller.message, "Copied to clipboard")
        XCTAssertEqual(fixture.controller.resultText, "one ")

        await finishSecondDictation(fixture)
        await waitForIdle(fixture.controller)

        XCTAssertEqual(fixture.controller.resultText, "")
        XCTAssertEqual(fixture.controller.message, "")
    }

    func testCopyResultDoesNotChangeAnActiveCapture() async throws {
        var copied: [String] = []
        let fixture = makeFixture(deliveryCount: 1, copyText: { copied.append($0) })
        let first = fixture.captures[0]
        fixture.firstSuspended.isInverted = true
        fixture.secondSuspended.isInverted = true
        fixture.captures[1].started.isInverted = true
        fixture.deliveries.fulfilled.isInverted = true

        fixture.controller.start()
        await fulfillment(of: [first.started], timeout: 2)
        fixture.controller.copyResult()

        XCTAssertTrue(fixture.controller.state.isActive)
        XCTAssertTrue(copied.isEmpty)

        fixture.controller.cancel()
        await waitForIdle(fixture.controller)
        await fulfillment(of: [fixture.firstSuspended, fixture.secondSuspended,
                               fixture.captures[1].started, fixture.deliveries.fulfilled], timeout: 0.1)
    }

    func testDismissClearsUnacknowledgedFailure() async throws {
        let fixture = makeFixture(deliveryCount: 1, deliveryResults: [false])
        fixture.captures[1].started.isInverted = true
        fixture.secondSuspended.isInverted = true

        await failFirstDictation(fixture)
        await fulfillment(of: [fixture.deliveries.fulfilled], timeout: 2)

        fixture.controller.dismiss()
        XCTAssertEqual(fixture.controller.state, .idle)
        XCTAssertEqual(fixture.controller.resultText, "")
        XCTAssertEqual(fixture.controller.message, "")
        await fulfillment(of: [fixture.captures[1].started, fixture.secondSuspended], timeout: 0.1)
    }

    func testUnchangedShortcutConfigurationRetainsTapDuringDrain() async throws {
        let settings = ShortcutSettings()
        let monitors = ShortcutMonitorStore()
        let fixture = makeFixture(
            deliveryCount: 1,
            shortcutSettings: settings,
            shortcutMonitorStore: monitors
        )
        fixture.controller.configureShortcut()
        await waitForMonitorCount(monitors, 1)
        let first = fixture.captures[0]
        fixture.secondSuspended.isInverted = true
        fixture.captures[1].started.isInverted = true
        fixture.deliveries.fulfilled.isInverted = true

        fixture.controller.start()
        await fulfillment(of: [first.started], timeout: 2)
        fixture.controller.finish()
        await fulfillment(of: [fixture.firstSuspended], timeout: 2)
        fixture.controller.configureShortcut()
        await yieldMainActor()

        XCTAssertEqual(monitors.created.count, 1)
        XCTAssertEqual(monitors.created[0].monitor.stopCount, 0)
        XCTAssertTrue(fixture.controller.shortcutReady)

        fixture.controller.cancel()
        await waitForIdle(fixture.controller)
        XCTAssertEqual(monitors.created.count, 1)
        XCTAssertEqual(monitors.created[0].monitor.stopCount, 0)
        await fulfillment(of: [fixture.secondSuspended, fixture.captures[1].started,
                               fixture.deliveries.fulfilled], timeout: 0.1)
    }

    func testShortcutChangeWaitsForIdleAndGestureRelease() async throws {
        let settings = ShortcutSettings()
        let monitors = ShortcutMonitorStore()
        let fixture = makeFixture(
            deliveryCount: 1,
            shortcutSettings: settings,
            shortcutMonitorStore: monitors
        )
        fixture.controller.configureShortcut()
        await waitForMonitorCount(monitors, 1)
        let first = fixture.captures[0]
        fixture.firstSuspended.isInverted = true
        fixture.secondSuspended.isInverted = true
        fixture.captures[1].started.isInverted = true
        fixture.deliveries.fulfilled.isInverted = true

        fixture.controller.handleShortcut(down: true, activation: .hold)
        await fulfillment(of: [first.started], timeout: 2)
        settings.shortcut = .rightOption
        fixture.controller.configureShortcut()
        await yieldMainActor()
        XCTAssertEqual(monitors.created.count, 1)
        XCTAssertEqual(monitors.created[0].monitor.stopCount, 0)

        fixture.controller.handleShortcut(down: false, activation: .hold)
        await yieldMainActor()
        XCTAssertEqual(monitors.created.count, 1)

        fixture.controller.cancel()
        await waitForInactive(fixture.controller)
        await waitForMonitorCount(monitors, 2)

        XCTAssertEqual(monitors.created[0].monitor.stopCount, 1)
        XCTAssertEqual(monitors.created[1].shortcut, .rightOption)
        await fulfillment(of: [fixture.firstSuspended, fixture.secondSuspended,
                               fixture.captures[1].started, fixture.deliveries.fulfilled], timeout: 0.1)
    }

    func testAccessibilityLossWaitsForIdleAndGestureRelease() async throws {
        let settings = ShortcutSettings()
        let monitors = ShortcutMonitorStore()
        let fixture = makeFixture(
            deliveryCount: 1,
            shortcutSettings: settings,
            shortcutMonitorStore: monitors
        )
        fixture.controller.configureShortcut()
        await waitForMonitorCount(monitors, 1)
        let first = fixture.captures[0]
        fixture.firstSuspended.isInverted = true
        fixture.secondSuspended.isInverted = true
        fixture.captures[1].started.isInverted = true
        fixture.deliveries.fulfilled.isInverted = true

        fixture.controller.handleShortcut(down: true, activation: .hold)
        await fulfillment(of: [first.started], timeout: 2)
        settings.trusted = false
        fixture.controller.configureShortcut()
        await yieldMainActor()
        XCTAssertEqual(monitors.created[0].monitor.stopCount, 0)

        fixture.controller.handleShortcut(down: false, activation: .hold)
        await yieldMainActor()
        XCTAssertEqual(monitors.created[0].monitor.stopCount, 0)

        fixture.controller.cancel()
        await waitForInactive(fixture.controller)
        await waitForShortcutStop(monitors, 1)

        XCTAssertEqual(monitors.created.count, 1)
        XCTAssertFalse(fixture.controller.shortcutReady)
        await fulfillment(of: [fixture.firstSuspended, fixture.secondSuspended,
                               fixture.captures[1].started, fixture.deliveries.fulfilled], timeout: 0.1)
    }

    func testSelectionRebaseRequiresSameFieldRangeAndExpectedCaret() {
        let original = CFRange(location: 10, length: 0)
        let expected = DictationSelectionRebase.expectedCaret(after: original, insertedUTF16Count: 4)
        XCTAssertEqual(expected?.location, 14)
        XCTAssertEqual(expected?.length, 0)

        XCTAssertTrue(DictationSelectionRebase.matchesCapturedRange(
            original: original, captured: original,
            sameApplication: true, sameWindow: true, sameElement: true))
        XCTAssertFalse(DictationSelectionRebase.matchesCapturedRange(
            original: original, captured: CFRange(location: 11, length: 0),
            sameApplication: true, sameWindow: true, sameElement: true))

        XCTAssertTrue(DictationSelectionRebase.canRebase(
            original: original, captured: original, expected: expected, current: expected,
            sameApplication: true, sameWindow: true, sameElement: true))

        XCTAssertFalse(DictationSelectionRebase.canRebase(
            original: original, captured: original, expected: expected, current: expected,
            sameApplication: true, sameWindow: true, sameElement: false),
            "A changed AX field must not be rebased.")
        XCTAssertFalse(DictationSelectionRebase.canRebase(
            original: original, captured: original, expected: expected,
            current: CFRange(location: 15, length: 0),
            sameApplication: true, sameWindow: true, sameElement: true),
            "A changed live selection must not be rebased.")
        XCTAssertFalse(DictationSelectionRebase.canRebase(
            original: original, captured: CFRange(location: 11, length: 0),
            expected: expected, current: expected,
            sameApplication: true, sameWindow: true, sameElement: true),
            "A destination captured at a different range must not be rebased.")
        XCTAssertFalse(DictationSelectionRebase.canRebase(
            original: original, captured: original, expected: expected, current: expected,
            sameApplication: false, sameWindow: true, sameElement: true))
        XCTAssertFalse(DictationSelectionRebase.canRebase(
            original: original, captured: original, expected: expected, current: expected,
            sameApplication: true, sameWindow: false, sameElement: true))

        // A third destination captured at the original range is not chained
        // through two receipts. It deliberately takes the safe fallback.
        XCTAssertFalse(DictationSelectionRebase.canRebase(
            original: original, captured: original, expected: expected,
            current: CFRange(location: 9, length: 0),
            sameApplication: true, sameWindow: true, sameElement: true))
    }

    func testExpectedCaretUsesUTF16Units() {
        let expected = DictationSelectionRebase.expectedCaret(
            after: CFRange(location: 3, length: 0),
            insertedUTF16Count: "😀".utf16.count
        )
        XCTAssertEqual(expected?.location, 5)
        XCTAssertEqual(expected?.length, 0)
    }

    private func makeFixture(
        deliveryCount: Int,
        waitForGesture: Bool = false,
        gestureWaitStarted: XCTestExpectation? = nil,
        afterFirstDispatch: (@MainActor () async -> Void)? = nil,
        firstCaptureStartError: Error? = nil,
        waitForSecondRecognition: Bool = false,
        secondCaptureStartError: Error? = nil,
        secondCaptureEmitsPacket: Bool = true,
        deliveryResults: [Bool] = [],
        copyText: (@MainActor (String) -> Void)? = nil,
        shortcutSettings: ShortcutSettings? = nil,
        shortcutMonitorStore: ShortcutMonitorStore? = nil
    ) -> Fixture {
        let firstSuspended = expectation(description: "first decoder suspended")
        let secondSuspended = expectation(description: "second decoder suspended")
        let secondRecognitionStarted: XCTestExpectation? = waitForSecondRecognition
            ? expectation(description: "second recognition started") : nil
        let decoder = SuspendedDecoder { key in
            if key == "one" { firstSuspended.fulfill() }
            if key == "two" { secondSuspended.fulfill() }
        }
        let model = TestRecognitionModel(decoder: decoder) { count in
            if count == 2 { secondRecognitionStarted?.fulfill() }
        }
        let recognizer = DictationRecognizer(idleRetention: .zero) {
            model
        }
        let firstCapture = TestDictationCapture(
            marker: 0.1, started: expectation(description: "first capture started"),
            startError: firstCaptureStartError)
        let secondCapture = TestDictationCapture(
            marker: 0.2, started: expectation(description: "second capture started"),
            startError: secondCaptureStartError, emitsPacket: secondCaptureEmitsPacket)
        let captureStore = CaptureStore(captures: [firstCapture, secondCapture])
        let delivered = expectation(description: "dictation deliveries")
        delivered.expectedFulfillmentCount = deliveryCount
        let deliveries = DeliveryRecorder(fulfilled: delivered)
        let destinationStore = DestinationStore(
            deliveries: deliveries,
            waitForGesture: waitForGesture,
            gestureWaitStarted: gestureWaitStarted,
            afterFirstDispatch: afterFirstDispatch,
            deliveryResults: deliveryResults
        )
        let dependencies = DictationController.Dependencies(
            canStart: { true },
            frontmostApplication: { nil },
            makeCapture: { captureStore.next() },
            resolveDestination: { _ in destinationStore.next() },
            requireMicrophonePermission: {},
            saveDictation: { _, _, _ in },
            recognizer: recognizer,
            shortcut: { shortcutSettings?.shortcut ?? .rightCommand },
            activation: { shortcutSettings?.activation ?? .hold },
            accessibilityTrusted: { shortcutSettings?.trusted ?? true },
            requestAccessibilityPermission: {},
            makeShortcutMonitor: { shortcut, callbacks in
                if let shortcutMonitorStore {
                    return shortcutMonitorStore.make(shortcut: shortcut, callbacks: callbacks)
                }
                return DictationShortcutMonitor(
                    shortcut: shortcut,
                    changed: callbacks.changed,
                    cancel: callbacks.cancel,
                    resetGesture: callbacks.resetGesture
                )
            },
            copyText: { text in
                if let copyText { copyText(text) }
                else { DictationTextDestination.copy(text) }
            }
        )
        return Fixture(
            controller: DictationController(dependencies: dependencies),
            decoder: decoder,
            captures: captureStore.captures,
            deliveries: deliveries,
            firstSuspended: firstSuspended,
            secondSuspended: secondSuspended,
            secondRecognitionStarted: secondRecognitionStarted
        )
    }

    private func failFirstDictation(_ fixture: Fixture) async {
        let first = fixture.captures[0]
        fixture.controller.start()
        await fulfillment(of: [first.started], timeout: 2)
        fixture.controller.finish()
        await fulfillment(of: [fixture.firstSuspended], timeout: 2)
        await fixture.decoder.release("one")
        await waitForInactive(fixture.controller)
    }

    private func finishSecondDictation(_ fixture: Fixture) async {
        let second = fixture.captures[1]
        fixture.controller.start()
        await fulfillment(of: [second.started], timeout: 2)
        fixture.controller.finish()
        await fulfillment(of: [fixture.secondSuspended], timeout: 2)
        await fixture.decoder.release("two")
        await fulfillment(of: [fixture.deliveries.fulfilled], timeout: 2)
        await waitForInactive(fixture.controller)
    }

    private func waitForIdle(_ controller: DictationController) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.state != .idle, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.state, .idle)
    }

    private func waitForInactive(_ controller: DictationController) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.isActive, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isActive)
    }

    private func yieldMainActor() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private func waitForMonitorCount(_ store: ShortcutMonitorStore, _ count: Int) async {
        for _ in 0..<100 {
            if store.created.count >= count { return }
            await Task.yield()
        }
        XCTFail("Expected \(count) shortcut monitors, got \(store.created.count)")
    }

    private func waitForShortcutStop(_ store: ShortcutMonitorStore, _ count: Int) async {
        for _ in 0..<100 {
            if (store.created.first?.monitor.stopCount ?? 0) >= count { return }
            await Task.yield()
        }
        XCTFail("Expected the shortcut monitor to stop \(count) time(s)")
    }

    private func waitDetached(for expectation: XCTestExpectation, timeout: TimeInterval = 2) async {
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: XCTWaiter.wait(for: [expectation], timeout: timeout))
            }
        }
        XCTAssertEqual(result, .completed)
    }
}

@MainActor
private struct Fixture {
    let controller: DictationController
    let decoder: SuspendedDecoder
    let captures: [TestDictationCapture]
    let deliveries: DeliveryRecorder
    let firstSuspended: XCTestExpectation
    let secondSuspended: XCTestExpectation
    let secondRecognitionStarted: XCTestExpectation?
}

@MainActor
private final class ShortcutSettings {
    var shortcut: DictationShortcut = .rightCommand
    var activation: DictationActivation = .hold
    var trusted = true
}

@MainActor
private final class ShortcutMonitorStore {
    struct Created {
        let shortcut: DictationShortcut
        let monitor: TestShortcutMonitor
    }

    private(set) var created: [Created] = []

    func make(shortcut: DictationShortcut,
              callbacks: DictationShortcutMonitorCallbacks) -> any DictationShortcutMonitoring {
        let monitor = TestShortcutMonitor(callbacks: callbacks)
        created.append(Created(shortcut: shortcut, monitor: monitor))
        return monitor
    }
}

@MainActor
private final class TestShortcutMonitor: DictationShortcutMonitoring {
    private let callbacks: DictationShortcutMonitorCallbacks
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(callbacks: DictationShortcutMonitorCallbacks) {
        self.callbacks = callbacks
    }

    func start() -> Bool {
        startCount += 1
        return true
    }

    func stop() {
        stopCount += 1
        callbacks.resetGesture()
    }
}

private enum TestFailure: Error {
    case start
}

private final class TestDictationCapture: DictationCapture, @unchecked Sendable {
    let packets: AsyncThrowingStream<CapturedAudioPacket, Error>
    let started: XCTestExpectation
    private let continuation: AsyncThrowingStream<CapturedAudioPacket, Error>.Continuation
    private let marker: Float
    private let startError: Error?
    private let emitsPacket: Bool

    init(marker: Float, started: XCTestExpectation, startError: Error? = nil, emitsPacket: Bool = true) {
        self.marker = marker
        self.started = started
        self.startError = startError
        self.emitsPacket = emitsPacket
        var continuation: AsyncThrowingStream<CapturedAudioPacket, Error>.Continuation!
        packets = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(16)) { continuation = $0 }
        self.continuation = continuation
    }

    func start(mode: CaptureMode, microphoneDeviceID: String?) async throws {
        started.fulfill()
        if let startError { throw startError }
        if emitsPacket {
            continuation.yield(CapturedAudioPacket(
                source: .microphone,
                presentationTime: 0,
                sampleRate: 16_000,
                samples: [marker] + Array(repeating: 0, count: 7_999)
            ))
        }
    }

    func stop(drainOutputQueues: Bool) async {
        continuation.finish()
    }

    func acknowledgePacket() {}
}

@MainActor
private final class CaptureStore {
    let captures: [TestDictationCapture]
    private var index = 0

    init(captures: [TestDictationCapture]) {
        self.captures = captures
    }

    func next() -> any DictationCapture {
        defer { index += 1 }
        return captures[min(index, captures.count - 1)]
    }
}

@MainActor
private final class DeliveryRecorder {
    struct Event {
        let target: String
        let text: String
    }

    private(set) var events: [Event] = []
    let fulfilled: XCTestExpectation

    init(fulfilled: XCTestExpectation) {
        self.fulfilled = fulfilled
    }

    func record(target: String, text: String) {
        events.append(Event(target: target, text: text))
        fulfilled.fulfill()
    }
}

@MainActor
private final class DestinationStore {
    private let deliveries: DeliveryRecorder
    private let waitForGesture: Bool
    private let gestureWaitStarted: XCTestExpectation?
    private let afterFirstDispatch: (@MainActor () async -> Void)?
    private let deliveryResults: [Bool]
    private var index = 0

    init(
        deliveries: DeliveryRecorder,
        waitForGesture: Bool,
        gestureWaitStarted: XCTestExpectation?,
        afterFirstDispatch: (@MainActor () async -> Void)?,
        deliveryResults: [Bool]
    ) {
        self.deliveries = deliveries
        self.waitForGesture = waitForGesture
        self.gestureWaitStarted = gestureWaitStarted
        self.afterFirstDispatch = afterFirstDispatch
        self.deliveryResults = deliveryResults
    }

    func next() -> any DictationTextDelivering {
        let identifier = index == 0 ? "A" : "B"
        let afterDispatch = index == 0 ? afterFirstDispatch : nil
        let result = deliveryResults.isEmpty ? true : deliveryResults[min(index, deliveryResults.count - 1)]
        defer { index += 1 }
        return TestDestination(
            identifier: identifier,
            deliveries: deliveries,
            waitForGesture: waitForGesture,
            gestureWaitStarted: gestureWaitStarted,
            afterDispatch: afterDispatch,
            result: result
        )
    }
}

@MainActor
private final class TestDestination: DictationTextDelivering {
    let identifier: String
    private let deliveries: DeliveryRecorder
    private let waitForGesture: Bool
    private let gestureWaitStarted: XCTestExpectation?
    private let afterDispatch: (@MainActor () async -> Void)?
    private let result: Bool

    init(
        identifier: String,
        deliveries: DeliveryRecorder,
        waitForGesture: Bool,
        gestureWaitStarted: XCTestExpectation?,
        afterDispatch: (@MainActor () async -> Void)?,
        result: Bool
    ) {
        self.identifier = identifier
        self.deliveries = deliveries
        self.waitForGesture = waitForGesture
        self.gestureWaitStarted = gestureWaitStarted
        self.afterDispatch = afterDispatch
        self.result = result
    }

    func insert(
        _ text: String,
        keepOnClipboard: Bool,
        method: DictationInsertionMethod,
        onDispatched: () -> Void,
        waitForGestureRelease: () async -> Void,
        gestureIsHeld: () -> Bool,
        onReceipt: (DictationInsertionReceipt) -> Void
    ) async -> Bool {
        if waitForGesture, gestureIsHeld() {
            gestureWaitStarted?.fulfill()
            await waitForGestureRelease()
        }
        guard !Task.isCancelled else { return false }
        deliveries.record(target: identifier, text: text)
        onDispatched()
        if let afterDispatch { await afterDispatch() }
        return result
    }
}

private actor DeliveryGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private actor SuspendedDecoder {
    private let onSuspend: @Sendable (String) -> Void
    private var continuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var released: Set<String> = []
    private var cancelled: Set<String> = []
    private var active = 0
    private var maximum = 0

    init(onSuspend: @escaping @Sendable (String) -> Void) {
        self.onSuspend = onSuspend
    }

    func suspend(_ key: String) async throws {
        active += 1
        maximum = max(maximum, active)
        onSuspend(key)
        defer { active -= 1 }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if released.contains(key) {
                    continuation.resume()
                } else if cancelled.contains(key) {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[key] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(key) }
        }
    }

    func release(_ key: String) {
        if let continuation = continuations.removeValue(forKey: key) {
            continuation.resume()
        } else {
            released.insert(key)
        }
    }

    func cancel(_ key: String) {
        if let continuation = continuations.removeValue(forKey: key) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelled.insert(key)
        }
    }

    func maximumConcurrency() -> Int { maximum }
}

private actor TestRecognitionModel: DictationRecognitionModel {
    let decoder: SuspendedDecoder
    private let onSession: @Sendable (Int) -> Void
    private var sessions = 0

    init(decoder: SuspendedDecoder, onSession: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.decoder = decoder
        self.onSession = onSession
    }

    func makeDictationSession(
        configuration: TranscriptSegmentationConfiguration
    ) async throws -> any DictationRecognitionSession {
        sessions += 1
        onSession(sessions)
        return TestRecognitionSession(decoder: decoder)
    }

    func reset() async throws {}
}

private actor TestRecognitionSession: DictationRecognitionSession {
    private let decoder: SuspendedDecoder
    private var marker: Float?
    private var key: String?

    init(decoder: SuspendedDecoder) {
        self.decoder = decoder
    }

    func append(samples: [Float], startTime: TimeInterval) async throws {
        if marker == nil { marker = samples.first(where: { $0 != 0 }) }
    }

    func finishDictation(
        appending samples: [Float],
        startTime: TimeInterval,
        endTime: TimeInterval
    ) async throws -> FinalTranscript {
        if marker == nil { marker = samples.first(where: { $0 != 0 }) }
        let key = (marker ?? 0) > 0.15 ? "two" : "one"
        self.key = key
        try await decoder.suspend(key)
        return FinalTranscript(segments: [
            TranscriptSegment(
                source: .microphone,
                start: startTime,
                end: endTime,
                text: key,
                isFinal: true
            )
        ])
    }

    func cancel() async {
        if let key { await decoder.cancel(key) }
    }
}
#endif
