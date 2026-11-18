import Foundation

/// One request's temporary ownership of the shared dictation model. The owner
/// must finish or cancel its session, reset the model, and then return the
/// lease. Keeping this explicit prevents an idle eviction from racing a native
/// Core ML operation.
struct DictationModelLease<Model: Sendable>: Sendable {
    let model: Model
    let id: UUID
}

/// Owns the one local Parakeet manager used by dictation and its archive
/// replay path. The load task is deliberately independent of every waiter so
/// cancelling one request cannot cancel the shared, uninterruptible Core ML
/// preparation. All waiter registration, cancellation, and resolution happens
/// on this actor.
actor DictationModelCache<Model: Sendable> {
    private struct Flight {
        let id: UUID
        let task: Task<Model, Error>
    }

    private struct Waiter {
        let flightID: UUID
        let continuation: CheckedContinuation<Model, Error>
    }

    private let idleRetention: Duration
    private let load: @Sendable () async throws -> Model
    private let unload: @Sendable (Model) async -> Void

    private var cachedModel: Model?
    private var flight: Flight?
    private var waiters: [UUID: Waiter] = [:]
    private var pendingAcquisitions: Set<UUID> = []
    private var activeLeases: Set<UUID> = []
    private var pinnedScopes: Set<UUID> = []
    private var releaseWhenIdle = false
    private var eviction: (token: UUID, task: Task<Void, Never>)?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupID: UUID?
    private var preparationObservers: [UUID: AsyncStream<Bool>.Continuation] = [:]

    init(
        idleRetention: Duration,
        load: @escaping @Sendable () async throws -> Model,
        unload: @escaping @Sendable (Model) async -> Void
    ) {
        self.idleRetention = idleRetention
        self.load = load
        self.unload = unload
    }

    deinit {
        eviction?.task.cancel()
        // An observer must not remain suspended after its owning recognizer
        // has gone away.
        for continuation in preparationObservers.values {
            continuation.finish()
        }
    }

    /// Starts preparation without a waiter. This is intentionally fire-and-
    /// forget: callers that need a result use acquire or waitUntilPrepared.
    func prewarm() {
        guard cachedModel == nil else { return }
        releaseWhenIdle = false
        cancelEviction()
        if flight == nil { _ = startFlight() }
    }

    /// Observes the actual shared preparation flight. A late observer gets the
    /// current state immediately, followed by transitions for later flights.
    /// This is state observation, so only the newest buffered value is useful.
    func modelPreparationUpdates() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Bool.self, bufferingPolicy: .bufferingNewest(1)
        )
        let observerID = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removePreparationObserver(observerID) }
        }
        preparationObservers[observerID] = continuation
        continuation.yield(flight != nil)
        return stream
    }

    /// Waits for the shared load but does not retain a model use beyond the
    /// wait. It is useful to benchmarks and deterministic readiness tests.
    func waitUntilPrepared() async throws {
        let lease = try await acquire(onPreparing: {})
        endUse(lease.id)
    }

    func beginScope(_ scope: UUID) {
        pinnedScopes.insert(scope)
        releaseWhenIdle = false
        cancelEviction()
    }

    func endScope(_ scope: UUID) {
        guard pinnedScopes.remove(scope) != nil else { return }
        guard pinnedScopes.isEmpty else { return }
        maybeReleaseWhenIdle()
    }

    /// Returns a lease only after the shared model is ready. The callback is
    /// invoked only when this request actually has to wait for weights.
    func acquire(
        onPreparing: @Sendable () -> Void = {}
    ) async throws -> DictationModelLease<Model> {
        try Task.checkCancellation()
        releaseWhenIdle = false
        cancelEviction()

        if let cachedModel {
            let leaseID = UUID()
            activeLeases.insert(leaseID)
            return DictationModelLease(model: cachedModel, id: leaseID)
        }

        let flightID = startFlight()
        onPreparing()

        let waiterID = UUID()
        pendingAcquisitions.insert(waiterID)
        do {
            let model = try await wait(waiterID: waiterID, flightID: flightID)
            try Task.checkCancellation()
            pendingAcquisitions.remove(waiterID)
            let leaseID = UUID()
            activeLeases.insert(leaseID)
            return DictationModelLease(model: model, id: leaseID)
        } catch {
            // This also covers cancellation before registration, cancellation
            // after resolution, and a flight failure. The continuation may
            // already have removed the waiter; this cleanup is idempotent.
            cancelWaiter(waiterID)
            throw error
        }
    }

    /// Marks the cache for release. Active leases and pending requests defer
    /// the actual cleanup until their operations have completed.
    func releaseIfIdle() {
        releaseWhenIdle = true
        cancelEviction()
        guard pinnedScopes.isEmpty, activeLeases.isEmpty,
              pendingAcquisitions.isEmpty, waiters.isEmpty else { return }

        if flight != nil { return }
        if let model = cachedModel {
            beginCleanup(model)
        }
    }

    /// Used during model replacement, after the controller has drained every
    /// dictation. Wait for a launch prewarm and its cleanup before deleting files.
    func releaseAndWaitIfIdle() async {
        releaseIfIdle()
        if let flight {
            let result = await flight.task.result
            resolveFlight(id: flight.id, result: result)
        }
        await cleanupTask?.value
    }

    /// Drops a model after its owner could not reset it. No other native work
    /// can be using this lease because the recognizer serializes recognition.
    func invalidate(_ leaseID: UUID) {
        guard activeLeases.remove(leaseID) != nil else { return }
        releaseWhenIdle = false
        cancelEviction()
        if let model = cachedModel {
            beginCleanup(model)
        }
    }

    func endUse(_ leaseID: UUID) {
        guard activeLeases.remove(leaseID) != nil else { return }
        guard pinnedScopes.isEmpty, activeLeases.isEmpty,
              pendingAcquisitions.isEmpty, waiters.isEmpty else { return }
        if releaseWhenIdle || idleRetention <= .zero {
            if let model = cachedModel { beginCleanup(model) }
        } else {
            scheduleEviction()
        }
    }

    private func startFlight() -> UUID {
        if let flight { return flight.id }
        let id = UUID()
        let load = self.load
        let predecessorCleanup = cleanupTask
        let task = Task<Model, Error>(priority: .userInitiated) {
            // Native model cleanup is also memory-heavy. A new load waits for
            // the previous manager to disappear, but this wait lives inside the
            // shared flight so it never blocks any request's cancellation.
            if let predecessorCleanup { await predecessorCleanup.value }
            return try await load()
        }
        flight = Flight(id: id, task: task)
        publishPreparationState(true)
        Task { [weak self] in
            let result = await task.result
            await self?.resolveFlight(id: id, result: result)
        }
        return id
    }

    private func wait(waiterID: UUID, flightID: UUID) async throws -> Model {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard let flight, flight.id == flightID else {
                    continuation.resume(throwing: STTError.modelNotLoaded)
                    return
                }
                waiters[waiterID] = Waiter(flightID: flightID, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        pendingAcquisitions.remove(waiterID)
        if let waiter = waiters.removeValue(forKey: waiterID) {
            waiter.continuation.resume(throwing: CancellationError())
        }
        maybeReleaseWhenIdle()
    }

    private func resolveFlight(id: UUID, result: Result<Model, Error>) {
        guard let flight, flight.id == id else { return }
        self.flight = nil
        publishPreparationState(false)

        switch result {
        case .success(let model):
            let resolved = waiters.filter { $0.value.flightID == id }
            let discard = releaseWhenIdle && pinnedScopes.isEmpty
                && resolved.isEmpty && pendingAcquisitions.isEmpty
            if discard {
                beginCleanup(model)
            } else {
                cachedModel = model
                for (waiterID, waiter) in resolved {
                    waiters.removeValue(forKey: waiterID)
                    waiter.continuation.resume(returning: model)
                }
                maybeScheduleEviction()
            }
        case .failure(let error):
            for (waiterID, waiter) in waiters where waiter.flightID == id {
                waiters.removeValue(forKey: waiterID)
                pendingAcquisitions.remove(waiterID)
                waiter.continuation.resume(throwing: error)
            }
            maybeReleaseWhenIdle()
        }
    }

    private func maybeReleaseWhenIdle() {
        guard pinnedScopes.isEmpty, activeLeases.isEmpty,
              pendingAcquisitions.isEmpty, waiters.isEmpty else { return }
        if releaseWhenIdle {
            if flight == nil, let model = cachedModel {
                beginCleanup(model)
            }
        } else {
            maybeScheduleEviction()
        }
    }

    private func maybeScheduleEviction() {
        guard pinnedScopes.isEmpty, cachedModel != nil, flight == nil, activeLeases.isEmpty,
              pendingAcquisitions.isEmpty, waiters.isEmpty else { return }
        if releaseWhenIdle || idleRetention <= .zero {
            if let model = cachedModel { beginCleanup(model) }
        } else {
            scheduleEviction()
        }
    }

    private func scheduleEviction() {
        cancelEviction()
        guard idleRetention > .zero else {
            if let model = cachedModel { beginCleanup(model) }
            return
        }
        let token = UUID()
        let task = Task { [weak self, idleRetention] in
            do { try await Task.sleep(for: idleRetention) } catch { return }
            await self?.expire(token)
        }
        eviction = (token, task)
    }

    private func expire(_ token: UUID) {
        guard eviction?.token == token else { return }
        eviction = nil
        guard pinnedScopes.isEmpty, activeLeases.isEmpty,
              pendingAcquisitions.isEmpty, waiters.isEmpty,
              flight == nil, let model = cachedModel else { return }
        beginCleanup(model)
    }

    private func cancelEviction() {
        eviction?.task.cancel()
        eviction = nil
    }

    private func removePreparationObserver(_ id: UUID) {
        preparationObservers.removeValue(forKey: id)
    }

    private func publishPreparationState(_ isPreparing: Bool) {
        guard !preparationObservers.isEmpty else { return }
        for continuation in preparationObservers.values {
            continuation.yield(isPreparing)
        }
    }

    private func beginCleanup(_ model: Model) {
        cachedModel = nil
        cancelEviction()
        let id = UUID()
        cleanupID = id
        let task = Task { [unload] in await unload(model) }
        cleanupTask = task
        Task { [weak self] in
            await task.value
            await self?.finishCleanup(id)
        }
    }

    private func finishCleanup(_ id: UUID) {
        guard cleanupID == id else { return }
        cleanupTask = nil
        cleanupID = nil
    }
}
