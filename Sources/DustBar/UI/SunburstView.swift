import SwiftUI

/// One drawn ring segment. Angles are radians clockwise from 12 o'clock.
/// Radii are fractions of the half-side of the square the sunburst is drawn in.
public struct SunburstArc: Equatable, Sendable {
    public let id: NodeID
    public let path: String        // stable across snapshots; used to match arcs when morphing
    public let depth: Int          // 1...rings
    public let start: Double
    public let end: Double
    public let inner: Double
    public let outer: Double
    public let hue: Double         // stable per top-level ancestor, 0..<1
    public let isDir: Bool
}

/// Pure geometry: layout over a DiskTree plus hit-testing. No UI state.
public enum SunburstLayout {
    public static let holeRadius = 0.40
    public static let ringGap = 0.01
    public static let minFraction = 0.005   // skip arcs below 0.5% of a full turn

    public static func arcs(tree: DiskTree, root: NodeID, rings: Int = 3,
                            minFraction: Double = minFraction) -> [SunburstArc] {
        guard root != noNode, Int(root) < tree.count, rings > 0 else { return [] }
        let total = tree.size[Int(root)]
        guard total > 0 else { return [] }
        var out: [SunburstArc] = []
        emit(tree, parent: root, depth: 1, rings: rings, start: 0, sweep: 2 * .pi,
             parentSize: total, minSweep: minFraction * 2 * .pi, top: nil, into: &out)
        return out
    }

    private static func emit(_ tree: DiskTree, parent: NodeID, depth: Int, rings: Int,
                             start: Double, sweep: Double, parentSize: UInt64,
                             minSweep: Double, top: NodeID?, into out: inout [SunburstArc]) {
        guard depth <= rings, parentSize > 0 else { return }
        let ring = (1 - holeRadius) / Double(rings)
        let innerR = holeRadius + Double(depth - 1) * ring
        var a = start
        for c in tree.children(of: parent) {
            let s = tree.size[Int(c)]
            guard s > 0 else { continue }
            let span = sweep * Double(s) / Double(parentSize)
            if span < minSweep { a += span; continue }
            let topID = top ?? c
            out.append(SunburstArc(id: c, path: tree.path(of: c), depth: depth, start: a, end: a + span,
                                   inner: innerR + ringGap / 2, outer: innerR + ring - ringGap / 2,
                                   hue: hue(for: topID), isDir: tree.isDir[Int(c)]))
            if tree.isDir[Int(c)] {
                emit(tree, parent: c, depth: depth + 1, rings: rings, start: a, sweep: span,
                     parentSize: s, minSweep: minSweep, top: topID, into: &out)
            }
            a += span
        }
    }

    /// Golden-ratio hue spread: stable for a given node id, well separated for neighbours.
    public static func hue(for id: NodeID) -> Double {
        let x = Double(id) * 0.618033988749895
        return x - x.rounded(.down)
    }

    /// Arc under a point given in half-side units relative to the centre (y grows downward).
    public static func hit(_ arcs: [SunburstArc], x: Double, y: Double) -> SunburstArc? {
        let r = (x * x + y * y).squareRoot()
        guard r >= holeRadius, r <= 1 else { return nil }
        var theta = atan2(x, -y)
        if theta < 0 { theta += 2 * .pi }
        return arcs.first { r >= $0.inner && r < $0.outer && theta >= $0.start && theta < $0.end }
    }

    /// Root-to-node path of ids, inclusive.
    public static func chain(_ tree: DiskTree, _ node: NodeID) -> [NodeID] {
        var out: [NodeID] = []
        var cur = node
        while cur != noNode && Int(cur) < tree.count {
            out.append(cur)
            if cur == 0 { break }
            cur = tree.parent[Int(cur)]
        }
        return out.reversed()
    }

    /// `id` only when it indexes `tree`: a rescan can swap in a smaller tree while a hover id is still set.
    static func valid(_ id: NodeID?, in tree: DiskTree) -> NodeID? {
        guard let id, Int(id) < tree.count else { return nil }
        return id
    }

    public static func title(_ tree: DiskTree, _ node: NodeID) -> String {
        if node == 0 {
            let base = (tree.rootPath as NSString).lastPathComponent
            return base.isEmpty || base == "/" ? "Macintosh HD" : base
        }
        return tree.name(node)
    }
}


