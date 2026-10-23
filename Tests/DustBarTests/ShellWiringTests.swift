import Foundation
import Testing
@testable import DustBar

private func cat(_ id: String, _ bytes: [UInt64]) -> CleanCategory {
    CleanCategory(id: id, title: id, detail: "", defaultSelected: false,
                  items: bytes.enumerated().map { CleanItem(path: "/h/\(id)/\($0.offset)", bytes: $0.element) })
}

@Test func scopeMapsToRoot() {
    #expect(ShellLogic.scanRoot(scope: .home, home: "/Users/x") == "/Users/x")
    #expect(ShellLogic.scanRoot(scope: .wholeDisk, home: "/Users/x") == "/System/Volumes/Data")
}

@Test func signatureChangesWithRootOrExclusions() {
    let a = ShellLogic.signature(root: "/h", excluded: ["/h/a", "/h/b"])
    #expect(a == ShellLogic.signature(root: "/h", excluded: ["/h/b", "/h/a"]))
    #expect(a != ShellLogic.signature(root: "/h", excluded: ["/h/a"]))
    #expect(a != ShellLogic.signature(root: "/System/Volumes/Data", excluded: ["/h/a", "/h/b"]))
}

@Test func cleanableBytesExcludesOverlappingCategories() {
    let cats = [cat("caches", [100, 50]), cat("trash", [25]), cat("duplicates", [1000]), cat("large", [5000])]
    #expect(ShellLogic.cleanableBytes(cats) == 175)
    #expect(ShellLogic.cleanableBytes([]) == 0)
}

@Test func normalizeDirtyKeepsOnlyPathsUnderRoot() {
    let out = ShellLogic.normalizeDirty(
        ["/Users/x/a/", "/Users/x", "/Users/x/b/./c", "/Users/xy/d", "/other/e", "relative/f", "/Users/x/a/../g"],
        root: "/Users/x/")
    #expect(out == ["/Users/x/a", "/Users/x", "/Users/x/b/c", "/Users/x/g"])
}

@Test func normalizeDirtyMapsPrivateAliases() {
    #expect(ShellLogic.normalizeDirty(["/private/var/folders/z"], root: "/var/folders") == ["/var/folders/z"])
    #expect(ShellLogic.normalizeDirty(["/var/folders/z"], root: "/private/var/folders") == ["/private/var/folders/z"])
}

@Test func cleanerStaysDeniedOutsideHomeForWholeDiskPaths() {
    let home = NSHomeDirectory()
    #expect(Rules.isDenied("/System/Volumes/Data" + home + "/Documents/a.txt", home: home))
    #expect(Rules.isDenied("/Applications/Foo.txt", home: home))
}

// MARK: Snapshot delete flow (fake runner; never calls tmutil)

private final class FakeSnaps: @unchecked Sendable {
    private let lock = NSLock()
    private var snaps: [LocalSnapshot]
    let failing: Set<String>
    private(set) var deleteCalls: [String] = []
    init(_ dates: [String], failing: Set<String> = []) {
        snaps = dates.compactMap(LocalSnapshot.init(date:))
        self.failing = failing
    }
    var ops: SnapshotOps {
        SnapshotOps(list: { [self] in lock.withLock { snaps } },
                    delete: { [self] s in
                        lock.withLock {
                            deleteCalls.append(s.date)
                            guard !failing.contains(s.date) else { return false }
                            snaps.removeAll { $0.date == s.date }
                            return true
                        }
                    })
    }
}

private let d1 = "2026-10-01-100000", d2 = "2026-10-02-100000", d3 = "2026-10-03-100000"

@Test func deleteAllRemovesEverythingOneByOne() async {
    let fake = FakeSnaps([d1, d2, d3])
    let out = await SnapshotFlow.deleteAll(ops: fake.ops, confirmed: fake.ops.list())
    #expect(out.deleted == 3 && out.failed == 0 && out.remaining.isEmpty)
    #expect(out.message == "Deleted 3 snapshots")
    #expect(fake.deleteCalls == [d1, d2, d3])
}

@Test func deleteAllReportsFailures() async {
    let fake = FakeSnaps([d1, d2, d3], failing: [d2])
    let out = await SnapshotFlow.deleteAll(ops: fake.ops, confirmed: fake.ops.list())
    #expect(out.message == "Deleted 2, 1 failed")
    #expect(out.remaining.map(\.date) == [d2])
}

@Test func deleteAllWithNothingListedDeletesNothing() async {
    let fake = FakeSnaps([])
    let out = await SnapshotFlow.deleteAll(ops: fake.ops, confirmed: fake.ops.list())
    #expect(out.message == "No local snapshots to delete" && fake.deleteCalls.isEmpty)
    #expect(SnapshotFlow.message(deleted: 1, failed: 0) == "Deleted 1 snapshot")
}

@Test func snapshotDisplay() {
    #expect(SnapshotFlow.display([]).count == 0 && SnapshotFlow.display([]).summary == nil)
    let s = SnapshotFlow.display([LocalSnapshot(date: d1)!])
    #expect(s.count == 1 && s.summary?.hasPrefix("1 local snapshot") == true)
}

@Test func deleteAllAbortsWhenListingChangedSinceConfirmation() async {
    let fake = FakeSnaps([d1, d2])
    let confirmed = fake.ops.list()
    let fresh = FakeSnaps([d1, d2, d3])               // a new snapshot appeared after the dialog count was produced
    let out = await SnapshotFlow.deleteAll(ops: fresh.ops, confirmed: confirmed)
    #expect(out.aborted && out.deleted == 0 && fresh.deleteCalls.isEmpty)
    #expect(out.message == SnapshotFlow.changedMessage && out.remaining.count == 3)
}

@Test func deleteAllActsOnlyOnConfirmedList() async {
    let fake = FakeSnaps([d1, d2])
    let out = await SnapshotFlow.deleteAll(ops: fake.ops, confirmed: fake.ops.list())
    #expect(!out.aborted && fake.deleteCalls == [d1, d2])
    let empty = await SnapshotFlow.deleteAll(ops: FakeSnaps([d1]).ops, confirmed: [])
    #expect(empty.aborted)
}
