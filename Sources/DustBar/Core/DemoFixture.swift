#if DUSTBAR_DEMO || DEBUG
import Foundation

/// Deterministic synthetic data for marketing screenshots. Never reads the disk; every path is under /Users/demo.
/// Compiled into demo builds and debug (test) builds only, never into the release binary.
enum DemoFixture {
    static let root = "/Users/demo"
    static let gb: UInt64 = 1_000_000_000
    static let mb: UInt64 = 1_000_000

    /// 994 GB disk, 87 GB free of which 9 GB purgeable.
    static let volume = VolumeStats(total: 994 * gb, free: 87_200_000_000, purgeable: 9 * gb)

    struct Entry: Equatable {
        let path: String      // relative to `root`
        let bytes: UInt64     // file size (leaves only)
    }

    // MARK: Seeded generator

    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {   // SplitMix64
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    private struct Builder {
        var rng = Rng(state: 0xD057_BA12)
        var out: [Entry] = []

        mutating func file(_ path: String, _ bytes: UInt64) { out.append(Entry(path: path, bytes: bytes)) }
        mutating func file(_ path: String, gb v: Double) { file(path, UInt64(v * 1e9)) }

        /// `count` files in `dir` sharing `total` bytes with seeded random weights; the last takes the remainder.
        mutating func spread(_ dir: String, count: Int, total: UInt64, name: (Int) -> String) {
            let weights = (0..<count).map { _ in 0.35 + rng.unit() * 1.3 }
            let sum = weights.reduce(0, +)
            var left = total
            for i in 0..<count {
                let b = i == count - 1 ? left : min(left, UInt64(Double(total) * weights[i] / sum))
                left -= b
                file(dir + "/" + name(i), b)
            }
        }

        mutating func spread(_ dir: String, count: Int, gb v: Double, name: (Int) -> String) {
            spread(dir, count: count, total: UInt64(v * 1e9), name: name)
        }
    }

    // MARK: File list

    /// Leaf files in depth-first order, so a prefix of the list is a plausible half-finished scan.
    static func entries() -> [Entry] {
        var b = Builder()
        let hex = Array("0123456789ABCDEF").map(String.init)

        // Movies
        let bundles: [(String, Double)] = [("Wedding 2025", 18), ("Brand Film", 14), ("Surf Trip", 11),
                                           ("Podcast Promo", 8), ("Product Demo", 6), ("Documentary", 5)]
        for (name, size) in bundles {
            let base = "Movies/Final Cut Projects/\(name).fcpbundle"
            b.spread(base + "/Original Media", count: 4, gb: size * 0.55) { "A00\($0 + 1)_C00\($0 + 2).mov" }
            b.spread(base + "/Render Files", count: 3, gb: size * 0.3) { "Render \($0 + 1).mov" }
            b.spread(base + "/Transcoded Media/High Quality Media", count: 3, gb: size * 0.14) { "Proxy \($0 + 1).mov" }
            b.file(base + "/Settings.plist", 40_000)
        }
        b.spread("Movies/Raw Footage/Sony A7S III", count: 12, gb: 24) { "C\(String(format: "%04d", 118 + $0)).mp4" }
        b.spread("Movies/Raw Footage/DJI Mavic", count: 8, gb: 12) { "DJI_\(String(format: "%04d", 40 + $0)).mov" }
        b.spread("Movies/Raw Footage/iPhone", count: 6, gb: 5) { "IMG_\(4100 + $0 * 7).mov" }
        b.spread("Movies/Exports", count: 8, gb: 15) { ["Wedding Highlight", "Brand Film v1", "Brand Film v2", "Surf Trip Cut",
                                                         "Promo 30s", "Promo 60s", "Demo Reel", "Documentary Trailer"][$0] + ".mp4" }

        // Developer
        b.spread("Developer/ios-app/Pods", count: 12, gb: 3.8) { "Pod\($0 + 1)/Pod\($0 + 1).framework" }
        b.spread("Developer/ios-app/build/Release-iphoneos", count: 4, gb: 2.2) { "ios-app\($0).app" }
        b.spread("Developer/ios-app/Assets", count: 10, gb: 1.1) { "Artwork\($0 + 1).psd" }
        b.spread("Developer/ios-app/Sources/Features", count: 14, total: 90 * mb) { "Feature\($0 + 1)View.swift" }
        b.spread("Developer/ios-app/Sources/Core", count: 8, total: 40 * mb) { "Service\($0 + 1).swift" }
        b.file("Developer/ios-app/.git/objects/pack/pack-9f3c.pack", gb: 0.9)
        b.spread("Developer/ios-app/Resources", count: 6, gb: 5.9) { "Sample\($0 + 1).mp4" }

        for i in 0..<40 {
            let pkg = ["react", "next", "webpack", "babel-core", "typescript", "lodash", "eslint", "tailwindcss", "sharp", "esbuild",
                       "swc-darwin", "prettier", "jest", "core-js", "rxjs", "date-fns", "zod", "axios", "stripe", "prisma",
                       "playwright", "vite", "rollup", "postcss", "terser", "uglify-js", "moment", "ajv", "chalk", "yargs",
                       "semver", "glob", "minimatch", "debug", "ms", "tslib", "acorn", "browserslist", "caniuse-lite", "graphql"][i]
            let big = i < 6 ? 0.55 : 0.15
            b.spread("Developer/web-shop/node_modules/\(pkg)/lib", count: 3, total: UInt64(big * 1e9 * (0.8 + b.rng.unit() * 0.4))) { "index\($0).js" }
            b.file("Developer/web-shop/node_modules/\(pkg)/(small files)", UInt64(2 + b.rng.next() % 6) * mb)
        }
        b.spread("Developer/web-shop/.next/cache", count: 6, gb: 3.4) { "webpack-\($0).pack" }
        b.spread("Developer/web-shop/public/images", count: 12, gb: 2.2) { "product-\($0 + 1).\($0 % 3 == 0 ? "png" : "jpg")" }
        b.spread("Developer/web-shop/src/components", count: 20, total: 6 * mb) { "Component\($0 + 1).tsx" }
        b.file("Developer/web-shop/.git/objects/pack/pack-77ab.pack", gb: 1.8)
        b.file("Developer/web-shop/package-lock.json", 900_000)
        b.spread("Developer/web-shop/dist", count: 5, total: 2_900 * mb) { "bundle-\($0).js.map" }

        b.spread("Developer/ml-experiments/data", count: 4, gb: 16.5) { ["train.zip", "val.zip", "embeddings.npy", "dataset.csv"][$0] }
        b.spread("Developer/ml-experiments/models", count: 6, gb: 8.9) { "checkpoint-\(($0 + 1) * 500).bin" }
        b.spread("Developer/ml-experiments/notebooks", count: 9, total: 380 * mb) { "experiment-\($0 + 1).ipynb" }
        b.spread("Developer/ml-experiments/.venv/lib/python3.12/site-packages", count: 8, gb: 2.2) { "pkg\($0).so" }

        b.spread("Developer/android-app/build/intermediates", count: 5, gb: 4.5) { "classes\($0).jar" }
        b.spread("Developer/android-app/.gradle/caches", count: 4, gb: 2.1) { "modules-\($0).bin" }
        b.spread("Developer/android-app/app/src/main", count: 12, total: 30 * mb) { "Screen\($0 + 1).kt" }
        b.file("Developer/android-app/app/release/app-release.apk", gb: 1.3)

        b.spread("Developer/old-landing-page/node_modules/framework", count: 6, gb: 2.7) { "dist\($0).js" }
        b.spread("Developer/old-landing-page/assets", count: 4, gb: 0.4) { "hero\($0 + 1).jpg" }
        b.spread("Developer/infra-tools/.terraform/providers", count: 4, gb: 1.2) { "terraform-provider-\(["aws", "gcp", "azure", "helm"][$0])" }
        b.spread("Developer/infra-tools/modules", count: 10, total: 18 * mb) { "main\($0 + 1).tf" }

        // Library
        let derived = ["ios-app", "web-shop-ios", "Podcast", "SwiftPlayground", "WidgetKit-Demo", "CameraKit"]
        for (i, name) in derived.enumerated() {
            let base = "Library/Developer/Xcode/DerivedData/\(name)-\(["abcd", "efgh", "ijkl", "mnop", "qrst", "uvwx"][i])1234"
            let weight = [8.5, 5.2, 4.1, 3.0, 2.0, 1.2][i]
            b.spread(base + "/Build/Products", count: 3, gb: weight * 0.6) { "Debug\($0).app" }
            b.spread(base + "/Index.noindex/DataStore", count: 2, gb: weight * 0.3) { "records\($0).idx" }
            b.file(base + "/Logs/Build/build.xcactivitylog", gb: weight * 0.1)
        }
        b.spread("Library/Developer/Xcode/Archives/2026-08-14", count: 2, gb: 4.8) { "ios-app \($0 + 1).xcarchive" }
        b.spread("Library/Developer/Xcode/iOS DeviceSupport", count: 3, gb: 11) { "iPhone16,2 18.\($0) (22A\($0)5)" }
        b.spread("Library/Developer/CoreSimulator/Caches/dyld", count: 3, gb: 3.6) { "dyld_shared_cache_\($0)" }
        b.spread("Library/Developer/CoreSimulator/Devices", count: 5, gb: 14) { "A1B2C3D\($0)/data.img" }

        let caches: [(String, Double)] = [("com.spotify.client", 4.2), ("Google", 3.1), ("com.apple.Safari", 1.4), ("Homebrew", 1.6),
                                          ("pip", 0.9), ("com.figma.Desktop", 1.1), ("com.tinyspeck.slackmacgap", 0.7),
                                          ("com.apple.dt.Xcode", 0.5), ("org.mozilla.firefox", 0.4)]
        for (name, size) in caches {
            b.spread("Library/Caches/\(name)", count: 3, gb: size) { "Cache\($0).db" }
        }
        b.spread("Library/Logs", count: 6, total: 1_100 * mb) { "app-\($0 + 1).log" }
        b.spread("Library/Logs/DiagnosticReports", count: 6, total: 480 * mb) { "crash-\($0 + 1).ips" }
        b.spread("Library/Application Support/Adobe", count: 5, gb: 6.8) { "Common/Media Cache/cache\($0).pek" }
        b.spread("Library/Application Support/Slack", count: 4, gb: 2.1) { "Cache/data\($0)" }
        b.spread("Library/Application Support/Code", count: 4, gb: 2.4) { "CachedData/chunk\($0).js" }
        b.file("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", gb: 31)
        b.spread("Library/Mobile Documents/com~apple~CloudDocs", count: 6, gb: 3) { "Sync\($0 + 1).pages" }

        // Pictures
        for (i, h) in hex.enumerated() {
            b.spread("Pictures/Photos Library.photoslibrary/originals/\(h)", count: 4, gb: 3.5) {
                "IMG_\(String(format: "%04d", i * 40 + $0)).\(["heic", "jpg", "mov", "heic"][$0])"
            }
            b.spread("Pictures/Photos Library.photoslibrary/resources/derivatives/\(h)", count: 2, gb: 0.75) { "thumb\($0).jpg" }
        }
        b.file("Pictures/Photos Library.photoslibrary/database/Photos.sqlite", gb: 1.8)
        b.file("Pictures/Lightroom/Catalog.lrcat", gb: 2.4)
        b.spread("Pictures/Lightroom/Catalog Previews.lrdata", count: 6, gb: 12) { "preview\($0).lrprev" }
        b.spread("Pictures/Lightroom/Catalog Smart Previews.lrdata", count: 4, gb: 3.6) { "smart\($0).dng" }
        b.spread("Pictures/Screenshots", count: 14, total: 1_200 * mb) { "Screenshot 2026-0\(1 + $0 % 9)-1\($0 % 9).png" }

        // Music
        let artists = ["Bonobo", "Khruangbin", "Four Tet", "Floating Points", "Nils Frahm", "Jon Hopkins",
                       "Tycho", "Caribou", "Jamie xx", "Mount Kimbie", "Boards of Canada", "Aphex Twin"]
        for (i, artist) in artists.enumerated() {
            b.spread("Music/Music/Media/Music/\(artist)/Album \(i + 1)", count: 4, gb: i % 3 == 0 ? 3.6 : 2.4) {
                "0\($0 + 1) Track.\(i % 3 == 0 ? "flac" : (i % 2 == 0 ? "m4a" : "mp3"))"
            }
        }
        for (i, name) in ["Night Drive", "Sketch 04", "Demo Beat", "Jam Session"].enumerated() {
            b.spread("Music/GarageBand/\(name).band/Media", count: 3, gb: 2.25) { "Audio \($0 + 1)-\(i).aif" }
        }

        // Documents
        b.spread("Documents/Archive", count: 6, gb: 20) { ["Client Backups 2022.zip", "Old Laptop Home.tar.gz", "Taxes 2019-2022.zip",
                                                            "Photos 2014.zip", "Contracts Archive.zip", "Email Export.zip"][$0] }
        b.spread("Documents/Archive/Scans", count: 12, total: 900 * mb) { "scan-\($0 + 1).pdf" }
        b.spread("Documents/Projects/Presentations", count: 6, gb: 4) { "Pitch Deck \($0 + 1).key" }
        b.spread("Documents/Projects/Reports", count: 10, gb: 2.6) { "Report Q\($0 % 4 + 1).pdf" }
        b.spread("Documents/Projects/Specs", count: 8, gb: 1.4) { "Spec \($0 + 1).docx" }
        b.spread("Documents/Projects/prototype-chat/node_modules/ws", count: 5, gb: 1.3) { "chunk\($0).js" }
        b.spread("Documents/Invoices", count: 12, total: 380 * mb) { "Invoice-2026-0\($0 + 1).pdf" }
        b.spread("Documents/Books", count: 8, gb: 4.2) { "Book \($0 + 1).\($0 % 2 == 0 ? "epub" : "pdf")" }

        // Downloads
        b.file("Downloads/Old Installers/Xcode_15.4.xip", gb: 3.2)
        b.file("Downloads/Old Installers/Install macOS Sonoma.dmg", gb: 13)
        b.file("Downloads/Old Installers/ubuntu-24.04-desktop-amd64.iso", gb: 4.6)
        b.file("Downloads/Old Installers/AdobeCreativeCloud.dmg", gb: 1.4)
        b.file("Downloads/Old Installers/Docker.dmg", gb: 0.6)
        b.file("Downloads/Old Installers/node-v18.19.0.pkg", gb: 0.04)
        b.file("Downloads/Old Installers/zoomusInstaller.pkg", gb: 0.12)
        b.file("Downloads/Old Installers/old-dataset-2021.zip", gb: 2.1)
        b.file("Downloads/Wedding Highlight (1).mp4", gb: 1.9)
        b.file("Downloads/Brand Film v2 copy.mov", gb: 2.4)
        b.file("Downloads/survey-results (1).zip", gb: 0.9)
        b.file("Downloads/Keynote Template copy.key", gb: 0.4)
        b.spread("Downloads", count: 14, total: 4_400 * mb) { "download-\($0 + 1).\(["pdf", "png", "zip", "jpg", "docx"][$0 % 5])" }

        // Desktop, Trash, dev caches
        b.spread("Desktop", count: 5, gb: 4) { $0 < 3 ? "Screen Recording \($0 + 1).mov" : "Notes \($0).png" }
        b.file(".Trash/old-project.zip", gb: 1.4)
        b.file(".Trash/Screen Recording old.mov", gb: 1.1)
        b.spread(".Trash/renders", count: 3, gb: 0.7) { "render\($0).mov" }
        for h in hex.prefix(8) {
            b.spread(".npm/_cacache/content-v2/sha512/\(h.lowercased())a", count: 2, gb: 0.36) { "blob\($0)" }
        }
        b.spread(".cache/pip", count: 3, gb: 0.9) { "wheel\($0).whl" }
        return b.out
    }

    // MARK: Tree

    /// The tree for the first `fraction` of the leaves (1 = complete). The leaf at the cut is scaled so growth looks continuous.
    static func tree(fraction: Double = 1) -> DiskTree {
        let all = entries()
        let f = min(max(fraction, 0), 1)
        let exact = Double(all.count) * f
        let whole = Int(exact)
        let tree = DiskTree(rootPath: root)
        var dirs: [String: NodeID] = ["": 0]
        func dir(_ comps: ArraySlice<Substring>) -> NodeID {
            let key = comps.joined(separator: "/")
            if let id = dirs[key] { return id }
            let id = tree.add(name: String(comps.last!), parent: dir(comps.dropLast()), isDir: true)
            dirs[key] = id
            return id
        }
        for (i, e) in all.enumerated() where i <= whole && (i < whole || exact > Double(whole)) {
            let comps = e.path.split(separator: "/")
            let parent = dir(comps.dropLast())
            let bytes = i < whole ? e.bytes : UInt64(Double(e.bytes) * (exact - Double(whole)))
            tree.add(name: String(comps.last!), parent: parent, isDir: false, size: bytes)
        }
        tree.rollUp()
        tree.compact()
        return tree
    }

    /// Directory sizes by absolute path.
    static func dirSizes(_ tree: DiskTree) -> [String: UInt64] {
        var out: [String: UInt64] = [:]
        for i in 0..<tree.count where tree.isDir[i] { out[tree.path(of: NodeID(i))] = tree.size[i] }
        return out
    }

    // MARK: Clean categories

    static func categories(tree: DiskTree) -> [CleanCategory] {
        let sizes = dirSizes(tree)
        var files: [String: UInt64] = [:]
        for i in 0..<tree.count where !tree.isDir[i] { files[tree.path(of: NodeID(i))] = tree.size[i] }
        func abs(_ rel: String) -> String { root + "/" + rel }
        func item(_ rel: String) -> CleanItem? {
            let p = abs(rel)
            guard let b = sizes[p] ?? files[p], b > 0 else { return nil }
            return CleanItem(path: p, bytes: b)
        }
        func children(_ rel: String, skip: Set<String> = []) -> [CleanItem] {
            let prefix = abs(rel) + "/"
            let all = Set(sizes.keys).union(files.keys)
            return all.filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") && !skip.contains(String($0.dropFirst(prefix.count))) }
                .sorted().compactMap { item(String($0.dropFirst(root.count + 1))) }
        }
        func make(_ id: String, _ title: String, _ detail: String, _ selected: Bool, _ items: [CleanItem]) -> CleanCategory {
            CleanCategory(id: id, title: title, detail: detail, defaultSelected: selected,
                          items: items.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path })
        }
        let devRoots = [".npm/_cacache", "Library/Caches/Homebrew", ".cache/pip", "Library/Caches/pip"]
        let base = [
            make("caches", "Caches", "App caches in ~/Library/Caches. Apps rebuild them.", true,
                 children("Library/Caches", skip: ["Homebrew", "pip"])),
            make("trash", "Trash", "Items already in the Trash. Emptying is permanent.", false, children(".Trash")),
            make("xcode", "Xcode data", "DerivedData and Archives.", false,
                 children("Library/Developer/Xcode/DerivedData") + children("Library/Developer/Xcode/Archives")),
            make("simulators", "Simulator caches", "CoreSimulator caches and iOS DeviceSupport untouched for 90+ days.", false,
                 children("Library/Developer/CoreSimulator/Caches") + children("Library/Developer/Xcode/iOS DeviceSupport")),
            make("devcaches", "Dev tool caches", "npm, pip, cargo and Homebrew caches. Re-downloadable.", false,
                 devRoots.compactMap(item)),
            make("logs", "Logs and crash reports", "Logs and crash reports untouched for 30+ days.", false,
                 children("Library/Logs", skip: ["DiagnosticReports"]) + children("Library/Logs/DiagnosticReports")),
            make("node_modules", "node_modules", "Dependencies of projects untouched for 30+ days. Reinstall to restore.", false,
                 ["Developer/web-shop/node_modules", "Developer/old-landing-page/node_modules",
                  "Documents/Projects/prototype-chat/node_modules"].compactMap(item)),
            make("downloads", "Old Downloads", "Downloads not used or changed in 90+ days.", false, children("Downloads/Old Installers")),
        ]
        let dupes = make("duplicates", "Duplicate files", "Identical copies of the same file. The oldest copy of each set is kept.", false,
                         ["Downloads/Wedding Highlight (1).mp4", "Downloads/Brand Film v2 copy.mov",
                          "Downloads/survey-results (1).zip", "Downloads/Keynote Template copy.key"].compactMap(item))
        let big = files.filter { $0.value >= 2 * gb && !$0.key.hasPrefix(abs("Library/")) && !$0.key.contains(".photoslibrary/") }
            .map { CleanItem(path: $0.key, bytes: $0.value) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }.prefix(7)
        let large = CleanCategory(id: "large", title: "Large files", detail: "Files over 1 GB outside Library.",
                                  defaultSelected: false, items: Array(big))
        // Caches (the preselected category, 11.4 GB) pinned first so the capture explains the footer's "Selected" total.
        // The rest keep the real app's size order.
        return StatusController.dedupe(base: base.filter { !$0.items.isEmpty }, duplicates: [dupes], large: large)
            .sorted { a, b in
                if (a.id == "caches") != (b.id == "caches") { return a.id == "caches" }
                return a.bytes != b.bytes ? a.bytes > b.bytes : a.id < b.id
            }
    }

