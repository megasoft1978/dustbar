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
final class StatusController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private static let staleAfter = Duration.seconds(300)
    private static let maxDirtyPaths = 50_000
    private static let snapshotGap = Duration.milliseconds(900)   // min main-actor gap between live snapshots (~1 s)

    private let model = AppModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var monitor: Monitor?
    private var dirtyPaths = Set<String>()
    private var needsFullRescan = false
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0                  // bumped on every start/cancel; stale scans publish nothing
    private var lastScanFinished: ContinuousClock.Instant?
    private var lastSnapshotAt: ContinuousClock.Instant?
    private var preLiveTree: DiskTree?              // last complete tree, restored if a live scan is discarded
    private var knownItemPaths = Set<String>()      // every item path seen by any completed scan
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let lowDisk = LowDiskAlert()
    private let menu = NSMenu()
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let alertSubmenu = NSMenu()

    override init() {
        super.init()
        buildMenu()
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading

        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 420, height: PopoverView.height)

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
        loadCachedTree()
    }

    /// Shows the last saved tree right away (flagged via `model.cachedAt`) while the first fresh scan has not published yet.
    private func loadCachedTree() {
        let root = home
        Task { [weak self] in
            let cached = await Task.detached(priority: .utility) { TreeCache.load(root: root) }.value
            guard let self, let cached, self.model.tree == nil else { return }
            self.model.tree = cached.tree
            self.model.cachedAt = cached.scannedAt
        }
    }

    /// Called on quit: cancel any scan and stop watching.
    func shutdown() {
        cancelScan()
        monitor?.stop()
    }

    // A running scan keeps going after the popover closes so the next open shows a finished result.
    // The SwiftUI view is dropped on close: a hidden hosting view keeps its render buffers (hundreds of MB while scanning).
    func popoverDidClose(_ notification: Notification) {
        guard !popover.isShown else { return }   // reopened before this close notification ran
        discardLiveSnapshot()   // restores the last complete tree and releases the partial snapshot
        popover.contentViewController = nil
        malloc_zone_pressure_relief(nil, 0)
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
        button.toolTip = "\(Self.byteText(stats.used)) / \(Self.byteText(stats.total))"
        lowDisk.evaluate(stats)
    }

    private static func freeText(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        return gb < 10 ? String(format: "%.1f GB", gb) : String(format: "%.0f GB", gb)
    }

    private static func byteText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .decimal)
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
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        scanIfStale()
    }

    /// Built once; state is refreshed in `menuWillOpen` so it is current every time the menu opens.
    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let alertItem = NSMenuItem(title: "Alert below", action: nil, keyEquivalent: "")
        for (index, threshold) in AlertThreshold.allCases.enumerated() {
            let item = NSMenuItem(title: threshold.title, action: #selector(setAlertThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            alertSubmenu.addItem(item)
        }
        alertItem.submenu = alertSubmenu
        menu.addItem(alertItem)

        let rescanItem = NSMenuItem(title: "Rescan now", action: #selector(rescanNow), keyEquivalent: "r")
        rescanItem.target = self
        menu.addItem(rescanItem)
        let aboutItem = NSMenuItem(title: "About DustBar", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DustBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menuWillOpen(_ menu: NSMenu) {
        switch SMAppService.mainApp.status {
        case .enabled: loginItem.state = .on
        case .requiresApproval: loginItem.state = .mixed
        default: loginItem.state = .off
        }
        // Only a real .app bundle can be registered as a login item.
        let isBundle = Bundle.main.bundlePath.hasSuffix(".app")
        loginItem.isEnabled = isBundle
        loginItem.toolTip = isBundle ? nil : "Launch at Login needs DustBar.app (run scripts/bundle.sh)"
        for item in alertSubmenu.items {
            item.state = AlertThreshold.allCases[item.tag] == lowDisk.threshold ? .on : .off
        }
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func setAlertThreshold(_ sender: NSMenuItem) {
        lowDisk.setThreshold(AlertThreshold.allCases[sender.tag])
        refreshStatusItem()   // re-evaluates immediately against current free space
    }

    @objc private func rescanNow() {
        rescan(force: true)
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)   // shows name and version from Info.plist
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
        guard model.tree != nil, model.cachedAt == nil else { rescan(); return }   // cached tree: always refresh
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
        discardLiveSnapshot()
        model.scanning = true
        model.discovering = true   // until the categories below are republished; cleared on cancel too
        model.progress = ScanProgress()
        dirtyPaths.removeAll()
        needsFullRescan = false
        lastSnapshotAt = nil
        let root = home
        let model = self.model
        scanTask = Task { [weak self] in
            guard let tree = await Scanner.scanLive(root: root, snapshotInterval: 1.0, onSnapshot: { snapshot in
                Task { @MainActor in self?.publishSnapshot(snapshot, generation: generation) }
            }, progress: { progress in
                Task { @MainActor in
                    if self?.scanGeneration == generation { model.progress = progress }
                }
            }) else { return }

            // Final tree: publish it, then derive categories from it. Each await re-checks the generation.
            guard !Task.isCancelled, let self, generation == self.scanGeneration else { return }
            self.preLiveTree = nil
            model.tree = tree
            model.cachedAt = nil
            model.isLiveSnapshot = false
            model.scanning = false
            self.lastScanFinished = ContinuousClock.now
            Task.detached(priority: .utility) {
                if let dev = TreeCache.deviceID(of: root) { TreeCache.save(tree, device: dev) }
            }

            let discovered = await Rules.discover(home: root)
            let basePaths = Set(discovered.flatMap(\.items).map(\.path))
            let dupResult = await Duplicates.find(tree: tree, excluding: basePaths)   // defaultSelected == false
            let large = Rules.largeFiles(from: tree, home: root)
            guard !Task.isCancelled, generation == self.scanGeneration else { return }
            let categories = Self.dedupe(base: discovered, duplicates: dupResult.category.map { [$0] } ?? [], kept: dupResult.kept, large: large)

            // Keep the user's choices for paths that still exist; default-select only paths never seen before.
            let newPaths = Set(categories.flatMap(\.items).map(\.path))
            let defaults = Set(categories.filter(\.defaultSelected).flatMap(\.items).map(\.path))
            model.selectedItems = model.selectedItems.intersection(newPaths)
                .union(defaults.subtracting(self.knownItemPaths))
            self.knownItemPaths = newPaths
            model.categories = categories
            model.discovering = false
            model.progress.done = true
            self.scanTask = nil
            malloc_zone_pressure_relief(nil, 0)   // hand the walk's and hashing's freed pages back
        }
    }

    /// Publishes a partial tree from a running scan. Throttled on the main actor; ignored once the scan is stale.
    private func publishSnapshot(_ snapshot: DiskTree, generation: Int) {
        guard popover.isShown, scanGeneration == generation, model.scanning, model.cachedAt == nil else { return }   // keep showing the full cached tree
        let now = ContinuousClock.now
        if let last = lastSnapshotAt, now - last < Self.snapshotGap { return }
        lastSnapshotAt = now
        if !model.isLiveSnapshot { preLiveTree = model.tree }
        model.tree = snapshot
        model.isLiveSnapshot = true
    }

    /// Replaces a partial live tree with the last complete tree (nil if there was none).
    private func discardLiveSnapshot() {
        guard model.isLiveSnapshot else { return }
        model.tree = preLiveTree
        model.isLiveSnapshot = false
        preLiveTree = nil
    }

    /// One place per path: duplicate and large items equal to or under any base item are dropped, `kept`
    /// copies leave the large category, and large files also drop items under duplicates. Empty categories are dropped.
    nonisolated static func dedupe(base: [CleanCategory], duplicates: [CleanCategory], kept: Set<String> = [],
                                   large: CleanCategory?) -> [CleanCategory] {
        let basePaths = Set(base.flatMap(\.items).map(\.path))
        func covered(_ path: String, _ set: Set<String>) -> Bool { set.contains(path) || hasAncestor(path, in: set) }
        let dupes = duplicates.map { category -> CleanCategory in
            var c = category
            c.items = category.items.filter { !covered($0.path, basePaths) }
            return c
        }
        let claimed = basePaths.union(dupes.flatMap(\.items).map(\.path))
        var result = base + dupes
        if var big = large {
            big.items = big.items.filter { !covered($0.path, claimed) && !kept.contains($0.path) }
            result.append(big)
        }
        return result.filter { !$0.items.isEmpty }
    }

    private nonisolated static func hasAncestor(_ path: String, in paths: Set<String>) -> Bool {
        var current = Substring(path)
        while let slash = current.lastIndex(of: "/"), slash != current.startIndex {
            current = current[..<slash]
            if paths.contains(String(current)) { return true }
        }
        return false
    }

    /// Cancels any running scan. Its result is discarded (never published).
    private func cancelScan() {
        if scanTask != nil { needsFullRescan = true }
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        discardLiveSnapshot()
        model.scanning = false
        model.discovering = false
    }

    private func clean(_ items: [CleanItem]) {
        runCleanup(permanent: false) { Cleaner.trash(items) }
    }

    private func emptyTrash(_ items: [CleanItem]) {
        let home = self.home
        runCleanup(permanent: true) { Cleaner.emptyTrash(items, home: home) }
    }

    /// Runs a cleaner off-main, publishes its result, then rescans (restarting any scan in flight so the view is fresh).
    private func runCleanup(permanent: Bool, _ work: @escaping @Sendable () -> CleanResult) {
        guard !model.cleaning else { return }   // ignore a second submit while one runs
        model.cleaning = true
        let model = self.model
        Task {
            var result = await Task.detached { work() }.value
            result.permanent = permanent
            model.cleaning = false
            model.lastResult = result
            model.selectedItems = CleanSelection.droppingCleaned(model.selectedItems, result: result)
            model.categories = []   // stale cards must not stay actionable while the rescan runs
            self.rescan(force: true)
        }
    }
}

