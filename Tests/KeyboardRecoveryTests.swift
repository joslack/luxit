import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private final class Clock {
    private struct Work { let time: TimeInterval; let run: () -> Void }
    private var work: [Work] = []
    private var now: TimeInterval = 0

    func schedule(after delay: TimeInterval, run: @escaping () -> Void) {
        work.append(Work(time: now + delay, run: run))
    }

    func advance(to end: TimeInterval) {
        while let next = work.indices.min(by: { work[$0].time < work[$1].time }),
              work[next].time <= end {
            let item = work.remove(at: next)
            now = item.time
            item.run()
        }
        now = end
    }
}

@main
private enum KeyboardRecoveryTests {
    static func main() {
        hotSwapWithoutWake()
        dockBurst()
        wakeAndDockOverlap()
        boundedFailures()
        cancellationAndRestart()
        initialMappingFailure()
        newerEventDuringRecovery()
        deallocation()
        if CommandLine.arguments.contains("--monitor-smoke") { monitorSmoke() }
        print("KeyboardRecoveryTests passed (hot swap, dock bursts, late service, wake overlap, cancellation)")
    }

    private static func hotSwapWithoutWake() {
        let clock = Clock()
        var actions: [KeyboardRecovery.Action] = []
        // The first query can see the old keyboard. A newly created service
        // loses the map before the delayed check; recovery must continue.
        let results = [true, false, false, true]
        let recovery = KeyboardRecovery(schedule: clock.schedule, log: { _ in }) { action in
            actions.append(action)
            return results[min(actions.count - 1, results.count - 1)]
        }
        recovery.request(.devicesChanged)
        clock.advance(to: 0.34)
        expect(actions.isEmpty, "A dock callback must wait for its services to settle")
        clock.advance(to: 0.36)
        expect(actions == [.reapplyMapping], "A hot swap repairs the map without wake, panel rebuild, or tap teardown")
        clock.advance(to: 30)
        expect(actions == Array(repeating: .reapplyMapping, count: 4), "A successful early query must not skip late-service repair")
    }

    private static func dockBurst() {
        let clock = Clock()
        var attempts = 0
        let recovery = KeyboardRecovery(schedule: clock.schedule, log: { _ in }) { _ in
            attempts += 1
            return true
        }
        recovery.request(.devicesChanged) // old keyboard removed
        clock.advance(to: 0.1)
        recovery.request(.devicesChanged) // built-in keyboard becomes available
        clock.advance(to: 0.2)
        recovery.request(.devicesChanged) // another dock interface settles
        clock.advance(to: 0.54)
        expect(attempts == 0, "Superseded dock callbacks must not each launch recovery")
        clock.advance(to: 0.56)
        expect(attempts == 1, "The final event in a burst triggers one repair")
        clock.advance(to: 30)
        expect(attempts == 2, "A stable map gets one settling pass and no perpetual polling")
    }

    private static func wakeAndDockOverlap() {
        for reasons: [KeyboardRecovery.Reason] in [[.wake, .devicesChanged], [.devicesChanged, .wake]] {
            let clock = Clock()
            var actions: [KeyboardRecovery.Action] = []
            let recovery = KeyboardRecovery(schedule: clock.schedule, log: { _ in }) { action in
                actions.append(action)
                return true
            }
            reasons.forEach(recovery.request)
            clock.advance(to: 30)
            expect(actions == [.refreshAfterWake, .reapplyMapping], "Wake refresh and device settling survive either notification order")
        }
    }

    private static func boundedFailures() {
        let clock = Clock()
        var actions: [KeyboardRecovery.Action] = []
        var messages: [String] = []
        let recovery = KeyboardRecovery(schedule: clock.schedule, log: { messages.append($0) }) { action in
            actions.append(action)
            return false
        }
        recovery.request(.wake)
        clock.advance(to: 60)
        expect(actions == [.refreshAfterWake] + Array(repeating: .reapplyMapping, count: 4), "Unavailable devices or permissions get bounded retries and only one wake refresh")
        expect(messages.last?.contains("exhausted") == true, "Exhausted recovery is diagnosable")
        recovery.request(.devicesChanged)
        clock.advance(to: 120)
        expect(actions.count == 10, "A later keyboard connection can recover after exhausted retries")
    }

    private static func cancellationAndRestart() {
        let clock = Clock()
        var actions: [KeyboardRecovery.Action] = []
        let recovery = KeyboardRecovery(schedule: clock.schedule, log: { _ in }) { action in
            actions.append(action)
            return true
        }
        recovery.request(.wake)
        recovery.cancel()
        clock.advance(to: 20)
        expect(actions.isEmpty, "Quitting must not remap keyboards after the original mapping is restored")
        recovery.request(.devicesChanged)
        clock.advance(to: 20.4)
        expect(actions == [.reapplyMapping], "A restart clears stale wake work")
        recovery.cancel()
        clock.advance(to: 40)
        expect(actions.count == 1, "Quitting also cancels a pending settling pass")
    }

    private static func initialMappingFailure() {
        let clock = Clock()
        var attempts = 0
        let recovery = KeyboardRecovery(schedule: clock.schedule, log: { _ in }) { action in
            expect(action == .reapplyMapping, "An initial remap retry keeps an already-running event tap")
            attempts += 1
            return attempts == 2
        }
        recovery.request(.mappingUnavailable)
        clock.advance(to: 30)
        expect(attempts == 2, "An initial failure stops retrying once both mapping and shortcut are ready")
    }

    private static func newerEventDuringRecovery() {
        let clock = Clock()
        var actions: [KeyboardRecovery.Action] = []
        var recovery: KeyboardRecovery!
        recovery = KeyboardRecovery(schedule: clock.schedule, log: { _ in }) { action in
            actions.append(action)
            if actions.count == 1 { recovery.request(.wake) }
            return true
        }
        recovery.request(.devicesChanged)
        clock.advance(to: 30)
        expect(actions == [.reapplyMapping, .refreshAfterWake, .reapplyMapping], "An event arriving inside a recovery supersedes its stale continuation")
        recovery = nil
    }

    private static func deallocation() {
        let clock = Clock()
        var attempts = 0
        var recovery: KeyboardRecovery? = KeyboardRecovery(schedule: clock.schedule, log: { _ in }) { _ in
            attempts += 1
            return false
        }
        recovery?.request(.devicesChanged)
        recovery = nil
        clock.advance(to: 30)
        expect(attempts == 0, "Queued work does not retain the recovery owner")
    }

    /// Opt-in hardware smoke check: enumerate keyboard services without opening
    /// devices, reading keystrokes, remapping anything, or launching Luxit.
    private static func monitorSmoke() {
        let monitor = KeyboardDeviceMonitor()
        var changes = 0
        monitor.onChange = { changes += 1 }
        monitor.start()
        monitor.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        expect(changes > 0, "The native observer enumerates this Mac's keyboard services")
        monitor.stop()
        let stoppedCount = changes
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        expect(changes == stoppedCount, "Stopping the monitor removes pending callbacks")
        monitor.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        expect(changes > stoppedCount, "The native monitor can restart cleanly")
        monitor.stop()
        print("Keyboard device observer smoke check passed")
    }
}
