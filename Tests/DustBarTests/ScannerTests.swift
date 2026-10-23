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
    let tree = await Scanner.scan(root: root) { p in last.withLock { $0 = p } }

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
    let tree = await Scanner.scan(root: root) { p in last.withLock { $0 = p } }

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
        return await Scanner.scanCancellable(root: root) { _ in }
    }
    cancelled.cancel()
    #expect(await cancelled.value == nil)

    let tree = try #require(await Scanner.scanCancellable(root: root) { _ in })
    #expect(tree.size[0] == allocated(root + "/x.bin"))
}
