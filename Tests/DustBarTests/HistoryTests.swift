import Foundation
import Testing
@testable import DustBar

@Suite struct HistoryTests {
    private let day: TimeInterval = 86_400

    /// Fresh temp file per test; only this file is removed.
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
    }

    /// Root "/r" with one file per top-level directory, so each directory's size is its file's size.
    private func makeTree(_ dirs: [String: UInt64], rootPath: String = "/r") -> DiskTree {
        let t = DiskTree(rootPath: rootPath)
        for (name, bytes) in dirs.sorted(by: { $0.key < $1.key }) {
            let d = t.add(name: name, parent: 0, isDir: true)
            t.add(name: "f.bin", parent: d, isDir: false, size: bytes)
        }
        t.rollUp()
        return t
    }

    @Test func missingFileReadsAsEmpty() {
        let url = tempURL()
        #expect(History.records(at: url).isEmpty)
        #expect(History.growth(current: makeTree(["a": 5_000_000]), from: url).isEmpty)
    }

    @Test func corruptFileReadsAsEmptyAndIsReplaced() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json {".utf8).write(to: url)
        #expect(History.growth(current: makeTree(["a": 5_000_000]), from: url).isEmpty)
        #expect(History.record(tree: makeTree(["a": 5_000_000]), date: Date(), to: url))
        #expect(History.records(at: url).count == 1)
    }

    @Test func growthComparesAgainstAgedBaseline() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let old = Date().addingTimeInterval(-3 * day)
        let recent = Date().addingTimeInterval(-60)
        History.record(tree: makeTree(["a": 1_000_000_000, "b": 4_000_000_000]), date: old, to: url)
        History.record(tree: makeTree(["a": 1_500_000_000, "b": 4_000_000_000]), date: recent, to: url)

        let now = makeTree(["a": 3_000_000_000, "b": 4_000_000_000, "c": 2_000_000_000])
        let rows = History.growth(current: now, from: url)
        #expect(rows.map(\.path) == ["/r/a"])   // "/r/c" is absent from the baseline, so its growth is unknown
        #expect(rows.map(\.deltaBytes) == [2_000_000_000])
        #expect(rows.first?.bytes == 3_000_000_000)
        #expect(rows.allSatisfy { $0.baseline == old })
    }

    @Test func directoryMissingFromBaselineIsNotCountedAsGrowth() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        History.record(tree: makeTree(["a": 1_000_000]), date: Date().addingTimeInterval(-3 * day), to: url)
        let rows = History.growth(current: makeTree(["a": 1_000_000, "new": 50_000_000]), from: url)
        #expect(rows.isEmpty)
    }

    @Test func oldestRecordIsUsedWhenNothingIsADayOld() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = Date().addingTimeInterval(-8 * 3600)
        History.record(tree: makeTree(["a": 1_000_000]), date: first, to: url)
        History.record(tree: makeTree(["a": 2_000_000]), date: Date().addingTimeInterval(-3600), to: url)
        let rows = History.growth(current: makeTree(["a": 5_000_000]), from: url)
        #expect(rows.map(\.deltaBytes) == [4_000_000])
        #expect(rows.first?.baseline == first)
    }

    @Test func sinceLimitsTheBaseline() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        History.record(tree: makeTree(["a": 1_000_000]), date: Date().addingTimeInterval(-5 * day), to: url)
        let kept = Date().addingTimeInterval(-2 * day)
        History.record(tree: makeTree(["a": 3_000_000]), date: kept, to: url)
        let rows = History.growth(current: makeTree(["a": 10_000_000]), since: kept.addingTimeInterval(-1), from: url)
        #expect(rows.map(\.deltaBytes) == [7_000_000])
        #expect(rows.first?.baseline == kept)
        #expect(History.growth(current: makeTree(["a": 10_000_000]), since: Date(), from: url).isEmpty)
    }

    @Test func otherRootsAreIgnored() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        History.record(tree: makeTree(["a": 1_000_000], rootPath: "/other"), date: Date().addingTimeInterval(-3 * day), to: url)
        #expect(History.growth(current: makeTree(["a": 9_000_000]), from: url).isEmpty)
    }

    @Test func smallGrowthIsNotReported() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        History.record(tree: makeTree(["a": 1_000_000]), date: Date().addingTimeInterval(-3 * day), to: url)
        #expect(History.growth(current: makeTree(["a": 1_000_500]), from: url).isEmpty)
        #expect(History.growth(current: makeTree(["a": 500]), from: url).isEmpty)
    }

    @Test func snapshotStopsAtDepthThree() {
        let t = DiskTree(rootPath: "/r")
        var parent: NodeID = 0
        for name in ["a", "b", "c", "d"] {
            parent = t.add(name: name, parent: parent, isDir: true)
        }
        t.add(name: "deep.bin", parent: parent, isDir: false, size: 10_000_000)
        t.rollUp()
        let dirs = History.dirSizes(t)
        #expect(Set(dirs.keys) == ["/r/a", "/r/a/b", "/r/a/b/c"])
        #expect(dirs["/r/a"] == 10_000_000)
    }

    @Test func recordIsSkippedWithinMinimumGap() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let t = Date().addingTimeInterval(-10 * 3600)
        #expect(History.record(tree: makeTree(["a": 1_000_000]), date: t, to: url))
        #expect(!History.record(tree: makeTree(["a": 2_000_000]), date: t.addingTimeInterval(3600), to: url))
        #expect(History.records(at: url).count == 1)
        #expect(History.record(tree: makeTree(["a": 3_000_000]), date: t.addingTimeInterval(6 * 3600), to: url))
        #expect(History.records(at: url).map { $0.dirs["/r/a"] } == [1_000_000, 3_000_000])
        // The gap is per root: another root is recorded even inside the gap.
        #expect(History.record(tree: makeTree(["a": 1_000_000], rootPath: "/other"),
                               date: t.addingTimeInterval(6 * 3600 + 60), to: url))
    }

    @Test func minimumGapIsInjectable() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let t = Date().addingTimeInterval(-3600)
        #expect(History.record(tree: makeTree(["a": 1_000_000]), date: t, to: url, minGap: 0))
        #expect(History.record(tree: makeTree(["a": 2_000_000]), date: t.addingTimeInterval(1), to: url, minGap: 0))
        #expect(History.records(at: url).count == 2)
    }

    @Test func keepsOnlyTheLastEightRecords() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        for i in 0..<10 {
            History.record(tree: makeTree(["a": UInt64(i + 1) * 1_000_000]),
                           date: Date().addingTimeInterval(-Double(10 - i) * 7 * 3600), to: url)
        }
        let kept = History.records(at: url)
        #expect(kept.count == 8)
        #expect(kept.last?.dirs["/r/a"] == 10_000_000)
        #expect(kept.first?.dirs["/r/a"] == 3_000_000)
    }

    @Test func fileStaysUnderTheSizeCap() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let long = String(repeating: "x", count: 200)
        var dirs: [String: UInt64] = [:]
        for i in 0..<200 { dirs["\(long)\(i)"] = UInt64(i + 1) * 1_000 }
        for i in 0..<8 {
            History.record(tree: makeTree(dirs), date: Date().addingTimeInterval(-Double(10 - i) * 7 * 3600), to: url)
        }
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size <= History.maxFileBytes)
        #expect(!History.records(at: url).isEmpty)
    }
}
