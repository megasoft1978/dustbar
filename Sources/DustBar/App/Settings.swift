import Foundation
import Observation

/// Area the scanner covers. Exposed only; scanner wiring comes later.
enum ScanScope: String, CaseIterable, Sendable {
    case home, wholeDisk

    var title: String {
        switch self {
        case .home: return "Home folder"
        case .wholeDisk: return "Whole disk"
        }
    }
}

/// User preferences, persisted in UserDefaults. Main-actor only.
@MainActor
@Observable
final class Settings {
    static let minReminderBytes: Int64 = 1_000_000_000          // 1 GB
    static let maxReminderBytes: Int64 = 1_000_000_000_000      // 1 TB
    static let defaultReminderBytes: Int64 = 5_000_000_000      // 5 GB
    static let reminderIntervalRange = 1...90
    static let defaultReminderIntervalDays = 7

    /// Same key `LowDiskAlert` reads, so both stay in sync.
    private static let thresholdKey = "lowDiskAlertThreshold"

    private enum Key {
        static let scanScope = "scanScope"
        static let excludedFolders = "excludedFolders"
        static let reminderEnabled = "cleanupReminderEnabled"
        static let reminderMinBytes = "cleanupReminderMinBytes"
        static let reminderIntervalDays = "cleanupReminderIntervalDays"
    }

    private let defaults: UserDefaults
    private let home: String

    var lowDiskThreshold: AlertThreshold {
        didSet { defaults.set(lowDiskThreshold.rawValue, forKey: Self.thresholdKey) }
    }

    var scanScope: ScanScope {
        didSet { defaults.set(scanScope.rawValue, forKey: Key.scanScope) }
    }

    /// Canonical absolute paths, each accepted by `validate`. Changes persist immediately.
    private(set) var excludedFolders: [String] {
        didSet { defaults.set(excludedFolders, forKey: Key.excludedFolders) }
    }

    var reminderEnabled: Bool {
        didSet { defaults.set(reminderEnabled, forKey: Key.reminderEnabled) }
    }

    /// Clamped to `minReminderBytes...maxReminderBytes`.
    var reminderMinBytes: Int64 {
        didSet {
            let clamped = min(max(reminderMinBytes, Self.minReminderBytes), Self.maxReminderBytes)
            if clamped != reminderMinBytes { reminderMinBytes = clamped }
            defaults.set(reminderMinBytes, forKey: Key.reminderMinBytes)
        }
    }

    /// Clamped to `reminderIntervalRange`.
    var reminderIntervalDays: Int {
        didSet {
            let range = Self.reminderIntervalRange
            let clamped = min(max(reminderIntervalDays, range.lowerBound), range.upperBound)
            if clamped != reminderIntervalDays { reminderIntervalDays = clamped }
            defaults.set(reminderIntervalDays, forKey: Key.reminderIntervalDays)
        }
    }

    init(defaults: UserDefaults = .standard,
         home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        let canonicalHome = Self.canonical(home)
        self.defaults = defaults
        self.home = canonicalHome
        lowDiskThreshold = (defaults.object(forKey: Self.thresholdKey) as? Double)
            .flatMap(AlertThreshold.init(rawValue:)) ?? .p10
        scanScope = defaults.string(forKey: Key.scanScope).flatMap(ScanScope.init(rawValue:)) ?? .home
        let stored = defaults.stringArray(forKey: Key.excludedFolders) ?? []
        var folders: [String] = []
        for path in stored {
            if let valid = Self.validate(path, home: canonicalHome, isDirectory: Self.isDirectory),
               !folders.contains(valid) {
                folders.append(valid)
            }
        }
        excludedFolders = folders
        reminderEnabled = defaults.object(forKey: Key.reminderEnabled) as? Bool ?? true
        let minBytes = (defaults.object(forKey: Key.reminderMinBytes) as? NSNumber)?.int64Value
        reminderMinBytes = min(max(minBytes ?? Self.defaultReminderBytes, Self.minReminderBytes), Self.maxReminderBytes)
        let days = defaults.object(forKey: Key.reminderIntervalDays) as? Int ?? Self.defaultReminderIntervalDays
        reminderIntervalDays = min(max(days, Self.reminderIntervalRange.lowerBound), Self.reminderIntervalRange.upperBound)
    }

    /// Adds a folder to the exclusion list. Returns false when `path` is rejected by `validate`.
    @discardableResult
    func addExcludedFolder(_ path: String) -> Bool {
        guard let valid = Self.validate(path, home: home, isDirectory: Self.isDirectory) else { return false }
        if !excludedFolders.contains(valid) {
            excludedFolders.append(valid)
        }
        return true
    }

    func removeExcludedFolder(_ path: String) {
        excludedFolders.removeAll { $0 == path }
    }

    /// Canonical form of `path` if it may be excluded: an absolute path to an existing directory that is
    /// strictly inside `home` or inside `/Volumes`. Rejects `/`, `home` itself, and `/Volumes` itself.
    static func validate(_ path: String, home: String, isDirectory: (String) -> Bool) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let candidate = canonical(path)
        let canonicalHome = canonical(home)
        guard candidate != "/", candidate != canonicalHome else { return nil }
        let insideHome = candidate.hasPrefix(canonicalHome + "/")
        let insideVolumes = candidate.hasPrefix("/Volumes/")
        guard insideHome || insideVolumes, isDirectory(candidate) else { return nil }
        return candidate
    }

    /// Symlinks resolved and `.`/`..` removed, so checks compare real locations.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
