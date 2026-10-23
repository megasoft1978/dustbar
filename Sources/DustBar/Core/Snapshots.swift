import Foundation

/// One Time Machine local snapshot. `date` is the stamp tmutil uses ("yyyy-MM-dd-HHmmss", local time) and is the only
/// text that ever reaches tmutil. `taken` is the same stamp parsed as a local Date.
public struct LocalSnapshot: Sendable, Equatable, Identifiable {
    public var id: String { date }
    public let date: String
    public let taken: Date

    /// Nil unless `date` is exactly the stamp shape with ASCII digits and names a real local time.
    public init?(date: String) {
        guard Snapshots.isValidDate(date), let taken = Snapshots.parse(date) else { return nil }
        self.date = date
        self.taken = taken
    }
}

// Time Machine local snapshots. Listing is read-only. Deleting is permanent and separate from Cleaner.trash.
public enum Snapshots {
    public typealias Runner = (String, [String]) -> (Int32, String)

    static let tmutil = "/usr/bin/tmutil"
    private static let prefix = "com.apple.TimeMachine."
    private static let suffix = ".local"
    private static let shape = Array("dddd-dd-dd-dddddd".utf8)

    /// Read-only: `tmutil listlocalsnapshots /`. Lines that are not a snapshot name are ignored. Oldest first.
    /// Returns [] when tmutil fails.
    public static func list(run: Runner = defaultRun) -> [LocalSnapshot] {
        let (status, out) = run(tmutil, ["listlocalsnapshots", "/"])
        guard status == 0 else { return [] }
        return out.split(whereSeparator: \.isNewline).compactMap { line -> LocalSnapshot? in
            var s = String(line).trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix(prefix) else { return nil }
            s.removeFirst(prefix.count)
            if s.hasSuffix(suffix) { s.removeLast(suffix.count) }
            return LocalSnapshot(date: s)
        }
        .sorted { $0.taken < $1.taken }
    }

    /// PERMANENT: runs `tmutil deletelocalsnapshots <date>`. Re-validates the date, and runs nothing for a bad one.
    /// True only when tmutil exits 0. The UI must confirm before calling this.
    public static func delete(_ s: LocalSnapshot, run: Runner = defaultRun) -> Bool {
        guard isValidDate(s.date) else { return false }
        return run(tmutil, ["deletelocalsnapshots", s.date]).0 == 0
    }

    /// Count plus oldest and newest. No size is estimated.
    public static func summary(_ snaps: [LocalSnapshot]) -> String {
        guard let oldest = snaps.min(by: { $0.taken < $1.taken }),
              let newest = snaps.max(by: { $0.taken < $1.taken }) else { return "No local snapshots" }
        let n = snaps.count
        return "\(n) local snapshot\(n == 1 ? "" : "s"), oldest \(display(oldest.taken)), newest \(display(newest.taken))"
    }

    /// Upper bound for one tmutil call; a hung process is terminated so callers never wait forever.
    static let runTimeout: TimeInterval = 60

    /// Production runner: argument array only, no shell. Stderr is discarded. Returns (-1, "") if the process
    /// cannot start or does not finish within `runTimeout`.
    public static func defaultRun(_ exe: String, _ args: [String]) -> (Int32, String) {
        run(exe, args, timeout: runTimeout)
    }

    private final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.withLock { data = d } }
        func get() -> Data { lock.withLock { data } }
    }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return (-1, "") }
        let captured = Captured()
        let drained = DispatchSemaphore(value: 0)
        let handle = out.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            captured.set(handle.readDataToEndOfFile())
            drained.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            return (-1, "")
        }
        _ = drained.wait(timeout: .now() + 5)
        return (p.terminationStatus, String(decoding: captured.get(), as: UTF8.self))
    }

    // MARK: - Validation and parsing

    /// Matches ^\d{4}-\d{2}-\d{2}-\d{6}$ with ASCII digits only. Byte-level so no regex engine sees the input.
    static func isValidDate(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard bytes.count == shape.count else { return false }
        let zero = UInt8(ascii: "0"), nine = UInt8(ascii: "9"), d = UInt8(ascii: "d")
        return zip(bytes, shape).allSatisfy { b, p in p == d ? (zero...nine).contains(b) : b == p }
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = format
        f.isLenient = false
        return f
    }

    /// Parses the stamp and requires the round trip to match, so impossible dates such as month 13 are rejected.
    static func parse(_ s: String) -> Date? {
        let f = formatter("yyyy-MM-dd-HHmmss")
        guard let d = f.date(from: s), f.string(from: d) == s else { return nil }
        return d
    }

    private static func display(_ d: Date) -> String {
        formatter("yyyy-MM-dd HH:mm").string(from: d)
    }
}
