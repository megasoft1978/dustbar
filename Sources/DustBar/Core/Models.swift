import Foundation
import Observation

// Shared contract. Slices must not change signatures here without telling the integrator.

public typealias NodeID = UInt32
public let noNode: NodeID = .max

/// Compact struct-of-arrays tree. Index 0 is the root.
public final class DiskTree: @unchecked Sendable {
    public private(set) var parent: [NodeID] = []
    public private(set) var firstChild: [NodeID] = []
    public private(set) var nextSibling: [NodeID] = []
    public private(set) var size: [UInt64] = []      // allocated bytes, includes descendants
    public private(set) var isDir: [Bool] = []
    private var nameOff: [UInt32] = []
    private var nameLen: [UInt16] = []
    private var arena: [UInt8] = []
    private var sharedOff: UInt32?
    private static let sharedName = "(small files)"
    public let rootPath: String

    public init(rootPath: String) {
        self.rootPath = rootPath
        _ = add(name: rootPath, parent: noNode, isDir: true)
    }

    public var count: Int { size.count }

    @discardableResult
    public func add(name: String, parent p: NodeID, isDir dir: Bool, size s: UInt64 = 0) -> NodeID {
        let id = NodeID(size.count)
        // "(small files)" repeats once per directory: store its bytes once and share the offset.
        if name == DiskTree.sharedName, let off = sharedOff {
            nameOff.append(off)
            nameLen.append(UInt16(DiskTree.sharedName.utf8.count))
            appendNode(id, parent: p, isDir: dir, size: s)
            return id
        }
        let nameBytes = name.utf8.prefix(Int(UInt16.max))
        let byteCount = nameBytes.count
        // Past 4 GB of names the arena offset would wrap, so the node is kept with an empty name instead.
        if DiskTree.fitsArena(arena.count, adding: byteCount) {
            if name == DiskTree.sharedName { sharedOff = UInt32(truncatingIfNeeded: arena.count) }
            nameOff.append(UInt32(truncatingIfNeeded: arena.count))
            nameLen.append(UInt16(truncatingIfNeeded: byteCount))
            arena.append(contentsOf: nameBytes)
        } else {
            nameOff.append(0)
            nameLen.append(0)
        }
        appendNode(id, parent: p, isDir: dir, size: s)
        return id
    }

    /// Adds a node whose parent is not known yet (post-order building): it points at `firstChild`'s sibling chain,
    /// whose members get `parent` set to the new node, and is itself chained before `next`.
    /// Link it under its parent later by passing the returned id as `next` of a sibling or as `firstChild` of the parent.
    @discardableResult
    func addDetached(name: String, isDir dir: Bool, size s: UInt64, firstChild head: NodeID = noNode, next: NodeID = noNode) -> NodeID {
        let id = add(name: name, parent: noNode, isDir: dir, size: s)
        nextSibling[Int(id)] = next
        adopt(head, under: id)
        return id
    }

    /// Makes `head`'s sibling chain the children of `p`.
    func adopt(_ head: NodeID, under p: NodeID) {
        firstChild[Int(p)] = head
        var c = head
        while c != noNode { parent[Int(c)] = p; c = nextSibling[Int(c)] }
    }

    private func appendNode(_ id: NodeID, parent p: NodeID, isDir dir: Bool, size s: UInt64) {
        parent.append(p); firstChild.append(noNode); nextSibling.append(noNode)
        size.append(s); isDir.append(dir)
        if p != noNode {
            nextSibling[Int(id)] = firstChild[Int(p)]
            firstChild[Int(p)] = id
        }
    }

    /// Drops spare array capacity left over from growth. Call once the tree is complete.
    public func compact() {
        func exact<T>(_ a: [T]) -> [T] {
            var out: [T] = []
            out.reserveCapacity(a.count)
            out.append(contentsOf: a)
            return out
        }
        parent = exact(parent); firstChild = exact(firstChild); nextSibling = exact(nextSibling)
        size = exact(size); isDir = exact(isDir)
        nameOff = exact(nameOff); nameLen = exact(nameLen); arena = exact(arena)
    }

    public func addSize(_ id: NodeID, _ bytes: UInt64) { size[Int(id)] &+= bytes }

    /// Adds each node's size to all ancestors. Call once after the walk if sizes were set on leaves only.
    public func rollUp() {
        for i in stride(from: count - 1, to: 0, by: -1) {
            let p = parent[i]
            if p != noNode { size[Int(p)] &+= size[i] }
        }
    }

    /// True when `extra` more name bytes keep every arena offset within UInt32.
    static func fitsArena(_ count: Int, adding extra: Int) -> Bool {
        count + extra <= Int(UInt32.max)
    }

    /// Raw columns for persistence (see TreeCache).
    struct Columns {
        var parent: [NodeID], firstChild: [NodeID], nextSibling: [NodeID]
        var size: [UInt64], isDir: [Bool]
        var nameOff: [UInt32], nameLen: [UInt16], arena: [UInt8]
    }

    var columns: Columns {
        Columns(parent: parent, firstChild: firstChild, nextSibling: nextSibling, size: size, isDir: isDir,
                nameOff: nameOff, nameLen: nameLen, arena: arena)
    }

