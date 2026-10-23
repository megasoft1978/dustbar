import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusController?.shutdown()
    }
}
