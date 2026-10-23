import Foundation
import Testing
@testable import DustBar

/// Collects values from @Sendable callbacks so a test can wait for a condition.
private final class Recorder<T: Sendable>: @unchecked Sendable {
    private let cond = NSCondition()
    private var values: [T] = []

    func add(_ v: T) {
        cond.lock()
        values.append(v)
        cond.broadcast()
        cond.unlock()
    }

    var all: [T] {
        cond.lock()
        defer { cond.unlock() }
        return values
    }

    /// Returns true once `pred` holds over the recorded values, false on timeout.
    func wait(timeout: TimeInterval, until pred: ([T]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        defer { cond.unlock() }
        while !pred(values) {
            if !cond.wait(until: deadline) { return pred(values) }
        }
        return true
    }
}

/// Fresh temp dir with symlinks resolved (FSEvents reports real paths, e.g. /private/var). Caller removes it.
private func makeTempDir() throws -> URL {
    let raw = FileManager.default.temporaryDirectory
        .appendingPathComponent("dustbar-monitor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    guard let real = realpath(raw.path, nil) else { return raw }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

@Test func currentStatsReportsRootVolume() {
    let s = Monitor.currentStats(path: "/")
    #expect(s.total > 0)
    #expect(s.free <= s.total)
}

@Test func startStopIdempotent() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let stats = Recorder<VolumeStats>()
    let m = Monitor(root: dir.path, onStats: { stats.add($0) }, onDirty: { _ in })

    m.start()
    m.start()
    // start() fires onStats once immediately.
    #expect(stats.wait(timeout: 10) { !$0.isEmpty })
    #expect((stats.all.first?.total ?? 0) > 0)

    m.stop()
    m.stop()
    m.start()
    m.stop()
}

@Test func fsEventsDeliversDirtyDirectory() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = dir.path
    let dirty = Recorder<Set<String>>()
    let m = Monitor(root: root, latency: 0.1, onStats: { _ in }, onDirty: { dirty.add($0) })

    m.start()
    defer { m.stop() }
    Thread.sleep(forTimeInterval: 0.5)  // let the stream settle before writing
    try Data("x".utf8).write(to: dir.appendingPathComponent("created.txt"))

    // FSEvents reports directories with a trailing slash.
    let delivered = dirty.wait(timeout: 10) { batches in
        batches.contains { $0.contains { $0.hasSuffix("/") ? String($0.dropLast()) == root : $0 == root } }
    }
    #expect(delivered)
}

/// Unresolved temp dir (NSTemporaryDirectory spelling, e.g. /var/folders/... which resolves to /private/var). Caller removes it.
private func makeRawTempDir() throws -> String {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("dustbar-monitor-raw-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

@Test func fsEventsReportsCallerSpellingOfRoot() throws {
    let root = try makeRawTempDir()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let dirty = Recorder<Set<String>>()
    let m = Monitor(root: root + "/", latency: 0.1, onStats: { _ in }, onDirty: { dirty.add($0) })

    m.start()
    defer { m.stop() }
    Thread.sleep(forTimeInterval: 0.5)
    try Data("x".utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent("created.txt"))

    // Trailing slash stripped, and resolved /private/var prefixes mapped back to the caller's root.
    let delivered = dirty.wait(timeout: 10) { batches in batches.flatMap { $0 }.contains(root) }
    #expect(delivered)
    #expect(!dirty.all.flatMap { $0 }.contains { $0.hasPrefix("/private/") })
}

@Test func fsEventsHonorsIgnorePrefixes() throws {
    let root = try makeRawTempDir()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(atPath: root + "/ignored", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: root + "/kept", withIntermediateDirectories: true)
    let dirty = Recorder<Set<String>>()
    let m = Monitor(root: root, latency: 0.1, ignorePrefixes: [root + "/ignored/"], onStats: { _ in }, onDirty: { dirty.add($0) })

    m.start()
    defer { m.stop() }
    Thread.sleep(forTimeInterval: 0.5)
    try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/ignored/a.txt"))
    Thread.sleep(forTimeInterval: 0.5)
    try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/kept/b.txt"))

    let delivered = dirty.wait(timeout: 10) { batches in batches.flatMap { $0 }.contains(root + "/kept") }
    #expect(delivered)
    #expect(!dirty.all.flatMap { $0 }.contains { $0 == root + "/ignored" || $0.hasPrefix(root + "/ignored/") })
}
