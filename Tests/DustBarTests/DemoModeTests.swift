import Foundation
import Testing
@testable import DustBar

private func signature(_ t: DiskTree) -> [String] {
    (0..<t.count).map { "\(t.path(of: NodeID($0))):\(t.size[$0]):\(t.isDir[$0])" }
}

@Test func demoFixtureIsDeterministic() {
    let a = DemoFixture.tree(), b = DemoFixture.tree()
    #expect(signature(a) == signature(b))
    #expect(DemoFixture.entries() == DemoFixture.entries())
    let ca = DemoFixture.categories(tree: a), cb = DemoFixture.categories(tree: b)
    #expect(ca.map(\.id) == cb.map(\.id))
    #expect(ca.map { $0.items.map(\.path) } == cb.map { $0.items.map(\.path) })
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(DemoFixture.history(tree: a, now: now) == DemoFixture.history(tree: b, now: now))
}

@Test func demoFixtureShapeAndPaths() {
    let t = DemoFixture.tree()
    let dirs = (0..<t.count).filter { t.isDir[$0] }.count
    #expect(dirs >= 250 && dirs <= 420)
    #expect(t.rootPath == "/Users/demo")
    for i in 0..<t.count {
        let p = t.path(of: NodeID(i))
        #expect(p == "/Users/demo" || p.hasPrefix("/Users/demo/"))
    }
    #expect(DemoFixture.volume.total == 994_000_000_000)
    #expect(DemoFixture.volume.free > 86_500_000_000 && DemoFixture.volume.free < 87_500_000_000)
    #expect(DemoFixture.snapshotOps().list().count == 3)
}

@Test func demoFixtureSizesRollUp() {
    let t = DemoFixture.tree()
    #expect(t.size[0] > 300_000_000_000)
    for i in 0..<t.count where t.isDir[i] {
        let kids = t.children(of: NodeID(i)).reduce(UInt64(0)) { $0 + t.size[Int($1)] }
        #expect(t.size[i] == kids)
    }
    let top = t.children(of: 0).map { t.size[Int($0)] }.sorted(by: >)
    #expect(top[0] > top[5] * 2)   // a big top-level split
    let partial = DemoFixture.tree(fraction: 0.4)
    #expect(partial.size[0] > 0 && partial.size[0] < t.size[0])
    #expect(DemoFixture.tree(fraction: 1).size[0] == t.size[0])
}

@Test func demoCategoriesAndTypesAreRich() {
    let t = DemoFixture.tree()
    let cats = DemoFixture.categories(tree: t)
    #expect(cats.count >= 5 && cats.count <= 10)
    for c in cats {
        #expect(!c.items.isEmpty)
        #expect(c.items.allSatisfy { $0.path.hasPrefix("/Users/demo/") && $0.bytes > 0 })
    }
    let paths = cats.flatMap(\.items).map(\.path)
    #expect(Set(paths).count == paths.count)
    #expect(cats.first { $0.id == "caches" }?.defaultSelected == true)
    #expect(FileTypes.breakdown(tree: t).count >= 7)
}

@Test func demoHistoryProducesGrowthRows() throws {
    let t = DemoFixture.tree()
    let records = DemoFixture.history(tree: t, now: .now)
    #expect(records.count == 8)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-history-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    struct File: Encodable { var version = 1; var records: [History.Record] }
    try JSONEncoder().encode(File(records: records)).write(to: url)
    #expect(History.growth(current: t, from: url).count >= 5)
}

@MainActor
@Test func demoParsesFlagsOnlyWithDemo() {
    #expect(DemoMode.parse(["x", "--demo-tab", "clean"]) == nil)
    let o = DemoMode.parse(["x", "--demo", "--demo-tab", "growth", "--demo-appearance", "dark", "--demo-scan", "--demo-open", "--demo-backdrop"])
    #expect(o == DemoMode.Options(tab: .growth, dark: true, scan: true, open: true, backdrop: true))
    #expect(DemoMode.parse(["x", "--demo"]) == DemoMode.Options())
}

private final class Spy: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func hit() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

@MainActor
@Test func demoCleanupNeverCallsCleaner() {
    let spy = Spy()
    let model = AppModel()
    DemoMode.install(on: model, real: .init(
        trash: { _ in spy.hit(); return CleanResult() },
        emptyTrash: { _ in spy.hit(); return CleanResult() },
        deleteSnapshot: { _ in spy.hit(); return true }))
    let item = CleanItem(path: "/Users/demo/Library/Caches/x", bytes: 1)
    model.onClean?([item])
    #expect(model.snapshotMessage == DemoMode.message)
    model.snapshotMessage = nil
    model.onEmptyTrash?([item])
    #expect(model.snapshotMessage == DemoMode.message)
    model.snapshotMessage = nil
    model.onDeleteSnapshots?()
    #expect(model.snapshotMessage == DemoMode.message)
    #expect(spy.count == 0)
    #expect(!model.cleaning && model.lastResult == nil)
}

@MainActor
@Test func demoPopulateSetsCompleteState() {
    let model = AppModel()
    DemoMode.populate(model, snapshotOps: DemoFixture.snapshotOps())
    #expect(model.tree?.rootPath == "/Users/demo")
    #expect(model.stats == DemoFixture.volume)
    #expect(model.progress.unreadableDirs == 0 && model.progress.done)
    #expect(!model.scanning && !model.discovering && !model.isLiveSnapshot)
    #expect(model.snapshotCount == 3)
    #expect(!model.categories.isEmpty && !model.selectedItems.isEmpty)
}
