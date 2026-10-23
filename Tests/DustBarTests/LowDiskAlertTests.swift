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

/// Stats for a 100-unit volume with `fraction` free.
private func stats(_ fraction: Double) -> VolumeStats {
    VolumeStats(total: 100, free: UInt64(fraction * 100), purgeable: 0)
}

@MainActor @Test func firesOnceWhenCrossingBelowAndNotRepeated() {
    let box = Box()
    let alert = makeAlert(.p10, fired: box)
    alert.evaluate(stats(0.50))
    #expect(box.count == 0)
    alert.evaluate(stats(0.09))
    alert.evaluate(stats(0.08))
    alert.evaluate(stats(0.12))   // inside the hysteresis band: still disarmed
    alert.evaluate(stats(0.09))
    #expect(box.count == 1)
}

@MainActor @Test func rearmsAboveThresholdPlusFivePoints() {
    let box = Box()
    let alert = makeAlert(.p10, fired: box)
    alert.evaluate(stats(0.05))
    alert.evaluate(stats(0.16))   // > 0.15: re-arm
    alert.evaluate(stats(0.05))
    #expect(box.count == 2)
}

@MainActor @Test func offNeverFires() {
    let box = Box()
    let alert = makeAlert(.off, fired: box)
    alert.evaluate(stats(0.0))
    #expect(box.count == 0)
}

@MainActor @Test func failedStatsReadNeverFires() {
    let box = Box()
    let alert = makeAlert(.p10, fired: box)
    alert.evaluate(VolumeStats())   // Monitor.currentStats() returns total == 0 when the read fails
    #expect(box.count == 0)
    alert.evaluate(stats(0.09))     // a real low reading still fires
    #expect(box.count == 1)
}
