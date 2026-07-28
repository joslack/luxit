import ApplicationServices
import Foundation

private func expect(
    _ actual: CapsLockEventDisposition,
    _ expected: CapsLockEventDisposition,
    _ message: String
) {
    guard actual == expected else {
        fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

@main
private enum CapsLockEventLogicTests {
    static func main() {
        let caps = CapsLockEventClassifier.capsLockKeyCode
        let remappedCaps = CapsLockEventClassifier.remappedCapsLockKeyCode

        expect(
            CapsLockEventClassifier.classify(type: .flagsChanged, keyCode: caps),
            .toggleAndConsume,
            "Caps Lock flagsChanged toggles exactly once"
        )
        expect(
            CapsLockEventClassifier.classify(type: .keyDown, keyCode: caps),
            .consume,
            "Caps Lock keyDown is consumed without another toggle"
        )
        expect(
            CapsLockEventClassifier.classify(type: .keyUp, keyCode: caps),
            .consume,
            "Caps Lock keyUp is consumed without another toggle"
        )
        expect(
            CapsLockEventClassifier.classify(type: .keyDown, keyCode: 0),
            .passThrough,
            "ordinary keyDown passes through"
        )
        expect(
            CapsLockEventClassifier.classify(type: .flagsChanged, keyCode: 58),
            .passThrough,
            "other modifier changes pass through"
        )
        expect(
            CapsLockEventClassifier.classify(type: .keyDown, keyCode: remappedCaps),
            .toggleAndConsume,
            "remapped Caps Lock F19 keyDown toggles immediately"
        )
        expect(
            CapsLockEventClassifier.classify(type: .keyUp, keyCode: remappedCaps),
            .consume,
            "remapped Caps Lock F19 keyUp is consumed"
        )
        expect(
            CapsLockEventClassifier.classify(type: .flagsChanged, keyCode: remappedCaps),
            .consume,
            "remapped Caps Lock never toggles on modifier changes"
        )

        let rapidFireEvents: [CGEventType] = Array(
            repeating: .flagsChanged,
            count: 20
        )
        let rapidFireToggleCount = rapidFireEvents.reduce(into: 0) { count, type in
            if CapsLockEventClassifier.classify(type: type, keyCode: caps)
                == .toggleAndConsume {
                count += 1
            }
        }
        guard rapidFireToggleCount == rapidFireEvents.count else {
            fputs("FAIL: rapid-fire Caps Lock presses were dropped\n", stderr)
            exit(1)
        }

        let remappedRapidFireEvents: [CGEventType] = Array(
            repeating: .keyDown,
            count: 20
        )
        let remappedRapidFireToggleCount = remappedRapidFireEvents.reduce(into: 0) {
            count, type in
            if CapsLockEventClassifier.classify(type: type, keyCode: remappedCaps)
                == .toggleAndConsume {
                count += 1
            }
        }
        guard remappedRapidFireToggleCount == remappedRapidFireEvents.count else {
            fputs("FAIL: rapid-fire remapped Caps Lock presses were dropped\n", stderr)
            exit(1)
        }

        let longPressSequence: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let longPressToggleCount = longPressSequence.reduce(into: 0) { count, type in
            if CapsLockEventClassifier.classify(type: type, keyCode: caps)
                == .toggleAndConsume {
                count += 1
            }
        }
        guard longPressToggleCount == 1 else {
            fputs("FAIL: a long Caps Lock press toggled more than once\n", stderr)
            exit(1)
        }

        print("CapsLockEventLogicTests passed")
    }
}
