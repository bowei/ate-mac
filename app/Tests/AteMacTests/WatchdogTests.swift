import Foundation
import Testing

@testable import AteMac

private let t0 = Date(timeIntervalSinceReferenceDate: 0)

private func at(_ seconds: TimeInterval) -> Date {
    t0.addingTimeInterval(seconds)
}

/// An armed watchdog that has just restarted the guest at time 60 and seen it
/// answer again.
private func restartedWatchdog() -> Watchdog {
    var w = Watchdog()
    w.responsive()
    #expect(w.unresponsive(at: at(0)) == .none)
    #expect(w.unresponsive(at: at(60)) == .restart)
    w.responsive()
    return w
}

struct WatchdogTests {
    @Test func unarmedNeverRestarts() {
        // A VM that never booted is left to limactl start's timeout.
        var w = Watchdog()
        for s in stride(from: 0.0, through: 3600, by: 5) {
            #expect(w.unresponsive(at: at(s)) == .none)
        }
        #expect(!w.armed)
    }

    @Test(arguments: [
        (59.0, Watchdog.Action.none),
        (60.0, Watchdog.Action.restart),
        (61.0, Watchdog.Action.restart),
    ])
    func restartsAfterLimit(elapsed: TimeInterval, want: Watchdog.Action) {
        var w = Watchdog()
        w.responsive()
        #expect(w.unresponsive(at: at(0)) == .none)
        #expect(w.unresponsive(at: at(elapsed)) == want)
    }

    @Test func responsiveResetsTheClock() {
        var w = Watchdog()
        w.responsive()
        #expect(w.unresponsive(at: at(0)) == .none)
        #expect(w.unresponsive(at: at(50)) == .none)
        w.responsive()
        #expect(w.unresponsive(at: at(55)) == .none)
        #expect(w.unresponsive(at: at(105)) == .none)
        #expect(w.unresponsive(at: at(115)) == .restart)
    }

    @Test func restartDisarmsUntilTheGuestAnswers() {
        var w = Watchdog()
        w.responsive()
        _ = w.unresponsive(at: at(0))
        #expect(w.unresponsive(at: at(60)) == .restart)
        #expect(!w.armed)
        // Still booting after the restart: no second restart.
        #expect(w.unresponsive(at: at(3600)) == .none)
    }

    @Test func givesUpOnASecondHangWithinTheWindow() {
        var w = restartedWatchdog()
        #expect(w.unresponsive(at: at(100)) == .none)
        #expect(w.unresponsive(at: at(160)) == .giveUp)
        #expect(w.gaveUp)
        w.responsive()
        #expect(w.unresponsive(at: at(1000)) == .none)
        #expect(w.unresponsive(at: at(2000)) == .none)
    }

    @Test func restartsAgainAfterTheWindow() {
        var w = restartedWatchdog()
        #expect(w.unresponsive(at: at(700)) == .none)
        #expect(w.unresponsive(at: at(760)) == .restart)
    }

    @Test func givesUpWhenARestartFails() {
        var w = restartedWatchdog()
        w.restartFailed()
        #expect(w.gaveUp)
        #expect(w.unresponsive(at: at(5000)) == .none)
    }

    @Test func resetStartsFresh() {
        var w = restartedWatchdog()
        _ = w.unresponsive(at: at(100))
        #expect(w.unresponsive(at: at(160)) == .giveUp)

        w.reset()
        #expect(!w.armed)
        #expect(!w.gaveUp)
        #expect(w.unresponsive(at: at(200)) == .none)
        // Once armed again, the earlier restart doesn't count against it.
        w.responsive()
        #expect(w.unresponsive(at: at(200)) == .none)
        #expect(w.unresponsive(at: at(260)) == .restart)
    }
}
