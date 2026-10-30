import Foundation

/// Decides when to restart a guest that stops answering commands, such as
/// after the Mac sleeps. It arms once the guest answers after a start, so a VM
/// that never booted is left to limactl start's own timeout. If the guest
/// hangs again within restartWindow of a restart, or a restart fails, it gives
/// up until the next reset.
struct Watchdog {
    enum Action: Equatable {
        case none, restart, giveUp
    }

    var unresponsiveLimit: TimeInterval = 60
    var restartWindow: TimeInterval = 600

    private(set) var armed = false
    private(set) var gaveUp = false
    private var unresponsiveSince: Date?
    private var lastRestart: Date?

    /// Call when the user starts, restarts or resets the VM.
    mutating func reset() {
        self = Watchdog(unresponsiveLimit: unresponsiveLimit, restartWindow: restartWindow)
    }

    mutating func responsive() {
        armed = true
        unresponsiveSince = nil
    }

    mutating func unresponsive(at now: Date) -> Action {
        guard armed, !gaveUp else { return .none }
        let since = unresponsiveSince ?? now
        unresponsiveSince = since
        guard now.timeIntervalSince(since) >= unresponsiveLimit else { return .none }

        unresponsiveSince = nil
        if let last = lastRestart, now.timeIntervalSince(last) < restartWindow {
            gaveUp = true
            return .giveUp
        }
        lastRestart = now
        armed = false
        return .restart
    }

    mutating func restartFailed() {
        gaveUp = true
    }
}
