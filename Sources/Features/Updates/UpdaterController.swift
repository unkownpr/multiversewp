import Combine
import Foundation
import Sparkle
import SwiftUI

/// SwiftUI-friendly wrapper around `SPUStandardUpdaterController` that exposes
/// the bits the rest of the app cares about — a "Check for Updates…" action
/// plus a `canCheckForUpdates` flag the UI binds against.
///
/// The orchestrator instantiates exactly one of these as a `@StateObject` on
/// `MultiverseWPApp`; downstream views receive it via `.environmentObject` or
/// direct injection (no global singletons).
@MainActor
final class UpdaterController: ObservableObject {

    /// Published mirror of `SPUUpdater.canCheckForUpdates`. SwiftUI views (the
    /// menu command, the About-tab button) bind their `.disabled` modifier to
    /// this so the control is only active when Sparkle is idle.
    @Published private(set) var canCheckForUpdates: Bool = false

    /// The underlying Sparkle controller. Held strongly for the lifetime of
    /// the app. `startingUpdater: true` means Sparkle begins its background
    /// schedule (every ~24h by default) the moment the controller is built.
    let controller: SPUStandardUpdaterController

    private var cancellables: Set<AnyCancellable> = []

    init(
        startingUpdater: Bool = true,
        updaterDelegate: SPUUpdaterDelegate? = nil,
        userDriverDelegate: SPUStandardUserDriverDelegate? = nil
    ) {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: userDriverDelegate
        )

        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)
    }

    /// Triggers a user-initiated update check. Bind menu items and buttons to
    /// this. Internally this hands off to `SPUStandardUpdaterController` which
    /// uses the standard Sparkle UI driver (the update dialog and progress
    /// window users expect on macOS).
    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
