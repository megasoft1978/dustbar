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
    private static let fullRescanAfter = Duration.seconds(24 * 3600)
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
    private var activeSignature: String?            // root + exclusions of the newest scan started (may still be running)
    private var lastFullScan: ContinuousClock.Instant?   // last complete walk of the whole root (not an incremental refresh)
    private var confirmedSnapshots: [LocalSnapshot] = []  // the list behind the count/summary the user sees; delete acts on this only
    private var lastSnapshotAt: ContinuousClock.Instant?
    private var preLiveTree: DiskTree?              // last complete tree, restored if a live scan is discarded
    private var knownItemPaths = Set<String>()      // every item path seen by any completed scan
    private let home: String
    private let settings: Settings
    private let lowDisk: LowDiskAlert
    private lazy var reminder = CleanupReminder(settings: settings)
    private let snapshotOps: SnapshotOps
    private var scannedSignature: String?           // root + exclusions of the tree on screen (nil: unknown, e.g. cached)
    private var lastPrune: UInt64?                  // pruneBelow used by the last complete scan; refresh must match it
    private let menu = NSMenu()
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    private var scanRoot: String { ShellLogic.scanRoot(scope: settings.scanScope, home: home) }

    init(snapshotOps: SnapshotOps = .live) {
        #if DUSTBAR_DEMO
        if let demo = DemoMode.options {
            let suite = UserDefaults(suiteName: DemoMode.suiteName) ?? .standard
            self.snapshotOps = DemoFixture.snapshotOps()
            home = DemoFixture.root
            settings = Settings(defaults: suite, home: DemoFixture.root)
            lowDisk = LowDiskAlert(defaults: suite, notify: { _ in })
            demoOptions = demo
        } else {
            self.snapshotOps = snapshotOps
            home = FileManager.default.homeDirectoryForCurrentUser.path
            settings = Settings()
            lowDisk = LowDiskAlert()
        }
        #else
        self.snapshotOps = snapshotOps
        home = FileManager.default.homeDirectoryForCurrentUser.path
        settings = Settings()
        lowDisk = LowDiskAlert()
        #endif
        super.init()
        lowDisk.setThreshold(settings.lowDiskThreshold)   // Settings and LowDiskAlert share one UserDefaults key
        observeSettings()
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
        model.onRefreshSnapshots = { [weak self] in self?.refreshSnapshots() }
        model.onDeleteSnapshots = { [weak self] in self?.deleteSnapshots() }

        #if DUSTBAR_DEMO
        if let demo = demoOptions {
            startDemo(demo)
            return
        }
        #endif

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
        let root = scanRoot
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
        #if DUSTBAR_DEMO
        if demoOptions != nil, model.scanning || model.isLiveSnapshot {
            demoTask?.cancel()
            DemoMode.populate(model, snapshotOps: snapshotOps)
        }
        #endif
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

    /// Threshold changes apply at once; scope and exclusion changes trigger a rescan right away.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.lowDiskThreshold
            _ = settings.scanScope
            _ = settings.excludedFolders
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.lowDisk.threshold != self.settings.lowDiskThreshold {
                    self.lowDisk.setThreshold(self.settings.lowDiskThreshold)
                    self.refreshStatusItem()
                }
                let sig = ShellLogic.signature(root: self.scanRoot, excluded: Set(self.settings.excludedFolders))
                if let known = self.activeSignature ?? self.scannedSignature, known != sig {
                    self.rescan(force: true)   // scope or exclusions changed: do not wait for the next popover open
                }
                self.observeSettings()
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
        #if DUSTBAR_DEMO
        if let demo = demoOptions {
            let scheme: ColorScheme? = demo.dark.map { $0 ? .dark : .light }
            let host = NSHostingController(rootView: AnyView(PopoverView(model: model, tab: demo.tab).preferredColorScheme(scheme)))
            if let appearance = DemoMode.forcedAppearance {
                popover.appearance = appearance
                host.view.appearance = appearance
            }
            popover.contentViewController = host
        } else {
            popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))
        }
        #else
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))
        #endif
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

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

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
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func showSettings() {
        SettingsWindow.show(settings: settings, launchAtLogin: .mainApp)
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

    /// Popover opened: full scan if there is no tree, it came from the cache, or settings changed what is scanned.
    /// Otherwise refresh incrementally when dirty paths are few; fall back to a full rescan when that is not possible
    /// or the dirty set is too large and the last scan is over 5 min old.
    private func scanIfStale() {
        guard let tree = model.tree, model.cachedAt == nil else { rescan(); return }   // cached tree: always refresh
        guard scannedSignature == ShellLogic.signature(root: scanRoot, excluded: Set(settings.excludedFolders)) else {
            rescan()   // scope or exclusions changed
            return
        }
        if lastFullScan.map({ ContinuousClock.now - $0 > Self.fullRescanAfter }) ?? true {
            rescan()   // periodic full walk: incremental refreshes ignore small root-level file changes
            return
        }
        // Incremental only for the home scope: the Monitor watches home alone, so whole-disk changes are invisible to it.
        if settings.scanScope == .home, !needsFullRescan, !model.scanning, !dirtyPaths.isEmpty {
            let dirty = ShellLogic.normalizeDirty(dirtyPaths, root: tree.rootPath)
            if dirty.isEmpty {
                dirtyPaths.removeAll()   // all outside the tree root
            } else if dirty.count <= ShellLogic.maxRefreshPaths {
                refreshIncrementally(tree: tree, dirty: dirty)
                return
            }
        }
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
        #if DUSTBAR_DEMO
        if demoOptions != nil { demoRescan(force: force); return }
        #endif
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
        let root = scanRoot
        let settingsExcluded = Set(settings.excludedFolders)
        let excluded = ShellLogic.excludedForScan(root: root, excluded: settingsExcluded)
        let prune = Scanner.defaultPruneThreshold(root: root)
        let signature = ShellLogic.signature(root: root, excluded: settingsExcluded)
        activeSignature = signature
        let homeScope = settings.scanScope == .home
        let model = self.model
        scanTask = Task { [weak self] in
            guard let tree = await Scanner.scanLive(root: root, snapshotInterval: 1.0, pruneBelow: prune, excluded: excluded, onSnapshot: { snapshot in
                Task { @MainActor in self?.publishSnapshot(snapshot, generation: generation) }
            }, progress: { progress in
                Task { @MainActor in
                    if self?.scanGeneration == generation { model.progress = progress }
                }
            }) else { return }
            guard !Task.isCancelled, let self, generation == self.scanGeneration else { return }
            await self.finishScan(tree: tree, root: root, homeScope: homeScope, prune: prune, signature: signature, generation: generation, full: true)
        }
    }

    /// Re-walks only the dirty directories of the complete tree on screen. Falls back to a full rescan when
    /// `Scanner.refresh` declines (too many dirs, root dirty, cancelled, ...).
    private func refreshIncrementally(tree: DiskTree, dirty: Set<String>) {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        model.scanning = true
        model.discovering = true
        model.progress = ScanProgress()
        dirtyPaths.removeAll()
        lastSnapshotAt = nil
        let root = home
        let settingsExcluded = Set(settings.excludedFolders)
        let excluded = ShellLogic.excludedForScan(root: root, excluded: settingsExcluded)
        let prune = lastPrune ?? Scanner.defaultPruneThreshold(root: tree.rootPath)
        let signature = scannedSignature ?? ShellLogic.signature(root: root, excluded: settingsExcluded)
        activeSignature = signature
        scanTask = Task { [weak self] in
            let refreshed = await Scanner.refresh(tree: tree, dirtyPaths: dirty, pruneBelow: prune, excluded: excluded)
            guard !Task.isCancelled, let self, generation == self.scanGeneration else { return }
            guard let refreshed else { self.rescan(force: true); return }
            await self.finishScan(tree: refreshed, root: root, homeScope: true, prune: prune, signature: signature, generation: generation)
        }
    }

    /// Publishes a complete tree (full or refreshed), persists it, then derives categories and notifications.
    /// Every await re-checks the generation.
    private func finishScan(tree: DiskTree, root: String, homeScope: Bool, prune: UInt64, signature: String, generation: Int, full: Bool = false) async {
        let excluded = Set(settings.excludedFolders)
        preLiveTree = nil
        model.tree = tree
        model.cachedAt = nil
        model.isLiveSnapshot = false
        model.scanning = false
        lastScanFinished = ContinuousClock.now
        if full { lastFullScan = lastScanFinished }
        scannedSignature = signature
        lastPrune = prune
        Task.detached(priority: .utility) {
            if let dev = TreeCache.deviceID(of: root) { TreeCache.save(tree, device: dev) }
            History.record(tree: tree)
        }

        // Whole-disk scans are explore-only: no discovery, large files or duplicates outside the home scope.
        var categories: [CleanCategory] = []
        if homeScope {
            let discovered = await Rules.discover(home: root, excluded: excluded)
            let basePaths = Set(discovered.flatMap(\.items).map(\.path))
            let dupResult = await Duplicates.find(tree: tree, excluding: basePaths)   // defaultSelected == false
            let large = Rules.largeFiles(from: tree, home: root, excluded: excluded)
            guard !Task.isCancelled, generation == scanGeneration else { return }
            categories = Self.dedupe(base: discovered, duplicates: dupResult.category.map { [$0] } ?? [], kept: dupResult.kept, large: large)
        }

        // Keep the user's choices for paths that still exist; default-select only paths never seen before.
        let newPaths = Set(categories.flatMap(\.items).map(\.path))
        let defaults = Set(categories.filter(\.defaultSelected).flatMap(\.items).map(\.path))
        model.selectedItems = model.selectedItems.intersection(newPaths)
            .union(defaults.subtracting(knownItemPaths))
        knownItemPaths = newPaths
        model.categories = categories
        model.discovering = false
        model.progress.done = true
        scanTask = nil
        if homeScope { reminder.notify(cleanableBytes: ShellLogic.cleanableBytes(categories)) }
        refreshSnapshots()
        malloc_zone_pressure_relief(nil, 0)   // hand the walk's and hashing's freed pages back
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

    // MARK: Time Machine snapshots

    private func applySnapshots(_ snaps: [LocalSnapshot]) {
        let shown = SnapshotFlow.display(snaps)
        confirmedSnapshots = snaps
        model.snapshotCount = shown.count
        model.snapshotSummary = shown.summary
    }

    private func refreshSnapshots() {
        let ops = snapshotOps
        Task { [weak self] in
            let snaps = await Task.detached(priority: .utility) { ops.list() }.value
            self?.applySnapshots(snaps)
        }
    }

    /// PERMANENT: deletes every listed snapshot. The UI confirms first. Ignored while scanning or cleaning.
    private func deleteSnapshots() {
        guard !model.scanning, !model.cleaning else { return }
        model.cleaning = true
        model.snapshotMessage = nil
        let ops = snapshotOps
        let confirmed = confirmedSnapshots
        Task { [weak self] in
            let outcome = await SnapshotFlow.deleteAll(ops: ops, confirmed: confirmed)
            guard let self else { return }
            self.model.cleaning = false
            self.applySnapshots(outcome.remaining)
            self.model.stats = Monitor.currentStats()
            self.model.snapshotMessage = outcome.message
        }
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

    #if DUSTBAR_DEMO
    // MARK: Demo mode (compiled only with -DDUSTBAR_DEMO)

    private var demoOptions: DemoMode.Options?
    private var demoTask: Task<Void, Never>?
    private var demoReplayed = false

    private func startDemo(_ options: DemoMode.Options) {
        DemoMode.install(on: model, real: .init(
            trash: { Cleaner.trash($0) },
            emptyTrash: { Cleaner.emptyTrash($0, home: DemoFixture.root) },
            deleteSnapshot: { Snapshots.delete($0) }))
        model.onRescan = { [weak self] in self?.demoRescan(force: true) }
        DemoMode.populate(model, snapshotOps: snapshotOps)
        if let tree = model.tree { DemoMode.installHistory(tree: tree) }
        refreshStatusItem()
        observeStats()
        if let path = options.exportStatusItem, let button = statusItem.button {
            let ok = DemoMode.exportStatusItem(image: button.image, title: button.attributedTitle, dark: options.dark ?? true, to: path)
            if let dir = History.demoURL?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: dir) }
            FileHandle.standardError.write(Data((ok ? "exported \(path)\n" : "export failed\n").utf8))
            exit(ok ? 0 : 1)
        }
        DemoMode.prepare(options) { [weak self] in
            guard let self, let button = self.statusItem.button, !self.popover.isShown else { return }
            self.statusItemClicked(button)
        }
    }

    /// Opening the popover replays the scan once when `--demo-scan` is set; the Rescan button always replays.
    private func demoRescan(force: Bool) {
        guard let options = demoOptions, force || (options.scan && !demoReplayed) else { return }
        demoReplayed = true
        demoTask?.cancel()
        let model = self.model
        let ops = snapshotOps
        demoTask = Task { await DemoMode.replayScan(model, snapshotOps: ops) }
    }
    #endif
}