/// Identity of a layout input; arcs are recomputed only when this changes.
struct SunburstLayoutKey: Equatable {
    let tree: ObjectIdentifier
    let root: NodeID
    let count: Int
    let revision: UInt64
}

/// Pure morph between two layouts of successive live snapshots, matched by path.
public enum SunburstTween {
    public static let duration = 0.8

    /// Cubic ease-in-out over linear progress `t` (clamped to 0...1).
    public static func ease(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// Arcs at linear progress `t`: matched arcs ease from their `prev` geometry to `next`;
    /// unmatched arcs grow out of their own midpoint from zero width; arcs that vanished are dropped.
    /// t = 0 gives the `prev` geometry, t = 1 gives `next`.
    public static func interpolate(prev: [SunburstArc], next: [SunburstArc], t: Double) -> [SunburstArc] {
        let e = ease(t)
        var byPath: [String: SunburstArc] = [:]
        byPath.reserveCapacity(prev.count)
        for arc in prev { byPath[arc.path] = arc }
        return next.map { n in
            if let p = byPath[n.path] {
                return n.with(start: lerp(p.start, n.start, e), end: lerp(p.end, n.end, e),
                              inner: lerp(p.inner, n.inner, e), outer: lerp(p.outer, n.outer, e))
            }
            let mid = (n.start + n.end) / 2
            return n.with(start: lerp(mid, n.start, e), end: lerp(mid, n.end, e), inner: n.inner, outer: n.outer)
        }
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

private extension SunburstArc {
    func with(start: Double, end: Double, inner: Double, outer: Double) -> SunburstArc {
        SunburstArc(id: id, path: path, depth: depth, start: start, end: end,
                    inner: inner, outer: outer, hue: hue, isDir: isDir)
    }
}

private struct ArcShape: Shape {
    let arc: SunburstArc

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        var p = Path()
        p.addArc(center: c, radius: arc.outer * R, startAngle: .radians(arc.start - .pi / 2),
                 endAngle: .radians(arc.end - .pi / 2), clockwise: false)
        p.addArc(center: c, radius: arc.inner * R, startAngle: .radians(arc.end - .pi / 2),
                 endAngle: .radians(arc.start - .pi / 2), clockwise: true)
        p.closeSubpath()
        return p
    }
}

public struct SunburstView: View {
    let tree: DiskTree
    @Binding var current: NodeID
    let revision: UInt64           // root size; changes while scanning so the layout refreshes
    let live: Bool                 // true while `tree` is a partial snapshot: no hover, no drill
    @State private var shown: [SunburstArc] = []      // layout of the latest tree
    @State private var previous: [SunburstArc] = []   // layout the current morph starts from
    @State private var startedAt = Date.distantPast
    @State private var animating = false
    @State private var epoch = 0
    @State private var lastRoot: NodeID = noNode
    @State private var hoverID: NodeID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(tree: DiskTree, current: Binding<NodeID>, revision: UInt64, live: Bool = false) {
        self.tree = tree
        self._current = current
        self.revision = revision
        self.live = live
    }

    /// `current` clamped to `tree`: a rescan can swap in a smaller tree while the old id is still set.
    private var cur: NodeID { current < tree.count ? current : 0 }

    private var key: SunburstLayoutKey {
        SunburstLayoutKey(tree: ObjectIdentifier(tree), root: cur, count: tree.count, revision: revision)
    }

    public var body: some View {
        VStack(spacing: 6) {
            breadcrumb
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let side = min(w, h)
                ZStack {
                    plot
                    centerLabel(side: side)
                }
                .frame(width: w, height: h)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let (x, y) = normalized(p, w: w, h: h)
                        let id = live ? nil : hitArc(x: x, y: y)?.id
                        if id != hoverID { hoverID = id }
                    case .ended:
                        if hoverID != nil { hoverID = nil }
                    }
                }
                .gesture(SpatialTapGesture().onEnded { v in tap(v.location, w: w, h: h) })
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: key) { refresh() }
        .onChange(of: live) { hoverID = nil }
        .task(id: epoch) {
            guard epoch > 0 else { return }
            try? await Task.sleep(for: .milliseconds(Int(SunburstTween.duration * 1000) + 50))
            if !Task.isCancelled { animating = false }
        }
    }

