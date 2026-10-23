import Foundation

// Slice A owns this file.
public enum Scanner {
    private static let smallThreshold: UInt64 = 1 << 20
    private static let smallLabel = "(small files)"
    private static let bufferSize = 64 * 1024
    private static let reportInterval = Duration.milliseconds(150)

    // sys/attr.h values, hardcoded so the macro import width never matters.
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnDevid: UInt32 = 0x0000_0002
    private static let cmnObjtype: UInt32 = 0x0000_0008
    private static let cmnFileid: UInt32 = 0x0200_0000
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let fileLinkcount: UInt32 = 0x0000_0001
    private static let fileAllocsize: UInt32 = 0x0000_0004
    private static let vreg: UInt32 = 1
    private static let vdir: UInt32 = 2
    private static let vlnk: UInt32 = 5

    /// Walks `root` (single device), builds a pruned DiskTree (files < 1 MB folded into a "(small files)" child per dir).
    /// A cancelled walk returns a partial tree; use `scanCancellable` when partial results must not be published.
    public static func scan(root: String, progress: @escaping @Sendable (ScanProgress) -> Void) async -> DiskTree {
        await walk(root: root, progress: progress).tree
    }

    /// Like `scan`, but returns nil if the calling task was cancelled before the walk finished.
    public static func scanCancellable(root: String, progress: @escaping @Sendable (ScanProgress) -> Void) async -> DiskTree? {
        let result = await walk(root: root, progress: progress)
        return result.cancelled ? nil : result.tree
    }

    private static func walk(root: String, progress: @escaping @Sendable (ScanProgress) -> Void) async -> (tree: DiskTree, cancelled: Bool) {
        let tree = DiskTree(rootPath: root)
        var rootStat = stat()
        guard stat(root, &rootStat) == 0 else {
            progress(ScanProgress(done: true))
            return (tree, Task.isCancelled)
        }
        let rootDev = rootStat.st_dev
        let maxConcurrent = max(1, ProcessInfo.processInfo.activeProcessorCount)
        var pending = [Pending(path: root, node: 0)]
        var seenLinks = Set<LinkKey>()
        var totals = ScanProgress()
        var lastReport = ContinuousClock.now

        // Workers only read directories; all tree mutation happens here, single-threaded.
        await withTaskGroup(of: DirResult.self) { group in
            var running = 0
            while true {
                while running < maxConcurrent, !Task.isCancelled, let dir = pending.popLast() {
                    running += 1
                    group.addTask(priority: .utility) {
                        DirResult(dir: dir, batch: readDirectory(path: dir.path, rootDev: rootDev))
                    }
                }
                guard let result = await group.next() else { break }
                running -= 1
                let dir = result.dir
                let batch = result.batch
                let prefix = dir.path.hasSuffix("/") ? dir.path : dir.path + "/"

                for name in batch.subdirs {
                    let id = tree.add(name: name, parent: dir.node, isDir: true)
                    pending.append(Pending(path: prefix + name, node: id))
                }
                for f in batch.bigFiles {
                    tree.add(name: f.name, parent: dir.node, isDir: false, size: f.bytes)
                    totals.files += 1
                    totals.bytes &+= f.bytes
                }
                var small = batch.smallBytes
                var smallCount = batch.smallCount
                totals.files += batch.smallCount
                totals.bytes &+= batch.smallBytes
                for link in batch.links {
                    if !seenLinks.insert(link.key).inserted { continue }   // hard link: count once
                    totals.files += 1
                    totals.bytes &+= link.bytes
                    if link.bytes >= smallThreshold {
                        tree.add(name: link.name, parent: dir.node, isDir: false, size: link.bytes)
                    } else {
                        small &+= link.bytes
                        smallCount += 1
                    }
                }
                if smallCount > 0 {
                    tree.add(name: smallLabel, parent: dir.node, isDir: false, size: small)
                }
                if batch.unreadable { totals.unreadableDirs += 1 }

                let now = ContinuousClock.now
                if now - lastReport >= reportInterval {
                    lastReport = now
                    progress(totals)
                }
            }
        }

        if Task.isCancelled { return (tree, true) }
        tree.rollUp()
        totals.done = true
        progress(totals)
        return (tree, false)
    }

    /// Reads one directory with getattrlistbulk. Pure w.r.t. the tree; safe to run concurrently.
    private static func readDirectory(path: String, rootDev: dev_t) -> DirBatch {
        var batch = DirBatch()
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == EACCES || errno == EPERM { batch.unreadable = true }
            return batch
        }
        defer { close(fd) }

