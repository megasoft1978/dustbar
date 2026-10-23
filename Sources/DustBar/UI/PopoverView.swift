import AppKit
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 680

    private enum Tab: Hashable { case explore, clean }

    public init(model: AppModel) { self.model = model }

    /// Test hook: starts on the Clean tab when `showClean` is true.
    init(model: AppModel, showClean: Bool) {
        self.model = model
        self._tab = State(initialValue: showClean ? .clean : .explore)
    }

    public var body: some View {
        VStack(spacing: 10) {
            header
            if model.progress.unreadableDirs > 0 { fullDiskAccessBanner }
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
        .padding(14)
        .frame(width: 420, height: PopoverView.height)
        .background(.ultraThinMaterial)
        // A new tree (rescan) has different node ids; drop the drill-down position from the old one.
        .onChange(of: model.tree.map(ObjectIdentifier.init)) { current = 0 }
    }

    // MARK: Header

    private var header: some View {
        let s = model.stats
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ByteText.string(s.free)) free")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
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
            if model.scanning { scanning.transition(.opacity) }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: model.scanning)
        .padding(12)
        .dustCard()
    }

    private var fullDiskAccessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
            Text("Some folders skipped. Grant Full Disk Access.")
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            scanLabel
        }
    }

    @ViewBuilder
    private var scanLabel: some View {
        let text = Text("Scanning… \(model.progress.files.formatted()) files · \(ByteText.string(model.progress.bytes))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        if reduceMotion {
            text
        } else {
            text.phaseAnimator([1.0, 0.45]) { view, phase in
                view.opacity(phase)
            } animation: { _ in
                .easeInOut(duration: 0.9)
            }
        }
    }

    // MARK: Explore

    @ViewBuilder
    private var explore: some View {
        if let tree = model.tree, tree.count > 0 {
            let rev = tree.size[0]
            VStack(spacing: 10) {
                SunburstView(tree: tree, current: $current, revision: rev, live: model.isLiveSnapshot)
                    .frame(height: 244)
                    .padding(10)
                    .dustCard()
                // Only the list scrolls, inside the space left under the chart.
                TopList(tree: tree, current: $current, revision: rev, live: model.isLiveSnapshot,
                        onClean: { model.onClean?($0) }, busy: model.cleaning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .dustCard()
            }
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