    /// Rebuilds a tree from saved columns; nil unless the columns are mutually consistent
    /// (equal lengths, every link in range or `noNode`, every name inside the arena, root first).
    convenience init?(rootPath: String, columns c: Columns) {
        let n = c.size.count
        guard n > 0, c.parent.count == n, c.firstChild.count == n, c.nextSibling.count == n, c.isDir.count == n,
              c.nameOff.count == n, c.nameLen.count == n, c.parent[0] == noNode else { return nil }
        for i in 0..<n {
            for link in [c.firstChild[i], c.nextSibling[i]] where link != noNode && Int(link) >= n { return nil }
            if i > 0, c.parent[i] != noNode, Int(c.parent[i]) >= n { return nil }
            if Int(c.nameOff[i]) + Int(c.nameLen[i]) > c.arena.count { return nil }
        }
        self.init(rootPath: rootPath)
        parent = c.parent; firstChild = c.firstChild; nextSibling = c.nextSibling
        size = c.size; isDir = c.isDir; nameOff = c.nameOff; nameLen = c.nameLen; arena = c.arena
        sharedOff = nil
    }

    public func name(_ id: NodeID) -> String {
        let o = Int(nameOff[Int(id)]), l = Int(nameLen[Int(id)])
        guard l > 0 else { return "" }
        return String(decoding: arena[o..<o + l], as: UTF8.self)
    }

    public func children(of id: NodeID) -> [NodeID] {
        var out: [NodeID] = []
        var c = firstChild[Int(id)]
        while c != noNode { out.append(c); c = nextSibling[Int(c)] }
        return out
    }

    public func path(of id: NodeID) -> String {
        var parts: [String] = []
        var cur = id
        while cur != 0 && cur != noNode { parts.append(name(cur)); cur = parent[Int(cur)] }
        return ([rootPath] + parts.reversed()).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
    }
}

public struct VolumeStats: Sendable, Equatable {
    public var total: UInt64
    public var free: UInt64            // available for important usage (includes purgeable)
    public var purgeable: UInt64
    public var used: UInt64 { total &- free }
    public var freeFraction: Double { total == 0 ? 0 : Double(free) / Double(total) }
    public init(total: UInt64 = 0, free: UInt64 = 0, purgeable: UInt64 = 0) {
        self.total = total; self.free = free; self.purgeable = purgeable
    }
}

public struct ScanProgress: Sendable {
    public var files: Int
    public var bytes: UInt64
    public var unreadableDirs: Int     // hint for Full Disk Access
    public var done: Bool
    public init(files: Int = 0, bytes: UInt64 = 0, unreadableDirs: Int = 0, done: Bool = false) {
        self.files = files; self.bytes = bytes; self.unreadableDirs = unreadableDirs; self.done = done
    }
}

public struct CleanItem: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let bytes: UInt64
    public init(path: String, bytes: UInt64) { self.path = path; self.bytes = bytes }
}

public struct CleanCategory: Identifiable, Sendable {
    public let id: String              // e.g. "caches", "xcode", "node_modules", "trash", "downloads", "large"
    public let title: String
    public let detail: String
    public let defaultSelected: Bool   // only caches + trash
    public var items: [CleanItem]
    public var bytes: UInt64 { items.reduce(0) { $0 &+ $1.bytes } }
    public init(id: String, title: String, detail: String, defaultSelected: Bool, items: [CleanItem]) {
        self.id = id; self.title = title; self.detail = detail
        self.defaultSelected = defaultSelected; self.items = items
    }
}

public struct CleanResult: Sendable {
    public var trashed: [CleanItem]
    public var refused: [CleanItem]    // denylisted
    public var failed: [(CleanItem, String)]
    public var permanent = false       // set by the shell: true for Empty Trash (permanent deletion)
    public var freedBytes: UInt64 { trashed.reduce(0) { $0 &+ $1.bytes } }
    public init(trashed: [CleanItem] = [], refused: [CleanItem] = [], failed: [(CleanItem, String)] = []) {
        self.trashed = trashed; self.refused = refused; self.failed = failed
    }
}

/// Observable state shared by shell and UI. Main-actor only.
@MainActor @Observable
public final class AppModel {
    public var stats = VolumeStats()
    public var tree: DiskTree?
    public var cachedAt: Date?                     // set while `tree` was loaded from the on-disk cache (nil when fresh)
    public var isLiveSnapshot = false              // true while `tree` is a partial snapshot from a running scan
    public var progress = ScanProgress()
    public var scanning = false
    public var categories: [CleanCategory] = []
    public var selectedItems: Set<String> = []     // CleanItem.path
    public var onRescan: (() -> Void)?             // set by shell
    public var onClean: (([CleanItem]) -> Void)?   // set by shell, runs Cleaner off-main
    public var onEmptyTrash: (([CleanItem]) -> Void)?  // permanent delete of ~/.Trash children only; UI must confirm first
    public var lastResult: CleanResult?
    public var cleaning = false                    // true while a cleanup runs; UI disables destructive buttons
    public init() {}
}
