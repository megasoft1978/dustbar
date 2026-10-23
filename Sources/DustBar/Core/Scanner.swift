import Foundation

// Slice A owns this file.
public enum Scanner {
    fileprivate static let smallThreshold: UInt64 = 1 << 20
    fileprivate static let smallLabel = "(small files)"
    fileprivate static let bufferSize = 64 * 1024   // 16 KB..1 MB measured within noise; 64 KB keeps buffers small
    fileprivate static let readerCount = max(1, ProcessInfo.processInfo.activeProcessorCount)   // ~/Library: 2->5.1s 4->3.7s 8->3.7s 12->3.5s 18->3.3-5s; ~: 4->55s 8->38s 18->35s
    fileprivate static let reportInterval = Duration.milliseconds(150)
    private static let snapshotDepth = 3          // levels below root kept in a snapshot
    private static let snapshotShareDivisor: UInt64 = 200   // keep nodes >= 1/200 (0.5%) of total
    private static let maxPrune: UInt64 = 5_000_000   // never above Duplicates' 5 MB minimum, so its files stay in the tree
    private static let pruneVolumeDivisor: UInt64 = 5000   // 0.02% of the volume's used space

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

    /// Smallest directory total that keeps its own node: max(1 MB, 0.02% of the volume's used space), capped at 5 MB.
    /// Smaller directories are folded into their parent's "(small files)" bucket without ever allocating nodes.
    public static func defaultPruneThreshold(root: String) -> UInt64 {
        var fs = statfs()
        guard statfs(root, &fs) == 0 else { return smallThreshold }
        let used = (UInt64(fs.f_blocks) &- UInt64(fs.f_bfree)) &* UInt64(fs.f_bsize)
        return min(maxPrune, max(smallThreshold, used / pruneVolumeDivisor))
    }

    /// Walks `root` (single device), builds a pruned DiskTree: directories whose total is below `pruneBelow`
    /// (default `defaultPruneThreshold`) and files below max(1 MB, `pruneBelow`) are folded into a "(small files)"
    /// child of the nearest kept directory.
    /// A cancelled walk returns a partial tree; use `scanCancellable` when partial results must not be published.
    public static func scan(root: String, pruneBelow: UInt64? = nil, progress: @escaping @Sendable (ScanProgress) -> Void) async -> DiskTree {
        await walk(root: root, pruneBelow: pruneBelow, progress: progress).tree
    }

    /// Like `scan`, but returns nil if the calling task was cancelled before the walk finished.
    public static func scanCancellable(root: String, pruneBelow: UInt64? = nil, progress: @escaping @Sendable (ScanProgress) -> Void) async -> DiskTree? {
        let result = await walk(root: root, pruneBelow: pruneBelow, progress: progress)
        return result.cancelled ? nil : result.tree
    }

