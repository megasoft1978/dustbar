import AppKit
import SwiftUI

extension FileTypes.Kind {
    var title: String {
        switch self {
        case .video: "Video"
        case .images: "Images"
        case .audio: "Audio"
        case .archives: "Archives"
        case .documents: "Documents"
        case .code: "Code"
        case .apps: "Apps"
        case .diskImages: "Disk images"
        case .other: "Other"
        case .smallFiles: "Other (small files)"
        }
    }

    var symbol: String {
        switch self {
        case .video: "film.fill"
        case .images: "photo.fill"
        case .audio: "music.note"
        case .archives: "archivebox.fill"
        case .documents: "doc.text.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .apps: "app.fill"
        case .diskImages: "opticaldiscdrive.fill"
        case .other: "doc.fill"
        case .smallFiles: "square.grid.2x2.fill"
        }
    }

    var color: Color {
        switch self {
        case .video: .purple
        case .images: .pink
        case .audio: .orange
        case .archives: .brown
        case .documents: .blue
        case .code: .green
        case .apps: .teal
        case .diskImages: .indigo
        case .other: .gray
        case .smallFiles: .gray.opacity(0.45)
        }
    }
}

/// Size by file type: one stacked bar, then a row per kind that expands to its largest files.
/// Reveal in Finder is the only action; nothing here deletes.
public struct TypesView: View {
    let model: AppModel
    @State private var slices: [FileTypes.TypeSlice] = []
    @State private var expanded: FileTypes.Kind?
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

    /// "1 file", "2 files", "1 folder": the count and the noun agree.
    static func countText(_ count: Int, folders: Bool) -> String {
        "\(count.formatted()) \(folders ? "folder" : "file")\(count == 1 ? "" : "s")"
    }

    public var body: some View {
        if let tree = model.tree, tree.count > 0 {
            VStack(alignment: .leading, spacing: 10) {
                Text("By type")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 6)
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else if slices.isEmpty {
                    Text("No files")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    bar
                    list
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .dustCard()
            .task(id: key) { await reload() }
        } else {
            let scanning = model.scanning && model.tree == nil
            ContentUnavailableView(
                scanning ? "Scanning…" : "Not scanned yet",
                systemImage: scanning ? "magnifyingglass" : "externaldrive.badge.questionmark",
                description: Text(scanning ? "Types appear when the scan finishes." : "Press Rescan to start.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reload() async {
        guard let tree = model.tree else { slices = []; return }
        let next = await Task.detached(priority: .userInitiated) { FileTypes.breakdown(tree: tree) }.value
        guard !Task.isCancelled else { return }
        slices = next
        loaded = true
    }

    private var bar: some View {
        let total = Double(max(1, slices.reduce(UInt64(0)) { $0 &+ $1.bytes }))
        return GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(slices) { slice in
                    Rectangle()
                        .fill(slice.kind.color.gradient)
                        .frame(width: geo.size.width * Double(slice.bytes) / total)
                }
            }
        }
        .frame(height: 12)
        .clipShape(Capsule())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: slices)
        .accessibilityHidden(true)
    }

    private var list: some View {
        let total = max(1, slices.reduce(UInt64(0)) { $0 &+ $1.bytes })
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(slices) { slice in
                    kindRow(slice, total: total)
                    if expanded == slice.kind {
                        ForEach(slice.top, id: \.path) { file in
                            fileRow(file)
                        }
                        .transition(.opacity)
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func toggle(_ kind: FileTypes.Kind) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            expanded = expanded == kind ? nil : kind
        }
    }

    private func kindRow(_ slice: FileTypes.TypeSlice, total: UInt64) -> some View {
        let isOpen = expanded == slice.kind
        let share = Double(slice.bytes) / Double(total)
        return Button { toggle(slice.kind) } label: {
            HStack(spacing: 10) {
                Image(systemName: slice.kind.symbol)
                    .foregroundStyle(slice.kind.color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(slice.kind.title)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(ByteText.string(slice.bytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    Text("\(Self.countText(slice.count, folders: slice.kind == .smallFiles)) · \(share.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isOpen ? "Hide largest files" : "Show largest files")
    }

    private func fileRow(_ file: FileTypes.TypedFile) -> some View {
        let url = URL(fileURLWithPath: file.path)
        let canReveal = model.cachedAt == nil
        return Button {
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            HStack(spacing: 8) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(ByteText.string(file.bytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.vertical, 3)
            .padding(.leading, 34)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canReveal)
        .help(file.path)
    }
}
