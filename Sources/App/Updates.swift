#if SPARKLE && !MAS_BUILD
import AppKit
import Sparkle

// MARK: - Updates (website build only)

/// The website build keeps itself current with Sparkle 2. Once a day it reads the feed in Info.plist
/// (SUFeedURL, adhdmusic.app/appcast.xml), downloads a newer version in the background (a small delta when the
/// feed has one for this version), and checks its EdDSA signature and Apple code signature before using it.
/// The Info.plist keys come from Scripts/build-app.sh --share; nothing here is on screen.
///
/// A menu bar app is rarely quit, so Sparkle's usual "install when the app quits" could wait for weeks.
/// Once a new version is ready, this installs it and reopens the app at a quiet moment instead: the panel is
/// closed and no music is playing or waiting to come back by itself (never started, paused by the person, or
/// stopped by the timer), and that has lasted 15 minutes. Quitting, logging out or restarting installs it too.
///
/// Compiled only with -D SPARKLE (--share), never with MAS_BUILD. The store build (App Review 2.4.5(vii)) and the personal build
/// never contain it.
@MainActor
final class SilentUpdates: NSObject, SPUUpdaterDelegate {
    private let controller: FocusController
    /// `--update-soon` (development): check right after launch and install after 20 quiet seconds.
    private let soon: Bool
    private var quietNeeded: TimeInterval { soon ? 20 : 15 * 60 }
    private var updaterController: SPUStandardUpdaterController?
    private var installNow: (() -> Void)?
    private var quietSince: Date?
    private var watch: Timer?

    init(controller: FocusController, soon: Bool) {
        self.controller = controller
        self.soon = soon
        super.init()
        let updates = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        updaterController = updates
        if soon { updates.updater.checkForUpdatesInBackground() }
    }

    /// Sparkle has downloaded and unpacked a new version and would install it when the app quits.
    /// Returning true takes over: Sparkle shows nothing and waits for `immediateInstallHandler`.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installNow = immediateInstallHandler
        quietSince = nil
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: soon ? 2 : 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfQuiet() }
        }
        installIfQuiet()
        return true
    }

    /// Nothing the person would miss: no music, no auto-pause that resumes by itself, the panel closed.
    private var isQuiet: Bool {
        guard !controller.panelVisible else { return false }
        switch controller.run {
        case .idle: return true
        case .playing: return false
        case .paused: return controller.pauseReason == .user || controller.pauseReason == .timer
        }
    }

    private func installIfQuiet() {
        guard let install = installNow else { return }
        guard isQuiet else { quietSince = nil; return }
        let since = quietSince ?? Date()
        quietSince = since
        guard Date().timeIntervalSince(since) >= quietNeeded else { return }
        watch?.invalidate()
        watch = nil
        installNow = nil
        // Sparkle quits the app (records close as on any quit), replaces it and opens the new version.
        install()
    }
}
#endif