    /// Like `scanCancellable`, but also calls `onSnapshot` with an independent, pruned DiskTree roughly every
    /// `snapshotInterval` seconds while the walk runs (first one after the first directory). Snapshots hold only
    /// the top 3 levels with nodes >= 0.5% of the total so far; their sizes are partial for unfinished dirs.
    /// The last `onSnapshot` call is the complete tree (the same instance that is returned). Returns nil if cancelled.
    public static func scanLive(
        root: String,
        snapshotInterval: Double = 1.5,
        pruneBelow: UInt64? = nil,
        onSnapshot: @escaping @Sendable (DiskTree) -> Void,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async -> DiskTree? {
        let sink = SnapshotSink(every: .seconds(snapshotInterval), emit: onSnapshot)
        let result = await walk(root: root, pruneBelow: pruneBelow, progress: progress, snapshot: sink)
        return result.cancelled ? nil : result.tree
    }

    fileprivate static let liveDepth: UInt32 = 3   // directories deeper than this only feed their depth-3 ancestor

    private static func walk(
        root: String,
        pruneBelow: UInt64?,
        progress: @escaping @Sendable (ScanProgress) -> Void,
        snapshot: SnapshotSink? = nil
    ) async -> (tree: DiskTree, cancelled: Bool) {
        let tree = DiskTree(rootPath: root)
        var rootStat = stat()
        guard stat(root, &rootStat) == 0 else {
            progress(ScanProgress(done: true))
            return (tree, Task.isCancelled)
        }
        let minDir = pruneBelow ?? defaultPruneThreshold(root: root)
        let run = WalkRun(
            root: root, rootDev: rootStat.st_dev, tree: tree, minDir: minDir,
            progress: progress, snapshot: snapshot)
        // The walk runs on its own threads (never the cooperative pool: open() can block forever on cloud /
        // File Provider folders); this task just waits for it and forwards cancellation.
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let thread = Thread {
                    run.execute()
                    cont.resume()
                }
                thread.name = "dustbar.scan.aggregate"
                thread.qualityOfService = .utility
                thread.start()
            }
        } onCancel: {
            run.cancel()
        }
        return (tree, run.wasCancelled || Task.isCancelled)
    }

    /// Independent pruned copy of `tree` (top `snapshotDepth` levels, nodes >= 1/`snapshotShareDivisor` of total).
    /// Dir sizes are already rolled up in `tree.size`; the copy is built with explicit sizes and never rolled up.
    /// Cost is bounded by the kept nodes (at most ~`snapshotShareDivisor` per level) plus their child lists.
    fileprivate static func makeSnapshot(of tree: DiskTree) -> DiskTree {
        let copy = DiskTree(rootPath: tree.rootPath)
        let total = tree.size[0]
        let minBytes = total / snapshotShareDivisor
        copy.addSize(0, total)   // root is created with size 0 and the copy is never rolled up
        var queue: [(src: NodeID, dst: NodeID, depth: Int)] = [(0, 0, 0)]
        var head = 0
        while head < queue.count {
            let (src, dst, depth) = queue[head]
            head += 1
            for c in tree.children(of: src) {
                let isDir = tree.isDir[Int(c)]
                let bytes = tree.size[Int(c)]
                guard bytes > 0, bytes >= minBytes else { continue }
                let id = copy.add(name: tree.name(c), parent: dst, isDir: isDir, size: bytes)
                if isDir && depth + 1 < snapshotDepth {
                    queue.append((c, id, depth + 1))
                }
            }
        }
        return copy
    }

    /// True when `root` lives on a filesystem where getattrlistbulk is reliable (APFS, HFS+). Others (exFAT, smb,
    /// nfs, FUSE) can report different file IDs from stat, so they take the readdir + lstat path.
    nonisolated(unsafe) static var forcePortable = false   // tests only

    static func supportsBulk(root: String) -> Bool {
        if forcePortable { return false }
        var fs = statfs()
        guard statfs(root, &fs) == 0 else { return true }
        let name = withUnsafeBytes(of: fs.f_fstypename) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return name == "apfs" || name == "hfs"
    }

    /// Portable fallback: readdir + fstatat. Same classification and byte accounting as the bulk path.
    fileprivate static func readDirectoryPortable(path: String, rootDev: dev_t, fileMin: UInt64, into batch: inout DirBatch) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == EACCES || errno == EPERM { batch.unreadable = true }
            return
        }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_dev == rootDev, let dir = fdopendir(fd) else { close(fd); return }
        defer { closedir(dir) }   // also closes fd
        while !Task.isCancelled, let ent = readdir(dir) {
            let nameBytes = withUnsafeBytes(of: &ent.pointee.d_name) { raw -> [UInt8] in
                Array(raw.prefix(while: { $0 != 0 }))
            }
            if nameBytes == [0x2E] || nameBytes == [0x2E, 0x2E] { continue }
            var withNul = nameBytes; withNul.append(0)
            var es = stat()
            let ok = withNul.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                    fstatat(fd, $0, &es, AT_SYMLINK_NOFOLLOW) == 0
                }
            }
            guard ok, es.st_dev == rootDev else { continue }
            let alloc = UInt64(es.st_blocks) * 512
            switch es.st_mode & S_IFMT {
            case S_IFDIR:
                batch.subdirNames.append(contentsOf: withNul)
            case S_IFREG, S_IFLNK:
                if es.st_mode & S_IFMT == S_IFREG && es.st_nlink > 1 {
                    let off = alloc >= fileMin ? withNul.withUnsafeBytes { batch.appendName($0) } : -1
                    batch.files.append(FileEntry(ino: UInt64(es.st_ino), bytes: alloc, nameOffset: off, isLink: true))
                } else if alloc >= fileMin {
                    batch.files.append(FileEntry(ino: 0, bytes: alloc, nameOffset: withNul.withUnsafeBytes { batch.appendName($0) }, isLink: false))
                } else {
                    batch.smallBytes &+= alloc
                    batch.smallCount += 1
                }
            default:
                break
            }
        }
    }

    /// Reads one directory with getattrlistbulk. Pure w.r.t. the tree; safe to run concurrently.
    fileprivate static func readDirectory(path: String, rootDev: dev_t, fileMin: UInt64, into batch: inout DirBatch) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == EACCES || errno == EPERM { batch.unreadable = true }
            return
        }
        defer { close(fd) }

        // open() crosses mount points; stay on the root's device.
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_dev == rootDev else { return }

        var list = attrlist()
        list.bitmapcount = 5
        list.commonattr = cmnReturnedAttrs | cmnName | cmnDevid | cmnObjtype | cmnFileid
        list.fileattr = fileLinkcount | fileAllocsize

        let buf = BufferPool.take()
        defer { BufferPool.give(buf) }
        while !Task.isCancelled {
            let n = getattrlistbulk(fd, &list, buf, bufferSize, 0)
            if n < 0 {
                if errno == EACCES || errno == EPERM { batch.unreadable = true }
                break
            }
            if n == 0 { break }
            var off = 0
            for _ in 0..<Int(n) {
                off = parseEntry(buf, at: off, rootDev: rootDev, fileMin: fileMin, into: &batch)
            }
        }
    }

    /// Parses one packed entry at `start` and returns the offset of the next one.
    /// Field order follows attribute bit order: common (NAME, DEVID, OBJTYPE, FILEID), then file (LINKCOUNT, ALLOCSIZE).
    /// Names are copied as raw bytes only for entries that need them (directories and files >= `fileMin`).
    private static func parseEntry(_ buf: UnsafeMutableRawPointer, at start: Int, rootDev: dev_t, fileMin: UInt64, into batch: inout DirBatch) -> Int {
        let length = Int(buf.loadUnaligned(fromByteOffset: start, as: UInt32.self))
        let common = buf.loadUnaligned(fromByteOffset: start + 4, as: UInt32.self)
        let file = buf.loadUnaligned(fromByteOffset: start + 4 + 12, as: UInt32.self)
        var p = start + 4 + 20                  // length + attribute_set_t (5 x u32)

        var nameAt = -1
        var nameLen = 0                         // includes the terminating NUL
        if common & cmnName != 0 {              // attrreference_t: offset (relative to itself), length
            nameAt = p + Int(buf.loadUnaligned(fromByteOffset: p, as: Int32.self))
            nameLen = Int(buf.loadUnaligned(fromByteOffset: p + 4, as: UInt32.self))
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
        let namePtr = UnsafeRawBufferPointer(start: buf + nameAt, count: max(0, nameLen))
        // Only dirs, regular files and symlinks (not followed). Devices, FIFOs and sockets are skipped.
        switch objType {
        case vdir:
            batch.subdirNames.append(contentsOf: namePtr)
        case vreg, vlnk:
            if objType == vreg && nlink > 1 {
                // Hard link: the aggregator dedupes by inode, so every link is reported (name only if it may become a node).
                let off = alloc >= fileMin ? batch.appendName(namePtr) : -1
                batch.files.append(FileEntry(ino: fileID, bytes: alloc, nameOffset: off, isLink: true))
            } else if alloc >= fileMin {
                batch.files.append(FileEntry(ino: 0, bytes: alloc, nameOffset: batch.appendName(namePtr), isLink: false))
            } else {
                batch.smallBytes &+= alloc
                batch.smallCount += 1
            }
        default:
            break
        }
        return next
    }
}

