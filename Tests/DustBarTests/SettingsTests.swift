import Foundation
import Testing
@testable import DustBar

private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "settings-\(UUID().uuidString)")!
}

/// Temp layout: `<base>/home/Projects/Cache` (inside home) and `<base>/outside` (not inside home).
private struct Fixture {
    let base: URL
    var home: String { base.appendingPathComponent("home").path }
    var cache: String { base.appendingPathComponent("home/Projects/Cache").path }
    var outside: String { base.appendingPathComponent("outside").path }

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)   // our own temp directory only
    }
}

@MainActor @Test func defaultsWhenNothingStored() {
    let settings = Settings(defaults: makeDefaults(), home: "/Users/test")
    #expect(settings.lowDiskThreshold == .p10)
    #expect(settings.scanScope == .home)
    #expect(settings.excludedFolders.isEmpty)
    #expect(settings.reminderEnabled)
    #expect(settings.reminderMinBytes == 5_000_000_000)
    #expect(settings.reminderIntervalDays == 7)
}

@MainActor @Test func thresholdUsesSameKeyAsLowDiskAlert() {
    let defaults = makeDefaults()
    let settings = Settings(defaults: defaults, home: "/Users/test")
    settings.lowDiskThreshold = .p5
    #expect(defaults.object(forKey: "lowDiskAlertThreshold") as? Double == 0.05)
    #expect(Settings(defaults: defaults, home: "/Users/test").lowDiskThreshold == .p5)
}

@MainActor @Test func scalarSettingsRoundTrip() {
    let defaults = makeDefaults()
    let settings = Settings(defaults: defaults, home: "/Users/test")
    settings.scanScope = .wholeDisk
    settings.reminderEnabled = false
    settings.reminderMinBytes = 20_000_000_000
    settings.reminderIntervalDays = 30
    let reloaded = Settings(defaults: defaults, home: "/Users/test")
    #expect(reloaded.scanScope == .wholeDisk)
    #expect(!reloaded.reminderEnabled)
    #expect(reloaded.reminderMinBytes == 20_000_000_000)
    #expect(reloaded.reminderIntervalDays == 30)
}

@MainActor @Test func reminderValuesAreClamped() {
    let settings = Settings(defaults: makeDefaults(), home: "/Users/test")
    settings.reminderIntervalDays = 0
    #expect(settings.reminderIntervalDays == 1)
    settings.reminderIntervalDays = 10_000
    #expect(settings.reminderIntervalDays == 90)
    settings.reminderMinBytes = 1
    #expect(settings.reminderMinBytes == Settings.minReminderBytes)
    settings.reminderMinBytes = Int64.max
    #expect(settings.reminderMinBytes == Settings.maxReminderBytes)
}

@MainActor @Test func storedOutOfRangeValuesAreClampedOnLoad() {
    let defaults = makeDefaults()
    defaults.set(0, forKey: "cleanupReminderIntervalDays")
    defaults.set(Int64(10), forKey: "cleanupReminderMinBytes")
    let settings = Settings(defaults: defaults, home: "/Users/test")
    #expect(settings.reminderIntervalDays == 1)
    #expect(settings.reminderMinBytes == Settings.minReminderBytes)
}

@MainActor @Test func validateRejectsRootHomeRelativeAndOutsidePaths() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    #expect(Settings.validate("/", home: fixture.home, isDirectory: exists) == nil)
    #expect(Settings.validate(fixture.home, home: fixture.home, isDirectory: exists) == nil)
    #expect(Settings.validate("relative/Cache", home: fixture.home, isDirectory: exists) == nil)
    #expect(Settings.validate(fixture.outside, home: fixture.home, isDirectory: exists) == nil)
    #expect(Settings.validate("/Volumes", home: fixture.home, isDirectory: { _ in true }) == nil)
    #expect(Settings.validate("/Applications/Foo", home: fixture.home, isDirectory: { _ in true }) == nil)
}

@MainActor @Test func validateRejectsMissingPathsAndAcceptsInsideHomeAndVolumes() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let missing = fixture.home + "/Missing"
    #expect(Settings.validate(missing, home: fixture.home, isDirectory: { FileManager.default.fileExists(atPath: $0) }) == nil)
    #expect(Settings.validate(fixture.cache, home: fixture.home, isDirectory: { FileManager.default.fileExists(atPath: $0) }) == Settings.canonical(fixture.cache))
    #expect(Settings.validate("/Volumes/Backup/Old", home: fixture.home, isDirectory: { _ in true }) == "/Volumes/Backup/Old")
}

@MainActor @Test func addAndRemoveExcludedFolderPersistsAndDeduplicates() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let defaults = makeDefaults()
    let settings = Settings(defaults: defaults, home: fixture.home)

    #expect(settings.addExcludedFolder(fixture.cache))
    #expect(settings.addExcludedFolder(fixture.cache))
    #expect(settings.excludedFolders == [Settings.canonical(fixture.cache)])
    #expect(!settings.addExcludedFolder(fixture.outside))
    #expect(!settings.addExcludedFolder(fixture.home))
    #expect(settings.excludedFolders.count == 1)

    let reloaded = Settings(defaults: defaults, home: fixture.home)
    #expect(reloaded.excludedFolders == [Settings.canonical(fixture.cache)])

    settings.removeExcludedFolder(Settings.canonical(fixture.cache))
    #expect(settings.excludedFolders.isEmpty)
    #expect(Settings(defaults: defaults, home: fixture.home).excludedFolders.isEmpty)
}

@MainActor @Test func loadDropsStoredPathsThatNoLongerValidate() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let defaults = makeDefaults()
    defaults.set([fixture.cache, fixture.outside, fixture.home + "/Gone", "/"], forKey: "excludedFolders")
    let settings = Settings(defaults: defaults, home: fixture.home)
    #expect(settings.excludedFolders == [Settings.canonical(fixture.cache)])
}
