import AppKit
import Combine
import SwiftUI

/// Owns the menu-bar status item and the Dock badge. Subscribes to
/// `AppEnvironment.$totalUnread` and mirrors the count into both surfaces.
///
/// Click on the status item brings the main window to the front so the app
/// stays useful even when the user minimizes everything.
@MainActor
final class MenuBarController: NSObject {

    private let environment: AppEnvironment
    private let statusItem: NSStatusItem
    private var cancellable: AnyCancellable?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        bind()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        // SF Symbol with built-in badge support — falls back to plain
        // "message" when no unread, swaps to "message.badge.fill" with a
        // textual count overlay otherwise.
        button.image = NSImage(systemSymbolName: "message", accessibilityDescription: "MultiverseWP")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeft
        button.target = self
        button.action = #selector(handleClick)
        button.toolTip = "MultiverseWP"
    }

    private func bind() {
        cancellable = environment.$totalUnread
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                self?.apply(unread: count)
            }
        apply(unread: environment.totalUnread)
    }

    private func apply(unread: Int) {
        guard let button = statusItem.button else { return }
        if unread > 0 {
            button.image = NSImage(systemSymbolName: "message.badge.filled.fill",
                                   accessibilityDescription: "MultiverseWP")
                ?? NSImage(systemSymbolName: "message.badge.fill",
                           accessibilityDescription: "MultiverseWP")
            button.image?.isTemplate = true
            button.title = " \(unread > 99 ? "99+" : String(unread))"
            NSApp.dockTile.badgeLabel = unread > 999 ? "999+" : String(unread)
        } else {
            button.image = NSImage(systemSymbolName: "message",
                                   accessibilityDescription: "MultiverseWP")
            button.image?.isTemplate = true
            button.title = ""
            NSApp.dockTile.badgeLabel = nil
        }
    }

    @objc private func handleClick() {
        showMainWindow()
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentViewController != nil }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // SwiftUI WindowGroup was closed — re-issue the standard new window
            // action so a fresh scene is created.
            NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
        }
    }
}
