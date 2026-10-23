import Foundation

/// On-disk copy of the last complete pruned tree, so the next launch can show it before the fresh scan finishes.
/// Format (little endian): "DBTC", version u32, device u32, scannedAt f64, count u32, arenaLen u32, rootLen u32,
/// root bytes, then the columns parent, firstChild, nextSibling (u32 each), size (u64), isDir (u8), nameOff (u32),
/// nameLen (u16), arena. The file length must match exactly; anything else is ignored.
public enum TreeCache {
    static let magic: [UInt8] = Array("DBTC".utf8)
    static let version: UInt32 = 1
    private static let headerSize = 4 + 4 + 4 + 8 + 4 + 4 + 4

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.megasoft78.dustbar/tree.bin")
    }

    public static func encode(_ tree: DiskTree, device: UInt32, scannedAt: Date) -> Data {
        let c = tree.columns
        let root = Array(tree.rootPath.utf8)
        var d = Data()
        d.reserveCapacity(headerSize + root.count + c.size.count * 35 + c.arena.count)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        func putArray<T>(_ a: [T]) { a.withUnsafeBytes { d.append(contentsOf: $0) } }
        d.append(contentsOf: magic)
        put(version.littleEndian); put(device.littleEndian)
        put(scannedAt.timeIntervalSince1970.bitPattern.littleEndian)
        put(UInt32(c.size.count).littleEndian); put(UInt32(c.arena.count).littleEndian); put(UInt32(root.count).littleEndian)
        d.append(contentsOf: root)
        putArray(c.parent); putArray(c.firstChild); putArray(c.nextSibling); putArray(c.size)
        d.append(contentsOf: c.isDir.map { $0 ? 1 : 0 })
        putArray(c.nameOff); putArray(c.nameLen); d.append(contentsOf: c.arena)
        return d
    }

    /// nil when the data is truncated, has another version/root/device, or is internally inconsistent.
    public static func decode(_ data: Data, root: String, device: UInt32) -> (tree: DiskTree, scannedAt: Date)? {
        guard data.count >= headerSize else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (DiskTree, Date)? in
            func u32(_ at: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
            guard Array(raw[0..<4]) == magic, u32(4) == version, u32(8) == device else { return nil }
            let stamp = Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 12, as: UInt64.self)))
            let n = Int(u32(20)), arenaLen = Int(u32(24)), rootLen = Int(u32(28))
            let expected = headerSize + rootLen + n * (4 + 4 + 4 + 8 + 1 + 4 + 2) + arenaLen
            guard n > 0, stamp.isFinite, data.count == expected, rootLen == root.utf8.count,
                  Array(raw[headerSize..<headerSize + rootLen]) == Array(root.utf8) else { return nil }
            var at = headerSize + rootLen
            func read<T>(_: T.Type, _ count: Int) -> [T] {
                let bytes = count * MemoryLayout<T>.stride
                defer { at += bytes }
                return [T](unsafeUninitializedCapacity: count) { buf, done in
                    if bytes > 0 { memcpy(buf.baseAddress!, raw.baseAddress! + at, bytes) }
                    done = count
                }
            }
            let parent = read(NodeID.self, n), first = read(NodeID.self, n), next = read(NodeID.self, n)
            let size = read(UInt64.self, n)
            let isDirBytes = read(UInt8.self, n)
            let nameOff = read(UInt32.self, n), nameLen = read(UInt16.self, n)
            let arena = read(UInt8.self, arenaLen)
            guard !isDirBytes.contains(where: { $0 > 1 }) else { return nil }
            let cols = DiskTree.Columns(parent: parent, firstChild: first, nextSibling: next, size: size,
                                        isDir: isDirBytes.map { $0 == 1 }, nameOff: nameOff, nameLen: nameLen, arena: arena)
            guard let tree = DiskTree(rootPath: root, columns: cols) else { return nil }
            return (tree, Date(timeIntervalSince1970: stamp))
        }
    }

    /// Writes atomically (temp file in the same directory, then rename). Failures are silent: the cache is optional.
    @discardableResult
    public static func save(_ tree: DiskTree, device: UInt32, scannedAt: Date = Date(), to url: URL = defaultURL) -> Bool {
        let data = encode(tree, device: device, scannedAt: scannedAt)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func load(root: String, from url: URL = defaultURL) -> (tree: DiskTree, scannedAt: Date)? {
        guard let device = deviceID(of: root),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return decode(data, root: root, device: device)
    }

    public static func deviceID(of path: String) -> UInt32? {
        var st = stat()
        return stat(path, &st) == 0 ? UInt32(bitPattern: st.st_dev) : nil
    }
}