private struct Pending: Sendable {
    let path: String
    let parent: Int32     // TreeBuilder slot of the parent directory, -1 for the root
    let depth: UInt32
    let live: NodeID      // nearest snapshot-tree ancestor-or-self
}

/// One regular file or hard link that may become a node (>= the file threshold), or a hard link to dedupe.
private struct FileEntry: Sendable {
    let ino: UInt64
    let bytes: UInt64
    let nameOffset: Int32   // into DirBatch.names; -1 when the entry is too small to ever be a node
    let isLink: Bool
}

/// Result of reading one directory. Names live in two packed NUL-terminated byte buffers, so reading a
/// directory costs a few allocations regardless of how many entries it has.
private struct DirBatch: Sendable {
    var subdirNames: [UInt8] = []
    var names: [UInt8] = []
    var files: [FileEntry] = []
    var smallBytes: UInt64 = 0
    var smallCount = 0
    var unreadable = false

    var capacity: Int { subdirNames.capacity + names.capacity + files.capacity * MemoryLayout<FileEntry>.stride }

    mutating func reset() {
        subdirNames.removeAll(keepingCapacity: true)
        names.removeAll(keepingCapacity: true)
        files.removeAll(keepingCapacity: true)
        smallBytes = 0; smallCount = 0; unreadable = false
    }

