#if canImport(XCTest)
import Foundation
import XCTest
@testable import ProsodyCore

@MainActor
final class LoginItemManagerTests: XCTestCase {
    func testRequiresApprovalPublishesStateAndOpensLoginItems() async {
        let backend = LoginItemTestBackend(status: .requiresApproval)
        let manager = LoginItemManager(backend: backend)

        await manager.refresh()

        XCTAssertEqual(manager.status, .requiresApproval)
        XCTAssertTrue(manager.isOn)
        XCTAssertTrue(manager.canToggle)
        XCTAssertTrue(manager.shouldOfferOpenLoginItems)
        XCTAssertTrue(manager.statusDescription.contains("Approve Prosody"))

        await manager.openLoginItems()
        let calls = await backend.calls
        XCTAssertEqual(calls, [.status, .openLoginItems])
        XCTAssertFalse(manager.isBusy)
    }

    func testNotFoundAttemptsRegistrationAndStillOffersSettings() async {
        let backend = LoginItemTestBackend(status: .notFound)
        let manager = LoginItemManager(backend: backend)

        await manager.refresh()

        XCTAssertEqual(manager.status, .notFound)
        XCTAssertFalse(manager.isOn)
        XCTAssertTrue(manager.canToggle)
        XCTAssertTrue(manager.shouldOfferOpenLoginItems)
        XCTAssertTrue(manager.statusDescription.contains("register"))

        manager.requestEnabled(true)
        await waitUntilIdle(manager)
        let calls = await backend.calls
        XCTAssertEqual(calls, [.status, .status, .register, .status])
        XCTAssertEqual(manager.status, .requiresApproval)
    }

    func testExistingEnabledRegistrationIsNotReRegistered() async {
        let backend = LoginItemTestBackend(status: .enabled)
        let manager = LoginItemManager(backend: backend)
        var mirrored: [Bool] = []
        manager.onSuccessfulUserInitiatedChange = { mirrored.append($0) }

        await manager.refresh()
        XCTAssertTrue(mirrored.isEmpty)
        manager.requestEnabled(true)
        await waitUntilIdle(manager)

        let calls = await backend.calls
        XCTAssertEqual(calls, [.status, .status, .status])
        XCTAssertFalse(calls.contains(.register))
        XCTAssertEqual(manager.status, .enabled)
        XCTAssertEqual(mirrored, [true])
    }

    func testDelayedRegistrationDisablesControlsAndRejectsOverlap() async {
        let backend = LoginItemTestBackend(status: .notRegistered, blocksRegister: true)
        let manager = LoginItemManager(backend: backend)
        var mirrored: [Bool] = []
        manager.onSuccessfulUserInitiatedChange = { mirrored.append($0) }
        await manager.refresh()

        manager.requestEnabled(true)
        await backend.waitForRegisterStart()

        XCTAssertTrue(manager.isBusy)
        XCTAssertFalse(manager.canToggle)
        await manager.refresh()
        let duringRegistration = await backend.calls
        XCTAssertEqual(duringRegistration, [.status, .status, .register])

        await backend.releaseRegister()
        await waitUntilIdle(manager)

        XCTAssertEqual(manager.status, .requiresApproval)
        XCTAssertEqual(mirrored, [true])
        XCTAssertFalse(manager.isBusy)
        let completed = await backend.calls
        XCTAssertEqual(completed, [.status, .status, .register, .status])
    }

    func testWorkerSerializesConcurrentOperations() async {
        let backend = LoginItemTestBackend(
            status: .notRegistered,
            operationDelay: .milliseconds(20)
        )
        let worker = LoginItemWorker(backend: backend)

        async let status = worker.status()
        async let registration = worker.setEnabled(true)
        _ = await (status, registration)

        let maximum = await backend.maxConcurrentCalls
        XCTAssertEqual(maximum, 1)
    }

    func testStatusFailureKeepsControlDisabledAndReportsError() async {
        let backend = LoginItemTestBackend(
            status: .notRegistered,
            statusError: .operationFailed("status unavailable")
        )
        let manager = LoginItemManager(backend: backend)

        await manager.refresh()

        XCTAssertNil(manager.status)
        XCTAssertFalse(manager.canToggle)
        XCTAssertTrue(manager.canRetry)
        XCTAssertTrue(manager.errorMessage?.contains("status unavailable") == true)
    }

    func testRegistrationFailureRestoresIdleStateAndPreservesStatus() async {
        let backend = LoginItemTestBackend(
            status: .notRegistered,
            registerError: .operationFailed("registration denied")
        )
        let manager = LoginItemManager(backend: backend)
        await manager.refresh()

        manager.requestEnabled(true)
        await waitUntilIdle(manager)

        XCTAssertEqual(manager.status, .notRegistered)
        XCTAssertFalse(manager.isBusy)
        XCTAssertTrue(manager.errorMessage?.contains("registration denied") == true)
        let calls = await backend.calls
        XCTAssertEqual(calls, [.status, .status, .register])
    }

