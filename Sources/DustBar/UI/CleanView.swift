import SwiftUI
import AppKit

/// Pure selection logic for the Clean tab. No UI state; safe to unit-test.
public enum CleanSelection {
    public enum TriState: Equatable, Sendable { case none, some, all }

    public static let trashID = "trash"
    public static let listLimit = 100

    public static func state(of category: CleanCategory, selected: Set<String>) -> TriState {
        guard !category.items.isEmpty else { return .none }
        let picked = category.items.reduce(0) { $0 + (selected.contains($1.path) ? 1 : 0) }
        if picked == 0 { return .none }
        return picked == category.items.count ? .all : .some
    }

    /// all -> clears the category's items; none or some -> selects all of them.
    public static func toggle(_ category: CleanCategory, selected: inout Set<String>) {
        let paths = category.items.map(\.path)
        if state(of: category, selected: selected) == .all {
            selected.subtract(paths)
        } else {
            selected.formUnion(paths)
        }
    }

    public static func toggle(_ item: CleanItem, selected: inout Set<String>) {
        if selected.contains(item.path) { selected.remove(item.path) } else { selected.insert(item.path) }
    }

    /// Selected items in category order. A path listed in several categories is returned once.
    public static func resolve(_ categories: [CleanCategory], selected: Set<String>) -> [CleanItem] {
        var seen = Set<String>()
        var out: [CleanItem] = []
        for category in categories {
            for item in category.items where selected.contains(item.path) && seen.insert(item.path).inserted {
                out.append(item)
            }
        }
        return out
    }

    public static func selectedBytes(_ categories: [CleanCategory], selected: Set<String>) -> UInt64 {
        resolve(categories, selected: selected).reduce(0) { $0 &+ $1.bytes }
    }

    /// Footer split: regular selections go to Trash; the trash category is deleted permanently.
    /// A path selected under both goes to the permanent side only.
    public struct Plan: Equatable, Sendable {
        public var trash: [CleanItem]   // permanent deletion
        public var rest: [CleanItem]    // move to Trash
        public var trashBytes: UInt64 { trash.reduce(0) { $0 &+ $1.bytes } }
        public var restBytes: UInt64 { rest.reduce(0) { $0 &+ $1.bytes } }
    }

    public static func plan(_ categories: [CleanCategory], selected: Set<String>) -> Plan {
        let trash = resolve(categories.filter { $0.id == trashID }, selected: selected)
        let trashPaths = Set(trash.map(\.path))
        let rest = resolve(categories.filter { $0.id != trashID }, selected: selected)
            .filter { !trashPaths.contains($0.path) }
        return Plan(trash: trash, rest: rest)
    }

    /// After a cleanup: drops only the paths that were moved to Trash or refused. Failed paths stay selected.
    public static func droppingCleaned(_ selected: Set<String>, result: CleanResult) -> Set<String> {
        var gone = Set(result.trashed.map(\.path))
        gone.formUnion(result.refused.map(\.path))
        return selected.subtracting(gone)
    }

    /// Expanded-list rows: the `limit` largest items, biggest first; `hidden` counts the rest.
    public static func listed(_ category: CleanCategory, limit: Int = listLimit) -> (shown: [CleanItem], hidden: Int) {
        let sorted = category.items.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        return (Array(sorted.prefix(limit)), max(0, sorted.count - limit))
    }

    /// Replaces a leading home directory with "~".
    public static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + String(path.dropFirst(prefix.count))
    }

    /// Title of the snapshot-delete confirmation.
    public static func snapshotTitle(count: Int) -> String {
        count == 1
            ? "Permanently delete 1 local snapshot?"
            : "Permanently delete \(count) local snapshots?"
    }

    public static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    public static func summary(_ result: CleanResult, permanent: Bool = false) -> String {
        let action = permanent
            ? "Permanently deleted \(format(result.freedBytes))"
            : "Moved \(format(result.freedBytes)) to Trash"
        return "\(action) · \(result.refused.count) refused · \(result.failed.count) failed"
    }
}

public struct CleanView: View {
    let model: AppModel
    @State private var expanded: Set<String> = []
    @State private var confirming = false
    @State private var confirmingEmpty = false
    @State private var confirmingSnapshots = false
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    public init(model: AppModel) { self.model = model }

    private var hasItems: Bool { model.categories.contains { !$0.items.isEmpty } }
    /// Destructive actions wait until the categories match the latest scan and no cleanup is running.
    private var busy: Bool { model.scanning || model.discovering || model.cleaning }

