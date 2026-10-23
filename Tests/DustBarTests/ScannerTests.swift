import Foundation
import Synchronization
import Testing
@testable import DustBar

private let mb = 1_048_576

/// Allocated bytes of a path (lstat, so symlinks report their own blocks).
private func allocated(_ path: String) -> UInt64 {
    var st = stat()
    guard lstat(path, &st) == 0 else { return 0 }
    return UInt64(st.st_blocks) * 512
}

private func makeFile(_ path: String, bytes: Int) {
    _ = FileManager.default.createFile(atPath: path, contents: Data(count: bytes))
}

private func makeTempRoot() throws -> String {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("dustbar-scan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func child(_ tree: DiskTree, of id: NodeID, named name: String) -> NodeID? {
    tree.children(of: id).first { tree.name($0) == name }
}

@Test func scanCountsAllocatedBytesAndFoldsSmallFiles() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(atPath: root + "/a/b/c", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: root + "/small", withIntermediateDirectories: true)

    var expected: UInt64 = 0
    func put(_ rel: String, _ bytes: Int) -> UInt64 {
        let p = root + "/" + rel
        makeFile(p, bytes: bytes)
        let n = allocated(p)
        expected += n
        return n
    }

    _ = put("a/big.bin", 2 * mb)                  // own node
    _ = put("a/b/c/deep.bin", 1_200_000)          // own node
    _ = put("a/b/tiny.txt", 100)                  // folded into a/b "(small files)"
    var smallTotal: UInt64 = 0
    for i in 0..<10 { smallTotal += put("small/s\(i).dat", 10_240) }   // folded into small/
    _ = put("h1.bin", 2 * mb)                     // hard link pair: counted once
    try FileManager.default.linkItem(atPath: root + "/h1.bin", toPath: root + "/h2.bin")
    try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: "a/big.bin")
    expected += allocated(root + "/link")          // symlink's own blocks only; target not followed

    let last = Mutex<ScanProgress?>(nil)
    let tree = await Scanner.scan(root: root, pruneBelow: 0) { p in last.withLock { $0 = p } }

    #expect(tree.size[0] == expected)
    let final = last.withLock { $0 }
    #expect(final?.done == true)
    #expect(final?.bytes == expected)
    #expect(final?.unreadableDirs == 0)

    let a = try #require(child(tree, of: 0, named: "a"))
    #expect(tree.isDir[Int(a)])
    let big = try #require(child(tree, of: a, named: "big.bin"))
    #expect(tree.size[Int(big)] == allocated(root + "/a/big.bin"))
    #expect(!tree.isDir[Int(big)])

    let b = try #require(child(tree, of: a, named: "b"))
    #expect(child(tree, of: b, named: "tiny.txt") == nil)
    let bNames = tree.children(of: b).map { tree.name($0) }.sorted()
    #expect(bNames == ["(small files)", "c"])
    let bSmall = try #require(child(tree, of: b, named: "(small files)"))
    #expect(!tree.isDir[Int(bSmall)])
    #expect(tree.size[Int(bSmall)] == allocated(root + "/a/b/tiny.txt"))

    let small = try #require(child(tree, of: 0, named: "small"))
    let smallKids = tree.children(of: small)
    #expect(smallKids.count == 1)
    let folded = try #require(smallKids.first)
    #expect(tree.name(folded) == "(small files)")
    #expect(!tree.isDir[Int(folded)])
    #expect(tree.size[Int(folded)] == smallTotal)
    #expect(tree.size[Int(small)] == smallTotal)

    let hardlinkNodes = tree.children(of: 0).filter { ["h1.bin", "h2.bin"].contains(tree.name($0)) }
    #expect(hardlinkNodes.count == 1)
    #expect(child(tree, of: 0, named: "link") == nil)   // symlink is tiny, so folded; never a 2 MB node
}

@Test func scanCountsUnreadableDirs() async throws {
    let root = try makeTempRoot()
    let locked = root + "/locked"
    try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
    makeFile(locked + "/x.bin", bytes: 2 * mb)
    chmod(locked, 0)
    defer {
        chmod(locked, 0o755)
        try? FileManager.default.removeItem(atPath: root)
    }

    let last = Mutex<ScanProgress?>(nil)
    let tree = await Scanner.scan(root: root, pruneBelow: 0) { p in last.withLock { $0 = p } }

    let final = last.withLock { $0 }
    #expect(final?.done == true)
    #expect(final?.unreadableDirs == 1)
    #expect(tree.size[0] == 0)
    #expect(child(tree, of: 0, named: "locked") != nil)
}

@Test func scanCancellableReturnsNilOnlyWhenCancelled() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    makeFile(root + "/x.bin", bytes: 2 * mb)

    // Wait for cancellation before walking so the result is deterministic.
    let cancelled = Task {
        while !Task.isCancelled { await Task.yield() }
        return await Scanner.scanCancellable(root: root, pruneBelow: 0) { _ in }
    }
    cancelled.cancel()
    #expect(await cancelled.value == nil)

    let tree = try #require(await Scanner.scanCancellable(root: root, pruneBelow: 0) { _ in })
    #expect(tree.size[0] == allocated(root + "/x.bin"))
}

