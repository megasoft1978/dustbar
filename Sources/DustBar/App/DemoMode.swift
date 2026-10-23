#if DUSTBAR_DEMO || DEBUG
import AppKit
import Foundation

/// Demo mode for marketing screenshots: the real UI over synthetic data (see DemoFixture).
/// Flags are honoured only in builds compiled with `-DDUSTBAR_DEMO` and only together with `--demo`.
@MainActor
enum DemoMode {
    static let message = "Demo: nothing was moved"
    static let suiteName = "dustbar.demo"

    struct Options: Equatable {
        var tab: PopoverView.Tab = .explore
        var dark: Bool?                 // nil: follow the system
        var scan = false
        var open = false
        var backdrop = false
        var exportStatusItem: String?   // write the menu bar item as a PNG, then quit
    }

    /// Nil unless `--demo` is present. Unknown values keep the defaults.
    nonisolated static func parse(_ args: [String]) -> Options? {
        guard args.contains("--demo") else { return nil }
        var o = Options()
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        switch value("--demo-tab") {
        case "types": o.tab = .types
        case "growth": o.tab = .growth
        case "clean": o.tab = .clean
        default: o.tab = .explore
        }
        switch value("--demo-appearance") {
        case "dark": o.dark = true
        case "light": o.dark = false
        default: break
        }
        o.scan = args.contains("--demo-scan")
        o.open = args.contains("--demo-open")
        o.backdrop = args.contains("--demo-backdrop")
        o.exportStatusItem = value("--demo-export-statusitem")
        return o
    }

    /// The real destructive actions. Demo mode accepts them only so wiring looks the same; it never calls them.
    struct RealActions: Sendable {
        var trash: @Sendable ([CleanItem]) -> CleanResult
        var emptyTrash: @Sendable ([CleanItem]) -> CleanResult
        var deleteSnapshot: @Sendable (LocalSnapshot) -> Bool
    }

    /// Replaces the model's destructive callbacks with ones that only show `message`.
    static func install(on model: AppModel, real: RealActions) {
        _ = real
        model.onClean = { [weak model] _ in flash(model) }
        model.onEmptyTrash = { [weak model] _ in flash(model) }
        model.onDeleteSnapshots = { [weak model] in flash(model) }
        model.onRefreshSnapshots = {}
    }

    private static func flash(_ model: AppModel?) {
        guard let model else { return }
        model.snapshotMessage = message
        Task { @MainActor [weak model] in
            try? await Task.sleep(for: .seconds(4))
            if model?.snapshotMessage == message { model?.snapshotMessage = nil }
        }
    }

    /// Complete demo state, no disk access.
    static func populate(_ model: AppModel, snapshotOps: SnapshotOps) {
        let tree = DemoFixture.tree()
        model.stats = DemoFixture.volume
        model.tree = tree
        model.cachedAt = nil
        model.isLiveSnapshot = false
        model.scanning = false
        model.discovering = false
        model.progress = ScanProgress(files: leafCount(tree) * scanFilesPerLeaf, bytes: tree.size[0], unreadableDirs: 0, done: true)
        let categories = DemoFixture.categories(tree: tree)
        model.categories = categories
        model.selectedItems = Set(categories.filter(\.defaultSelected).flatMap(\.items).map(\.path))
        let snaps = snapshotOps.list()
        let shown = SnapshotFlow.display(snaps)
        model.snapshotCount = shown.count
        model.snapshotSummary = shown.summary
    }

    static let scanFilesPerLeaf = 1_700
    static let scanSteps = 24          // x 250 ms = 6 s

    static func leafCount(_ tree: DiskTree) -> Int { (0..<tree.count).filter { !tree.isDir[$0] }.count }

