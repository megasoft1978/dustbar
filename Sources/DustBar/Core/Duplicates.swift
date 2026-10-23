import Foundation
import CryptoKit

// Duplicate-file finder. Read-only. Reports redundant copies only; the oldest copy of each set is kept.
public enum Duplicates {
    private static let maxItems = 500
    private static let edgeBytes: UInt64 = 64 * 1024
    private static let chunkBytes = 256 * 1024
    private static let smallLabel = "(small files)"

    /// Production entry point: real home, no extra roots. Compatibility wrapper.
    public static func find(tree: DiskTree, minBytes: UInt64 = 5_000_000) async -> [CleanCategory] {
        await find(tree: tree, minBytes: minBytes, excluding: [], home: NSHomeDirectory(), roots: []).category.map { [$0] } ?? []
    }

    /// Candidates equal to or under any `excluding` path are never offered (callers pass every base-category item path).
    /// `kept` lists the oldest copy of each duplicate set: callers must drop those from other categories too.
    public static func find(tree: DiskTree, minBytes: UInt64 = 5_000_000, excluding: Set<String> = []) async
        -> (category: CleanCategory?, kept: Set<String>) {
        await find(tree: tree, minBytes: minBytes, excluding: excluding, home: NSHomeDirectory(), roots: [])
    }

    /// `home` and `roots` exist for tests, as in Cleaner.trash. Production never passes them.
    static func find(tree: DiskTree, minBytes: UInt64, home: String, roots: [String]) async -> [CleanCategory] {
        await find(tree: tree, minBytes: minBytes, excluding: [], home: home, roots: roots).category.map { [$0] } ?? []
    }

