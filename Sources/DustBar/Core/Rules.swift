import Foundation

// Slice C owns this file.
public enum Rules {
    /// Absolute prefixes never touched. Checked on the lexical path, and on the physical path outside any allowed root.
    private static let systemDenied = ["/System", "/usr", "/bin", "/sbin", "/private", "/Library", "/Applications"]
    /// Denied subtrees under each allowed root (home or test root). Children included.
    private static let rootDeniedSubtrees = [
        "Library/Keychains", "Library/Mail", "Library/Mobile Documents", "Library/Messages",
        "Library/Application Support", "Library/Containers", "Library/Group Containers",
        "Library/Preferences", "Music", ".ssh", ".gnupg", ".aws",
    ]
    /// Denied only when the path is exactly this root-relative location ("" is the root). Children stay allowed.
    private static let rootDeniedExact = [
        "", "Library", ".Trash",
        "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
        "Library/Caches", "Library/Developer", "Library/Logs",
    ]

    /// True unless `path` resolves strictly inside `home` or one of `roots` and is clear of the denylist.
    /// Both the lexical and the symlink-resolved (physical) forms are checked. Production passes no `roots`.
    public static func isDenied(_ path: String, home: String = NSHomeDirectory(), roots: [String] = []) -> Bool {
        denied(path, home: home, roots: roots, exact: true)
    }

    /// `exact: false` is the traversal check: a root-level folder such as ~/Documents is itself denied but must stay walkable.
    private static func denied(_ path: String, home: String, roots: [String], exact: Bool) -> Bool {
        guard path.hasPrefix("/") else { return true }
        let lex = key(lexical(path))
        let phys = key(physical(path))
        if [lex, phys].contains(where: { $0.split(separator: "/").contains { $0.hasSuffix(".app") || $0.hasSuffix(".photoslibrary") } }) {
            return true
        }
        var matched: [(lex: String, phys: String)] = []
        for root in [home] + roots {
            let r = (lex: key(lexical(root)), phys: key(physical(root)))
            if strictlyWithin(lex, r.lex) && strictlyWithin(phys, r.phys) { matched.append(r) }
        }
        guard !matched.isEmpty else { return true }
        for sys in systemDenied.map(key) where within(lex, sys) || within(phys, sys) {
            // A root that itself sits under a system prefix (a temp dir under /private) is not a system path.
            if !matched.contains(where: { within($0.lex, sys) || within($0.phys, sys) }) { return true }
        }
        for r in matched {
            for sub in rootDeniedSubtrees.map(key) where within(lex, r.lex + "/" + sub) || within(phys, r.phys + "/" + sub) {
                return true
            }
            guard exact else { continue }
            for sub in rootDeniedExact.map(key) {
                let l = sub.isEmpty ? r.lex : r.lex + "/" + sub
                let p = sub.isEmpty ? r.phys : r.phys + "/" + sub
                if lex == l || phys == p { return true }
            }
        }
        return false
    }

    /// Scans home for cleanable categories. Read-only. Empty categories are dropped; sorted by bytes desc.
    public static func discover(home: String) async -> [CleanCategory] {
        await Task.detached(priority: .utility) {
            Rules.categories(home: home, largeThreshold: 1_000_000_000)
        }.value
    }

