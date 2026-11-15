import Combine
import Foundation
import ServiceManagement

public enum LoginItemManagerError: Error, LocalizedError, Equatable, Sendable {
    case unavailable
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "\(AppConstants.applicationName) cannot manage its login item from this app bundle."
        case .operationFailed(let message):
            return "Could not manage \(AppConstants.applicationName)'s login item: \(message)"
        }
    }
}

public enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown

    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .unknown
        }
    }
}

protocol LoginItemBackend: Sendable {
    func status() async throws -> LoginItemStatus
    func register() async throws
    func unregister() async throws
    func openLoginItems() async
}

/// ServiceManagement calls can synchronously cross into system services. Keep
/// every read and mutation on this actor's executor, and serialize calls even
/// though actors are reentrant while awaiting a backend operation.
actor LoginItemWorker {
    private let backend: any LoginItemBackend
    private var tail: Task<Void, Never>?

    init(backend: any LoginItemBackend) {
        self.backend = backend
    }

    func status() async -> Result<LoginItemStatus, LoginItemManagerError> {
        let backend = self.backend
        return await enqueue {
            do { return .success(try await backend.status()) }
            catch { return .failure(Self.map(error)) }
        }
    }

    func setEnabled(_ enabled: Bool) async -> Result<LoginItemStatus, LoginItemManagerError> {
        let backend = self.backend
        return await enqueue {
            do {
                let current = try await backend.status()
                switch (enabled, current) {
                case (true, .enabled), (true, .requiresApproval):
                    break
                case (true, .notRegistered):
                    try await backend.register()
                case (true, .notFound):
                    // LaunchServices can report a stale not-found state after
                    // an app is moved into /Applications. Try the registration
                    // once and let the refreshed status decide the outcome.
                    try await backend.register()
                    let refreshed = try await backend.status()
                    guard refreshed != .notFound else {
                        throw LoginItemManagerError.unavailable
                    }
                    return .success(refreshed)
                case (true, .unknown):
                    throw LoginItemManagerError.unavailable
                case (false, .notRegistered):
                    break
                case (false, .enabled), (false, .requiresApproval):
                    try await backend.unregister()
                case (false, .notFound):
                    return .success(.notRegistered)
                case (false, .unknown):
                    throw LoginItemManagerError.unavailable
                }
                return .success(try await backend.status())
            } catch {
                return .failure(Self.map(error))
            }
        }
    }

    func openLoginItems() async {
        let backend = self.backend
        await enqueue { await backend.openLoginItems() }
    }

    private func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task.detached(priority: .userInitiated) {
            if let previous { await previous.value }
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private nonisolated static func map(_ error: Error) -> LoginItemManagerError {
        if let error = error as? LoginItemManagerError { return error }
        return .operationFailed(error.localizedDescription)
    }
}

/// Main-actor presentation state for the Settings login-item control. The
/// actual registration remains the source of truth: refreshing never changes
/// it, and a stable bundle identifier lets an existing enabled entry survive a
/// display-name rename. macOS caches login-item registrations by bundle ID;
/// keep that ID stable. A user-revoked or invalidated registration can only be
/// restored by the user approving it in System Settings.
@MainActor
public final class LoginItemManager: ObservableObject {
    /// One live manager is retained for the app lifetime. Creating it performs
    /// no IPC; status is read only by the explicit refresh entry points.
    public static let live = LoginItemManager()

    @Published public private(set) var status: LoginItemStatus?
    @Published public private(set) var isBusy = false
    @Published public private(set) var errorMessage: String?

    /// Set once by the Settings pane. The callback survives pane navigation so
    /// a completed user action can still update the compatibility cache.
    var onSuccessfulUserInitiatedChange: ((Bool) -> Void)?

    private let worker: LoginItemWorker

    public init() {
        worker = LoginItemWorker(backend: LiveLoginItemBackend())
    }

    init(backend: any LoginItemBackend) {
        worker = LoginItemWorker(backend: backend)
    }

    public var isOn: Bool {
        status == .enabled || status == .requiresApproval
    }

    public var requiresApproval: Bool {
        status == .requiresApproval
    }

    public var canToggle: Bool {
        !isBusy && status != nil && status != .unknown
    }

    public var shouldOfferOpenLoginItems: Bool {
        status == .requiresApproval || status == .notFound
    }

    public var canRetry: Bool {
        errorMessage != nil && !isBusy
    }

    public var showsProgress: Bool {
        isBusy && status == nil
    }

    public var statusDescription: String {
        let summary: String
        switch status {
        case nil:
            summary = isBusy ? "Checking login item status…" : "Login item status has not been checked."
        case .notRegistered:
            summary = "\(AppConstants.applicationName) does not open at login."
        case .enabled:
            summary = "\(AppConstants.applicationName) opens automatically when you sign in."
        case .requiresApproval:
            summary = "Registration is waiting for approval. Approve \(AppConstants.applicationName) in System Settings > General > Login Items."
        case .notFound:
            summary = "Turn this on to ask macOS to register \(AppConstants.applicationName) as a login item."
        case .unknown:
            summary = "Login item status is unavailable."
        }
        guard let errorMessage else { return summary }
        return "\(summary) \(errorMessage)"
    }

    /// Refresh only when the pane appears, the app becomes active, or the user
    /// explicitly retries. There is deliberately no polling loop.
    public func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        apply(await worker.status())
    }

    /// Called directly from the toggle. Marking the control busy before the
    /// task starts prevents a second click from queueing another mutation.
    public func requestEnabled(_ enabled: Bool) {
        guard canToggle else { return }
        isBusy = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            self.apply(await self.worker.setEnabled(enabled), requestedEnabled: enabled)
        }
    }

    public func openLoginItems() async {
        guard !isBusy else { return }
        isBusy = true
        await worker.openLoginItems()
        isBusy = false
    }

    private func apply(
        _ result: Result<LoginItemStatus, LoginItemManagerError>,
        requestedEnabled: Bool? = nil
    ) {
        isBusy = false
        switch result {
        case .success(let status):
            self.status = status
            errorMessage = nil
            if let requestedEnabled {
                if requestedEnabled, status == .enabled || status == .requiresApproval {
                    onSuccessfulUserInitiatedChange?(true)
                } else if !requestedEnabled, status == .notRegistered {
                    onSuccessfulUserInitiatedChange?(false)
                }
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

private struct LiveLoginItemBackend: LoginItemBackend {
    func status() async throws -> LoginItemStatus {
        LoginItemStatus(SMAppService.mainApp.status)
    }

    func register() async throws {
        try SMAppService.mainApp.register()
    }

    func unregister() async throws {
        try await SMAppService.mainApp.unregister()
    }

    func openLoginItems() async {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Demo and fixture surfaces use this in-memory backend so they can exercise
/// status and approval UI without touching the user's real login registration.
actor FixtureLoginItemBackend: LoginItemBackend {
    private var currentStatus: LoginItemStatus

    init(status: LoginItemStatus = .notRegistered) {
        currentStatus = status
    }

    func status() async throws -> LoginItemStatus {
        currentStatus
    }

    func register() async throws {
        switch currentStatus {
        case .notRegistered:
            currentStatus = .requiresApproval
        case .notFound, .unknown:
            throw LoginItemManagerError.unavailable
        case .enabled, .requiresApproval:
            break
        }
    }

    func unregister() async throws {
        switch currentStatus {
        case .notFound, .unknown:
            throw LoginItemManagerError.unavailable
        case .enabled, .requiresApproval:
            currentStatus = .notRegistered
        case .notRegistered:
            break
        }
    }

    func openLoginItems() async {}
}
