import SwiftUI

/// Formats byte counts with the system file-size style.
enum ByteText {
    static func string(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

extension View {
    /// Rounded glass card: native glass on macOS 26+, ultra-thin material before.
    @ViewBuilder
    func dustCard(cornerRadius: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

// Slice E owns PopoverView/SunburstView/TopList; slice F owns CleanView.
public struct PopoverView: View {
    let model: AppModel
    @State private var tab: Tab = .explore
    @State private var current: NodeID = 0

    private enum Tab: Hashable { case explore, clean }

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 12) {
            header
            Picker("Section", selection: $tab) {
                Text("Explore").tag(Tab.explore)
                Text("Clean").tag(Tab.clean)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch tab {
            case .explore:
                explore
            case .clean:
                CleanView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(width: 420, height: 560)
        .background(.ultraThinMaterial)
    }

    // MARK: Header

    private var header: some View {
        let s = model.stats
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ByteText.string(s.free)) free")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("of \(ByteText.string(s.total))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.onRescan?()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.scanning)
                .help("Rescan")
            }
            UsageBar(stats: s)
            legend(s)
            if model.scanning { scanning }
            if model.progress.unreadableDirs > 0 {
                Label("Grant Full Disk Access for complete results", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .dustCard()
    }

    private func legend(_ s: VolumeStats) -> some View {
        let purge = min(s.purgeable, s.free)
        return HStack(spacing: 14) {
            LegendDot(color: .accentColor, label: "Used", bytes: s.used)
            LegendDot(color: .orange.opacity(0.7), label: "Purgeable", bytes: purge)
            LegendDot(color: .secondary.opacity(0.25), label: "Free", bytes: s.free - purge)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView()
                .progressViewStyle(.linear)
            Text("Scanning \(model.progress.files.formatted()) files · \(ByteText.string(model.progress.bytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: Explore

    @ViewBuilder
    private var explore: some View {
        if let tree = model.tree, tree.count > 0 {
            let rev = tree.size[0]
            ScrollView {
                VStack(spacing: 12) {
                    SunburstView(tree: tree, current: $current, revision: rev)
                        .frame(height: 300)
                        .padding(12)
                        .dustCard()
                    TopList(tree: tree, current: current, revision: rev,
                            onClean: { model.onClean?($0) })
                        .padding(12)
                        .dustCard()
                }
            }
            .scrollIndicators(.hidden)
        } else {
            ContentUnavailableView(
                "Not scanned yet",
                systemImage: "externaldrive.badge.questionmark",
                description: Text(model.scanning ? "Scanning…" : "Press Rescan to start.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct UsageBar: View {
    let stats: VolumeStats

    var body: some View {
        GeometryReader { geo in
            let total = Double(max(stats.total, 1))
            let purge = min(stats.purgeable, stats.free)
            let w = Double(geo.size.width)
            HStack(spacing: 0) {
                Rectangle().fill(Color.accentColor)
                    .frame(width: w * Double(stats.used) / total)
                Rectangle().fill(Color.orange.opacity(0.7))
                    .frame(width: w * Double(purge) / total)
                Rectangle().fill(Color.secondary.opacity(0.25))
                    .frame(width: w * Double(stats.free - purge) / total)
            }
        }
        .frame(height: 12)
        .clipShape(Capsule())
    }
}

private struct LegendDot: View {
    let color: Color
    let label: String
    let bytes: UInt64

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label) \(ByteText.string(bytes))")
                .monospacedDigit()
        }
    }
}