    public var body: some View {
        let plan = CleanSelection.plan(model.categories, selected: model.selectedItems)
        VStack(spacing: 0) {
            if let result = model.lastResult { resultBanner(result) }
            if model.snapshotCount > 0 { snapshotCard }
            if model.discovering {
                ProgressView("Analyzing…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hasItems {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.categories) { categoryCard($0) }
                    }
                    .padding(12)
                }
                .scrollIndicators(.never)
            } else if model.scanning {
                ProgressView("Scanning…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
            if hasItems { footer(plan) }
        }
        .confirmationDialog(
            "Move \(CleanSelection.format(plan.restBytes)) to Trash?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                model.onClean?(plan.rest)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items go to the Trash and can be restored.")
        }
        .confirmationDialog(
            CleanSelection.snapshotTitle(count: model.snapshotCount),
            isPresented: $confirmingSnapshots,
            titleVisibility: .visible
        ) {
            Button("Delete Snapshots", role: .destructive) {
                model.onDeleteSnapshots?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Time Machine backups on your backup disk are not affected.")
        }
        .confirmationDialog(
            "Permanently delete \(plan.trash.count) items (\(CleanSelection.format(plan.trashBytes)))? This cannot be undone.",
            isPresented: $confirmingEmpty,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                model.onEmptyTrash?(plan.trash)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Sections

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Nothing to clean")
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultBanner(_ result: CleanResult) -> some View {
        let ok = result.failed.isEmpty
        return HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(CleanSelection.summary(result, permanent: result.permanent))
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding([.horizontal, .top], 12)
    }

    /// Time Machine local snapshots: a separate permanent action, never part of the Trash plan.
    private var snapshotCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Time Machine local snapshots")
                        .font(.body.weight(.semibold))
                    if let summary = model.snapshotSummary {
                        Text(summary)
                            .font(.callout)
                            .monospacedDigit()
                    }
                    Text("Local snapshots use space until macOS removes them. Deleting is permanent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer(minLength: 0)
                Button {
                    confirmingSnapshots = true
                } label: {
                    Label("Delete snapshots…", systemImage: "trash.slash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)
                .disabled(busy)
            }
            if let message = model.snapshotMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private func categoryCard(_ category: CleanCategory) -> some View {
        let state = CleanSelection.state(of: category, selected: model.selectedItems)
        let isOpen = expanded.contains(category.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                checkbox(state, label: category.title) {
                    CleanSelection.toggle(category, selected: &model.selectedItems)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title).font(.body.weight(.semibold))
                    Text(category.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(CleanSelection.format(category.bytes))
                        .monospacedDigit()
                    Text("\(category.items.count) items")
                        .font(.caption)
                }
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button {
                if isOpen { expanded.remove(category.id) } else { expanded.insert(category.id) }
            } label: {
                Label(isOpen ? "Hide" : "Review", systemImage: isOpen ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(category.items.isEmpty)

            if isOpen {
                let listed = CleanSelection.listed(category)
                VStack(spacing: 6) {
                    ForEach(listed.shown) { itemRow($0) }
                    if listed.hidden > 0 {
                        Text("+\(listed.hidden) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func itemRow(_ item: CleanItem) -> some View {
        HStack(spacing: 8) {
            checkbox(model.selectedItems.contains(item.path) ? .all : .none, label: item.path, font: .body) {
                CleanSelection.toggle(item, selected: &model.selectedItems)
            }
            Text(CleanSelection.abbreviate(item.path, home: home))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(CleanSelection.format(item.bytes))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(item.path) in Finder")
        }
    }

    private func footer(_ plan: CleanSelection.Plan) -> some View {
        VStack(spacing: 10) {
            if !plan.trash.isEmpty {
                Button {
                    confirmingEmpty = true
                } label: {
                    Label("Empty Trash (permanent)", systemImage: "trash.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(busy)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(CleanSelection.format(plan.restBytes))
                        .font(.headline)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                Button {
                    confirming = true
                } label: {
                    Label(
                        plan.rest.isEmpty ? "Move to Trash" : "Move \(CleanSelection.format(plan.restBytes)) to Trash",
                        systemImage: "trash"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(plan.rest.isEmpty || busy)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: Helpers

    private func checkbox(_ state: CleanSelection.TriState, label: String, font: Font = .title3,
                          action: @escaping () -> Void) -> some View {
        let symbol: String
        switch state {
        case .none: symbol = "square"
        case .some: symbol = "minus.square.fill"
        case .all: symbol = "checkmark.square.fill"
        }
        return Button(action: action) {
            Image(systemName: symbol)
                .font(font)
                .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(state == .all ? "selected" : state == .some ? "partially selected" : "not selected")
    }
}
