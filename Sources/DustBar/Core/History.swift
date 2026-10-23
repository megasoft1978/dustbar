import Foundation

/// Size snapshots taken after each completed scan, so the Growth view can show what grew since an earlier scan.
/// Stored as JSON (atomic write). A missing, oversized or corrupt file reads as empty history; nothing traps.
public enum History {
    public struct Record: Codable, Equatable, Sendable {
        public let date: Date
        public let root: String
        public let rootBytes: UInt64
        public let dirs: [String: UInt64]      // path -> allocated bytes, directories up to `maxDepth`
    }

    public struct GrowthRow: Identifiable, Equatable, Sendable {
        public var id: String { path }
        public let path: String
        public let bytes: UInt64               // size now
        public let deltaBytes: UInt64          // growth since `baseline`
        public let baseline: Date
    }

    private struct File: Codable {
        var version: Int
        var records: [Record]
    }

    static let fileVersion = 1
    static let maxRecords = 8
    static let maxDirs = 200
    static let maxDepth = 3
    static let maxFileBytes = 200_000
    static let minBaselineAge: TimeInterval = 24 * 60 * 60
    static let minDeltaBytes: UInt64 = 1_000_000
    public static let minRecordGap: TimeInterval = 6 * 60 * 60   // keeps `maxRecords` slots spanning days, not hours

    public static var defaultURL: URL {
        #if DUSTBAR_DEMO
        if let demoURL { return demoURL }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.megasoft78.dustbar/history.json")
    }

    #if DUSTBAR_DEMO
    /// Demo builds read and write history here instead of the real cache folder.
    nonisolated(unsafe) static var demoURL: URL?
    #endif

    /// Appends a snapshot of `tree` and keeps the newest `maxRecords`. Returns false when nothing was written,
    /// including when the newest record for the same root is less than `minGap` old.
    @discardableResult
    public static func record(tree: DiskTree, date: Date = .now, to url: URL = defaultURL,
                              minGap: TimeInterval = minRecordGap) -> Bool {
        guard tree.count > 0 else { return false }
        let existing = records(at: url)
        if let newest = existing.filter({ $0.root == tree.rootPath }).map(\.date).max(),
           date.timeIntervalSince(newest) < minGap {
            return false
        }
        var kept = Array((existing + [snapshot(tree, date: date)]).suffix(maxRecords))
        var data = encode(kept)
        while data.count > maxFileBytes {
            if kept.count > 1 {
                kept.removeFirst()
            } else if let first = kept.first, first.dirs.count > 1 {
                let half = first.dirs.sorted { $0.value > $1.value }.prefix(first.dirs.count / 2)
                kept[0] = Record(date: first.date, root: first.root, rootBytes: first.rootBytes,
                                 dirs: Dictionary(uniqueKeysWithValues: half.map { ($0.key, $0.value) }))
            } else {
                return false
            }
            data = encode(kept)
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Growth of `current` against one baseline record of the same root, largest growth first.
    /// The baseline is the oldest record at least 24 h old, or the oldest record when none is that old;
    /// `since` limits the candidates to records dated on or after it. Empty when there is no baseline.
    /// Directories missing from the baseline are skipped: their growth since then is unknown, not their whole size.
    public static func growth(current: DiskTree, since: Date? = nil, limit: Int = 20,
                              from url: URL = defaultURL) -> [GrowthRow] {
        let now = Date()
        let pool = records(at: url).filter {
            $0.root == current.rootPath && $0.date <= now && $0.date >= (since ?? .distantPast)
        }
        let aged = pool.filter { now.timeIntervalSince($0.date) >= minBaselineAge }
        guard let base = (aged.isEmpty ? pool : aged).min(by: { $0.date < $1.date }) else { return [] }
        let rows = dirSizes(current).compactMap { path, bytes -> GrowthRow? in
            guard let old = base.dirs[path] else { return nil }
            let delta = bytes > old ? bytes - old : 0
            guard delta >= minDeltaBytes else { return nil }
            return GrowthRow(path: path, bytes: bytes, deltaBytes: delta, baseline: base.date)
        }
        return Array(rows.sorted { $0.deltaBytes != $1.deltaBytes ? $0.deltaBytes > $1.deltaBytes : $0.path < $1.path }
            .prefix(max(0, limit)))
    }

    /// Stored records, oldest first. Empty for a missing, oversized, unreadable or foreign file.
    static func records(at url: URL) -> [Record] {
        guard let data = try? Data(contentsOf: url), data.count <= maxFileBytes,
              let file = try? JSONDecoder().decode(File.self, from: data), file.version == fileVersion else { return [] }
        return Array(file.records.suffix(maxRecords))
    }

    static func snapshot(_ tree: DiskTree, date: Date) -> Record {
        Record(date: date, root: tree.rootPath, rootBytes: tree.size[0], dirs: dirSizes(tree))
    }

    /// The largest directories (up to `maxDepth` below the root), capped at `maxDirs`, keyed by path.
    static func dirSizes(_ tree: DiskTree) -> [String: UInt64] {
        var found: [(id: NodeID, bytes: UInt64)] = []
        var level: [NodeID] = [0]
        for _ in 0..<maxDepth {
            var next: [NodeID] = []
            for parent in level {
                for c in tree.children(of: parent) where tree.isDir[Int(c)] && tree.size[Int(c)] > 0 {
                    next.append(c)
                    found.append((c, tree.size[Int(c)]))
                }
            }
            level = next
        }
        let top = found.sorted { $0.bytes > $1.bytes }.prefix(maxDirs)
        return Dictionary(top.map { (tree.path(of: $0.id), $0.bytes) }, uniquingKeysWith: { a, _ in a })
    }

    private static func encode(_ records: [Record]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(File(version: fileVersion, records: records))) ?? Data()
    }
}
