import AppKit
import SwiftUI

public struct TopRow: Identifiable, Equatable, Sendable {
    public let id: NodeID
    public let name: String
    public let path: String
    public let bytes: UInt64
    public let fraction: Double    // share of the current node's size
    public let isDir: Bool
    public let canAct: Bool        // false for the "(small files)" pseudo node or a path that no longer exists
}

public enum TopListLayout {
    public static let smallFilesName = "(small files)"

    public static func canAct(name: String, path: String, fileExists: (String) -> Bool) -> Bool {
        name != smallFilesName && fileExists(path)
    }

    /// Largest non-empty children of `parent`, biggest first.
    public static func topChildren(_ tree: DiskTree, of parent: NodeID, limit: Int = 12) -> [NodeID] {
        tree.children(of: parent)
            .filter { tree.size[Int($0)] > 0 }
            .sorted { tree.size[Int($0)] > tree.size[Int($1)] }
            .prefix(limit)
            .map { $0 }
    }

    public static func rows(_ tree: DiskTree, of parent: NodeID, limit: Int = 12,
                            fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [TopRow] {
        let total = Double(tree.size[Int(parent)])
        return topChildren(tree, of: parent, limit: limit).map { c in
            let b = tree.size[Int(c)]
            let name = tree.name(c)
            let path = tree.path(of: c)
            return TopRow(id: c, name: name, path: path, bytes: b,
                          fraction: total > 0 ? Double(b) / total : 0, isDir: tree.isDir[Int(c)],
                          canAct: canAct(name: name, path: path, fileExists: fileExists))
        }
    }
}

struct TopList: View {
    let tree: DiskTree
    let current: NodeID
    let revision: UInt64           // root size; changes while scanning so rows refresh
    var onClean: ([CleanItem]) -> Void
    @State private var rows: [TopRow] = []
    @State private var pendingTrash: TopRow?

    private struct Key: Equatable {
        let tree: ObjectIdentifier
        let current: NodeID
        let count: Int
        let revision: UInt64
    }

    private var key: Key {
        Key(tree: ObjectIdentifier(tree), current: current, count: tree.count, revision: revision)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                Text("Empty folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
            ForEach(rows) { row in
                rowView(row)
                    .contextMenu {
                        if row.canAct {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
                            }
                            if !Rules.isDenied(row.path) {
                                Button("Move to Trash", role: .destructive) { pendingTrash = row }
                            }
                        }
                    }
            }
        }
        .confirmationDialog(
            "Move to Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            titleVisibility: .visible,
            presenting: pendingTrash
        ) { row in
            Button("Move to Trash", role: .destructive) {
                onClean([CleanItem(path: row.path, bytes: row.bytes)])
            }
        } message: { row in
            Text("\(row.name) (\(ByteText.string(row.bytes))) will be moved to the Trash.")
        }
        .onAppear(perform: refresh)
        .onChange(of: key) { refresh() }
    }

    private func refresh() {
        rows = current < tree.count ? TopListLayout.rows(tree, of: current) : []
    }

    private func rowView(_ row: TopRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.isDir ? "folder.fill" : "doc.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(ByteText.string(row.bytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(Color.accentColor.gradient)
                            .frame(width: max(2, geo.size.width * row.fraction))
                    }
                }
                .frame(height: 4)
            }
        }
        .contentShape(Rectangle())
    }
}