    mutating func appendName(_ raw: UnsafeRawBufferPointer) -> Int32 {
        let off = names.count
        names.append(contentsOf: raw)
        return Int32(truncatingIfNeeded: off)
    }

    func name(at offset: Int) -> String {
        names.withUnsafeBufferPointer { buf in
            var end = offset
            while end < buf.count, buf[end] != 0 { end += 1 }
            return String(decoding: UnsafeBufferPointer(rebasing: buf[offset..<end]), as: UTF8.self)
        }
    }
}

private struct DirResult: Sendable {
    let dir: Pending
    let batch: DirBatch
}

private struct SnapshotSink: Sendable {
    let every: Duration
    let emit: @Sendable (DiskTree) -> Void
}

/// Builds the final tree post-order. A directory is open from when its listing arrives until all its
/// subdirectories have finished; only then is its total known and its node created (or skipped if small).
/// Children are chained detached and adopted when their parent is created, so pruned subtrees allocate nothing.
private final class TreeBuilder {
    struct Frame {
        var path = ""
        var parent: Int32 = -1
        var remaining: Int32 = 0
        var total: UInt64 = 0
        var small: UInt64 = 0         // own small files plus the totals of pruned child directories
        var head: NodeID = noNode     // kept children so far (sibling chain)
    }

    let tree: DiskTree
    let minDir: UInt64
    private var frames: [Frame] = []
    private var free: [Int32] = []

    init(tree: DiskTree, minDir: UInt64) { self.tree = tree; self.minDir = minDir }

    func open(path: String, parent: Int32) -> Int32 {
        var f = Frame()
        f.path = path
        f.parent = parent
        if let slot = free.popLast() {
            frames[Int(slot)] = f
            return slot
        }
        frames.append(f)
        return Int32(frames.count - 1)
    }

    func addFile(name: String, bytes: UInt64, to slot: Int32) {
        frames[Int(slot)].head = tree.addDetached(name: name, isDir: false, size: bytes, next: frames[Int(slot)].head)
    }

    func addSmall(_ bytes: UInt64, to slot: Int32) { frames[Int(slot)].small &+= bytes }

    /// Records the directory's own file bytes and subdirectory count; finishes it right away when it has none.
    func setPending(_ subdirs: Int32, bytes: UInt64, slot: Int32) {
        frames[Int(slot)].total &+= bytes
        frames[Int(slot)].remaining = subdirs
        if subdirs == 0 { finish(slot) }
    }

