import Foundation

/// Main-run-loop recovery. Dock changes often arrive as a burst, and a HID
/// device can be visible before its keyboard event service is ready to remap.
final class KeyboardRecovery {
    enum Reason: Equatable { case wake, devicesChanged, mappingUnavailable }
    enum Action: Equatable { case refreshAfterWake, reapplyMapping }
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    private let schedule: Schedule
    private let recover: (Action) -> Bool
    private let log: (String) -> Void
    private let delays: [TimeInterval] = [0.35, 0.75, 1.5, 3.0, 6.0]
    private var generation = 0
    private var needsWakeRefresh = false
    private var needsDeviceSettle = false

    init(
        schedule: @escaping Schedule = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        log: @escaping (String) -> Void,
        recover: @escaping (Action) -> Bool
    ) {
        self.schedule = schedule
        self.log = log
        self.recover = recover
    }

    func request(_ reason: Reason) {
        generation += 1
        // A device callback must not cancel a still-pending wake refresh.
        needsWakeRefresh = needsWakeRefresh || reason == .wake
        needsDeviceSettle = needsDeviceSettle || reason == .devicesChanged
        log("Keyboard recovery scheduled reason=\(reason)")
        run(generation: generation, attempt: 0)
    }

    func cancel() {
        generation += 1
        needsWakeRefresh = false
        needsDeviceSettle = false
    }

    private func run(generation: Int, attempt: Int) {
        schedule(delays[attempt]) { [weak self] in
            guard let self, generation == self.generation else { return }
            let action: Action = self.needsWakeRefresh ? .refreshAfterWake : .reapplyMapping
            self.needsWakeRefresh = false
            let needsFollowUp = self.needsDeviceSettle && attempt == 0
            let ready = self.recover(action)
            guard generation == self.generation else { return }
            if !needsFollowUp { self.needsDeviceSettle = false }
            if ready && !needsFollowUp {
                self.log("Keyboard recovery succeeded attempt=\(attempt + 1)")
            } else if attempt + 1 < self.delays.count {
                self.run(generation: generation, attempt: attempt + 1)
            } else {
                self.log("Keyboard recovery exhausted; Quartz fallback remains active")
            }
        }
    }
}
