import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(environment: AppEnvironment.shared)
    }

    /// When the user closes the last window we keep the process alive so the
    /// menu-bar item still receives notifications. Re-opening from the Dock or
    /// the menu-bar item re-creates a window via SwiftUI's reopen handler.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            menuBar?.showMainWindow()
        }
        return true
    }
}
