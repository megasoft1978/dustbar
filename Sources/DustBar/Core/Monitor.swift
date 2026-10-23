import Foundation
import CoreServices

// Slice B owns this file.

/// Strips trailing "/" (keeps "/" itself).
private func trimSlash(_ p: String) -> String {
    var s = p
    while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
    return s
}

/// True when `p` equals `prefix` or lies beneath it. Both already trimmed.
private func isUnder(_ p: String, _ prefix: String) -> Bool {
    p == prefix || p.hasPrefix(prefix == "/" ? "/" : prefix + "/")
}

/// Maps `p` from `from` to `to` when it lies under `from`. Both already trimmed.
private func rebase(_ p: String, from: String, to: String) -> String? {
    guard isUnder(p, from) else { return nil }
    if p == from { return to }
    let rest = p.dropFirst(from == "/" ? 1 : from.count + 1)
    return (to == "/" ? "" : to) + "/" + rest
}

/// Symlink-resolved spelling of `path` (FSEvents reports resolved paths, e.g. /private/var).
private func resolvedPath(_ path: String) -> String {
    guard let real = realpath(path, nil) else { return trimSlash(path) }
    defer { free(real) }
    return String(cString: real)
}

/// Owned by the FSEvents stream context (retained until the stream is released).
/// Maps resolved FSEvents paths back to the caller's spelling of the root and drops ignored prefixes.
private final class DirtyRelay: Sendable {
    let onDirty: @Sendable (Set<String>) -> Void
    let realRoot: String
    let displayRoot: String
    let ignore: [String]

    init(onDirty: @escaping @Sendable (Set<String>) -> Void, realRoot: String, displayRoot: String, ignore: [String]) {
        self.onDirty = onDirty
        self.realRoot = realRoot
        self.displayRoot = displayRoot
        self.ignore = ignore
    }

    func emit(_ raw: [String]) {
        let paths = raw.map { p -> String in
            let t = trimSlash(p)
            return rebase(t, from: realRoot, to: displayRoot) ?? t
        }.filter { p in !ignore.contains { isUnder(p, $0) } }
        if !paths.isEmpty { onDirty(Set(paths)) }
    }
}

public final class Monitor: @unchecked Sendable {
    private let root: String           // caller spelling, trailing "/" stripped
    private let realRoot: String       // symlink-resolved; what FSEvents watches and reports
    private let latency: CFTimeInterval
    private let ignore: [String]       // caller spelling; events under these are dropped
    private let onStats: @Sendable (VolumeStats) -> Void
    private let onDirty: @Sendable (Set<String>) -> Void
    private let queue = DispatchQueue(label: "dustbar.monitor", qos: .utility)
    private let lock = NSLock()
    // Guarded by `lock`. Both are nil when stopped.
    private var timer: DispatchSourceTimer?
    private var stream: FSEventStreamRef?

    /// onStats: every 60 s. onDirty: batched changed directory paths from FSEvents (30 s latency).
    /// ignorePrefixes: paths equal to or under these (caller spelling) are never reported.
    public convenience init(root: String, ignorePrefixes: [String] = [], onStats: @escaping @Sendable (VolumeStats) -> Void, onDirty: @escaping @Sendable (Set<String>) -> Void) {
        self.init(root: root, latency: 30, ignorePrefixes: ignorePrefixes, onStats: onStats, onDirty: onDirty)
    }

    /// Internal so tests can shorten the FSEvents latency.
    init(root: String, latency: CFTimeInterval, ignorePrefixes: [String] = [], onStats: @escaping @Sendable (VolumeStats) -> Void, onDirty: @escaping @Sendable (Set<String>) -> Void) {
        self.root = trimSlash(root)
        self.realRoot = resolvedPath(root)
        self.latency = latency
        self.ignore = ignorePrefixes.map(trimSlash)
        self.onStats = onStats
        self.onDirty = onDirty
    }

    deinit { stop() }

    /// Idempotent. Fires onStats immediately, then every 60 s (10 s leeway), and watches `root` for changes.
    /// If the FSEvents stream cannot start, the stats timer still runs and `root` is reported dirty once.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }

        let relay = DirtyRelay(onDirty: onDirty, realRoot: realRoot, displayRoot: root, ignore: ignore)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(relay).toOpaque(),
            retain: nil,
            release: { info in
                if let info { Unmanaged<DirtyRelay>.fromOpaque(info).release() }
            },
            copyDescription: nil
        )
        if let s = FSEventStreamCreate(
            nil,
            { _, info, _, paths, _, _ in
                guard let info else { return }
                let relay = Unmanaged<DirtyRelay>.fromOpaque(info).takeUnretainedValue()
                let dirs = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray)
                    .compactMap { $0 as? String }
                if !dirs.isEmpty { relay.emit(dirs) }
            },
            &context,
            [realRoot] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) {
            FSEventStreamSetDispatchQueue(s, queue)
            if FSEventStreamStart(s) {
                stream = s
            } else {
                // Release callback drops the relay once the stream is released.
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
                reportWatchFailure()
            }
        } else {
            // Stream never took ownership, so balance the passRetained above.
            Unmanaged<DirtyRelay>.fromOpaque(context.info!).release()
            reportWatchFailure()
        }

        let onStats = self.onStats
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .seconds(60), leeway: .seconds(10))
        t.setEventHandler { onStats(Monitor.currentStats()) }
        t.resume()
        timer = t
    }

    /// Idempotent. Cancels the timer and tears down the FSEvents stream.
    public func stop() {
        lock.lock()
        let t = timer
        let s = stream
        timer = nil
        stream = nil
        lock.unlock()

        t?.cancel()
        if let s {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    /// Caller must hold `lock`. Tells the consumer the whole root may have changed.
    private func reportWatchFailure() {
        let onDirty = self.onDirty
        let root = self.root
        queue.async { onDirty([root]) }
    }

    public static func currentStats(path: String = "/") -> VolumeStats {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity,
              let available = v.volumeAvailableCapacity,
              let important = v.volumeAvailableCapacityForImportantUsage else {
            return VolumeStats()
        }
        let t = UInt64(max(0, total))
        let free = min(UInt64(max(0, important)), t)
        let avail = min(UInt64(max(0, available)), t)
        return VolumeStats(total: t, free: free, purgeable: free > avail ? free - avail : 0)
    }
}
