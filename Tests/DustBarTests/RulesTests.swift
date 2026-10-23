import Foundation
import Testing
@testable import DustBar

/// Scratch tree under the physical temp dir. Removes only what it created: single files/links, then empty dirs.
final class Scratch {
    let root: String
    private var files: [String] = []
    private var dirs: [String] = []

    init() throws {
        root = Scratch.physicalTempDir() + "/dustbar-test-" + UUID().uuidString
        try ensureDir(root)
    }

    /// /var resolves to /private/var; the root must be physical so the checks see the same path the code acts on.
    private static func physicalTempDir() -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(FileManager.default.temporaryDirectory.path, &buf) != nil else {
            return FileManager.default.temporaryDirectory.path
        }
        return String(cString: buf)
    }

    private func ensureDir(_ path: String) throws {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try ensureDir((path as NSString).deletingLastPathComponent)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        dirs.append(path)
    }

    @discardableResult
    func file(_ rel: String, bytes: Int = 65_536, modified: Date? = nil) throws -> String {
        let path = root + "/" + rel
        try ensureDir((path as NSString).deletingLastPathComponent)
        FileManager.default.createFile(atPath: path, contents: Data(count: bytes))
        files.append(path)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path) }
        return path
    }

    func dir(_ rel: String, modified: Date? = nil) throws -> String {
        let path = root + "/" + rel
        try ensureDir(path)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path) }
        return path
    }

    func link(_ rel: String, to target: String) throws -> String {
        let path = root + "/" + rel
        try ensureDir((path as NSString).deletingLastPathComponent)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        files.append(path)
        return path
    }

    func cleanup() {
        for f in files.reversed() { try? FileManager.default.removeItem(atPath: f) }
        for d in dirs.reversed() { _ = rmdir(d) }
    }
}

@Suite(.serialized) struct RulesTests {
    private let home = "/Users/tester"