    static func categories(home rawHome: String, largeThreshold: UInt64, folderBudget: Int = 100_000) -> [CleanCategory] {
        let home = lexical(rawHome)
        let now = Date()
        var cats: [CleanCategory] = []
        func add(_ id: String, _ title: String, _ detail: String, _ selected: Bool, _ items: [CleanItem]) {
            let kept = items.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
            guard !kept.isEmpty else { return }
            cats.append(CleanCategory(id: id, title: title, detail: detail, defaultSelected: selected, items: kept))
        }

        // Tool caches: each root is one item. Excluded from ~/Library/Caches so no path appears twice.
        let devRoots = [".npm/_cacache", "Library/Caches/Homebrew", ".cache/pip", ".cargo/registry/cache", "Library/Caches/pip"]
            .map { home + "/" + $0 }
        let devItems = devRoots.filter { entry($0)?.isDir == true }.map { CleanItem(path: $0, bytes: allocatedSize($0)) }

        add("caches", "Caches", "App caches in ~/Library/Caches. Apps rebuild them.", true,
            topLevel(home + "/Library/Caches", skip: Set(devRoots)))
        add("trash", "Trash", "Items already in the Trash. Emptying is permanent.", false, topLevel(home + "/.Trash"))
        add("xcode", "Xcode data", "DerivedData, Archives and iOS DeviceSupport.", false,
            ["Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives", "Library/Developer/Xcode/iOS DeviceSupport"]
                .flatMap { topLevel(home + "/" + $0) })
        add("devcaches", "Dev tool caches", "npm, pip, cargo and Homebrew caches. Re-downloadable.", false, devItems)

        var nodeModules: [CleanItem] = []
        let cutoff30 = now.addingTimeInterval(-30 * 86_400)
        for sub in ["Desktop", "Documents", "Developer", "Projects"] {
            findNodeModules(in: home + "/" + sub, depth: 1, cutoff: cutoff30, out: &nodeModules)
        }
        add("node_modules", "node_modules", "Dependencies of projects untouched for 30+ days. Reinstall to restore.", false, nodeModules)

        let cutoff90 = now.addingTimeInterval(-90 * 86_400)
        var downloads: [CleanItem] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: home + "/Downloads")) ?? [] {
            let p = home + "/Downloads/" + name
            guard let e = entry(p), !e.isLink else { continue }
            let last = [e.modified, e.accessed].compactMap { $0 }.max()
            if let last, last < cutoff90 { downloads.append(CleanItem(path: p, bytes: allocatedSize(p))) }
        }
        add("downloads", "Old Downloads", "Downloads not used or changed in 90+ days.", false, downloads)

        let claimed = cats.flatMap { $0.items.map(\.path) }
        var large: [CleanItem] = []
        findLargeFiles(home: home, threshold: largeThreshold, folderBudget: folderBudget, out: &large)
        large = large.filter { item in !claimed.contains { within(key(item.path), key($0)) } }
        add("large", "Large files", "Files over 1 GB outside Library.", false, large)

        return cats.sorted { $0.bytes > $1.bytes }
    }

    // MARK: - Discovery helpers

    private static func findNodeModules(in dir: String, depth: Int, cutoff: Date, out: inout [CleanItem]) {
        guard depth <= 6, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        // A project is active if any of these changed recently. The directory mtime alone misses edits to existing files.
        let lastActive = names.contains("node_modules")
            ? [dir, dir + "/package.json", dir + "/package-lock.json", dir + "/yarn.lock", dir + "/pnpm-lock.yaml", dir + "/.git/HEAD"]
                .compactMap { entry($0)?.modified }.max()
            : nil
        for name in names where !name.hasPrefix(".") {
            let p = dir + "/" + name
            guard let e = entry(p), e.isDir, !e.isLink else { continue }
            if name == "node_modules" {
                if let m = lastActive, m < cutoff { out.append(CleanItem(path: p, bytes: allocatedSize(p))) }
            } else if depth < 6 {
                findNodeModules(in: p, depth: depth + 1, cutoff: cutoff, out: &out)
            }
        }
    }

    /// Large-file scan, one top-level folder at a time, breadth-first, each with its own entry budget.
    /// A big folder cannot starve the others, and shallow files are seen before a budget runs out.
    private static func findLargeFiles(home: String, threshold: UInt64, folderBudget: Int, out: inout [CleanItem]) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? [] where name != "Library" && name != ".Trash" {
            let top = home + "/" + name
            guard let e = entry(top), !e.isLink else { continue }
            if !e.isDir {
                if e.size >= threshold { out.append(CleanItem(path: top, bytes: e.size)) }
                continue
            }
            guard !denied(top, home: home, roots: [], exact: false) else { continue }
            var queue: [(dir: String, depth: Int)] = [(top, 0)]
            var head = 0
            var budget = folderBudget
            while head < queue.count && budget > 0 {
                let (dir, depth) = queue[head]
                head += 1
                guard depth <= 12, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
                for child in names {
                    budget -= 1
                    if budget <= 0 { break }
                    let p = dir + "/" + child
                    guard let ce = entry(p), !ce.isLink else { continue }
                    if ce.isDir {
                        if !denied(p, home: home, roots: [], exact: false) { queue.append((p, depth + 1)) }
                    } else if ce.size >= threshold {
                        out.append(CleanItem(path: p, bytes: ce.size))
                    }
                }
            }
        }
    }

    private static func topLevel(_ dir: String, skip: Set<String> = []) -> [CleanItem] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.compactMap { name in
            let p = dir + "/" + name
            guard !skip.contains(p) else { return nil }
            return CleanItem(path: p, bytes: allocatedSize(p))
        }
    }

    /// Allocated bytes of a file or tree. Symlinks are never followed and count as 0.
    private static func allocatedSize(_ path: String) -> UInt64 {
        guard let e = entry(path), !e.isLink else { return 0 }
        if !e.isDir { return e.size }
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: Array(entryKeys),
                                                      options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in en {
            guard let s = entry(url: url) else { continue }
            if s.isLink {
                if s.isDir { en.skipDescendants() }
                continue
            }
            if !s.isDir { total &+= s.size }
        }
        return total
    }

    private struct Entry {
        var isDir: Bool
        var isLink: Bool
        var size: UInt64
        var modified: Date?
        var accessed: Date?
    }

    private static let entryKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .contentAccessDateKey,
    ]

    private static func entry(_ path: String) -> Entry? { entry(url: URL(fileURLWithPath: path)) }

    private static func entry(url: URL) -> Entry? {
        guard let v = try? url.resourceValues(forKeys: entryKeys) else { return nil }
        return Entry(isDir: v.isDirectory ?? false, isLink: v.isSymbolicLink ?? false,
                     size: UInt64(max(0, v.totalFileAllocatedSize ?? 0)),
                     modified: v.contentModificationDate, accessed: v.contentAccessDate)
    }

    // MARK: - Path normalization

    /// Lexical normalization: drops "." and resolves ".." textually.
    static func lexical(_ path: String) -> String {
        var out: [Substring] = []
        for c in path.split(separator: "/") {
            if c == "." { continue }
            if c == ".." { _ = out.popLast(); continue }
            out.append(c)
        }
        return "/" + out.joined(separator: "/")
    }

    /// Physical path: resolves symlinks component by component, so ".." after a link follows the link target.
    /// Returns "/" (always denied) when a symlink loop is detected.
    static func physical(_ path: String) -> String {
        var resolved: [String] = []
        var pending = path.split(separator: "/").map(String.init)
        var hops = 0
        while !pending.isEmpty {
            let c = pending.removeFirst()
            if c.isEmpty || c == "." { continue }
            if c == ".." { _ = resolved.popLast(); continue }
            resolved.append(c)
            let current = "/" + resolved.joined(separator: "/")
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else { continue }
            hops += 1
            if hops > 255 { return "/" }
            resolved.removeLast()
            if dest.hasPrefix("/") { resolved = [] }
            pending = dest.split(separator: "/").map(String.init) + pending
        }
        return "/" + resolved.joined(separator: "/")
    }

    /// Physical parent directory plus the lexical last component, joined once. Acting on this exact string
    /// means the path that was checked is the path that is used. The final component is not resolved, so a
    /// symlink is acted on as a link. Nil for "/" and relative paths.
    static func resolvedChild(_ path: String) -> (dir: String, name: String, path: String)? {
        guard path.hasPrefix("/") else { return nil }
        let lex = lexical(path)
        guard lex != "/", let cut = lex.lastIndex(of: "/") else { return nil }
        let dir = physical(String(lex[..<cut]))
        let name = String(lex[lex.index(after: cut)...])
        return (dir, name, (dir == "/" ? "" : dir) + "/" + name)
    }

    /// Case-insensitive, Unicode-normalized form used for every comparison (APFS is case-insensitive, case-preserving).
    private static func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }

    /// Both arguments must already be keyed.
    private static func within(_ p: String, _ base: String) -> Bool { p == base || p.hasPrefix(base + "/") }
    private static func strictlyWithin(_ p: String, _ base: String) -> Bool { p != base && p.hasPrefix(base + "/") }
}
