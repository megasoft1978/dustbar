import Foundation
import Synchronization
import Testing
@testable import DustBar

/// phys_footprint (what Activity Monitor reports); excludes pages libmalloc marked reusable.
private func residentBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

/// Env-gated benchmark: DUSTBAR_SCAN_BENCH=<path> swift test --filter scanBench
@Test(.enabled(if: ProcessInfo.processInfo.environment["DUSTBAR_SCAN_BENCH"] != nil))
func scanBench() async {
    let root = ProcessInfo.processInfo.environment["DUSTBAR_SCAN_BENCH"]!
    let prune = ProcessInfo.processInfo.environment["DUSTBAR_PRUNE_BELOW"].flatMap { UInt64($0) }
    let snaps = Mutex<[UInt64]>([])
    let prog = Mutex<ScanProgress>(ScanProgress())
    let base = residentBytes() >> 20
    let start = ContinuousClock.now
    let sampler = Task.detached {
        var peak: UInt64 = 0
        while !Task.isCancelled { peak = max(peak, residentBytes()); try? await Task.sleep(for: .milliseconds(50)) }
        return peak
    }
    var tree = await Scanner.scanLive(root: root, snapshotInterval: 1.0, pruneBelow: prune,
        onSnapshot: { t in snaps.withLock { $0.append(t.size[0]) } },
        progress: { p in prog.withLock { $0 = p } })
    let elapsed = ContinuousClock.now - start
    sampler.cancel()
    let before = residentBytes() >> 20
    malloc_zone_pressure_relief(nil, 0)
    print("BENCH relief \(before)MB -> \(residentBytes() >> 20)MB")
    let peak = await sampler.value
    let s = snaps.withLock { $0 }
    let nodes = tree?.count ?? -1
    tree = nil
    malloc_zone_pressure_relief(nil, 0)
    var ms = malloc_statistics_t()
    malloc_zone_statistics(nil, &ms)
    print("BENCH mallocInUse=\(ms.size_in_use >> 20)MB allocated=\(ms.size_allocated >> 20)MB blocks=\(ms.blocks_in_use)")
    print("BENCH afterRelease=\(residentBytes() >> 20)MB")
    if ProcessInfo.processInfo.environment["DUSTBAR_BENCH_HOLD"] != nil { try? await Task.sleep(for: .seconds(25)) }
    print("BENCH elapsed=\(elapsed) snapshots=\(s.count) rootSizes=\(s.prefix(12).map { $0 >> 20 })MB... final=\((s.last ?? 0) >> 20) files=\(prog.withLock { $0.files }) nodes=\(nodes) baseRSS=\(base)MB peakRSS=\(peak >> 20)MB endRSS=\(residentBytes() >> 20)MB")
}

/// Env-gated: DUSTBAR_REFRESH_BENCH=1 (or a path; default ~/Library) swift test --filter refreshBench
/// Full scan vs refresh of 20 random existing directories; prints times and the largest size mismatch.
@Test(.enabled(if: ProcessInfo.processInfo.environment["DUSTBAR_REFRESH_BENCH"] != nil))
func refreshBench() async throws {
    let env = ProcessInfo.processInfo.environment["DUSTBAR_REFRESH_BENCH"]!
    let root = env.hasPrefix("/") ? env : NSHomeDirectory() + "/Library"
    let t0 = ContinuousClock.now
    let tree = try #require(await Scanner.scanCancellable(root: root, progress: { _ in }))
    let full = ContinuousClock.now - t0

    // Random kept directories, each below 1% of the total so the refresh stays incremental.
    var pool = (1..<tree.count).filter { tree.isDir[$0] && tree.size[$0] > 0 && tree.size[$0] < tree.size[0] / 100 }
    var dirty = Set<String>()
    while dirty.count < 20, !pool.isEmpty {
        dirty.insert(tree.path(of: NodeID(pool.remove(at: Int.random(in: 0..<pool.count)))))
    }
    let t1 = ContinuousClock.now
    let refreshed = await Scanner.refresh(tree: tree, dirtyPaths: dirty)
    let incr = ContinuousClock.now - t1

    var maxDiff: UInt64 = 0
    var compared = 0
    if let refreshed {
        func index(_ t: DiskTree) -> [String: UInt64] {
            var m: [String: UInt64] = [:]
            for i in 0..<t.count where t.isDir[i] { m[t.path(of: NodeID(i))] = t.size[i] }
            return m
        }
        let a = index(tree), b = index(refreshed)
        for (p, s) in a { if let r = b[p] { compared += 1; maxDiff = max(maxDiff, s > r ? s - r : r - s) } }
    }
    print("REFRESH root=\(root) full=\(full) refresh=\(incr) dirty=\(dirty.count) result=\(refreshed == nil ? "nil" : "tree") dirsCompared=\(compared) maxSizeMismatch=\(maxDiff)B")
    #expect(refreshed != nil)
    #expect(maxDiff == 0)
}
