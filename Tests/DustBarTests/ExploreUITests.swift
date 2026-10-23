import AppKit
import SwiftUI
import XCTest
@testable import DustBar

final class ExploreUITests: XCTestCase {
    /// Hand-built tree (sizes in bytes, total 9510):
    /// /x
    /// ├── A (dir, 5000)
    /// │   ├── a1 (3000)
    /// │   └── a2 (2000)
    /// ├── B (file, 3000)
    /// ├── C (file, 1500)
    /// └── tiny (file, 10)   <- below 0.5% of a turn, must be skipped
    private func makeTree() -> (DiskTree, A: NodeID, a1: NodeID, a2: NodeID, B: NodeID, C: NodeID, tiny: NodeID) {
        let t = DiskTree(rootPath: "/x")
        let a = t.add(name: "A", parent: 0, isDir: true)
        let a1 = t.add(name: "a1", parent: a, isDir: false, size: 3000)
        let a2 = t.add(name: "a2", parent: a, isDir: false, size: 2000)
        let b = t.add(name: "B", parent: 0, isDir: false, size: 3000)
        let c = t.add(name: "C", parent: 0, isDir: false, size: 1500)
        let tiny = t.add(name: "tiny", parent: 0, isDir: false, size: 10)
        t.rollUp()
        return (t, a, a1, a2, b, c, tiny)
    }

    func testTopLevelArcsProportionalAndContiguous() {
        let (t, a, _, _, b, c, _) = makeTree()
        let arcs = SunburstLayout.arcs(tree: t, root: 0)
        let top = arcs.filter { $0.depth == 1 }.sorted { $0.start < $1.start }
        XCTAssertEqual(top.count, 3)
        XCTAssertEqual(top.map(\.id).sorted(), [a, b, c].sorted())
        // Skipped 'tiny' (10 bytes) is angularly first here and leaves its gap before the first arc.
        XCTAssertEqual(top[0].start, 2 * .pi * 10 / 9510, accuracy: 1e-9)
        XCTAssertEqual(top[0].end, top[1].start, accuracy: 1e-12)
        XCTAssertEqual(top[1].end, top[2].start, accuracy: 1e-12)
        for arc in top {
            let fraction = Double(t.size[Int(arc.id)]) / 9510
            XCTAssertEqual(arc.end - arc.start, 2 * .pi * fraction, accuracy: 1e-9)
        }
    }

    func testTinyArcSkipped() {
        let (t, _, _, _, _, _, tiny) = makeTree()
        XCTAssertFalse(SunburstLayout.arcs(tree: t, root: 0).contains { $0.id == tiny })
    }

