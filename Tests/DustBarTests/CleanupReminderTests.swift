import Foundation
import Testing
@testable import DustBar

private let gb: Int64 = 1_000_000_000
private let day: TimeInterval = 86_400
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
private func makeSettings(enabled: Bool = true, minBytes: Int64 = 5 * gb, days: Int = 7) -> Settings {
    let settings = Settings(defaults: UserDefaults(suiteName: "reminder-\(UUID().uuidString)")!, home: "/Users/test")
    settings.reminderEnabled = enabled
    settings.reminderMinBytes = minBytes
    settings.reminderIntervalDays = days
    return settings
}

private final class Sent: @unchecked Sendable {
    var bodies: [String] = []
    var accept = true
}

@MainActor
private func makeReminder(clock: @escaping () -> Date, settings: Settings, defaults: UserDefaults, sent: Sent) -> CleanupReminder {
    CleanupReminder(settings: settings, defaults: defaults, clock: clock, sink: { body in
        sent.bodies.append(body)
        return sent.accept
    })
}

@MainActor @Test func shouldNotifyRespectsEnabledFlag() {
    let settings = makeSettings(enabled: false)
    #expect(!CleanupReminder.shouldNotify(now: t0, lastNotified: nil, cleanableBytes: 50 * gb, settings: settings))
}

@MainActor @Test func shouldNotifyRespectsMinimumBytes() {
    let settings = makeSettings(minBytes: 5 * gb)
    #expect(!CleanupReminder.shouldNotify(now: t0, lastNotified: nil, cleanableBytes: 5 * gb - 1, settings: settings))
    #expect(CleanupReminder.shouldNotify(now: t0, lastNotified: nil, cleanableBytes: 5 * gb, settings: settings))
}

@MainActor @Test func shouldNotifyFirstTimeWhenNeverNotified() {
    let settings = makeSettings()
    #expect(CleanupReminder.shouldNotify(now: t0, lastNotified: nil, cleanableBytes: 6 * gb, settings: settings))
}

@MainActor @Test func shouldNotifyWaitsForFullInterval() {
    let settings = makeSettings(days: 7)
    let last = t0
    #expect(!CleanupReminder.shouldNotify(now: last.addingTimeInterval(7 * day - 1), lastNotified: last,
                                          cleanableBytes: 6 * gb, settings: settings))
    #expect(CleanupReminder.shouldNotify(now: last.addingTimeInterval(7 * day), lastNotified: last,
                                         cleanableBytes: 6 * gb, settings: settings))
}

@MainActor @Test func notifyNeverFiresTwiceWithinInterval() {
    let defaults = UserDefaults(suiteName: "reminder-\(UUID().uuidString)")!
    let sent = Sent()
    var now = t0
    let reminder = makeReminder(clock: { now }, settings: makeSettings(days: 3), defaults: defaults, sent: sent)

    #expect(reminder.notify(cleanableBytes: 8 * gb))
    now = t0.addingTimeInterval(day)
    #expect(!reminder.notify(cleanableBytes: 8 * gb))
    now = t0.addingTimeInterval(2 * day)
    #expect(!reminder.notify(cleanableBytes: 8 * gb))
    now = t0.addingTimeInterval(3 * day)
    #expect(reminder.notify(cleanableBytes: 8 * gb))
    #expect(sent.bodies.count == 2)
}

@MainActor @Test func lastNotifiedPersistsAcrossInstances() {
    let defaults = UserDefaults(suiteName: "reminder-\(UUID().uuidString)")!
    let settings = makeSettings()
    let sent = Sent()
    #expect(makeReminder(clock: { t0 }, settings: settings, defaults: defaults, sent: sent).notify(cleanableBytes: 6 * gb))
    #expect(defaults.object(forKey: CleanupReminder.lastNotifiedKey) as? Date == t0)
    #expect(!makeReminder(clock: { t0 }, settings: settings, defaults: defaults, sent: sent).notify(cleanableBytes: 6 * gb))
    #expect(sent.bodies.count == 1)
}

@MainActor @Test func notifyBelowMinimumOrDisabledSendsNothing() {
    let defaults = UserDefaults(suiteName: "reminder-\(UUID().uuidString)")!
    let sent = Sent()
    #expect(!makeReminder(clock: { t0 }, settings: makeSettings(minBytes: 5 * gb), defaults: defaults, sent: sent)
        .notify(cleanableBytes: gb))
    #expect(!makeReminder(clock: { t0 }, settings: makeSettings(enabled: false), defaults: defaults, sent: sent)
        .notify(cleanableBytes: 50 * gb))
    #expect(sent.bodies.isEmpty)
    #expect(defaults.object(forKey: CleanupReminder.lastNotifiedKey) == nil)
}

@MainActor @Test func rejectedNotificationDoesNotBurnTheInterval() {
    let defaults = UserDefaults(suiteName: "reminder-\(UUID().uuidString)")!
    let sent = Sent()
    sent.accept = false
    let reminder = makeReminder(clock: { t0 }, settings: makeSettings(), defaults: defaults, sent: sent)
    #expect(!reminder.notify(cleanableBytes: 6 * gb))
    #expect(defaults.object(forKey: CleanupReminder.lastNotifiedKey) == nil)

    sent.accept = true
    #expect(reminder.notify(cleanableBytes: 6 * gb))
    #expect(defaults.object(forKey: CleanupReminder.lastNotifiedKey) as? Date == t0)
    #expect(sent.bodies.count == 2)
}

@MainActor @Test func messageStatesSizeAndNeverAutoDeletes() {
    let body = CleanupReminder.message(cleanableBytes: 12 * gb)
    #expect(body.hasPrefix("12 GB can be cleaned"))
    #expect(body.contains("open DustBar to review"))
    #expect(body.hasSuffix("Nothing is deleted automatically."))
}
