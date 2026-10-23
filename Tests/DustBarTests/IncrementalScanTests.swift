import Foundation
import Testing
@testable import DustBar

private let mb = 1_048_576
private var fm: FileManager { .default }

private func makeFile(_ path: String, bytes: Int) {
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    _ = fm.createFile(atPath: path, contents: Data(count: bytes))
}

private func makeTempRoot() throws -> String {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("dustbar-incr-\(UUID().uuidString)")
    try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

/// Every node as relative path -> size, so two trees compare regardless of sibling order.
private func sizes(_ tree: DiskTree) -> [String: UInt64] {
    var out: [String: UInt64] = [:]
    func walk(_ id: NodeID, _ prefix: String) {
        for c in tree.children(of: id) {
            let p = prefix + "/" + tree.name(c)
            out[p] = tree.size[Int(c)]
            walk(c, p)
        }
    }
    out["/"] = tree.size[0]
    walk(0, "")
    return out
}

private func fixture() throws -> String {
    let root = try makeTempRoot()
    makeFile(root + "/a/x.bin", bytes: 2 * mb)
    makeFile(root + "/a/sub/y.bin", bytes: 1_500_000)
    makeFile(root + "/a/tiny.txt", bytes: 100)
    makeFile(root + "/b/z.bin", bytes: 2 * mb)
    makeFile(root + "/c/w.bin", bytes: 2 * mb)
    makeFile(root + "/d/v.bin", bytes: 2 * mb)
    for i in 0..<16 { makeFile(root + "/ballast/f\(i).bin", bytes: 5 * mb) }
    return root
}

@Test func refreshEqualsFullRescanAfterChanges() async throws {
    let root = try fixture()
    defer { try? fm.removeItem(atPath: root) }
    let old = try #require(await Scanner.scanCancellable(root: root, pruneBelow: 0) { _ in })
    let oldSizes = sizes(old)

    makeFile(root + "/a/new.bin", bytes: 3 * mb)               // added
    makeFile(root + "/a/newdir/q.bin", bytes: 2 * mb)          // new dir, not in the tree: attributed to /a
    makeFile(root + "/a/tiny2.txt", bytes: 500)                // folded
    try fm.removeItem(atPath: root + "/b/z.bin")               // removed
    makeFile(root + "/c/w.bin", bytes: 4 * mb)                 // grown
    try fm.removeItem(atPath: root + "/d")                     // directory gone

    let dirty: Set<String> = [root + "/a/sub", root + "/a/newdir/q.bin", root + "/b", root + "/c/w.bin", root + "/d", "/somewhere/else"]
    let refreshed = try #require(await Scanner.refresh(tree: old, dirtyPaths: dirty, pruneBelow: 0))
    let full = try #require(await Scanner.scanCancellable(root: root, pruneBelow: 0) { _ in })

    #expect(sizes(refreshed) == sizes(full))
    #expect(refreshed !== old)
    #expect(sizes(old) == oldSizes)                            // the shown tree is untouched
    #expect(refreshed.size[0] != old.size[0])
}

@Test func refreshWithoutChangesMatchesAndEmptyDirtyReturnsSameTree() async throws {
    let root = try fixture()
    defer { try? fm.removeItem(atPath: root) }
    let old = try #require(await Scanner.scanCancellable(root: root, pruneBelow: 0) { _ in })
    let same = try #require(await Scanner.refresh(tree: old, dirtyPaths: [root + "/a", root + "/a/sub", root + "/c"], pruneBelow: 0))
    #expect(sizes(same) == sizes(old))
    let none = try #require(await Scanner.refresh(tree: old, dirtyPaths: [], pruneBelow: 0))
    #expect(none === old)
}

@Test func refreshReturnsNilWhenFullRescanNeeded() async throws {
    let root = try fixture()
    defer { try? fm.removeItem(atPath: root) }
    for i in 0..<250 { try fm.createDirectory(atPath: root + "/many/m\(i)", withIntermediateDirectories: true) }
    let old = try #require(await Scanner.scanCancellable(root: root, pruneBelow: 0) { _ in })

    // too many directories
    let many = Set((0..<250).map { root + "/many/m\($0)" })
    #expect(await Scanner.refresh(tree: old, dirtyPaths: many, pruneBelow: 0) == nil)
    // covers more than 25% of the bytes
    #expect(await Scanner.refresh(tree: old, dirtyPaths: [root + "/ballast"], pruneBelow: 0) == nil)
    // root itself, or an unknown top-level directory (nearest existing ancestor is the root)
    #expect(await Scanner.refresh(tree: old, dirtyPaths: [root], pruneBelow: 0) == nil)
    try fm.createDirectory(atPath: root + "/brand-new/deep", withIntermediateDirectories: true)
    #expect(await Scanner.refresh(tree: old, dirtyPaths: [root + "/brand-new/deep"], pruneBelow: 0) == nil)

    // root vanished
    let gone = try makeTempRoot()
    makeFile(gone + "/a/x.bin", bytes: 2 * mb)
    let goneTree = try #require(await Scanner.scanCancellable(root: gone, pruneBelow: 0) { _ in })
    try fm.removeItem(atPath: gone)
    #expect(await Scanner.refresh(tree: goneTree, dirtyPaths: [gone + "/a"], pruneBelow: 0) == nil)
}

@Test func excludedPathsAreSkippedByScansAndRefresh() async throws {
    let root = try fixture()
    defer { try? fm.removeItem(atPath: root) }
    let skip = root + "/ballast"
    for i in 0..<8 { makeFile(root + "/other/f\(i).bin", bytes: 5 * mb) }   // keeps /a under the 25% bound
    let plain = try #require(await Scanner.scanCancellable(root: root, pruneBelow: 0) { _ in })
    let ex = try #require(await Scanner.scanCancellable(root: root, pruneBelow: 0, excluded: [skip + "/"]) { _ in })
    let live = try #require(await Scanner.scanLive(root: root, pruneBelow: 0, excluded: [skip], onSnapshot: { _ in }, progress: { _ in }))
    #expect(sizes(ex) == sizes(live))
    #expect(ex.children(of: 0).allSatisfy { ex.name($0) != "ballast" })
    let ballast = try #require(plain.children(of: 0).first { plain.name($0) == "ballast" })
    #expect(ex.size[0] == plain.size[0] - plain.size[Int(ballast)])

    // dirty path inside an excluded dir is ignored; a dirty ancestor does not re-enter it
    makeFile(root + "/ballast/extra.bin", bytes: 2 * mb)
    makeFile(root + "/a/new.bin", bytes: 2 * mb)
    let r = try #require(await Scanner.refresh(tree: ex, dirtyPaths: [skip + "/extra.bin", root + "/a"], pruneBelow: 0, excluded: [skip]))
    let full = try #require(await Scanner.scanCancellable(root: root, pruneBelow: 0, excluded: [skip]) { _ in })
    #expect(sizes(r) == sizes(full))
}

@Test func dirtyFileDirectlyUnderRootIsIgnoredAndNewNestedDirRescansParent() async throws {
    let root = try fixture()
    defer { try? fm.removeItem(atPath: root) }
    let old = try #require(await Scanner.scanCancellable(root: root, pruneBelow: 0) { _ in })

    // a new file directly in the root, and a vanished one: no fallback, tree unchanged
    makeFile(root + "/loose.txt", bytes: 1000)
    let same = try #require(await Scanner.refresh(tree: old, dirtyPaths: [root + "/loose.txt", root + "/gone.txt"], pruneBelow: 0))
    #expect(same === old)

    // a new nested directory under an existing one: its parent is rescanned, not the root
    try fm.removeItem(atPath: root + "/loose.txt")
    makeFile(root + "/a/fresh/deeper/n.bin", bytes: 2 * mb)
    let r = try #require(await Scanner.refresh(tree: old, dirtyPaths: [root + "/a/fresh", root + "/loose.txt"], pruneBelow: 0))
    let full = try #require(await Scanner.scanCancellable(root: root, pruneBelow: 0) { _ in })
    #expect(sizes(r) == sizes(full))
    #expect(r.size[0] == old.size[0] + UInt64(2 * mb))
}

@Test func wholeDiskExclusionsAreRerootedAndApplyToTheWalk() async throws {
    let base = try makeTempRoot()                     // stands in for /System/Volumes/Data
    defer { try? fm.removeItem(atPath: base) }
    makeFile(base + "/Users/x/skip/big.bin", bytes: 3 * mb)
    makeFile(base + "/Users/x/keep/k.bin", bytes: 2 * mb)
    let canonical = "/Users/x/skip"
    let mapped = ShellLogic.excludedForScan(root: base, excluded: [canonical, "/Volumes/ext", base + "/Users/x/other"], wholeDisk: base)
    #expect(mapped == [base + canonical, "/Volumes/ext", base + "/Users/x/other"])
    // other roots pass through untouched
    #expect(ShellLogic.excludedForScan(root: "/Users/x", excluded: [canonical], wholeDisk: base) == [canonical])

    let raw = try #require(await Scanner.scanCancellable(root: base, pruneBelow: 0, excluded: [canonical]) { _ in })
    #expect(sizes(raw)["/Users/x/skip"] != nil)       // unmapped spelling never matches: the bug
    let ok = try #require(await Scanner.scanCancellable(root: base, pruneBelow: 0, excluded: mapped) { _ in })
    let s = sizes(ok)
    #expect(s["/Users/x/skip"] == nil && s["/Users/x/skip/big.bin"] == nil)
    #expect(s["/Users/x/keep/k.bin"] != nil)
}
