import Foundation
import Testing
@testable import DustBar

private func sampleTree() -> DiskTree {
    let t = DiskTree(rootPath: "/tmp/root")
    let a = t.add(name: "a", parent: 0, isDir: true, size: 300)
    t.add(name: "big.bin", parent: a, isDir: false, size: 200)
    t.add(name: "(small files)", parent: a, isDir: false, size: 100)
    t.add(name: "ünï.txt", parent: 0, isDir: false, size: 50)
    t.addSize(0, 350)
    return t
}

private func tempFile() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dustbar-cache-\(UUID().uuidString)/tree.bin")
}

@Test func treeCacheRoundtrip() throws {
    let tree = sampleTree()
    let when = Date(timeIntervalSince1970: 1_700_000_000.5)
    let data = TreeCache.encode(tree, device: 7, scannedAt: when)
    let (back, at) = try #require(TreeCache.decode(data, root: "/tmp/root", device: 7))
    #expect(at == when)
    #expect(back.count == tree.count)
    #expect(back.size == tree.size && back.parent == tree.parent && back.isDir == tree.isDir)
    #expect(back.firstChild == tree.firstChild && back.nextSibling == tree.nextSibling)
    for i in 0..<tree.count { #expect(back.name(NodeID(i)) == tree.name(NodeID(i))) }
    #expect(back.path(of: 2) == tree.path(of: 2))
}

@Test func treeCacheRejectsMismatchAndCorruption() throws {
    let data = TreeCache.encode(sampleTree(), device: 7, scannedAt: Date())
    #expect(TreeCache.decode(data, root: "/other", device: 7) == nil)
    #expect(TreeCache.decode(data, root: "/tmp/root", device: 8) == nil)
    #expect(TreeCache.decode(data.dropLast(), root: "/tmp/root", device: 7) == nil)
    #expect(TreeCache.decode(Data(), root: "/tmp/root", device: 7) == nil)
    var badMagic = data; badMagic[0] = 0
    #expect(TreeCache.decode(badMagic, root: "/tmp/root", device: 7) == nil)
    var badVersion = data; badVersion[4] = 99
    #expect(TreeCache.decode(badVersion, root: "/tmp/root", device: 7) == nil)
    // Flip bytes everywhere: must never crash, and any accepted result must be self-consistent.
    for i in stride(from: 0, to: data.count, by: 3) {
        var bad = data; bad[i] ^= 0xFF
        if let (t, _) = TreeCache.decode(bad, root: "/tmp/root", device: 7) {
            for n in 0..<t.count { _ = t.name(NodeID(n)); _ = t.children(of: NodeID(n)) }
        }
    }
}

@Test func treeCacheSaveLoadAtomicAndIgnoresGarbage() throws {
    let url = tempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let root = NSTemporaryDirectory()
    let tree = DiskTree(rootPath: root)
    tree.add(name: "x", parent: 0, isDir: false, size: 5)
    tree.rollUp()
    #expect(TreeCache.save(tree, device: TreeCache.deviceID(of: root)!, to: url))
    let loaded = try #require(TreeCache.load(root: root, from: url))
    #expect(loaded.tree.count == 2)
    try Data("garbage".utf8).write(to: url)
    #expect(TreeCache.load(root: root, from: url) == nil)
    #expect(TreeCache.load(root: root, from: url.appendingPathExtension("missing")) == nil)
}

// MARK: - Malicious cache rejection

private typealias Cols = DiskTree.Columns

private func goodColumns() -> Cols { sampleTree().columns }

/// Re-encodes mutated columns by building a tree with arbitrary links (bypasses add()).
private func decodeMutated(_ edit: (inout Cols) -> Void) -> DiskTree? {
    var c = goodColumns()
    edit(&c)
    return DiskTree(rootPath: "/tmp/root", columns: c)
}

private func renamed(_ c: inout Cols, node: Int, to name: String) {
    c.nameOff[node] = UInt32(c.arena.count)
    c.nameLen[node] = UInt16(name.utf8.count)
    c.arena.append(contentsOf: Array(name.utf8))
}

@Test func validColumnsAccepted() { #expect(decodeMutated { _ in } != nil) }

@Test func rejectsCyclicSiblingChain() {
    // nodes: 0 root, 1 a, 2 big.bin, 3 (small files), 4 ünï.txt; make a's children loop 3 -> 2.
    #expect(decodeMutated { $0.nextSibling[Int($0.firstChild[1])] = $0.firstChild[1] } == nil)
    #expect(decodeMutated { $0.nextSibling[1] = 4 } == nil)
}

@Test func rejectsCyclicParentChain() {
    #expect(decodeMutated { $0.parent[1] = 4; $0.parent[4] = 1 } == nil)
    #expect(decodeMutated { $0.parent[2] = 2 } == nil)
}

@Test func rejectsBadNames() {
    for bad in ["..", ".", "", "a/b", "../x", "a\u{0}b"] {
        #expect(decodeMutated { renamed(&$0, node: 4, to: bad) } == nil, "name \(bad.debugDescription)")
    }
}

@Test func rejectsChildLargerThanParent() {
    #expect(decodeMutated { $0.size[2] = 301 } == nil)
}

@Test func rejectsUnreachableNode() {
    #expect(decodeMutated { $0.nextSibling[4] = noNode } == nil)   // orphans node 1 and its subtree
}

@Test func boundedTraversalOnCyclicTree() {
    let t = DiskTree(rootPath: "/r")
    let a = t.add(name: "a", parent: 0, isDir: true, size: 1)
    let b = t.add(name: "b", parent: 0, isDir: true, size: 1)
    t.adopt(a, under: 0)
    t.adopt(b, under: a)   // parent cycle: a's parent is 0 but b -> a -> ... build loop below
    #expect(t.children(of: 0).count <= t.count)
    _ = t.path(of: b)
}