    @Test func deniesSystemAndAppPaths() {
        let paths = [
            "/System/Library/CoreServices", "/usr/bin/env", "/bin/sh", "/sbin/mount", "/private/etc/hosts",
            "/Library/Caches/x", "/Applications/Safari.app", "/Users/tester/Applications/Foo.app/Contents/Info.plist",
            "/Users/tester/Downloads/Thing.app",
        ]
        for p in paths { #expect(Rules.isDenied(p, home: home), "\(p) should be denied") }
    }

    @Test func deniesHomeRootsAndPrivateSubtrees() {
        let paths = [
            home, home + "/", home + "/Library", home + "/.Trash",
            home + "/Library/Keychains/login.keychain-db", home + "/Library/Mail/V10",
            home + "/Library/Mobile Documents/iCloud~x", home + "/Library/Messages/chat.db",
            home + "/Library/Application Support/Foo", home + "/Music", home + "/Music/Music/Library.musiclibrary",
            home + "/Pictures/Photos.photoslibrary", home + "/Library/Containers/app/x",
        ]
        for p in paths { #expect(Rules.isDenied(p, home: home), "\(p) should be denied") }
    }

    @Test func deniesCloudAndPrivateLibrarySubtrees() {
        for sub in ["CloudStorage", "Safari", "Cookies", "Calendars"] {
            #expect(Rules.isDenied(home + "/Library/" + sub, home: home), "\(sub) should be denied")
            #expect(Rules.isDenied(home + "/Library/" + sub + "/x/y.bin", home: home), "\(sub) child should be denied")
        }
    }

    @Test func deniesExactHomeRoots() {
        let roots = [
            "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", ".ssh", ".gnupg", ".aws",
            "Library/Caches", "Library/Developer", "Library/Logs",
        ]
        for r in roots {
            #expect(Rules.isDenied(home + "/" + r, home: home), "~/\(r) should be denied")
            #expect(Rules.isDenied(home + "/" + r + "/", home: home), "~/\(r)/ should be denied")
        }
    }

    @Test func allowsChildrenOfExactRoots() {
        for p in [home + "/Downloads/old.zip", home + "/Downloads/Old Folder/x", home + "/Desktop/proj/node_modules",
                  home + "/Documents/a.txt", home + "/Library/Caches/com.foo/blob",
                  home + "/Library/Developer/Xcode/DerivedData/App-abc/Build.bin"] {
            #expect(!Rules.isDenied(p, home: home), "\(p) should be allowed")
        }
    }

    @Test func deniesCredentialSubtrees() {
        for p in [home + "/.ssh", home + "/.ssh/id_ed25519", home + "/.aws/credentials", home + "/.gnupg/x", home + "/.SSH/ID_RSA"] {
            #expect(Rules.isDenied(p, home: home), "\(p) should be denied")
        }
    }

    @Test func deniesOutsideHome() {
        for p in ["/opt/data/x", "/Users/other/Documents/a.txt", "relative/path", "/Users/tester2/Caches/x"] {
            #expect(Rules.isDenied(p, home: home), "\(p) should be denied")
        }
    }

    @Test func allowsCachesAndDocuments() {
        for p in [home + "/Library/Caches/com.foo/blob", home + "/Documents/a.txt", home + "/Downloads/x.zip",
                  home + "/Desktop/proj/node_modules", home + "/.npm/_cacache/x"] {
            #expect(!Rules.isDenied(p, home: home), "\(p) should be allowed")
        }
    }

    @Test func caseInsensitiveDenials() {
        let denied = [
            "/USERS/TESTER/library/keychains/login.keychain-db", "/Users/Tester/LIBRARY", "/Users/TESTER/DESKTOP",
            "/users/tester/library/caches", "/Users/tester/MUSIC/x", "/Users/Tester/Downloads/Thing.APP",
            "/Users/tester/Pictures/Photos.PHOTOSLIBRARY", "/users/tester/.TRASH", "/SYSTEM/Library/CoreServices",
            "/Applications/SAFARI.app",
        ]
        for p in denied { #expect(Rules.isDenied(p, home: home), "\(p) should be denied") }
    }

    @Test func caseInsensitiveAllows() {
        #expect(!Rules.isDenied("/USERS/TESTER/Documents/a.txt", home: "/users/tester"))
        #expect(!Rules.isDenied("/Users/tester/library/caches/com.FOO/blob", home: home))
        #expect(!Rules.isDenied("/users/tester/downloads/old.zip", home: "/USERS/Tester"))
    }

    @Test func normalizesUnicodeBeforeComparing() {
        // Decomposed (NFD) and precomposed (NFC) spellings of the same name must compare equal.
        let nfc = "/Users/Jos\u{00E9}"
        let nfd = "/Users/Jose\u{0301}"
        #expect(Rules.isDenied(nfd + "/Desktop", home: nfc))
        #expect(!Rules.isDenied(nfc + "/Documents/a.txt", home: nfd))
    }

    @Test func normalizesTraversalBeforeChecking() {
        #expect(Rules.isDenied(home + "/Documents/../../../System/Library", home: home))
        #expect(Rules.isDenied(home + "/Documents/../../../../usr/bin/env", home: home))
        #expect(Rules.isDenied(home + "/Documents/../Library/Keychains/x", home: home))
        #expect(Rules.isDenied(home + "/Library/Caches/../Keychains/x", home: home))
        #expect(!Rules.isDenied(home + "/Library/Caches/../Caches/com.foo", home: home))
    }

    @Test func refusesSymlinksThatEscape() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        let fakeHome = s.root + "/home"
        _ = try s.dir("home")
        _ = try s.link("home/sys", to: "/System")
        _ = try s.link("home/keys", to: fakeHome + "/Library/Keychains")
        _ = try s.file("home/Documents/a.txt")
        _ = try s.link("home/docs", to: fakeHome + "/Documents")
        #expect(Rules.isDenied(fakeHome + "/sys/Library", home: fakeHome))
        #expect(Rules.isDenied(fakeHome + "/keys/login.keychain-db", home: fakeHome))
        #expect(Rules.isDenied(fakeHome + "/docs/../sys/Library", home: fakeHome))
        #expect(Rules.isDenied(fakeHome + "/docs", home: fakeHome))
        #expect(!Rules.isDenied(fakeHome + "/docs/a.txt", home: fakeHome))
    }

    @Test func extraRootsWidenOnlyWhenPassed() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        let other = "/Users/nobody-dustbar"
        let ok = try s.file("scratch/a.txt")
        let keys = try s.file("Library/Keychains/k")
        #expect(Rules.isDenied(ok, home: other))
        #expect(!Rules.isDenied(ok, home: other, roots: [s.root]))
        #expect(Rules.isDenied(keys, home: other, roots: [s.root]))
        #expect(Rules.isDenied(s.root, home: other, roots: [s.root]))
    }

    @Test func discoverBuildsCategoriesOnFakeHome() async throws {
        let s = try Scratch()
        defer { s.cleanup() }
        let h = s.root
        let now = Date()
        let old = now.addingTimeInterval(-120 * 86_400)

        try s.file("Library/Caches/com.one/blob.bin")
        try s.file("Library/Caches/com.two/x")
        try s.file("Library/Caches/Homebrew/bottle.tar")
        try s.file(".Trash/old.dmg")
        try s.file("Library/Developer/Xcode/DerivedData/App-abc/Build.bin")
        try s.file(".npm/_cacache/content.bin")
        try s.file("Downloads/old.zip", modified: old)
        try s.file("Downloads/new.zip", modified: now)
        try s.file("Desktop/proj/node_modules/pkg/index.js")
        _ = try s.dir("Desktop/proj", modified: now.addingTimeInterval(-60 * 86_400))
        try s.file("Desktop/fresh/node_modules/pkg/index.js")

        let cats = Rules.categories(home: h)
        let byID = Dictionary(uniqueKeysWithValues: cats.map { ($0.id, $0) })
        for id in ["caches", "trash", "xcode", "devcaches", "node_modules", "downloads"] {
            #expect(byID[id] != nil, "missing category \(id)")
        }
        #expect(byID["large"] == nil, "large files come from the tree, not discovery")
        #expect(byID["caches"]?.defaultSelected == true)
        #expect(byID["trash"]?.defaultSelected == false)
        #expect(byID["xcode"]?.defaultSelected == false)
        #expect(byID["devcaches"]?.defaultSelected == false)
        #expect(byID["node_modules"]?.defaultSelected == false)
        #expect(byID["downloads"]?.defaultSelected == false)

        let caches = Set(byID["caches"]?.items.map(\.path) ?? [])
        #expect(caches.contains(h + "/Library/Caches/com.one"))
        #expect(!caches.contains(h + "/Library/Caches/Homebrew"))
        let devPaths = Set(byID["devcaches"]?.items.map(\.path) ?? [])
        #expect(devPaths.contains(h + "/Library/Caches/Homebrew"))
        #expect(devPaths.contains(h + "/.npm/_cacache"))
        #expect(byID["node_modules"]?.items.map(\.path) == [h + "/Desktop/proj/node_modules"])
        #expect(byID["downloads"]?.items.map(\.path) == [h + "/Downloads/old.zip"])

        #expect(cats.allSatisfy { !$0.items.isEmpty && $0.bytes > 0 })
        #expect(cats.map(\.bytes) == cats.map(\.bytes).sorted(by: >))
        #expect(cats.flatMap { $0.items }.allSatisfy { !Rules.isDenied($0.path, home: h) })
    }

    @Test func staleNodeModulesUsesNewestProjectSignal() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        let now = Date()
        let old = now.addingTimeInterval(-120 * 86_400)
        let projects = ["packageJson", "yarnLock", "gitHead", "stale"]
        for p in projects { try s.file("Developer/\(p)/node_modules/pkg/index.js") }
        try s.file("Developer/packageJson/package.json", modified: now)
        try s.file("Developer/yarnLock/yarn.lock", modified: now)
        try s.file("Developer/gitHead/.git/HEAD", modified: now)
        // Backdate project dirs last: creating children would otherwise reset their mtime.
        for p in projects { _ = try s.dir("Developer/\(p)", modified: old) }

        let cats = Rules.categories(home: s.root)
        let nm = cats.first { $0.id == "node_modules" }
        #expect(nm?.items.map(\.path) == [s.root + "/Developer/stale/node_modules"])
    }

