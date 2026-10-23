import Foundation
import UserNotifications

/// Periodic "space can be reclaimed" notification. Only tells the user; never deletes anything.
@MainActor
final class CleanupReminder {
    static let lastNotifiedKey = "cleanupReminderLastNotified"
    private static let requestID = "dustbar.cleanup-reminder"

    /// Test seam: receives the body and returns whether it was accepted.
    typealias Sink = (_ body: String) -> Bool

    private let settings: Settings
    private let defaults: UserDefaults
    private let clock: () -> Date
    private let sink: Sink?   // test seam: replaces the system notification
    private let presenter = NotificationPresenter()

    init(settings: Settings,
         defaults: UserDefaults = .standard,
         clock: @escaping () -> Date = { Date() },
         sink: Sink? = nil) {
        self.settings = settings
        self.defaults = defaults
        self.clock = clock
        self.sink = sink
    }

    /// True when enabled, `cleanableBytes` meets the minimum, and at least `reminderIntervalDays` have
    /// passed since `lastNotified` (or it was never set).
    static func shouldNotify(now: Date, lastNotified: Date?, cleanableBytes: Int64, settings: Settings) -> Bool {
        guard settings.reminderEnabled, cleanableBytes >= settings.reminderMinBytes else { return false }
        guard let lastNotified else { return true }
        let interval = TimeInterval(settings.reminderIntervalDays) * 86_400
        return now.timeIntervalSince(lastNotified) >= interval
    }

    static func message(cleanableBytes: Int64) -> String {
        let size = ByteCountFormatter.string(fromByteCount: cleanableBytes, countStyle: .decimal)
        return "\(size) can be cleaned — open DustBar to review. Nothing is deleted automatically."
    }

    /// Posts the reminder if `shouldNotify` allows it. `lastNotified` is recorded only once the notification is
    /// accepted, so a denied or failed request doesn't burn the interval. Returns true when the reminder was
    /// accepted by the sink, or handed to the system (where acceptance is checked asynchronously).
    @discardableResult
    func notify(cleanableBytes: Int64) -> Bool {
        let now = clock()
        let lastNotified = defaults.object(forKey: Self.lastNotifiedKey) as? Date
        guard Self.shouldNotify(now: now, lastNotified: lastNotified,
                                cleanableBytes: cleanableBytes, settings: settings) else { return false }
        let body = Self.message(cleanableBytes: cleanableBytes)
        if let sink {
            guard sink(body) else { return false }
            defaults.set(now, forKey: Self.lastNotifiedKey)
            return true
        }
        Task {
            guard await post(body) else { return }
            defaults.set(now, forKey: Self.lastNotifiedKey)
        }
        return true
    }

    /// Returns true when the system accepted the request.
    private func post(_ body: String) async -> Bool {
        // UNUserNotificationCenter traps without a bundle identifier (e.g. `swift run`).
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let center = UNUserNotificationCenter.current()
        center.delegate = presenter
        let content = UNMutableNotificationContent()
        content.title = "DustBar"
        content.body = body
        let request = UNNotificationRequest(identifier: Self.requestID, content: content, trigger: nil)
        // Authorization is requested lazily, on the first reminder.
        let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
        guard granted else { return false }
        return (try? await center.add(request)) != nil
    }
}