    private func finish(_ first: Int32) {
        var s = first
        while true {
            let f = frames[Int(s)]
            frames[Int(s)] = Frame()
            free.append(s)
            var head = f.head
            if f.parent < 0 || f.total >= minDir, f.small > 0 {
                head = tree.addDetached(name: "(small files)", isDir: false, size: f.small, next: head)
            }
            if f.parent < 0 {
                tree.adopt(head, under: 0)
                tree.addSize(0, f.total)
                return
            }
            let par = Int(f.parent)
            if f.total >= minDir {
                let name: String
                if let slash = f.path.utf8.lastIndex(of: UInt8(ascii: "/")) {
                    name = String(f.path[f.path.index(after: slash)...])
                } else {
                    name = f.path
                }
                frames[par].head = tree.addDetached(name: name, isDir: true, size: f.total, firstChild: head, next: frames[par].head)
            } else {
                frames[par].small &+= f.total
            }
            frames[par].total &+= f.total
            frames[par].remaining -= 1
            if frames[par].remaining > 0 { return }
            s = f.parent
        }
    }
}

/// Inode numbers seen so far (hard-link dedupe). Open-addressing table of raw UInt64s: ~8 bytes per slot instead of
/// a Swift Set's growth spikes. Inode 0 is never valid, so 0 marks an empty slot.
private struct InodeSet {
    private var slots: UnsafeMutablePointer<UInt64>?
    private var capacity = 0          // power of two
    private var count = 0

    /// True when `ino` was not present (and is now).
    mutating func insert(_ ino: UInt64) -> Bool {
        let key = ino == 0 ? UInt64.max : ino
        if (count + 1) * 4 > capacity * 3 { grow() }
        guard place(key, in: slots!, capacity: capacity) else { return false }
        count += 1
        return true
    }

    private func place(_ key: UInt64, in table: UnsafeMutablePointer<UInt64>, capacity cap: Int) -> Bool {
        var i = Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> 24) & (cap - 1)
        while table[i] != 0 {
            if table[i] == key { return false }
            i = (i + 1) & (cap - 1)
        }
        table[i] = key
        return true
    }

    private mutating func grow() {
        let newCap = max(1 << 12, capacity * 2)
        let fresh = calloc(newCap, MemoryLayout<UInt64>.size)!.assumingMemoryBound(to: UInt64.self)
        if let old = slots {
            for i in 0..<capacity where old[i] != 0 { _ = place(old[i], in: fresh, capacity: newCap) }
            free(old)
        }
        slots = fresh
        capacity = newCap
    }

    mutating func release() {
        free(slots)
        slots = nil; capacity = 0; count = 0
    }
}

/// Reusable getattrlistbulk buffers (one per concurrent read) instead of an allocation per directory.
private enum BufferPool {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var buffers: [UnsafeMutableRawPointer] = []

    static func take() -> UnsafeMutableRawPointer {
        lock.lock(); defer { lock.unlock() }
        return buffers.popLast() ?? UnsafeMutableRawPointer.allocate(byteCount: Scanner.bufferSize, alignment: 8)
    }

    static func give(_ buf: UnsafeMutableRawPointer) {
        lock.lock(); defer { lock.unlock() }
        buffers.append(buf)
    }

    /// Frees the idle buffers once a scan is over.
    static func drain() {
        lock.lock(); defer { lock.unlock() }
        for b in buffers { b.deallocate() }
        buffers.removeAll()
    }
}

/// One walk. A fixed set of reader threads pops directories from `pending` and posts their packed listings to
/// `results`; the single aggregator thread (`execute`) folds them into the tree post-order and queues subdirectories.
/// There is no task or closure per directory, listings are recycled through `spare`, and a reader that blocks
/// longer than `timeout` is abandoned (its directory counts as unreadable and a replacement reader starts).
private final class WalkRun: @unchecked Sendable {
    private struct Reading {
        let dir: Pending
        let since: ContinuousClock.Instant
    }
    private static let timeout: Duration = .seconds(5)
    private static let maxBacklog = 48
    private static let maxSpareCapacity = 256 * 1024   // listings bigger than this are not kept for reuse