    @Test func largeFilesComeFromTreeAndSkipDeniedPaths() {
        let home = "/Users/tester"
        let t = DiskTree(rootPath: home)
        let docs = t.add(name: "Documents", parent: 0, isDir: true)
        t.add(name: "big.bin", parent: docs, isDir: false, size: 2_000)
        t.add(name: "(small files)", parent: docs, isDir: false, size: 5_000)     // fold node, never a file
        t.add(name: "folder.bin", parent: docs, isDir: true, size: 9_000)         // directories are not files
        let lib = t.add(name: "Library", parent: 0, isDir: true)
        t.add(name: "huge.bin", parent: lib, isDir: false, size: 9_000)           // outside Library only
        let ssh = t.add(name: ".ssh", parent: 0, isDir: true)
        t.add(name: "id_key", parent: ssh, isDir: false, size: 9_000)             // denylisted subtree
        let app = t.add(name: "Foo.app", parent: 0, isDir: true)
        t.add(name: "bin", parent: app, isDir: false, size: 9_000)                // app bundle

        let cat = Rules.largeFiles(from: t, home: home, minBytes: 1_000)
        #expect(cat?.id == "large")
        #expect(cat?.defaultSelected == false)
        #expect(cat?.items.map(\.path) == [home + "/Documents/big.bin"])
        #expect(cat?.items.map(\.bytes) == [2_000])
    }

    @Test func largeFilesUseOneGigabyteByDefaultAndReturnNilWhenEmpty() {
        let home = "/Users/tester"
        let t = DiskTree(rootPath: home)
        t.add(name: "under.bin", parent: 0, isDir: false, size: 999_999_999)
        t.add(name: "over.bin", parent: 0, isDir: false, size: 1_500_000_000)
        #expect(Rules.largeFiles(from: t, home: home)?.items.map(\.path) == [home + "/over.bin"])

        let none = DiskTree(rootPath: home)
        none.add(name: "small.bin", parent: 0, isDir: false, size: 10)
        #expect(Rules.largeFiles(from: none, home: home) == nil)
    }

    @Test func discoverSkipsEmptyHome() async throws {
        let s = try Scratch()
        defer { s.cleanup() }
        #expect(Rules.categories(home: s.root).isEmpty)
        #expect(await Rules.discover(home: s.root).isEmpty)
    }
}
