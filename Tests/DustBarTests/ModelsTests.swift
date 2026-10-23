import Testing
@testable import DustBar

@Test func treeRollUp() {
    let t = DiskTree(rootPath: "/x")
    let d = t.add(name: "d", parent: 0, isDir: true)
    t.add(name: "f", parent: d, isDir: false, size: 10)
    t.rollUp()
    #expect(t.size[0] == 10)
    #expect(t.path(of: 2) == "/x/d/f")
}

@Test func arenaGuardStopsAtFourGigabytes() {
    #expect(DiskTree.fitsArena(Int(UInt32.max) - 3, adding: 3))
    #expect(!DiskTree.fitsArena(Int(UInt32.max) - 3, adding: 4))
    #expect(!DiskTree.fitsArena(Int(UInt32.max) + 1, adding: 0))

    let t = DiskTree(rootPath: "/x")
    let n = t.add(name: "ok", parent: 0, isDir: false, size: 1)
    #expect(t.name(n) == "ok")
    #expect(t.name(0) == "/x")
}

@MainActor @Test func liveSnapshotFlagDefaultsOff() {
    #expect(!AppModel().isLiveSnapshot)
}

@Test func dedupeKeepsEachPathInOneCategory() {
    func cat(_ id: String, _ paths: [String]) -> CleanCategory {
        CleanCategory(id: id, title: id, detail: "", defaultSelected: false,
                      items: paths.map { CleanItem(path: $0, bytes: 1) })
    }
    let out = StatusController.dedupe(
        base: [cat("caches", ["/h/c/a"])],
        duplicates: [cat("duplicates", ["/h/d/x", "/h/c/a"])],
        large: cat("large", ["/h/d/x", "/h/c/a/big.bin", "/h/big.bin"])
    )
    #expect(out.map(\.id) == ["caches", "duplicates", "large"])
    #expect(out[1].items.map(\.path) == ["/h/d/x"])
    #expect(out[2].items.map(\.path) == ["/h/big.bin"])

    let empty = StatusController.dedupe(base: [], duplicates: [cat("duplicates", ["/h/c/a"])],
                                        large: cat("large", ["/h/c/a"]))
    #expect(empty.map(\.id) == ["duplicates"])
}

private func cat(_ id: String, _ paths: [String]) -> CleanCategory {
    CleanCategory(id: id, title: id, detail: "", defaultSelected: false,
                  items: paths.map { CleanItem(path: $0, bytes: 1) })
}

@Test func dedupeDropsDuplicateNestedUnderBaseItem() {
    let out = StatusController.dedupe(
        base: [cat("caches", ["/h/c/a"])],
        duplicates: [cat("duplicates", ["/h/c/a/inner.bin", "/h/d/x"])],
        large: nil
    )
    #expect(out.first { $0.id == "duplicates" }?.items.map(\.path) == ["/h/d/x"])
}

@Test func dedupeRemovesKeptPathFromLarge() {
    let out = StatusController.dedupe(
        base: [], duplicates: [cat("duplicates", ["/h/d/copy"])], kept: ["/h/d/orig"],
        large: cat("large", ["/h/d/orig", "/h/big.bin", "/h/c/a/x"])
    )
    #expect(out.first { $0.id == "large" }?.items.map(\.path) == ["/h/big.bin", "/h/c/a/x"])
}

@Test func dedupeNeverListsPathTwice() {
    let out = StatusController.dedupe(
        base: [cat("caches", ["/h/c/a"])],
        duplicates: [cat("duplicates", ["/h/d/x", "/h/c/a/y"])],
        kept: ["/h/k"],
        large: cat("large", ["/h/d/x", "/h/k", "/h/c/a/z", "/h/other"])
    )
    let all = out.flatMap(\.items).map(\.path)
    #expect(all.count == Set(all).count)
    #expect(!out.contains { $0.items.isEmpty })
}

@MainActor @Test func cleaningFlagAndPermanentDefaultOff() {
    #expect(!AppModel().cleaning)
    #expect(!CleanResult().permanent)
}
