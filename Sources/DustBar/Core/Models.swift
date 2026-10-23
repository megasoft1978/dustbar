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
    public let rootPath: String

    public init(rootPath: String) {
        self.rootPath = rootPath
        _ = add(name: rootPath, parent: noNode, isDir: true)
    }

    public var count: Int { size.count }

    @discardableResult
    public func add(name: String, parent p: NodeID, isDir dir: Bool, size s: UInt64 = 0) -> NodeID {
        let id = NodeID(size.count)
        let bytes = Array(name.utf8.prefix(Int(UInt16.max)))
        nameOff.append(UInt32(arena.count))
        nameLen.append(UInt16(bytes.count))
        arena.append(contentsOf: bytes)
        parent.append(p); firstChild.append(noNode); nextSibling.append(noNode)
        size.append(s); isDir.append(dir)
        if p != noNode {
            nextSibling[Int(id)] = firstChild[Int(p)]
            firstChild[Int(p)] = id
        }
        return id
    }

    public func addSize(_ id: NodeID, _ bytes: UInt64) { size[Int(id)] &+= bytes }

    /// Adds each node's size to all ancestors. Call once after the walk if sizes were set on leaves only.
    public func rollUp() {
        for i in stride(from: count - 1, to: 0, by: -1) {
            let p = parent[i]
            if p != noNode { size[Int(p)] &+= size[i] }
        }
    }

    public func name(_ id: NodeID) -> String {
        let o = Int(nameOff[Int(id)]), l = Int(nameLen[Int(id)])
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
    public var progress = ScanProgress()
    public var scanning = false
    public var categories: [CleanCategory] = []
    public var selectedItems: Set<String> = []     // CleanItem.path
    public var onRescan: (() -> Void)?             // set by shell
    public var onClean: (([CleanItem]) -> Void)?   // set by shell, runs Cleaner off-main
    public var onEmptyTrash: (([CleanItem]) -> Void)?  // permanent delete of ~/.Trash children only; UI must confirm first
    public var lastResult: CleanResult?
    public init() {}
}