    // MARK: History

    /// Eight records ending yesterday, oldest 28 days back, with the headline folders growing the most.
    static func history(tree: DiskTree, now: Date) -> [History.Record] {
        let current = History.dirSizes(tree)
        let boost: [String: Double] = [
            root + "/Library/Developer/Xcode": 0.34, root + "/Library/Developer": 0.30, root + "/Movies/Final Cut Projects": 0.22,
            root + "/Movies": 0.14, root + "/Developer": 0.22, root + "/Library": 0.12,
            root + "/Developer/ml-experiments": 0.38, root + "/Library/Containers": 0.18, root + "/Developer/ml-experiments/models": 0.5,
            root + "/Downloads": 0.14, root + "/Pictures/Photos Library.photoslibrary": 0.06,
            root + "/Developer/web-shop": 0.15, root + "/Library/Caches": 0.25, root + "/Music": 0.04,
        ]
        var rng = Rng(state: 0x4157_0123)
        var growth: [String: Double] = [:]
        for path in current.keys.sorted() {
            let r = rng.unit()
            growth[path] = boost[path] ?? (r < 0.5 ? 0 : r * 0.05)
        }
        let days: [Double] = [28, 24, 20, 16, 12, 8, 4, 1]
        return days.enumerated().map { i, d in
            let progress = Double(i) / Double(days.count - 1)
            var dirs: [String: UInt64] = [:]
            for (path, bytes) in current {
                dirs[path] = UInt64(Double(bytes) / (1 + (growth[path] ?? 0) * (1 - progress)))
            }
            let total = dirs.filter { $0.key.dropFirst(root.count + 1).contains("/") == false }.values.reduce(0, +)
            return History.Record(date: now.addingTimeInterval(-d * 86_400), root: root, rootBytes: total, dirs: dirs)
        }
    }

    // MARK: Snapshots

    static func snapshotOps(now: Date = .now) -> SnapshotOps {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let snaps = [30, 22, 6].compactMap { hours in LocalSnapshot(date: f.string(from: now.addingTimeInterval(-Double(hours) * 3600))) }
        return SnapshotOps(list: { snaps }, delete: { _ in false })
    }
}
#endif
