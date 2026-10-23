import SwiftUI

/// "Grew since <date>": directories that gained the most since an earlier scan, with tiny bars scaled to the top gain.
public struct GrowthView: View {
    let model: AppModel
    @State private var rows: [History.GrowthRow] = []
    @State private var loaded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: AppModel) { self.model = model }

    private struct Key: Equatable {
        let tree: ObjectIdentifier
        let count: Int
        let revision: UInt64
    }

    private var key: Key? {
        model.tree.map { Key(tree: ObjectIdentifier($0), count: $0.count, revision: $0.size[0]) }
    }

    public var body: some View {
        if let tree = model.tree, tree.count > 0 {
            VStack(alignment: .leading, spacing: 10) {
                header
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else if rows.isEmpty {
                    ContentUnavailableView(
                        "Not enough history yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Growth shows up after a few scans, a day or more apart.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .dustCard()
            .task(id: key) { await reload(tree) }
        } else {
            let scanning = model.scanning && model.tree == nil
            ContentUnavailableView(
                scanning ? "Scanning…" : "Not scanned yet",
                systemImage: scanning ? "magnifyingglass" : "externaldrive.badge.questionmark",
                description: Text(scanning ? "Growth appears when the scan finishes." : "Press Rescan to start.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var header: some View {
        if let since = rows.first?.baseline {
            Text("Grew since \(since.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 6)
        }
    }

    private func reload(_ tree: DiskTree) async {
        let next = await Task.detached(priority: .utility) { History.growth(current: tree) }.value
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { rows = next }
        loaded = true
    }

    private var list: some View {
        let top = max(1, rows.map(\.deltaBytes).max() ?? 1)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    rowView(row, fraction: Double(row.deltaBytes) / Double(top))
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func rowView(_ row: History.GrowthRow, fraction: Double) -> some View {
        let url = URL(fileURLWithPath: row.path)
        return HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("+\(ByteText.string(row.deltaBytes))")
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
                .font(.callout)
                Text(row.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(Color.orange.gradient)
                            .frame(width: max(4, geo.size.width * fraction))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .help(row.path)
    }
}