        // open() crosses mount points; stay on the root's device.
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_dev == rootDev else { return batch }

        var list = attrlist()
        list.bitmapcount = 5
        list.commonattr = cmnReturnedAttrs | cmnName | cmnDevid | cmnObjtype | cmnFileid
        list.fileattr = fileLinkcount | fileAllocsize

        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buf.deallocate() }
        while !Task.isCancelled {
            let n = getattrlistbulk(fd, &list, buf, bufferSize, 0)
            if n < 0 {
                if errno == EACCES || errno == EPERM { batch.unreadable = true }
                break
            }
            if n == 0 { break }
            var off = 0
            for _ in 0..<Int(n) {
                off = parseEntry(buf, at: off, rootDev: rootDev, into: &batch)
            }
        }
        return batch
    }

    /// Parses one packed entry at `start` and returns the offset of the next one.
    /// Field order follows attribute bit order: common (NAME, DEVID, OBJTYPE, FILEID), then file (LINKCOUNT, ALLOCSIZE).
    private static func parseEntry(_ buf: UnsafeMutableRawPointer, at start: Int, rootDev: dev_t, into batch: inout DirBatch) -> Int {
        let length = Int(buf.loadUnaligned(fromByteOffset: start, as: UInt32.self))
        let common = buf.loadUnaligned(fromByteOffset: start + 4, as: UInt32.self)
        let file = buf.loadUnaligned(fromByteOffset: start + 4 + 12, as: UInt32.self)
        var p = start + 4 + 20                  // length + attribute_set_t (5 x u32)

        var nameAt = -1
        if common & cmnName != 0 {              // attrreference_t: offset (relative to itself), length
            nameAt = p + Int(buf.loadUnaligned(fromByteOffset: p, as: Int32.self))
            p += 8
        }
        var devid: dev_t = 0
        if common & cmnDevid != 0 {
            devid = buf.loadUnaligned(fromByteOffset: p, as: dev_t.self)
            p += 4
        }
        var objType: UInt32 = 0
        if common & cmnObjtype != 0 {
            objType = buf.loadUnaligned(fromByteOffset: p, as: UInt32.self)
            p += 4
        }
        var fileID: UInt64 = 0
        if common & cmnFileid != 0 {
            fileID = buf.loadUnaligned(fromByteOffset: p, as: UInt64.self)
            p += 8
        }
        var nlink: UInt32 = 1
        if file & fileLinkcount != 0 {
            nlink = buf.loadUnaligned(fromByteOffset: p, as: UInt32.self)
            p += 4
        }
        var alloc: UInt64 = 0
        if file & fileAllocsize != 0 {
            alloc = UInt64(bitPattern: buf.loadUnaligned(fromByteOffset: p, as: Int64.self))
        }

        let next = start + length
        guard nameAt >= 0, devid == rootDev else { return next }
        // Only dirs, regular files and symlinks (not followed). Devices, FIFOs and sockets are skipped.
        switch objType {
        case vdir:
            batch.subdirs.append(name(buf, at: nameAt))
        case vreg, vlnk:
            if objType == vreg && nlink > 1 {
                batch.links.append(LinkEntry(name: name(buf, at: nameAt), key: LinkKey(dev: devid, ino: fileID), bytes: alloc))
            } else if alloc >= smallThreshold {
                batch.bigFiles.append(FileEntry(name: name(buf, at: nameAt), bytes: alloc))
            } else {
                batch.smallBytes &+= alloc
                batch.smallCount += 1
            }
        default:
            break
        }
        return next
    }

    private static func name(_ buf: UnsafeMutableRawPointer, at offset: Int) -> String {
        String(cString: (buf + offset).assumingMemoryBound(to: CChar.self))
    }
}

private struct Pending: Sendable {
    let path: String
    let node: NodeID
}

private struct FileEntry: Sendable {
    let name: String
    let bytes: UInt64
}

private struct LinkKey: Hashable, Sendable {
    let dev: dev_t
    let ino: UInt64
}

private struct LinkEntry: Sendable {
    let name: String
    let key: LinkKey
    let bytes: UInt64
}

private struct DirBatch: Sendable {
    var subdirs: [String] = []
    var bigFiles: [FileEntry] = []
    var smallBytes: UInt64 = 0
    var smallCount = 0
    var links: [LinkEntry] = []
    var unreadable = false
}

private struct DirResult: Sendable {
    let dir: Pending
    let batch: DirBatch
}