/// Deepest level under `id` (0 when `id` has no children).
private func maxDepth(_ tree: DiskTree, _ id: NodeID = 0, _ depth: Int = 0) -> Int {
    tree.children(of: id).map { maxDepth(tree, $0, depth + 1) }.max() ?? depth
}

@Test func scanLiveDeliversPrunedSnapshotsEndingWithFinalTree() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(atPath: root + "/a/b/c", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: root + "/small", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: root + "/d1/d2/d3/d4", withIntermediateDirectories: true)
    makeFile(root + "/a/b/c/deep.bin", bytes: 2 * mb)
    makeFile(root + "/a/big.bin", bytes: 2 * mb)
    makeFile(root + "/a/b/tiny.txt", bytes: 100)
    for i in 0..<10 { makeFile(root + "/small/s\(i).dat", bytes: 10_240) }
    makeFile(root + "/d1/d2/d3/d4/deep4.bin", bytes: 2 * mb)

    let snapshots = Mutex<[DiskTree]>([])
    let live = await Scanner.scanLive(
        root: root,
        snapshotInterval: 0.01,
        pruneBelow: 0,
        onSnapshot: { s in snapshots.withLock { $0.append(s) } },
        progress: { _ in })
    let final = try #require(live)
    let reference = try #require(await Scanner.scanCancellable(root: root, pruneBelow: 0) { _ in })
    #expect(final.size[0] == reference.size[0])
    #expect(final.size[0] > 0)

    let all = snapshots.withLock { $0 }
    #expect(!all.isEmpty)
    #expect(all.last === final)                                  // last snapshot is the complete tree
    #expect(all.allSatisfy { $0.size[0] <= final.size[0] })
    #expect(zip(all, all.dropFirst()).allSatisfy { $0.size[0] <= $1.size[0] })
    for s in all.dropLast() {
        #expect(s !== final)                                      // independent copies, never the live tree
        #expect(maxDepth(s) <= 3)                                 // top 3 levels only
    }
}

@Test func scanLiveReturnsNilWhenCancelled() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    makeFile(root + "/x.bin", bytes: 2 * mb)

    // Wait for cancellation before walking so the result is deterministic.
    let cancelled = Task {
        while !Task.isCancelled { await Task.yield() }
        return await Scanner.scanLive(root: root, onSnapshot: { _ in }, progress: { _ in })
    }
    cancelled.cancel()
    #expect(await cancelled.value == nil)
}

@Test func scanPrunesSmallDirectoriesIntoParentBucket() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    for d in ["keep/inner", "tiny/sub", "mid"] {
        try FileManager.default.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true)
    }
    makeFile(root + "/keep/inner/big.bin", bytes: 3 * mb)
    makeFile(root + "/keep/note.txt", bytes: 100)
    makeFile(root + "/tiny/sub/a.txt", bytes: 5_000)
    makeFile(root + "/tiny/b.txt", bytes: 5_000)
    makeFile(root + "/mid/m.bin", bytes: 1_200_000)       // >= 1 MB file but its dir is under the 2 MB threshold
    let expected = allocated(root + "/keep/inner/big.bin") + allocated(root + "/keep/note.txt")
        + allocated(root + "/tiny/sub/a.txt") + allocated(root + "/tiny/b.txt") + allocated(root + "/mid/m.bin")

    let tree = await Scanner.scan(root: root, pruneBelow: UInt64(2 * mb)) { _ in }
    #expect(tree.size[0] == expected)
    let names = tree.children(of: 0).map { tree.name($0) }.sorted()
    #expect(names == ["(small files)", "keep"])           // tiny/ and mid/ never get nodes
    let bucket = try #require(child(tree, of: 0, named: "(small files)"))
    let keep = try #require(child(tree, of: 0, named: "keep"))
    #expect(tree.size[Int(bucket)] == expected - tree.size[Int(keep)])
    let inner = try #require(child(tree, of: keep, named: "inner"))
    #expect(child(tree, of: keep, named: "(small files)") != nil)
    let big = try #require(child(tree, of: inner, named: "big.bin"))
    #expect(tree.path(of: big) == root + "/keep/inner/big.bin")
}

@Test func portableReaderMatchesBulkReader() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(atPath: root + "/a/b", withIntermediateDirectories: true)
    makeFile(root + "/a/big.bin", bytes: 2 * mb)
    makeFile(root + "/a/b/deep.bin", bytes: 1_300_000)
    makeFile(root + "/a/b/tiny.txt", bytes: 100)
    makeFile(root + "/h1.bin", bytes: 2 * mb)
    try FileManager.default.linkItem(atPath: root + "/h1.bin", toPath: root + "/h2.bin")
    try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: "a/big.bin")

    let bulk = await Scanner.scan(root: root, pruneBelow: 0) { _ in }
    Scanner.forcePortable = true
    let portable = await Scanner.scan(root: root, pruneBelow: 0) { _ in }
    Scanner.forcePortable = false
    #expect(portable.size[0] == bulk.size[0])
    #expect(portable.count == bulk.count)
    #expect(Set((0..<portable.count).map { portable.path(of: NodeID($0)) }) == Set((0..<bulk.count).map { bulk.path(of: NodeID($0)) }))
}