    func testSecondRingNestedInParentSpan() {
        let (t, a, a1, a2, _, _, _) = makeTree()
        let arcs = SunburstLayout.arcs(tree: t, root: 0)
        let parent = arcs.first { $0.id == a }!
        let s1 = arcs.first { $0.id == a1 }!
        let s2 = arcs.first { $0.id == a2 }!
        XCTAssertEqual(s1.depth, 2)
        XCTAssertEqual(s2.depth, 2)
        XCTAssertEqual(s1.end - s1.start, (parent.end - parent.start) * 3000 / 5000, accuracy: 1e-9)
        XCTAssertEqual(s2.end - s2.start, (parent.end - parent.start) * 2000 / 5000, accuracy: 1e-9)
        XCTAssertEqual(min(s1.start, s2.start), parent.start, accuracy: 1e-12)
        XCTAssertEqual(max(s1.end, s2.end), parent.end, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(s1.inner, parent.outer)
    }

    func testRingRadiiOrderedAndInsideDisk() {
        let (t, _, _, _, _, _, _) = makeTree()
        let arcs = SunburstLayout.arcs(tree: t, root: 0)
        for arc in arcs {
            XCTAssertGreaterThan(arc.inner, SunburstLayout.holeRadius)
            XCTAssertLessThanOrEqual(arc.outer, 1)
            XCTAssertLessThan(arc.inner, arc.outer)
        }
    }

    func testRingLimitAndDescendantColor() {
        let (t, a, a1, _, b, _, _) = makeTree()
        let one = SunburstLayout.arcs(tree: t, root: 0, rings: 1)
        XCTAssertTrue(one.allSatisfy { $0.depth == 1 })
        let arcs = SunburstLayout.arcs(tree: t, root: 0)
        XCTAssertEqual(arcs.first { $0.id == a1 }!.hue, arcs.first { $0.id == a }!.hue)
        XCTAssertNotEqual(arcs.first { $0.id == b }!.hue, arcs.first { $0.id == a }!.hue)
    }

    func testSubtreeLayoutUsesRootOfSubtree() {
        let (t, a, a1, a2, _, _, _) = makeTree()
        let arcs = SunburstLayout.arcs(tree: t, root: a)
        XCTAssertEqual(Set(arcs.map(\.id)), [a1, a2])
        XCTAssertEqual(arcs.first { $0.id == a1 }!.depth, 1)
        XCTAssertEqual(arcs.reduce(0.0) { $0 + ($1.end - $1.start) }, 2 * .pi * 3000 / 5000 + 2 * .pi * 2000 / 5000, accuracy: 1e-9)
    }

    func testHitTestByAngleAndRadius() {
        let (t, a, a1, _, b, _, _) = makeTree()
        let arcs = SunburstLayout.arcs(tree: t, root: 0)
        func point(_ arc: SunburstArc, radius: Double) -> (Double, Double) {
            let theta = (arc.start + arc.end) / 2
            return (radius * sin(theta), -radius * cos(theta))
        }
        let ringA = arcs.first { $0.id == a }!
        let (x1, y1) = point(ringA, radius: (ringA.inner + ringA.outer) / 2)
        XCTAssertEqual(SunburstLayout.hit(arcs, x: x1, y: y1)?.id, a)

        let inner = arcs.first { $0.id == a1 }!
        let (x2, y2) = point(inner, radius: (inner.inner + inner.outer) / 2)
        XCTAssertEqual(SunburstLayout.hit(arcs, x: x2, y: y2)?.id, a1)

        let bArc = arcs.first { $0.id == b }!
        let (x3, y3) = point(bArc, radius: (bArc.inner + bArc.outer) / 2)
        XCTAssertEqual(SunburstLayout.hit(arcs, x: x3, y: y3)?.id, b)

        XCTAssertNil(SunburstLayout.hit(arcs, x: 0, y: 0))      // centre hole
        XCTAssertNil(SunburstLayout.hit(arcs, x: 1.5, y: 0))    // outside the disk
    }

    func testChainAndTopChildren() {
        let (t, a, a1, _, b, _, _) = makeTree()
        XCTAssertEqual(SunburstLayout.chain(t, a1), [0, a, a1])
        XCTAssertEqual(SunburstLayout.chain(t, 0), [0])
        XCTAssertEqual(TopListLayout.topChildren(t, of: 0, limit: 2), [a, b])
        XCTAssertEqual(TopListLayout.rows(t, of: 0).count, 4)
        XCTAssertEqual(TopListLayout.rows(t, of: 0).first?.path, "/x/A")
    }

    func testCanActHidesSmallFilesAndMissingPaths() {
        XCTAssertFalse(TopListLayout.canAct(name: "(small files)", path: "/x/(small files)", fileExists: { _ in true }))
        XCTAssertFalse(TopListLayout.canAct(name: "a1", path: "/x/a1", fileExists: { _ in false }))
        XCTAssertTrue(TopListLayout.canAct(name: "a1", path: "/x/a1", fileExists: { _ in true }))
    }

    func testRowsCarryCanAct() {
        let (t, _, _, _, _, _, _) = makeTree()
        let rows = TopListLayout.rows(t, of: 0, fileExists: { $0 != "/x/B" })
        XCTAssertEqual(rows.first { $0.name == "B" }?.canAct, false)
        XCTAssertEqual(rows.first { $0.name == "A" }?.canAct, true)
    }

    /// Same logical children as `makeTree` but inserted in another order, so node ids differ by path.
    private func grownTree(extra: Bool) -> DiskTree {
        let t = DiskTree(rootPath: "/x")
        _ = t.add(name: "C", parent: 0, isDir: false, size: 1500)
        _ = t.add(name: "B", parent: 0, isDir: false, size: 6000)
        if extra { _ = t.add(name: "D", parent: 0, isDir: false, size: 2500) }
        t.rollUp()
        return t
    }

    func testTweenEndpointsAndPathMatching() {
        let (t1, _, _, _, _, _, _) = makeTree()
        let t2 = grownTree(extra: false)
        let prev = SunburstLayout.arcs(tree: t1, root: 0)
        let next = SunburstLayout.arcs(tree: t2, root: 0)
        XCTAssertEqual(SunburstTween.interpolate(prev: prev, next: next, t: 1), next)
        let bPrev = prev.first { $0.path == "/x/B" }!
        let bNext = next.first { $0.path == "/x/B" }!
        XCTAssertNotEqual(bPrev.id, bNext.id)          // ids differ between snapshots
        XCTAssertNotEqual(bPrev.start, bNext.start)    // geometry really changes
        let bAt0 = SunburstTween.interpolate(prev: prev, next: next, t: 0).first { $0.path == "/x/B" }!
        XCTAssertEqual(bAt0.start, bPrev.start, accuracy: 1e-9)
        XCTAssertEqual(bAt0.end, bPrev.end, accuracy: 1e-9)
    }

    func testNewArcGrowsFromZeroWidth() {
        let (t1, _, _, _, _, _, _) = makeTree()
        let t2 = grownTree(extra: true)
        let prev = SunburstLayout.arcs(tree: t1, root: 0)
        let next = SunburstLayout.arcs(tree: t2, root: 0)
        let d = next.first { $0.path == "/x/D" }!
        let at0 = SunburstTween.interpolate(prev: prev, next: next, t: 0).first { $0.path == "/x/D" }!
        XCTAssertEqual(at0.start, at0.end, accuracy: 1e-9)
        let at1 = SunburstTween.interpolate(prev: prev, next: next, t: 1).first { $0.path == "/x/D" }!
        XCTAssertEqual(at1.start, d.start, accuracy: 1e-9)
        XCTAssertEqual(at1.end, d.end, accuracy: 1e-9)
    }

    func testVanishedArcsDroppedAndIntermediateStaysBetween() {
        let (t1, _, _, _, _, _, _) = makeTree()
        let t2 = grownTree(extra: true)
        let withD = SunburstLayout.arcs(tree: t2, root: 0)
        let plain = SunburstLayout.arcs(tree: t1, root: 0)
        let out = SunburstTween.interpolate(prev: withD, next: plain, t: 0.5)
        XCTAssertEqual(out.map(\.path).sorted(), plain.map(\.path).sorted())
        let a = withD.first { $0.path == "/x/B" }!
        let b = plain.first { $0.path == "/x/B" }!
        let mid = out.first { $0.path == "/x/B" }!
        XCTAssertEqual(mid.start, (a.start + b.start) / 2, accuracy: 1e-9)
    }

    func testEaseIsClampedAndMonotonic() {
        XCTAssertEqual(SunburstTween.ease(-1), 0)
        XCTAssertEqual(SunburstTween.ease(2), 1)
        XCTAssertEqual(SunburstTween.ease(0.5), 0.5, accuracy: 1e-12)
        var last = -1.0
        for i in 0...100 {
            let v = SunburstTween.ease(Double(i) / 100)
            XCTAssertGreaterThanOrEqual(v, last)
            last = v
        }
    }

    func testRetargetStartsFromGeometryOnScreen() {
        let (t1, _, _, _, _, _, _) = makeTree()
        let t2 = grownTree(extra: false)
        let t3 = grownTree(extra: true)
        let from = SunburstLayout.arcs(tree: t1, root: 0)
        let target = SunburstLayout.arcs(tree: t2, root: 0)
        let next = SunburstLayout.arcs(tree: t3, root: 0)
        let onScreen = SunburstTween.interpolate(prev: from, next: target, t: 0.5)
        let retargeted = SunburstTween.interpolate(prev: onScreen, next: next, t: 0)
        for arc in onScreen {
            let r = retargeted.first { $0.path == arc.path }!
            XCTAssertEqual(r.start, arc.start, accuracy: 1e-9)
            XCTAssertEqual(r.end, arc.end, accuracy: 1e-9)
        }
    }

    /// A rescan can leave a drill-down id larger than the new tree's count; rendering must clamp, not trap.
    @MainActor
    func testOutOfRangeCurrentRendersRootWithoutTrapping() {
        let small = DiskTree(rootPath: "/small")
        _ = small.add(name: "only", parent: 0, isDir: false, size: 100)
        small.rollUp()
        var current: NodeID = 999
        let binding = Binding<NodeID>(get: { current }, set: { current = $0 })
        _ = NSApplication.shared
        let view = SunburstView(tree: small, current: binding, revision: small.size[0])
            .frame(width: 300, height: 300)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        window.orderOut(nil)
        XCTAssertEqual(current, 0)
    }

    func testStaleHoverIDIsIgnoredAfterTreeShrinks() {
        let (t, _, _, _, _, _, _) = makeTree()
        let small = DiskTree(rootPath: "/y")
        small.add(name: "only", parent: 0, isDir: false, size: 1)
        small.rollUp()
        // An id from the big tree that no longer exists in the smaller one.
        let stale = NodeID(t.count - 1)
        XCTAssertNil(SunburstLayout.valid(stale, in: small))
        XCTAssertNil(SunburstLayout.valid(nil, in: small))
        XCTAssertEqual(SunburstLayout.valid(0, in: small), 0)
        XCTAssertEqual(SunburstLayout.valid(stale, in: t), stale)
    }
}

/// Renders the popover to PNG files for visual review. Runs only when DUSTBAR_SNAPSHOT_DIR is set.
@MainActor
final class PopoverSnapshotTests: XCTestCase {
    private func sampleModel() -> AppModel {
        let model = AppModel()
        model.stats = VolumeStats(total: 2_000_000_000_000, free: 205_000_000_000, purgeable: 7_800_000_000)
        model.progress = ScanProgress(files: 1_600_000, bytes: 420_000_000_000, unreadableDirs: 12, done: true)
        let t = DiskTree(rootPath: "/Users/demo")
        let library = t.add(name: "Library", parent: 0, isDir: true)
        let developer = t.add(name: "Developer", parent: library, isDir: true)
        _ = t.add(name: "Runtime.dmg", parent: developer, isDir: false, size: 120_000_000_000)
        _ = t.add(name: "Devices", parent: developer, isDir: false, size: 60_000_000_000)
        _ = t.add(name: "Xcode DerivedData", parent: developer, isDir: false, size: 80_000_000_000)
        let caches = t.add(name: "Caches", parent: library, isDir: true)
        _ = t.add(name: "com.apple.Safari", parent: caches, isDir: false, size: 50_000_000_000)
        _ = t.add(name: "Homebrew", parent: caches, isDir: false, size: 70_000_000_000)
        let movies = t.add(name: "Movies", parent: 0, isDir: true)
        _ = t.add(name: "Holiday 2024 Family Archive.mov", parent: movies, isDir: false, size: 100_000_000_000)
        _ = t.add(name: "Project Final Cut.mp4", parent: movies, isDir: false, size: 50_000_000_000)
        _ = t.add(name: "Pictures", parent: 0, isDir: false, size: 90_000_000_000)
        let downloads = t.add(name: "Downloads", parent: 0, isDir: true)
        _ = t.add(name: "installer-macos-26.dmg", parent: downloads, isDir: false, size: 14_000_000_000)
        _ = t.add(name: "archive.zip", parent: downloads, isDir: false, size: 40_000_000_000)
        _ = t.add(name: "Desktop Sketches", parent: 0, isDir: false, size: 25_000_000_000)
        _ = t.add(name: "tiny", parent: 0, isDir: false, size: 10)
        t.rollUp()
        model.tree = t

        let cacheItems = [
            CleanItem(path: "/Users/demo/Library/Caches/Homebrew", bytes: 70_000_000_000),
            CleanItem(path: "/Users/demo/Library/Caches/com.apple.Safari", bytes: 50_000_000_000),
        ]
        model.categories = [
            CleanCategory(id: "caches", title: "Caches", detail: "Regenerated automatically by apps.",
                          defaultSelected: true, items: cacheItems),
            CleanCategory(id: "xcode", title: "Xcode DerivedData", detail: "Build products. Safe to delete.",
                          defaultSelected: false,
                          items: [CleanItem(path: "/Users/demo/Library/Developer/Xcode/DerivedData", bytes: 80_000_000_000)]),
            CleanCategory(id: "trash", title: "Trash", detail: "Permanently removes items already in the Trash.",
                          defaultSelected: true,
                          items: [CleanItem(path: "/Users/demo/.Trash/old.zip", bytes: 3_000_000_000)]),
        ]
        model.selectedItems = Set(cacheItems.map(\.path))
        return model
    }

    func testRenderPopoverSnapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["DUSTBAR_SNAPSHOT_DIR"] else { return }
        let model = sampleModel()
        _ = NSApplication.shared   // AppKit views need an application instance
        // Hosted in an off-screen window so the popover renders through the real AppKit path.
        for dark in [false, true] {
            let name = dark ? "dark" : "light"
            for (tabName, showClean) in [("explore", false), ("clean", true)] {
                let view = PopoverView(model: model, showClean: showClean)
                    .background(dark ? Color(white: 0.11) : Color(white: 0.90))
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 420, height: 560)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(1.0))
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    XCTFail("no bitmap: \(tabName)-\(name)")
                    window.orderOut(nil)
                    continue
                }
                host.cacheDisplay(in: host.bounds, to: rep)
                window.orderOut(nil)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    XCTFail("png failed: \(tabName)-\(name)")
                    continue
                }
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("render-\(tabName)-\(name).png"))
            }
        }
    }
}
