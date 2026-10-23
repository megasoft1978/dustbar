import Foundation

/// Pure helpers behind StatusController, kept free of AppKit so tests can drive them.
enum ShellLogic {
    /// Whole-disk scans start here (the Data volume holds every user-visible file; "/" would add the sealed system volume).
    static let wholeDiskRoot = "/System/Volumes/Data"
    /// Above this many normalized dirty paths a full rescan is cheaper than an incremental refresh.
    static let maxRefreshPaths = 5_000
    /// Categories that overlap the base ones; excluded from the cleanable total to avoid double counting.
    static let overlappingCategoryIDs: Set<String> = ["duplicates", "large"]

    static func scanRoot(scope: ScanScope, home: String) -> String {
        switch scope {
        case .home: return home
        case .wholeDisk: return wholeDiskRoot
        }
    }

    /// Identifies what a scan covered; a different signature means the tree on screen is stale for the current settings.
    static func signature(root: String, excluded: Set<String>) -> String {
        ([root] + excluded.sorted()).joined(separator: "\n")
    }

    /// Exclusions in the spelling the walk will see. Settings stores canonical paths (/Users/x/foo), but a whole-disk
    /// walk builds its paths under `wholeDisk` (/System/Volumes/Data/Users/x/foo), so those are re-rooted there.
    /// /Volumes entries and paths already under the root are kept as they are; any other root is passed through.
    static func excludedForScan(root: String, excluded: Set<String>, wholeDisk: String = wholeDiskRoot) -> Set<String> {
        guard root == wholeDisk else { return excluded }
        var out = Set<String>()
        for e in excluded where e.hasPrefix("/") {
            if e == "/Volumes" || e.hasPrefix("/Volumes/") || e == wholeDisk || e.hasPrefix(wholeDisk + "/") {
                out.insert(e)
            } else {
                out.insert(wholeDisk + e)
            }
        }
        return out
    }

    /// Sum of base categories (duplicates and large files overlap them).
    static func cleanableBytes(_ categories: [CleanCategory]) -> Int64 {
        let total = categories.filter { !overlappingCategoryIDs.contains($0.id) }
            .reduce(UInt64(0)) { $0 &+ $1.bytes }
        return Int64(clamping: total)
    }

    /// Dirty paths in the spelling of `root`: standardized, trailing slash stripped, `/private` aliases mapped,
    /// anything outside `root` dropped. Pure string work, no filesystem access.
    static func normalizeDirty(_ paths: Set<String>, root rawRoot: String) -> Set<String> {
        let root = standardize(rawRoot)
        func inside(_ p: String) -> Bool { root == "/" || p == root || p.hasPrefix(root + "/") }
        var out = Set<String>()
        for raw in paths where raw.hasPrefix("/") {
            let p = standardize(raw)
            var candidates = [p, "/private" + p]
            if p.hasPrefix("/private/") { candidates.append(String(p.dropFirst("/private".count))) }
            if let hit = candidates.first(where: inside) { out.insert(hit) }
        }
        return out
    }

    private static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.path
    }
}

/// Seam over `tmutil` so tests never touch real snapshots.
struct SnapshotOps: Sendable {
    var list: @Sendable () -> [LocalSnapshot]
    var delete: @Sendable (LocalSnapshot) -> Bool

    static let live = SnapshotOps(list: { Snapshots.list() }, delete: { Snapshots.delete($0) })
}

enum SnapshotFlow {
    struct Outcome: Sendable, Equatable {
        var deleted: Int
        var failed: Int
        var remaining: [LocalSnapshot]
        var message: String
        var aborted = false
    }

    static let changedMessage = "Snapshots changed since the count was shown. Review the list and try again."

    /// Deletes exactly the `confirmed` snapshots (the ones the UI showed), one by one, off the calling actor, then re-lists.
    static func deleteAll(ops: SnapshotOps, confirmed: [LocalSnapshot]) async -> Outcome {
        await Task.detached(priority: .utility) { deleteAllSync(ops: ops, confirmed: confirmed) }.value
    }

    /// Re-lists first and aborts, deleting nothing, when the live set differs from `confirmed`.
    static func deleteAllSync(ops: SnapshotOps, confirmed: [LocalSnapshot]) -> Outcome {
        let fresh = ops.list()
        guard Set(fresh.map(\.date)) == Set(confirmed.map(\.date)) else {
            return Outcome(deleted: 0, failed: 0, remaining: fresh, message: changedMessage, aborted: true)
        }
        var deleted = 0, failed = 0
        for s in confirmed { if ops.delete(s) { deleted += 1 } else { failed += 1 } }
        return Outcome(deleted: deleted, failed: failed, remaining: ops.list(), message: message(deleted: deleted, failed: failed))
    }

    static func message(deleted: Int, failed: Int) -> String {
        if deleted == 0 && failed == 0 { return "No local snapshots to delete" }
        if failed == 0 { return "Deleted \(deleted) snapshot\(deleted == 1 ? "" : "s")" }
        return "Deleted \(deleted), \(failed) failed"
    }

    /// (count, summary) as shown by the model; summary is nil when there are none.
    static func display(_ snaps: [LocalSnapshot]) -> (count: Int, summary: String?) {
        (snaps.count, snaps.isEmpty ? nil : Snapshots.summary(snaps))
    }
}
