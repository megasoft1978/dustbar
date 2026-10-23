import AppKit
import Observation
import ServiceManagement
import SwiftUI

enum StatusTint: Sendable { case none, amber, red }

/// Ring glyph: track plus filled arc = used fraction.
private func ringImage(used: Double, tint: StatusTint) -> NSImage {
    NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        let color: NSColor
        switch tint {
        case .none: color = .black
        case .amber: color = .systemOrange
        case .red: color = .systemRed
        }
        let ring = rect.insetBy(dx: 1.5, dy: 1.5)
        color.withAlphaComponent(0.3).setStroke()
        let track = NSBezierPath(ovalIn: ring)
        track.lineWidth = 2.5
        track.stroke()
        if used > 0 {
            color.setStroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: ring.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * CGFloat(min(used, 1)), clockwise: true)
            arc.lineWidth = 2.5
            arc.stroke()
        }
        return true
    }
}

@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    private static let staleAfter = Duration.seconds(300)
    private static let maxDirtyPaths = 50_000

    private let model = AppModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var monitor: Monitor?
    private var dirtyPaths = Set<String>()
    private var needsFullRescan = false
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0                  // bumped on every start/cancel; stale scans publish nothing
    private var lastScanFinished: ContinuousClock.Instant?
    private var knownItemPaths = Set<String>()      // every item path seen by any completed scan
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    override init() {
        super.init()
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading

        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 420, height: 560)
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))

        model.onRescan = { [weak self] in self?.rescan(force: true) }
        model.onClean = { [weak self] items in self?.clean(items) }
        model.onEmptyTrash = { [weak self] items in self?.emptyTrash(items) }

        model.stats = Monitor.currentStats()
        refreshStatusItem()
        observeStats()

        // Caches and Trash churn constantly; changes there should not trigger rescans.
        let monitor = Monitor(
            root: home,
            ignorePrefixes: [home + "/Library/Caches", home + "/.Trash"],
            onStats: { [weak self] stats in
                Task { @MainActor in
                    if self?.model.stats != stats { self?.model.stats = stats }
                }
            },
            onDirty: { [weak self] paths in Task { @MainActor in self?.recordDirty(paths) } }
        )
        monitor.start()
        self.monitor = monitor
    }

    /// Called on quit: cancel any scan and stop watching.
    func shutdown() {
        cancelScan()
        monitor?.stop()
    }

    func popoverDidClose(_ notification: Notification) {
        cancelScan()
    }

    private func observeStats() {
        withObservationTracking {
            _ = model.stats
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshStatusItem()
                self?.observeStats()
            }
        }
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let stats = model.stats
        let free = stats.freeFraction
        let tint: StatusTint = free < 0.05 ? .red : (free < 0.15 ? .amber : .none)
        let used = stats.total == 0 ? 0 : Double(stats.used) / Double(stats.total)
        let image = ringImage(used: used, tint: tint)
        image.isTemplate = tint == .none
        button.image = image
        let color: NSColor = tint == .red ? .systemRed : (tint == .amber ? .systemOrange : .labelColor)
        button.attributedTitle = NSAttributedString(
            string: " " + Self.freeText(stats.free),
            attributes: [.foregroundColor: color, .font: NSFont.menuBarFont(ofSize: 0)]
        )
    }

    private static func freeText(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        return gb < 10 ? String(format: "%.1f GB", gb) : String(format: "%.0f GB", gb)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            if popover.isShown { popover.performClose(nil) }
            showMenu()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        scanIfStale()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed
        default: login.state = .off
        }
        // Only a real .app bundle can be registered as a login item.
        if !Bundle.main.bundlePath.hasSuffix(".app") {
            login.isEnabled = false
            login.toolTip = "Launch at Login needs DustBar.app (run scripts/bundle.sh)"
        }
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DustBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("DustBar launch-at-login toggle failed: \(error.localizedDescription)")
            showAlert("Could not change Launch at Login", error.localizedDescription)
            return
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func showAlert(_ title: String, _ detail: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    /// Popover opened: scan if there is no tree yet, or if dirty paths exist and the last scan is over 5 min old.
    private func scanIfStale() {
        guard model.tree != nil else { rescan(); return }
        let dirty = !dirtyPaths.isEmpty || needsFullRescan
        let stale = lastScanFinished.map { ContinuousClock.now - $0 > Self.staleAfter } ?? true
        if dirty && stale { rescan() }
    }

    private func recordDirty(_ paths: Set<String>) {
        guard !needsFullRescan else { return }
        dirtyPaths.formUnion(paths)
        if dirtyPaths.count > Self.maxDirtyPaths {
            dirtyPaths.removeAll()
            needsFullRescan = true
        }
    }

    /// Without `force`, a no-op while a scan runs. With `force`, cancels the running scan and restarts.
    private func rescan(force: Bool = false) {
        if model.scanning && !force { return }
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        model.scanning = true
        model.progress = ScanProgress()
        dirtyPaths.removeAll()
        needsFullRescan = false
        let root = home
        let model = self.model
        scanTask = Task { [weak self] in
            guard let tree = await Scanner.scanCancellable(root: root, progress: { progress in
                Task { @MainActor in
                    if self?.scanGeneration == generation { model.progress = progress }
                }
            }) else { return }
            let categories = await Rules.discover(home: root)
            guard !Task.isCancelled, let self, generation == self.scanGeneration else { return }

            // Keep the user's choices for paths that still exist; default-select only paths never seen before.
            let newPaths = Set(categories.flatMap(\.items).map(\.path))
            let defaults = Set(categories.filter(\.defaultSelected).flatMap(\.items).map(\.path))
            model.selectedItems = model.selectedItems.intersection(newPaths)
                .union(defaults.subtracting(self.knownItemPaths))
            self.knownItemPaths = newPaths
            model.tree = tree
            model.categories = categories
            model.progress.done = true
            model.scanning = false
            self.lastScanFinished = ContinuousClock.now
            self.scanTask = nil
        }
    }

    /// Cancels any running scan. Its result is discarded (never published).
    private func cancelScan() {
        if scanTask != nil { needsFullRescan = true }
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        model.scanning = false
    }

    private func clean(_ items: [CleanItem]) {
        runCleanup { Cleaner.trash(items) }
    }

    private func emptyTrash(_ items: [CleanItem]) {
        let home = self.home
        runCleanup { Cleaner.emptyTrash(items, home: home) }
    }

    /// Runs a cleaner off-main, publishes its result, then rescans (restarting any scan in flight so the view is fresh).
    private func runCleanup(_ work: @escaping @Sendable () -> CleanResult) {
        let model = self.model
        Task {
            let result = await Task.detached { work() }.value
            model.lastResult = result
            model.selectedItems = []
            self.rescan(force: true)
        }
    }
}
