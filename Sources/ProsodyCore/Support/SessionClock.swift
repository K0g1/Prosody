import Foundation

public enum SessionClockError: Error, Equatable, Sendable {
    case alreadyRunning
    case notRunning
    case invalidTimestamp
}

/// A session timeline made up of one or more capture epochs.
///
/// `firstPTS` and all method arguments are presentation timestamps from the
/// same audio clock. They are deliberately not wall-clock dates: pauses and
/// device clock changes must not move transcript time backwards or forwards.
public struct SessionClock: Codable, Equatable, Sendable {
    public private(set) var epochs: [CaptureEpoch]
    public private(set) var accumulatedDuration: TimeInterval
    public private(set) var isRunning: Bool

    private var activeEpochID: UUID?

    public init() {
        self.epochs = []
        self.accumulatedDuration = 0
        self.isRunning = false
        self.activeEpochID = nil
    }

    public var currentEpochID: UUID? {
        activeEpochID
    }

    public var elapsed: TimeInterval {
        max(0, accumulatedDuration)
    }

    /// Returns the current duration without mutating the clock. This is used
    /// for live UI snapshots between pause/stop commits.
    public func elapsed(atPTS: TimeInterval?) -> TimeInterval {
        guard isRunning, let atPTS, Self.isValid(atPTS), let activeEpochID,
              let epoch = epochs.first(where: { $0.id == activeEpochID })
        else { return elapsed }
        return max(elapsed, epoch.sessionOffset + max(0, atPTS - epoch.firstPTS))
    }

    public mutating func start(firstPTS: TimeInterval) throws {
        guard Self.isValid(firstPTS) else { throw SessionClockError.invalidTimestamp }
        guard !isRunning, epochs.isEmpty else { throw SessionClockError.alreadyRunning }

        let epoch = CaptureEpoch(sessionOffset: 0, firstPTS: firstPTS)
        epochs = [epoch]
        activeEpochID = epoch.id
        accumulatedDuration = 0
        isRunning = true
    }

    public mutating func pause(atPTS: TimeInterval) throws -> TimeInterval {
        guard Self.isValid(atPTS) else { throw SessionClockError.invalidTimestamp }
        guard isRunning, let activeEpochID,
              let epoch = epochs.first(where: { $0.id == activeEpochID })
        else { throw SessionClockError.notRunning }

        let delta = max(0, atPTS - epoch.firstPTS)
        accumulatedDuration = max(accumulatedDuration, epoch.sessionOffset + delta)
        self.activeEpochID = nil
        isRunning = false
        return elapsed
    }

    public mutating func resume(firstPTS: TimeInterval) throws {
        guard Self.isValid(firstPTS) else { throw SessionClockError.invalidTimestamp }
        guard !isRunning, !epochs.isEmpty else {
            throw isRunning ? SessionClockError.alreadyRunning : SessionClockError.notRunning
        }

        let epoch = CaptureEpoch(sessionOffset: elapsed, firstPTS: firstPTS)
        epochs.append(epoch)
        activeEpochID = epoch.id
        isRunning = true
    }

    /// Stops the active epoch. Finishing while paused is valid and simply
    /// returns the already accumulated duration.
    @discardableResult
    public mutating func stop(atPTS: TimeInterval? = nil) throws -> TimeInterval {
        if isRunning {
            guard let atPTS else { throw SessionClockError.invalidTimestamp }
            return try pause(atPTS: atPTS)
        }
        return elapsed
    }

    public func time(forPTS pts: TimeInterval, epochID: UUID? = nil) -> TimeInterval {
        guard Self.isValid(pts) else { return elapsed }

        let selectedID = epochID ?? activeEpochID
        guard let selectedID,
              let epoch = epochs.first(where: { $0.id == selectedID })
        else { return elapsed }

        return max(0, epoch.sessionOffset + max(0, pts - epoch.firstPTS))
    }

    public func epoch(for id: UUID) -> CaptureEpoch? {
        epochs.first(where: { $0.id == id })
    }

    public mutating func reset() {
        epochs.removeAll(keepingCapacity: false)
        accumulatedDuration = 0
        isRunning = false
        activeEpochID = nil
    }

    private static func isValid(_ value: TimeInterval) -> Bool {
        value.isFinite && value >= 0
    }
}

/// Serialized access to a `SessionClock` for capture coordinators.
public actor SessionClockActor {
    private var clock: SessionClock

    public init(clock: SessionClock = SessionClock()) {
        self.clock = clock
    }

    public func start(firstPTS: TimeInterval) throws {
        try clock.start(firstPTS: firstPTS)
    }

    public func pause(atPTS: TimeInterval) throws -> TimeInterval {
        try clock.pause(atPTS: atPTS)
    }

    public func resume(firstPTS: TimeInterval) throws {
        try clock.resume(firstPTS: firstPTS)
    }

    public func stop(atPTS: TimeInterval? = nil) throws -> TimeInterval {
        try clock.stop(atPTS: atPTS)
    }

    public func time(forPTS pts: TimeInterval, epochID: UUID? = nil) -> TimeInterval {
        clock.time(forPTS: pts, epochID: epochID)
    }

    public func snapshot() -> SessionClock {
        clock
    }

    public func elapsed(atPTS: TimeInterval?) -> TimeInterval {
        clock.elapsed(atPTS: atPTS)
    }

    public func reset() {
        clock.reset()
    }
}
