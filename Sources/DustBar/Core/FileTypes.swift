import Foundation

/// Groups allocated bytes by file kind (from the extension) for the Types view. Pure: reads the tree only.
/// Directories contribute through their files; "(small files)" folds become `smallFiles`, so the slices
/// always add up to the root size.
public enum FileTypes {
    public enum Kind: String, CaseIterable, Sendable, Hashable {
        case video, images, audio, archives, documents, code, apps, diskImages, other
        case smallFiles          // "(small files)" folds, shown as "Other (small files)"
    }

    public struct TypedFile: Equatable, Sendable {
        public let path: String
        public let bytes: UInt64
        public init(path: String, bytes: UInt64) { self.path = path; self.bytes = bytes }
    }

    public struct TypeSlice: Identifiable, Equatable, Sendable {
        public var id: Kind { kind }
        public let kind: Kind
        public let bytes: UInt64
        public let count: Int          // files; for smallFiles, the folders holding a bucket
        public let top: [TypedFile]    // largest first, at most `topLimit`; smallFiles entries are their folders
        public init(kind: Kind, bytes: UInt64, count: Int, top: [TypedFile]) {
            self.kind = kind; self.bytes = bytes; self.count = count; self.top = top
        }
    }

    public static let topLimit = 5
    static let smallFilesName = "(small files)"

    static let extensions: [Kind: [String]] = [
        .video: ["mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "webm", "mpg", "mpeg", "m2ts", "vob", "3gp"],
        .images: ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "psd", "ai",
                  "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "raf"],
        .audio: ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "wma", "caf", "alac", "mid", "midi"],
        .archives: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz", "lzma", "cab"],
        .documents: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf",
                     "rtfd", "md", "odt", "ods", "odp", "csv", "epub", "mobi", "tex"],
        .code: ["swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "java", "kt", "kts", "go", "rs", "py", "rb",
                "js", "mjs", "cjs", "jsx", "ts", "tsx", "php", "pl", "sh", "zsh", "bash", "html", "htm", "css", "scss",
                "json", "yaml", "yml", "xml", "toml", "sql", "lua", "dart", "scala", "ipynb", "plist", "gradle"],
        .apps: ["app", "pkg", "mpkg", "ipa", "apk", "exe", "msi", "appx", "deb", "rpm", "xip"],
        .diskImages: ["dmg", "iso", "img", "sparseimage", "sparsebundle", "vmdk", "vdi", "qcow2", "toast", "cdr"],
    ]

    private static let kindByExtension: [String: Kind] = {
        var map: [String: Kind] = [:]
        for (kind, exts) in extensions { for ext in exts { map[ext] = kind } }
        return map
    }()

    /// Kind of a file node by its name. Names without an extension (or starting with a dot) are `other`.
    static func kind(of name: String) -> Kind {
        if name == smallFilesName { return .smallFiles }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .other }
        return kindByExtension[name[name.index(after: dot)...].lowercased()] ?? .other
    }

    /// Non-empty kinds, largest first. Empty when the tree has no file bytes.
    public static func breakdown(tree: DiskTree) -> [TypeSlice] {
        var tallies: [Kind: Tally] = [:]
        for i in 0..<tree.count where !tree.isDir[i] && tree.size[i] > 0 {
            let id = NodeID(i)
            tallies[kind(of: tree.name(id)), default: Tally()].add(id, bytes: tree.size[i])
        }
        return tallies.compactMap { kind, tally -> TypeSlice? in
            guard tally.bytes > 0 else { return nil }
            let top = tally.top.map { entry in
                TypedFile(path: displayPath(tree, entry.id, kind: kind), bytes: entry.bytes)
            }
            return TypeSlice(kind: kind, bytes: tally.bytes, count: tally.count, top: top)
        }
        .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.kind.rawValue < $1.kind.rawValue }
    }

    /// A bucket has no path of its own, so it is listed under the folder that holds it.
    private static func displayPath(_ tree: DiskTree, _ id: NodeID, kind: Kind) -> String {
        guard kind == .smallFiles, tree.parent[Int(id)] != noNode else { return tree.path(of: id) }
        return tree.path(of: tree.parent[Int(id)])
    }

    private struct Tally {
        var bytes: UInt64 = 0
        var count = 0
        var top: [(id: NodeID, bytes: UInt64)] = []

        mutating func add(_ id: NodeID, bytes b: UInt64) {
            bytes &+= b
            count += 1
            guard top.count < FileTypes.topLimit || b > top[top.count - 1].bytes else { return }
            let at = top.firstIndex { $0.bytes < b } ?? top.count
            top.insert((id, b), at: at)
            if top.count > FileTypes.topLimit { top.removeLast() }
        }
    }
}