    /// Growing partial trees at ~250 ms, then the final state. Cancel by cancelling the task.
    static func replayScan(_ model: AppModel, snapshotOps: SnapshotOps) async {
        model.scanning = true
        model.discovering = true
        model.progress = ScanProgress()
        for step in 1..<scanSteps {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            let partial = DemoFixture.tree(fraction: Double(step) / Double(scanSteps))
            model.tree = partial
            model.isLiveSnapshot = true
            model.progress = ScanProgress(files: leafCount(partial) * scanFilesPerLeaf, bytes: partial.size[0])
        }
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        populate(model, snapshotOps: snapshotOps)
    }
}
#endif

#if DUSTBAR_DEMO
extension DemoMode {
    /// Parsed once from the process arguments.
    static let options: Options? = parse(CommandLine.arguments)

    /// The forced appearance for the popover, its hosting view and the whole app; nil follows the system.
    static var forcedAppearance: NSAppearance? {
        switch options?.dark {
        case true?: return NSAppearance(named: .darkAqua)
        case false?: return NSAppearance(named: .aqua)
        case nil: return nil
        }
    }

    /// Renders the status item (ring + title) at 4x with a transparent background, in the forced appearance,
    /// and writes it as PNG. Menu bar colours: white on dark, black on light. No screen capture involved.
    static func exportStatusItem(image: NSImage?, title: NSAttributedString, dark: Bool, to path: String) -> Bool {
        let ink: NSColor = dark ? .white : .black
        let text = NSMutableAttributedString(attributedString: title)
        text.addAttribute(.foregroundColor, value: ink, range: NSRange(location: 0, length: text.length))
        let isTemplate = true   // neutral menu bar look: the ring takes the same ink as the text
        let imgSize = image?.size ?? .zero
        let textSize = text.size()
        let pad: CGFloat = 6
        let size = NSSize(width: ceil(pad + imgSize.width + textSize.width + pad), height: 24)
        let scale: CGFloat = 4
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let _ = Optional(rep.size = size),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = ctx
        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill(using: .copy)
        var x = pad
        if let image {
            let rect = NSRect(x: x, y: (size.height - imgSize.height) / 2, width: imgSize.width, height: imgSize.height)
            if isTemplate {
                let tinted = NSImage(size: imgSize, flipped: false) { r in
                    image.draw(in: r)
                    ink.set()
                    r.fill(using: .sourceIn)
                    return true
                }
                tinted.draw(in: rect)
            } else {
                image.draw(in: rect)
            }
            x += imgSize.width
        }
        text.draw(at: NSPoint(x: x, y: (size.height - textSize.height) / 2))
        NSGraphicsContext.current = saved
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Appearance, history file, backdrop and delayed popover; called once from the status controller.
    static func prepare(_ options: Options, openPopover: @escaping @MainActor () -> Void) {
        switch options.dark {
        case true?: NSApp.appearance = NSAppearance(named: .darkAqua)
        case false?: NSApp.appearance = NSAppearance(named: .aqua)
        case nil: break
        }
        if options.backdrop { showBackdrop(dark: options.dark ?? false) }
        if options.open {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                openPopover()
            }
        }
    }

    /// Writes the fixture history to a temp file and points History at it (the real cache is never touched).
    static func installHistory(tree: DiskTree) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dustbar-demo-\(ProcessInfo.processInfo.processIdentifier)/history.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        struct File: Encodable { var version = History.fileVersion; var records: [History.Record] }
        let records = DemoFixture.history(tree: tree, now: .now)
        if let data = try? JSONEncoder().encode(File(records: records)) { try? data.write(to: url, options: .atomic) }
        History.demoURL = url
    }

    private static var backdropWindow: NSWindow?

    private static func showBackdrop(dark: Bool) {
        guard let screen = NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.backgroundColor = dark
            ? NSColor(srgbRed: 0x0B / 255, green: 0x12 / 255, blue: 0x20 / 255, alpha: 1)
            : NSColor(srgbRed: 0xE9 / 255, green: 0xEE / 255, blue: 0xF5 / 255, alpha: 1)
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        backdropWindow = window
    }
}
#endif
