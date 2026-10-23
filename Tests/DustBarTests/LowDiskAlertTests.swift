import Foundation
import Testing
@testable import DustBar

@MainActor
private func makeAlert(_ threshold: AlertThreshold, fired: Box) -> LowDiskAlert {
    let defaults = UserDefaults(suiteName: "lowdisk-\(UUID().uuidString)")!
    let alert = LowDiskAlert(defaults: defaults, notify: { _ in fired.count += 1 })
    alert.setThreshold(threshold)
    return alert
}

private final class Box { var count = 0 }

@MainActor @Test func firesOnceWhenCrossingBelowAndNotRepeated() {
    let box = Box()
    let alert = makeAlert(.p10, fired: box)
    alert.evaluate(freeFraction: 0.50, free: 1)
    #expect(box.count == 0)
    alert.evaluate(freeFraction: 0.09, free: 1)
    alert.evaluate(freeFraction: 0.08, free: 1)
    alert.evaluate(freeFraction: 0.12, free: 1)   // inside the hysteresis band: still disarmed
    alert.evaluate(freeFraction: 0.09, free: 1)
    #expect(box.count == 1)
}

@MainActor @Test func rearmsAboveThresholdPlusFivePoints() {
    let box = Box()
    let alert = makeAlert(.p10, fired: box)
    alert.evaluate(freeFraction: 0.05, free: 1)
    alert.evaluate(freeFraction: 0.16, free: 1)   // > 0.15: re-arm
    alert.evaluate(freeFraction: 0.05, free: 1)
    #expect(box.count == 2)
}

@MainActor @Test func offNeverFires() {
    let box = Box()
    let alert = makeAlert(.off, fired: box)
    alert.evaluate(freeFraction: 0.0, free: 0)
    #expect(box.count == 0)
}