    static func find(tree: DiskTree, minBytes: UInt64, excluding: Set<String>, home: String, roots: [String]) async
        -> (category: CleanCategory?, kept: Set<String>) {
        let task = Task(priority: .utility) {
            await run(tree: tree, minBytes: minBytes, excluding: excluding, home: home, roots: roots)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private struct Candidate: Sendable {
        let path: String
        let bytes: UInt64      // allocated bytes from the tree, as reported to the user
        let size: UInt64       // st_size, used for grouping and for the hash reads
        let dev: dev_t
        let ino: ino_t
        let birth: Int64       // creation time in ns; the oldest copy is kept
    }

    private struct InodeKey: Hashable, Sendable {
        let dev: dev_t
        let ino: ino_t
    }

    private struct Hashed: Sendable {
        let cand: Candidate
        let digest: [UInt8]
    }

    private struct SetKey: Hashable, Sendable {
        let size: UInt64
        let digest: [UInt8]
    }

    private static func run(tree: DiskTree, minBytes: UInt64, excluding: Set<String>, home: String, roots: [String]) async
        -> (category: CleanCategory?, kept: Set<String>) {
        let none: (category: CleanCategory?, kept: Set<String>) = (nil, [])
        guard let candidates = collect(tree: tree, minBytes: minBytes, excluding: excluding, home: home, roots: roots) else { return none }

        // Stage 1: same byte size. Singletons cannot be duplicates.
        let bySize = Dictionary(grouping: candidates, by: \.size).values.filter { $0.count > 1 }.flatMap { $0 }
        let heads = await hashAll(bySize, partial: true)
        guard !Task.isCancelled else { return none }

        // Stage 2: head + tail digest. Stage 3: full digest, only for files still colliding.
        let partialSets = Dictionary(grouping: heads, by: { SetKey(size: $0.cand.size, digest: $0.digest) })
            .values.filter { $0.count > 1 }.flatMap { $0 }
        let fulls = await hashAll(partialSets.map(\.cand), partial: false)
        guard !Task.isCancelled else { return none }

        var items: [CleanItem] = []
        var kept = Set<String>()
        for set in Dictionary(grouping: fulls, by: { SetKey(size: $0.cand.size, digest: $0.digest) }).values where set.count > 1 {
            let ordered = set.map(\.cand).sorted { ($0.birth, $0.path) < ($1.birth, $1.path) }
            // The oldest eligible copy is never offered, so at least one copy of every set always survives.
            if let first = ordered.first { kept.insert(first.path) }
            items += ordered.dropFirst().map { CleanItem(path: $0.path, bytes: $0.bytes) }
        }
        guard !items.isEmpty else { return none }

        items.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        let category = CleanCategory(
            id: "duplicates",
            title: "Duplicate files",
            detail: "Identical copies of the same file. The oldest copy of each set is kept.",
            defaultSelected: false,
            items: Array(items.prefix(maxItems))
        )
        return (category, kept)
    }

    /// Walks the tree for regular files over `minBytes`. nil when cancelled.
    private static func collect(tree: DiskTree, minBytes: UInt64, excluding: Set<String>, home: String, roots: [String]) -> [Candidate]? {
        let skip = excluding.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        var out: [Candidate] = []
        var seen = Set<InodeKey>()
        var stack: [NodeID] = [0]
        while let id = stack.popLast() {
            if Task.isCancelled { return nil }
            // An empty name would make path(of:) return the parent directory, so such a node is never offered.
            guard id == 0 || !tree.name(id).isEmpty else { continue }
            if tree.isDir[Int(id)] {
                stack.append(contentsOf: tree.children(of: id))
                continue
            }
            guard tree.size[Int(id)] >= minBytes, tree.name(id) != smallLabel else { continue }
            // Rules.isDenied resolves symlinks through Foundation; drain its autoreleased objects per file.
            let c: Candidate? = autoreleasepool {
                let path = tree.path(of: id)
                guard !excluded(path, home: home, roots: roots), !isExcludedByCaller(path, skip) else { return nil }
                return candidate(path, bytes: tree.size[Int(id)])
            }
            guard let c, seen.insert(InodeKey(dev: c.dev, ino: c.ino)).inserted else { continue }
            out.append(c)
        }
        return out
    }

    private static func isExcludedByCaller(_ path: String, _ skip: [String]) -> Bool {
        let k = path.precomposedStringWithCanonicalMapping.lowercased()
        return skip.contains { k == $0 || k.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// Denylist, ~/Library, and anything inside an .app bundle (Rules.isDenied covers .app components).
    private static func excluded(_ path: String, home: String, roots: [String]) -> Bool {
        let library = home + "/Library"
        return path == library || path.hasPrefix(library + "/") || Rules.isInTrash(path, home: home)
            || Rules.isInCloudStorage(path, home: home) || Rules.isDenied(path, home: home, roots: roots)
    }

    /// Hard links (nlink > 1) free no space when one name is removed, so they never count as copies.
    private static func candidate(_ path: String, bytes: UInt64) -> Candidate? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1, st.st_size > 0 else { return nil }
        let birth = Int64(st.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_birthtimespec.tv_nsec)
        return Candidate(path: path, bytes: bytes, size: UInt64(st.st_size), dev: st.st_dev, ino: st.st_ino, birth: birth)
    }

    /// Shared state of one hashing run. Workers run on a dedicated queue, off the cooperative pool.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        private var live: Int
        private var cancelledFlag = false
        private(set) var out: [Hashed] = []
        var continuation: CheckedContinuation<[Hashed], Never>?

        init(workers: Int) { live = workers }

        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelledFlag }
        func cancel() { lock.lock(); cancelledFlag = true; lock.unlock() }
        func take(limit: Int) -> Int? {
            lock.lock(); defer { lock.unlock() }
            guard !cancelledFlag, next < limit else { return nil }
            next += 1
            return next - 1
        }
        func add(_ h: Hashed) { lock.lock(); out.append(h); lock.unlock() }
        /// Called by each worker as it exits; the last one resumes the awaiting task.
        func finish() {
            lock.lock()
            live -= 1
            let done = live == 0
            let result = out
            lock.unlock()
            if done { continuation?.resume(returning: result); continuation = nil }
        }
    }

    private static let hashQueue = DispatchQueue(label: "dustbar.duplicates.hash", qos: .utility, attributes: .concurrent)

    /// Digests `candidates` on a dedicated concurrent queue (width max(2, ncpu/2)). Files that fail to hash or changed since the walk are dropped.
    private static func hashAll(_ candidates: [Candidate], partial: Bool) async -> [Hashed] {
        guard !candidates.isEmpty, !Task.isCancelled else { return [] }
        let width = min(candidates.count, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        let run = Run(workers: width)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<[Hashed], Never>) in
                run.continuation = cont
                for _ in 0..<width {
                    hashQueue.async {
                        while let i = run.take(limit: candidates.count) {
                            let c = candidates[i]
                            let h = autoreleasepool { digest(c, partial: partial, cancelled: { run.cancelled }) }
                            if let h { run.add(Hashed(cand: c, digest: h)) }
                        }
                        run.finish()
                    }
                }
            }
        } onCancel: {
            run.cancel()
        }
    }

    /// Partial: first and last 64 KB (the whole file when it is 128 KB or less). Full: every byte, streamed in 256 KB chunks.
    private static func digest(_ c: Candidate, partial: Bool, cancelled: () -> Bool) -> [UInt8]? {
        let fd = open(c.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // The file must still be the one the walk saw: same device, inode and size.
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_dev == c.dev, st.st_ino == c.ino, UInt64(st.st_size) == c.size else { return nil }

        var ranges: [(start: UInt64, count: UInt64)] = [(0, c.size)]
        if partial && c.size > 2 * edgeBytes {
            ranges = [(0, edgeBytes), (c.size - edgeBytes, edgeBytes)]
        }
        var sha = SHA256()
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkBytes, alignment: 16)
        defer { buf.deallocate() }
        _ = fcntl(fd, F_NOCACHE, 1)
        for r in ranges {
            guard feed(fd, r.start, r.count, &sha, buf, cancelled) else { return nil }
        }
        return Array(sha.finalize())
    }

    private static func feed(_ fd: Int32, _ start: UInt64, _ count: UInt64, _ sha: inout SHA256, _ buf: UnsafeMutableRawBufferPointer, _ cancelled: () -> Bool) -> Bool {
        var off = start
        var left = count
        while left > 0 {
            if cancelled() { return false }
            let want = Int(min(left, UInt64(buf.count)))
            let n = pread(fd, buf.baseAddress, want, off_t(off))
            guard n > 0 else { return false }
            sha.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buf[0..<n]))
            off += UInt64(n)
            left -= UInt64(n)
        }
        return true
    }
}