    func testRequiresApprovalCanBeUnregistered() async {
        let backend = LoginItemTestBackend(status: .requiresApproval)
        let manager = LoginItemManager(backend: backend)
        var mirrored: [Bool] = []
        manager.onSuccessfulUserInitiatedChange = { mirrored.append($0) }
        await manager.refresh()

        manager.requestEnabled(false)
        await waitUntilIdle(manager)

        XCTAssertEqual(manager.status, .notRegistered)
        XCTAssertFalse(manager.isOn)
        XCTAssertEqual(mirrored, [false])
        let calls = await backend.calls
        XCTAssertEqual(calls, [.status, .status, .unregister, .status])
    }

    func testFixtureBackendNeverUsesServiceManagement() async {
        let manager = LoginItemManager(backend: FixtureLoginItemBackend())
        await manager.refresh()

        manager.requestEnabled(true)
        await waitUntilIdle(manager)

        XCTAssertEqual(manager.status, .requiresApproval)
        XCTAssertTrue(manager.requiresApproval)
    }

    func testLiveManagerIsRetainedAcrossSettingsPanes() {
        XCTAssertTrue(LoginItemManager.live === LoginItemManager.live)
    }

    func testCachedStatusDoesNotShowProgressDuringRepeatedRefresh() async {
        let backend = LoginItemTestBackend(
            status: .enabled,
            operationDelay: .milliseconds(40)
        )
        let manager = LoginItemManager(backend: backend)
        await manager.refresh()
        XCTAssertEqual(manager.status, .enabled)

        let refresh = Task { await manager.refresh() }
        await waitUntilBusy(manager)

        XCTAssertFalse(manager.showsProgress)
        XCTAssertEqual(manager.status, .enabled)
        await refresh.value
    }

    func testLaunchPreferencePersistsWithoutServiceManagement() {
        let suite = "Prosody-Login-Item-Tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = ProsodyPreferences(defaults: defaults)
        preferences.launchAtLogin = true

        XCTAssertTrue(defaults.bool(forKey: "preferences.launchAtLogin"))
        XCTAssertTrue(ProsodyPreferences(defaults: defaults).launchAtLogin)
    }

    private func waitUntilIdle(
        _ manager: LoginItemManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if !manager.isBusy { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Login item operation did not finish", file: file, line: line)
    }

    private func waitUntilBusy(
        _ manager: LoginItemManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if manager.isBusy { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Login item operation did not start", file: file, line: line)
    }
}

private actor LoginItemTestBackend: LoginItemBackend {
    enum Call: Equatable, Sendable {
        case status
        case register
        case unregister
        case openLoginItems
    }

    private(set) var calls: [Call] = []
    private(set) var maxConcurrentCalls = 0
    private var activeCalls = 0
    private var currentStatus: LoginItemStatus
    private let operationDelay: Duration
    private let statusError: LoginItemManagerError?
    private let registerError: LoginItemManagerError?
    private let unregisterError: LoginItemManagerError?
    private let blocksRegister: Bool
    private var registerStarted = false
    private var registerStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var registerRelease: CheckedContinuation<Void, Never>?

    init(
        status: LoginItemStatus,
        operationDelay: Duration = .zero,
        statusError: LoginItemManagerError? = nil,
        registerError: LoginItemManagerError? = nil,
        unregisterError: LoginItemManagerError? = nil,
        blocksRegister: Bool = false
    ) {
        currentStatus = status
        self.operationDelay = operationDelay
        self.statusError = statusError
        self.registerError = registerError
        self.unregisterError = unregisterError
        self.blocksRegister = blocksRegister
    }

    func status() async throws -> LoginItemStatus {
        enter(.status)
        defer { leave() }
        await delayIfNeeded()
        if let statusError { throw statusError }
        return currentStatus
    }

    func register() async throws {
        enter(.register)
        defer { leave() }
        await delayIfNeeded()

        if blocksRegister {
            await withCheckedContinuation { continuation in
                registerRelease = continuation
                signalRegisterStarted()
            }
        } else {
            signalRegisterStarted()
        }

        if let registerError { throw registerError }
        if currentStatus == .notRegistered || currentStatus == .notFound {
            currentStatus = .requiresApproval
        }
    }

    func unregister() async throws {
        enter(.unregister)
        defer { leave() }
        await delayIfNeeded()
        if let unregisterError { throw unregisterError }
        currentStatus = .notRegistered
    }

    func openLoginItems() async {
        enter(.openLoginItems)
        defer { leave() }
        await delayIfNeeded()
    }

    func waitForRegisterStart() async {
        guard !registerStarted else { return }
        await withCheckedContinuation { registerStartWaiters.append($0) }
    }

    func releaseRegister() {
        let continuation = registerRelease
        registerRelease = nil
        continuation?.resume()
    }

    private func signalRegisterStarted() {
        registerStarted = true
        let waiters = registerStartWaiters
        registerStartWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func enter(_ call: Call) {
        calls.append(call)
        activeCalls += 1
        maxConcurrentCalls = max(maxConcurrentCalls, activeCalls)
    }

    private func leave() {
        activeCalls -= 1
    }

    private func delayIfNeeded() async {
        guard operationDelay != .zero else { return }
        try? await Task.sleep(for: operationDelay)
    }
}
#endif