    /// Static ring when idle; a per-frame morph only while live or within the settle window.
    /// The timeline pauses once the morph settles, so a long live scan does not redraw every frame.
    @ViewBuilder
    private var plot: some View {
        if !reduceMotion && (animating || live) {
            TimelineView(.animation(paused: !animating)) { timeline in
                ring(animating ? SunburstTween.interpolate(prev: previous, next: shown, t: progress(at: timeline.date)) : shown)
            }
        } else {
            ring(shown)
        }
    }

    /// Plain shape layers instead of a Canvas: a Canvas redrawn on every snapshot kept ~190 MB of
    /// graphics backing stores alive while the popover was open.
    private func ring(_ arcs: [SunburstArc]) -> some View {
        ZStack {
            ForEach(arcs, id: \.path) { arc in
                let hovered = arc.id == hoverID
                let base = Color(hue: arc.hue, saturation: 0.55, brightness: 0.95 - 0.08 * Double(arc.depth - 1))
                ArcShape(arc: arc)
                    .fill(base.opacity(hovered ? 1 : 0.85))
                    .overlay { if hovered { ArcShape(arc: arc).stroke(Color.primary.opacity(0.8), lineWidth: 1.5) } }
            }
        }
    }

    private func refresh() {
        if current >= tree.count { current = 0 }
        let next = SunburstLayout.arcs(tree: tree, root: cur)
        // Morph only between snapshots of the same root; drilling or first paint snaps.
        let animate = !reduceMotion && cur == lastRoot && !shown.isEmpty
        // A snapshot landing mid-morph starts from the geometry on screen now, not from the old target.
        let onScreen = animating ? SunburstTween.interpolate(prev: previous, next: shown, t: progress(at: Date())) : shown
        lastRoot = cur
        previous = animate ? onScreen : next
        shown = next
        startedAt = Date()
        hoverID = nil
        if animate {
            animating = true
            epoch += 1
        }
    }

    private func progress(at date: Date) -> Double {
        date.timeIntervalSince(startedAt) / SunburstTween.duration
    }

    /// Arc under a point, ignoring any arc whose id is outside `tree` (layout left over from a replaced tree).
    private func hitArc(x: Double, y: Double) -> SunburstArc? {
        guard let arc = SunburstLayout.hit(shown, x: x, y: y), Int(arc.id) < tree.count else { return nil }
        return arc
    }

    private func normalized(_ p: CGPoint, w: CGFloat, h: CGFloat) -> (Double, Double) {
        let R = Double(min(w, h)) / 2
        return ((Double(p.x) - Double(w) / 2) / R, (Double(p.y) - Double(h) / 2) / R)
    }

    private func tap(_ p: CGPoint, w: CGFloat, h: CGFloat) {
        guard !live else { return }
        let (x, y) = normalized(p, w: w, h: h)
        if (x * x + y * y).squareRoot() < SunburstLayout.holeRadius {
            if cur != 0 {
                let parent = tree.parent[Int(cur)]
                current = parent == noNode ? 0 : parent
                hoverID = nil
            }
            return
        }
        if let arc = hitArc(x: x, y: y), arc.isDir {
            current = arc.id
            hoverID = nil
        }
    }

    private func centerLabel(side: CGFloat) -> some View {
        let node = SunburstLayout.valid(hoverID, in: tree) ?? cur
        return VStack(spacing: 2) {
            Text(live ? "Scanning…" : SunburstLayout.title(tree, node))
                .font(.caption.weight(.semibold))
                .lineLimit(1).truncationMode(.middle)
            Text(ByteText.string(tree.size[Int(node)]))
                .font(.system(.body, design: .rounded).weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 4)
        // Hole diameter is holeRadius * side; keep the label inside it.
        .frame(width: side * SunburstLayout.holeRadius * 0.8)
        .allowsHitTesting(false)
    }

    private var breadcrumb: some View {
        let nodes = SunburstLayout.chain(tree, cur)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(nodes.enumerated()), id: \.element) { i, node in
                        if i > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button(SunburstLayout.title(tree, node)) {
                            guard node != cur else { return }
                            current = node
                            hoverID = nil
                        }
                        .buttonStyle(.plain)
                        .disabled(live)
                        .font(.caption.weight(node == cur ? .semibold : .regular))
                        .foregroundStyle(node == cur ? .primary : .secondary)
                        .id(node)
                    }
                }
            }
            .onChange(of: cur) { proxy.scrollTo(cur, anchor: .trailing) }
        }
        .frame(height: 20)
    }
}