    private let root: String
    private let rootDev: dev_t
    private let tree: DiskTree
    private let minDir: UInt64
    private let fileMin: UInt64
    private let useBulk: Bool
    private let progress: @Sendable (ScanProgress) -> Void
    private let snapshot: SnapshotSink?

    private let lock = NSLock()
    private let workSem = DispatchSemaphore(value: 0)     // one count per queued directory (or per shutdown wake)
    private let resultSem = DispatchSemaphore(value: 0)   // one count per posted result (or wake-up)
    private var pending: [Pending] = []
    private var results: [DirResult] = []
    private var spare: [DirBatch] = []
    private var reading: [Int: Reading] = [:]
    private var nextWorker = 0
    private var stopping = false
    private var cancelled = false
    private var workerCount = 0

    init(root: String, rootDev: dev_t, tree: DiskTree, minDir: UInt64,
         progress: @escaping @Sendable (ScanProgress) -> Void, snapshot: SnapshotSink?) {
        self.root = root; self.rootDev = rootDev; self.tree = tree; self.minDir = minDir
        self.fileMin = max(Scanner.smallThreshold, minDir)   // a file >= minDir forces its parent chain to be kept
        self.progress = progress; self.snapshot = snapshot
        self.useBulk = Scanner.supportsBulk(root: root)
    }

    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        resultSem.signal()
    }

    // MARK: Readers

    private func startWorker() {
        lock.lock()
        let id = nextWorker
        nextWorker += 1
        workerCount += 1
        lock.unlock()
        let thread = Thread { [self] in readLoop(id: id) }
        thread.name = "dustbar.scan.read"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func readLoop(id: Int) {
        while true {
            workSem.wait()
            // Backpressure: never let finished listings pile up faster than the aggregator folds them in.
            while true {
                lock.lock(); let backlog = results.count, quit = stopping; lock.unlock()
                if backlog < Self.maxBacklog || quit { break }
                usleep(300)
            }
            lock.lock()
            if stopping { lock.unlock(); return }
            guard let dir = pending.popLast() else { lock.unlock(); continue }
            reading[id] = Reading(dir: dir, since: .now)
            var batch = spare.popLast() ?? DirBatch()
            lock.unlock()

            if useBulk {
                Scanner.readDirectory(path: dir.path, rootDev: rootDev, fileMin: fileMin, into: &batch)
            } else {
                Scanner.readDirectoryPortable(path: dir.path, rootDev: rootDev, fileMin: fileMin, into: &batch)
            }

            lock.lock()
            if reading.removeValue(forKey: id) == nil {   // abandoned while blocked: the aggregator moved on
                lock.unlock()
                return
            }
            results.append(DirResult(dir: dir, batch: batch))
            lock.unlock()
            resultSem.signal()
        }
    }

    /// Called by the aggregator. Gives up on reads stuck past the timeout and replaces their readers.
    private func abandonStuckReaders() {
        let now = ContinuousClock.now
        lock.lock()
        let stuck = reading.filter { now - $0.value.since >= Self.timeout }
        for (id, r) in stuck {
            reading[id] = nil
            var timedOut = DirBatch()
            timedOut.unreadable = true
            results.append(DirResult(dir: r.dir, batch: timedOut))
        }
        lock.unlock()
        for _ in stuck {
            resultSem.signal()
            startWorker()
        }
    }

    // MARK: Aggregator

    func execute() {
        let builder = TreeBuilder(tree: tree, minDir: minDir)
        let live = snapshot == nil ? nil : DiskTree(rootPath: root)   // top levels only, rolled up as listings arrive
        var seenLinks = InodeSet()                                    // every entry is on rootDev, so the inode alone identifies a file
        var totals = ScanProgress()
        var lastReport = ContinuousClock.now
        var lastSnapshot: ContinuousClock.Instant?
        let readers = Scanner.readerCount

        lock.lock(); pending = [Pending(path: root, parent: -1, depth: 0, live: 0)]; lock.unlock()
        workSem.signal()
        for _ in 0..<readers { startWorker() }

        var batchOfResults: [DirResult] = []
        var newDirs: [Pending] = []
        while true {
            lock.lock()
            swap(&batchOfResults, &results)
            let finished = batchOfResults.isEmpty && pending.isEmpty && reading.isEmpty
            let stop = cancelled
            lock.unlock()
            if stop || finished { break }
            if batchOfResults.isEmpty {
                _ = resultSem.wait(timeout: .now() + .milliseconds(500))
                abandonStuckReaders()
                continue
            }
            for _ in 0..<batchOfResults.count { _ = resultSem.wait(timeout: .now()) }   // keep the count in step

            for index in batchOfResults.indices {
                let dir = batchOfResults[index].dir
                var batch = batchOfResults[index].batch
                let slot = builder.open(path: dir.path, parent: dir.parent)
                let prefix = dir.path.hasSuffix("/") ? dir.path : dir.path + "/"
                let childDepth = dir.depth + 1
                let showChildren = dir.depth < Scanner.liveDepth    // snapshot lists this directory's children

                var subdirs: Int32 = 0
                batch.subdirNames.withUnsafeBufferPointer { buf in
                    var start = 0
                    for i in 0..<buf.count where buf[i] == 0 {
                        let name = String(decoding: UnsafeBufferPointer(rebasing: buf[start..<i]), as: UTF8.self)
                        start = i + 1
                        var childLive = dir.live
                        if showChildren, let live { childLive = live.add(name: name, parent: dir.live, isDir: true) }
                        newDirs.append(Pending(path: prefix + name, parent: slot, depth: childDepth, live: childLive))
                        subdirs += 1
                    }
                }

                var small = batch.smallBytes
                var bytes = batch.smallBytes
                totals.files += batch.smallCount
                for f in batch.files {
                    if f.isLink, !seenLinks.insert(f.ino) { continue }   // hard link: count once
                    totals.files += 1
                    bytes &+= f.bytes
                    if f.nameOffset < 0 {
                        small &+= f.bytes
                        continue
                    }
                    let name = batch.name(at: Int(f.nameOffset))
                    builder.addFile(name: name, bytes: f.bytes, to: slot)
                    if showChildren, let live { live.add(name: name, parent: dir.live, isDir: false, size: f.bytes) }
                }
                totals.bytes &+= bytes
                if small > 0 {
                    builder.addSmall(small, to: slot)
                    if showChildren, let live { live.add(name: Scanner.smallLabel, parent: dir.live, isDir: false, size: small) }
                }
                if batch.unreadable { totals.unreadableDirs += 1 }

                if bytes > 0, let live {
                    var n = dir.live
                    while n != noNode {
                        live.addSize(n, bytes)
                        n = live.parent[Int(n)]
                    }
                }

                if !newDirs.isEmpty {
                    lock.lock(); pending.append(contentsOf: newDirs); lock.unlock()
                    for _ in 0..<newDirs.count { workSem.signal() }
                    newDirs.removeAll(keepingCapacity: true)
                }
                builder.setPending(subdirs, bytes: bytes, slot: slot)

                batch.reset()
                if batch.capacity <= Self.maxSpareCapacity {
                    lock.lock(); if spare.count < Self.maxBacklog { spare.append(batch) }; lock.unlock()
                }
            }
            batchOfResults.removeAll(keepingCapacity: true)

            let now = ContinuousClock.now
            if now - lastReport >= Scanner.reportInterval {
                lastReport = now
                progress(totals)
            }
            if let snap = snapshot, let live,
               lastSnapshot.map({ now - $0 >= snap.every }) ?? true {
                lastSnapshot = now
                snap.emit(Scanner.makeSnapshot(of: live))
            }
            abandonStuckReaders()
        }

        // Shut the readers down; abandoned or still-blocked ones exit when (if) they return.
        lock.lock(); stopping = true; let n = workerCount; spare.removeAll(); pending.removeAll(); lock.unlock()
        for _ in 0..<n { workSem.signal() }
        seenLinks.release()
        BufferPool.drain()

        if wasCancelled { return }
        tree.compact()
        snapshot?.emit(tree)
        totals.done = true
        progress(totals)
    }
}

