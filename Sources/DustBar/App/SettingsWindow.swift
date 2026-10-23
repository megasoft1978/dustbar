import AppKit
import ServiceManagement
import SwiftUI

/// Launch-at-login hooks the Settings window calls. Defaults to `SMAppService.mainApp`.
struct LaunchAtLoginControl {
    let isEnabled: @MainActor () -> Bool
    let setEnabled: @MainActor (Bool) throws -> Void

    @MainActor
    static var mainApp: LaunchAtLoginControl {
        LaunchAtLoginControl(
            isEnabled: { SMAppService.mainApp.status == .enabled },
            setEnabled: { enabled in
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            }
        )
    }
}

/// Single, non-resizable Settings window.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static var controller: NSHostingController<AnyView>?
    private static weak var boundSettings: Settings?
    private static var revision = 0

    static func show(settings: Settings, launchAtLogin: LaunchAtLoginControl = .mainApp) {
        if let controller, window != nil, boundSettings === settings {
            // Existing window: rebuild the root so the view takes the given control and re-reads the system state.
            revision += 1
            controller.rootView = root(settings: settings, launchAtLogin: launchAtLogin)
        } else {
            window?.close()
            let newController = NSHostingController(rootView: root(settings: settings, launchAtLogin: launchAtLogin))
            newController.sizingOptions = []
            let newWindow = NSWindow(contentViewController: newController)
            newWindow.title = "DustBar Settings"
            newWindow.styleMask = [.titled, .closable, .miniaturizable]
            newWindow.setContentSize(NSSize(width: 480, height: 520))
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
            controller = newController
            boundSettings = settings
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// `.id(revision)` gives each show a fresh view identity, so its state is re-initialised from the system.
    private static func root(settings: Settings, launchAtLogin: LaunchAtLoginControl) -> AnyView {
        AnyView(SettingsView(settings: settings, launchAtLogin: launchAtLogin).id(revision))
    }
}
