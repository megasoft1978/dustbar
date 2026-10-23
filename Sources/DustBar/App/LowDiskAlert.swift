import AppKit
import Foundation
import UserNotifications

/// Free-space level below which a low-disk notification fires. `off` disables alerts.
enum AlertThreshold: Double, CaseIterable, Sendable {
    case off = 0
    case p5 = 0.05
    case p10 = 0.10
    case p15 = 0.15

    var title: String {
        switch self {
        case .off: return "Off"
        case .p5: return "5%"
        case .p10: return "10%"
        case .p15: return "15%"
        }
    }
}

/// Shows notifications while the app is frontmost too (menu bar apps are usually never frontmost).
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

/// Fires once when free space drops below the threshold; re-arms after free space recovers above threshold + 5 points.
@MainActor
final class LowDiskAlert {
    private static let defaultsKey = "lowDiskAlertThreshold"
    private static let rearmMargin = 0.05
    private static let requestID = "dustbar.lowdisk"

    private(set) var threshold: AlertThreshold
    private var armed = true
    private let defaults: UserDefaults
    private let presenter = NotificationPresenter()
    private let onNotify: ((UInt64) -> Void)?   // test seam: replaces the system notification

    init(defaults: UserDefaults = .standard, notify: ((UInt64) -> Void)? = nil) {
        self.defaults = defaults
        self.onNotify = notify
        let raw = defaults.object(forKey: Self.defaultsKey) as? Double
        threshold = raw.flatMap(AlertThreshold.init(rawValue:)) ?? .p10
    }

    func setThreshold(_ value: AlertThreshold) {
        threshold = value
        defaults.set(value.rawValue, forKey: Self.defaultsKey)
        armed = true   // a new level is evaluated from scratch on the next stats update
    }

    /// Called on every stats update (no timer; the Monitor drives it).
    func evaluate(freeFraction: Double, free: UInt64) {
        guard threshold != .off else { return }
        let limit = threshold.rawValue
        if armed, freeFraction < limit {
            armed = false
            notify(free: free)
        } else if !armed, freeFraction > limit + Self.rearmMargin {
            armed = true
        }
    }

    private func notify(free: UInt64) {
        if let onNotify { onNotify(free); return }
        // UNUserNotificationCenter traps without a bundle identifier (e.g. `swift run`).
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = presenter
        let content = UNMutableNotificationContent()
        content.title = "Disk almost full"
        content.body = "\(ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .decimal)) free. Open DustBar to clean up."
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.requestID, content: content, trigger: nil)
        Task {
            // Authorization is requested lazily, on the first crossing; the system prompts only once.
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            try? await center.add(request)
        }
    }
}
