import Foundation
import Testing
@testable import DustBar

@Suite struct DuplicatesTests {
    /// Temp dir for one test. `cleanup` removes only this directory.
    private final class Fixture {
        let root: String

        init() throws {
            // Physical path, so Rules sees the same path the code reads (/var resolves to /private/var).
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            let temp = realpath(FileManager.default.temporaryDirectory.path, &buf) != nil
                ? String(cString: buf) : FileManager.default.temporaryDirectory.path
            root = temp + "/dustbar-dup-" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        }

        func path(_ rel: String) -> String { root + "/" + rel }

        /// Writes `data` at a root-relative path and returns its absolute path.
        @discardableResult
        func write(_ rel: String, _ data: Data) throws -> String {
            let p = path(rel)
            try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: p))
            return p
        }

        func cleanup() { try? FileManager.default.removeItem(atPath: root) }
    }

    /// Deterministic bytes.
    private func blob(_ count: Int, salt: UInt8 = 0) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 131) &+ salt })
    }

    /// Hand-built tree: one file node per entry with its real byte count, parent dirs created on demand.
    private func tree(_ root: String, _ files: [(rel: String, bytes: UInt64)]) -> DiskTree {
        let t = DiskTree(rootPath: root)
        var dirs: [String: NodeID] = [:]
        for f in files {
            let parts = f.rel.split(separator: "/").map(String.init)
            var parent: NodeID = 0
            var prefix = ""
            for dir in parts.dropLast() {
                prefix += prefix.isEmpty ? dir : "/" + dir
                if let d = dirs[prefix] {
                    parent = d
                } else {
                    parent = t.add(name: dir, parent: parent, isDir: true)
                    dirs[prefix] = parent
                }
            }
            t.add(name: parts.last ?? f.rel, parent: parent, isDir: false, size: f.bytes)
        }
        return t
    }

    @Test func reportsExtraCopiesAndKeepsOldest() async throws {
        let s = try Fixture()
        defer { s.cleanup() }
        let content = blob(300_000)
        let a = try s.write("a/one.bin", content)
        try await Task.sleep(for: .milliseconds(30))
        let b = try s.write("b/two.bin", content)
        try await Task.sleep(for: .milliseconds(30))
        let c = try s.write("c/three.bin", content)
        let t = tree(s.root, [("a/one.bin", 300_000), ("b/two.bin", 300_000), ("c/three.bin", 300_000)])

        let cats = await Duplicates.find(tree: t, minBytes: 100_000, home: s.root, roots: [])

        let cat = try #require(cats.first)
        #expect(cats.count == 1)
        #expect(cat.id == "duplicates")
        #expect(cat.title == "Duplicate files")
        #expect(!cat.defaultSelected)
        #expect(Set(cat.items.map(\.path)) == [b, c])
        #expect(!cat.items.map(\.path).contains(a))
        #expect(cat.items.allSatisfy { $0.bytes == 300_000 })
    }

    @Test func sameSizeDifferentContentIsNotDuplicate() async throws {
        let s = try Fixture()
        defer { s.cleanup() }
        let x = blob(300_000)
        var y = x
        y[150_000] ^= 0xFF  // differs only in the middle, outside the head and tail windows
        try s.write("x.bin", x)
        try s.write("y.bin", y)
        let t = tree(s.root, [("x.bin", 300_000), ("y.bin", 300_000)])

        let cats = await Duplicates.find(tree: t, minBytes: 100_000, home: s.root, roots: [])

        #expect(cats.isEmpty)
    }

    @Test func hardLinkPairIsNotCounted() async throws {
        let s = try Fixture()
        defer { s.cleanup() }
        let p = try s.write("a/one.bin", blob(300_000))
        try FileManager.default.createDirectory(atPath: s.path("b"), withIntermediateDirectories: true)
        let q = s.path("b/linked.bin")
        #expect(link(p, q) == 0)
        let t = tree(s.root, [("a/one.bin", 300_000), ("b/linked.bin", 300_000)])

        let cats = await Duplicates.find(tree: t, minBytes: 100_000, home: s.root, roots: [])

        #expect(cats.isEmpty)
    }

    @Test func belowThresholdIgnoredAboveThresholdReported() async throws {
        let s = try Fixture()
        defer { s.cleanup() }
        let small = blob(100_000)
        try s.write("a/s1.bin", small)
        try s.write("b/s2.bin", small)
        let big = blob(6_000_000)
        try s.write("a/big1.bin", big)
        try await Task.sleep(for: .milliseconds(30))
        let big2 = try s.write("b/big2.bin", big)
        let t = tree(s.root, [
            ("a/s1.bin", 100_000), ("b/s2.bin", 100_000),
            ("a/big1.bin", 6_000_000), ("b/big2.bin", 6_000_000),
        ])

        // Default threshold (5 MB): the small pair is excluded, the big pair reports its younger copy.
        let cats = await Duplicates.find(tree: t, minBytes: 5_000_000, home: s.root, roots: [])

        #expect(cats.first?.items.map(\.path) == [big2])
    }

    @Test func deniedPathsSkipped() async throws {
        let s = try Fixture()
        defer { s.cleanup() }
        let pair = blob(300_000)
        let denied = [".ssh/id1", ".ssh/id2", "Library/Foo/a.bin", "Library/Foo/b.bin",
                      "Foo.app/Contents/x.bin", "Foo.app/Contents/y.bin"]
        for rel in denied { try s.write(rel, pair) }
        try s.write("projects/x.bin", pair)
        try s.write("projects/y.bin", pair)
        let t = tree(s.root, (denied + ["projects/x.bin", "projects/y.bin"]).map { ($0, UInt64(300_000)) })

        let cats = await Duplicates.find(tree: t, minBytes: 100_000, home: s.root, roots: [])

        // Only the projects pair is considered, so exactly one redundant copy remains.
        let items = try #require(cats.first).items
        #expect(items.count == 1)
        #expect(items.allSatisfy { $0.path.hasPrefix(s.path("projects/")) })
    }

    @Test func excludedAndNestedPathsNeverOffered() async throws {
        let s = try Fixture()
        defer { s.cleanup() }
        let content = blob(300_000)
        let old = try s.write("proj/node_modules/a.bin", content)  // oldest, inside an excluded item
        try await Task.sleep(for: .milliseconds(30))
        let b = try s.write("b/two.bin", content)
        try await Task.sleep(for: .milliseconds(30))
        let c = try s.write("c/three.bin", content)
        let t = tree(s.root, [("proj/node_modules/a.bin", 300_000), ("b/two.bin", 300_000), ("c/three.bin", 300_000)])

        let r = await Duplicates.find(tree: t, minBytes: 100_000, excluding: [s.path("proj/node_modules"), c], home: s.root, roots: [])

        // a is under an excluded item, c is excluded: only b remains eligible, alone, so nothing is offered.
        #expect(r.category == nil)
        #expect(r.kept.isEmpty)
        _ = (old, b)
    }

    @Test func keptPathIsReturned() async throws {
        let s = try Fixture()
        defer { s.cleanup() }
        let content = blob(300_000)
        let a = try s.write("a/one.bin", content)
        try await Task.sleep(for: .milliseconds(30))
        let b = try s.write("b/two.bin", content)
        let t = tree(s.root, [("a/one.bin", 300_000), ("b/two.bin", 300_000)])

        let r = await Duplicates.find(tree: t, minBytes: 100_000, excluding: [], home: s.root, roots: [])

        #expect(r.kept == [a])
        #expect(r.category?.items.map(\.path) == [b])
    }

    @Test func trashAndCloudStorageSkipped() async throws {
        let s = try Fixture()
        defer { s.cleanup() }
        let content = blob(300_000)
        let kept = try s.write("docs/a.bin", content)
        try s.write(".Trash/t1.bin", content)
        try s.write("Library/CloudStorage/Drive/c1.bin", content)
        let t = tree(s.root, [("docs/a.bin", 300_000), (".Trash/t1.bin", 300_000), ("Library/CloudStorage/Drive/c1.bin", 300_000)])

        let r = await Duplicates.find(tree: t, minBytes: 100_000, excluding: [], home: s.root, roots: [])

        #expect(r.category == nil)
        #expect(r.kept.isEmpty)
        _ = kept
    }

    @Test func allCopiesAreNeverOffered() async throws {
        let s = try Fixture()
        defer { s.cleanup() }
        let content = blob(300_000)
        var rels: [(String, UInt64)] = []
        var paths: [String] = []
        for i in 0..<4 {
            paths.append(try s.write("d\(i)/f.bin", content))
            rels.append(("d\(i)/f.bin", 300_000))
            try await Task.sleep(for: .milliseconds(20))
        }
        // The oldest copy is excluded (as if the user may trash it): a surviving copy must still not be offered.
        let r = await Duplicates.find(tree: tree(s.root, rels), minBytes: 100_000, excluding: [paths[0]], home: s.root, roots: [])
        let offered = Set(r.category?.items.map(\.path) ?? [])
        #expect(!offered.isEmpty)
        #expect(offered.count < 3)
        #expect(!offered.contains(paths[0]))
        #expect(r.kept == [paths[1]])
        #expect(Set(paths).subtracting(offered).subtracting([paths[0]]).count >= 1)
    }

    @Test func cancellationReturnsPromptly() async throws {
        let s = try Fixture()
        defer { s.cleanup() }
        let content = blob(8_000_000)
        var rels: [(String, UInt64)] = []
        for i in 0..<12 {
            try s.write("d\(i)/f.bin", content)
            rels.append(("d\(i)/f.bin", 8_000_000))
        }
        let t = tree(s.root, rels)
        let root = s.root
        let task = Task { await Duplicates.find(tree: t, minBytes: 100_000, excluding: [], home: root, roots: []) }
        task.cancel()
        let started = ContinuousClock.now
        let r = await task.value
        #expect(started.duration(to: .now) < .seconds(5))
        #expect(r.category == nil)
    }
}
