import SwiftUI

/// One drawn ring segment. Angles are radians clockwise from 12 o'clock.
/// Radii are fractions of the half-side of the square the sunburst is drawn in.
public struct SunburstArc: Equatable, Sendable {
    public let id: NodeID
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
    public static let holeRadius = 0.30
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
            out.append(SunburstArc(id: c, depth: depth, start: a, end: a + span,
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

public struct SunburstView: View {
    let tree: DiskTree
    @Binding var current: NodeID
    let revision: UInt64           // root size; changes while scanning so the layout refreshes
    @State private var arcs: [SunburstArc] = []
    @State private var hoverID: NodeID?

    public init(tree: DiskTree, current: Binding<NodeID>, revision: UInt64) {
        self.tree = tree
        self._current = current
        self.revision = revision
    }

    private var key: SunburstLayoutKey {
        SunburstLayoutKey(tree: ObjectIdentifier(tree), root: current, count: tree.count, revision: revision)
    }

    public var body: some View {
        VStack(spacing: 6) {
            breadcrumb
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let side = min(w, h)
                ZStack {
                    Canvas { ctx, size in
                        let c = CGPoint(x: size.width / 2, y: size.height / 2)
                        let R = min(size.width, size.height) / 2
                        for arc in arcs {
                            var p = Path()
                            p.addArc(center: c, radius: arc.outer * R,
                                     startAngle: .radians(arc.start - .pi / 2),
                                     endAngle: .radians(arc.end - .pi / 2), clockwise: false)
                            p.addArc(center: c, radius: arc.inner * R,
                                     startAngle: .radians(arc.end - .pi / 2),
                                     endAngle: .radians(arc.start - .pi / 2), clockwise: true)
                            p.closeSubpath()
                            let base = Color(hue: arc.hue, saturation: 0.55,
                                             brightness: 0.95 - 0.08 * Double(arc.depth - 1))
                            let hovered = arc.id == hoverID
                            ctx.fill(p, with: .color(base.opacity(hovered ? 1 : 0.85)))
                            if hovered { ctx.stroke(p, with: .color(.primary.opacity(0.8)), lineWidth: 1.5) }
                        }
                    }
                    centerLabel(side: side)
                }
                .frame(width: w, height: h)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let (x, y) = normalized(p, w: w, h: h)
                        let id = SunburstLayout.hit(arcs, x: x, y: y)?.id
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
    }

    private func refresh() {
        if current >= tree.count { current = 0 }
        arcs = SunburstLayout.arcs(tree: tree, root: current)
        hoverID = nil
    }

    private func normalized(_ p: CGPoint, w: CGFloat, h: CGFloat) -> (Double, Double) {
        let R = Double(min(w, h)) / 2
        return ((Double(p.x) - Double(w) / 2) / R, (Double(p.y) - Double(h) / 2) / R)
    }

    private func tap(_ p: CGPoint, w: CGFloat, h: CGFloat) {
        let (x, y) = normalized(p, w: w, h: h)
        if (x * x + y * y).squareRoot() < SunburstLayout.holeRadius {
            if current != 0 {
                let parent = tree.parent[Int(current)]
                current = parent == noNode ? 0 : parent
                hoverID = nil
            }
            return
        }
        if let arc = SunburstLayout.hit(arcs, x: x, y: y), arc.isDir {
            current = arc.id
            hoverID = nil
        }
    }

    private func centerLabel(side: CGFloat) -> some View {
        let shown = hoverID ?? current
        return VStack(spacing: 2) {
            Text(SunburstLayout.title(tree, shown))
                .font(.caption.weight(.semibold))
                .lineLimit(1).truncationMode(.middle)
            Text(ByteText.string(tree.size[Int(shown)]))
                .font(.system(.body, design: .rounded).weight(.bold))
                .monospacedDigit()
        }
        .padding(.horizontal, 4)
        .frame(width: side * SunburstLayout.holeRadius * 1.7)
        .allowsHitTesting(false)
    }

    private var breadcrumb: some View {
        let nodes = SunburstLayout.chain(tree, current)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(nodes.enumerated()), id: \.element) { i, node in
                    if i > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button(SunburstLayout.title(tree, node)) { current = node; hoverID = nil }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(node == current ? .primary : .secondary)
                        .disabled(node == current)
                }
            }
        }
        .frame(height: 20)
    }
}
