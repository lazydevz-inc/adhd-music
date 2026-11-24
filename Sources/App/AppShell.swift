import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - Entry point

@main
enum FocusMusicMain {
    static func main() {
        #if !MAS_BUILD || MAS_TEST
        if CommandLine.arguments.contains("--print-login-status") {
            let status = SMAppService.mainApp.status
            let names: [SMAppService.Status: String] = [.notRegistered: "notRegistered", .enabled: "enabled",
                                                         .requiresApproval: "requiresApproval", .notFound: "notFound"]
            print("login item: \(names[status] ?? "unknown(\(status.rawValue))")")
            exit(0)
        }
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

// MARK: - Menu bar icon (headset over a waveform)

// The headset-and-wave design drawn here is not under the MIT License: copyright lazydevz Inc.,
// all rights reserved. See ASSETS.md.
enum MenuBarIcon {
    static func image(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let s = rect.width / 24
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let band = NSBezierPath()
            band.appendArc(withCenter: NSPoint(x: 12 * s, y: 13.5 * s), radius: 8.5 * s, startAngle: 180, endAngle: 0, clockwise: false)
            band.lineWidth = 2 * s
            band.lineCapStyle = .round
            band.stroke()
            NSBezierPath(roundedRect: NSRect(x: 2.5 * s, y: 13 * s, width: 4 * s, height: 7 * s), xRadius: 2 * s, yRadius: 2 * s).fill()
            NSBezierPath(roundedRect: NSRect(x: 17.5 * s, y: 13 * s, width: 4 * s, height: 7 * s), xRadius: 2 * s, yRadius: 2 * s).fill()
            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: 8.25 * s, y: 16.5 * s))
            wave.line(to: NSPoint(x: 8.25 * s, y: 14.5 * s))
            wave.appendArc(withCenter: NSPoint(x: 9.5 * s, y: 14.5 * s), radius: 1.25 * s, startAngle: 180, endAngle: 0, clockwise: false)
            wave.line(to: NSPoint(x: 10.75 * s, y: 18.5 * s))
            wave.appendArc(withCenter: NSPoint(x: 12 * s, y: 18.5 * s), radius: 1.25 * s, startAngle: 180, endAngle: 0, clockwise: true)
            wave.line(to: NSPoint(x: 13.25 * s, y: 14.5 * s))
            wave.appendArc(withCenter: NSPoint(x: 14.5 * s, y: 14.5 * s), radius: 1.25 * s, startAngle: 180, endAngle: 0, clockwise: false)
            wave.line(to: NSPoint(x: 15.75 * s, y: 16.5 * s))
            wave.lineWidth = 2 * s
            wave.lineCapStyle = .round
            wave.lineJoinStyle = .round
            wave.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Glass panel window

final class GlassPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Metrics.compactWidth, height: 480),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        // Takes keyboard focus without activating the app, so ⌘Q, ⌘, and Esc reach the panel
        // while the app you were working in stays frontmost.
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .utilityWindow
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosts SwiftUI content on Liquid Glass and reports its height.
final class GlassHost<Content: View>: NSView {
    let glass = NSGlassEffectView()
    let hosting: NSHostingView<Content>

    /// Rounds the glass and clips this view to the same shape. Liquid Glass draws a soft shadow outside
    /// its shape; in a window exactly the glass's size that shadow showed as dark square corners, and the
    /// window server then shaped the window's own shadow as a rectangle too.
    var cornerRadius: CGFloat {
        get { glass.cornerRadius }
        set {
            glass.cornerRadius = newValue
            layer?.cornerRadius = newValue
        }
    }

    init(rootView: Content, cornerRadius: CGFloat) {
        hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        self.cornerRadius = cornerRadius
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        glass.contentView = container
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var options = LaunchOptions.current
    private var paths: AppPaths!
    private var settings: AppSettings!
    private var library: LibraryStore!
    private var ledger: LedgerStore!
    private var controller: FocusController!

    private var statusItem: NSStatusItem!
    private var panel: GlassPanel?
    private var panelHost: GlassHost<AnyView>?
    /// Height of the small panel as SwiftUI last measured it.
    private var compactHeight: CGFloat = 480
    /// Whether the panel frame currently has the expanded (History/Playlist/Settings) size.
    private var frameIsExpanded = false
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var termSource: DispatchSourceSignal?
    #if SPARKLE && !MAS_BUILD
    private var updates: SilentUpdates?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Close the running record properly when the system or `kill` asks the app to quit.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source

        paths = AppPaths.resolve(options)
        settings = AppSettings(defaults: .standard, languageOverride: options.language)
        library = LibraryStore(paths: paths)
        ledger = LedgerStore(url: paths.recordsURL)
        if options.seedDemo {
            let firstSongs = Dictionary(grouping: library.tracks, by: { $0.genre.rawValue }).mapValues { $0.prefix(2).map(\.id) }
            ledger.seedDemo(startHour: settings.dayStartHour, songs: firstSongs)
        }
        controller = FocusController(settings: settings, library: library, ledger: ledger, options: options)
        if options.soundLog { controller.logOtherSound(to: paths.dataDir.appendingPathComponent("other-sound.log")) }
        controller.$panelPage.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.panelPageChanged() }
        }.store(in: &cancellables)

        SystemIntegration.applyDock(settings.showInDock)
        if !options.isDevelopment {
            #if MAS_BUILD
            // The store build never adds itself as a login item (App Review 2.4.5(iii)): it only shows what
            // macOS has, and the Settings switch registers it when the person turns it on.
            settings.openAtLogin = SystemIntegration.openAtLoginEnabled
            #else
            if settings.openAtLogin != SystemIntegration.openAtLoginEnabled { SystemIntegration.setOpenAtLogin(settings.openAtLogin) }
            #endif
        }
        settings.$showInDock.dropFirst().sink { show in SystemIntegration.applyDock(show) }.store(in: &cancellables)
        settings.$language.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.controller.applyLanguage(); self?.refreshStatusItem() }
        }.store(in: &cancellables)

        setupStatusItem()
        installMainMenu()
        controller.onTick = { [weak self] in self?.refreshStatusItem() }
        refreshStatusItem()

        if options.dark { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if let page = options.preview {
            // Wait until the menu bar has placed the status item; the grown panel hangs under it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.showPreview(page) }
        }
        if options.openPanel {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.openPanel() }
        }
        if options.autoplay {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.controller.setIntention("Writing the API docs")
                self?.controller.play()
            }
        }
        if options.scenario { runScenario() }
        if options.pageTour { runPageTour() }
        #if SPARKLE && !MAS_BUILD
        // Website build only: silent daily updates from adhdmusic.app (Updates.swift).
        updates = SilentUpdates(controller: controller, soon: options.updateSoon)
        #endif
    }

    /// Development: drives the real controller and engine through common actions and logs the state.
    private func runScenario() {
        let c = controller!
        let steps: [(Double, String, () -> Void)] = [
            (0.5, "play", { c.setIntention("Scenario"); c.play() }),
            (6, "next track", { c.nextTrack() }),
            (12, "pause", { c.pause(.user) }),
            (15, "resume", { c.play() }),
            (18, "effect high", { c.setEffect(.high) }),
            (21, "music → next choice", { c.cycleMusic(1) }),
            (26, "away", { c.debugAway(true) }),
            (29, "back", { c.debugAway(false) }),
            (32, "call", { c.debugCall(true) }),
            (35, "call ended", { c.debugCall(false) }),
            (38, "intention change", { c.setIntention("Second task") }),
            (41, "previous track", { c.previousTrack() }),
            (42.5, "headphones out", { c.debugHeadphonesOut() }),
            (44, "headphones back", { c.debugOutputChange() }),
            (45, "other sound starts", { c.debugOtherSound("Google Chrome") }),
            (46, "other sound stops", { c.debugOtherSound(nil) }),
            (47.5, "pause", { c.pause(.user) }),
            // Playlist: rows, the progress bar, list order, Don't play / Play again.
            (49, "playlist: shuffle off, play the 3rd song in the list", {
                c.setShuffle(false)
                let list = c.library.ordered(for: c.musicChoice, sort: c.settings.playlistSort)
                if list.count > 2 { c.playTrack(list[2].id) }
            }),
            (52, "playlist: bar to 10:00", { c.seek(to: 600) }),
            (55, "playlist: next = the song below", { c.nextTrack() }),
            (58, "playlist: previous = back up", { c.previousTrack() }),
            (61, "playlist: don't play this song", { if let id = c.currentTrack?.id { c.dontPlay(id) } }),
            (64, "playlist: play it again", { if let id = c.library.hiddenTracks().first?.id { c.playAgain(id) } }),
            (66, "playlist: pause, bar to 5:00 while paused", { c.pause(.user); c.seek(to: 300) }),
            (68, "playlist: play from 5:00", { c.play() }),
            (71, "playlist: shuffle back on", { c.setShuffle(true) }),
            (72, "quit", { NSApp.terminate(nil) })
        ]
        let logURL = paths.dataDir.appendingPathComponent("scenario.log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        func write(_ line: String) {
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            handle.seekToEndOfFile()
            handle.write((line + "\n").data(using: .utf8)!)
            try? handle.close()
        }
        for (time, name, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + time) {
                action()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    write(String(format: "%5.1fs [%@] %@", time + 1.2, name, c.debugState))
                }
            }
        }
    }

    /// Development: walks the panel through every page and logs its frame, to check grow/shrink.
    private func runPageTour() {
        let pages: [(Double, FocusController.PanelPage?)] = [
            (1.0, .main), (2.5, .history), (4.0, .library), (5.5, .settings), (7.0, .main),
            (8.5, .sound), (11.5, .main), (13.0, nil)
        ]
        let logURL = paths.dataDir.appendingPathComponent("page-tour.log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        for (time, page) in pages {
            DispatchQueue.main.asyncAfter(deadline: .now() + time) { [weak self] in
                guard let self else { return }
                if let page { self.showPage(page) } else { self.closePanel() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    let f = self.panel?.frame ?? .zero
                    let line = String(format: "%5.1fs page=%@ visible=%@ frame=%.0f,%.0f %.0fx%.0f radius=%.0f\n", time + 0.9,
                                      page.map { "\($0)" } ?? "closed", (self.panel?.isVisible ?? false) ? "yes" : "no",
                                      f.minX, f.minY, f.width, f.height, self.panelHost?.cornerRadius ?? 0)
                    if let handle = try? FileHandle(forWritingTo: logURL) {
                        handle.seekToEndOfFile()
                        handle.write(line.data(using: .utf8)!)
                        try? handle.close()
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = MenuBarIcon.image()
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(statusClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        var text = ""
        if let time = controller.menuBarText { text = " " + time }
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: controller.isPlaying ? NSColor.labelColor : NSColor.labelColor.withAlphaComponent(0.55)
        ])
        if let tag = controller.menuBarTag {
            attributed.append(NSAttributedString(string: "  " + tag, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.75),
                .baselineOffset: 1
            ]))
        }
        button.attributedTitle = attributed
        button.toolTip = AppIdentity.name
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel()
            showContextMenu()
        } else {
            panel?.isVisible == true ? closePanel() : openPanel()
        }
    }

    private func showContextMenu() {
        let s = settings.strings
        let menu = NSMenu()
        func item(_ title: String, _ key: String, _ action: Selector) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = self
            menu.addItem(entry)
        }
        item(controller.isPlaying ? s.pause : s.play, "", #selector(menuTogglePlay))
        menu.addItem(.separator())
        item(s.menuHistory, "", #selector(menuHistory))
        item(s.menuPlaylist, "", #selector(menuPlaylist))
        menu.addItem(.separator())
        item(s.menuSettings, ",", #selector(menuSettings))
        item(s.menuQuit, "q", #selector(menuQuit))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Key equivalents while the app is active (⌘Q, ⌘, and editing). The panel handles its own keys in installMonitors.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(AppIdentity.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    @objc private func menuTogglePlay() { controller.togglePlay() }
    @objc private func menuHistory() { showPage(.history) }
    @objc private func menuPlaylist() { showPage(.library) }
    @objc private func menuSettings() { showPage(.settings) }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: Panel

    private func makePanelRoot() -> AnyView {
        AnyView(PanelRoot(c: controller, settings: settings, library: library)
            .onPreferenceChange(PanelHeightKey.self) { [weak self] height in
                Task { @MainActor in self?.compactContentHeight(height) }
            })
    }

    /// Opens the panel on a page, or switches the open panel to it.
    private func showPage(_ page: FocusController.PanelPage) {
        if panel?.isVisible == true {
            controller.panelPage = page
        } else {
            openPanel(page: page)
        }
    }

    private func openPanel(page: FocusController.PanelPage = .main) {
        if panel == nil {
            let p = GlassPanel()
            let host = GlassHost(rootView: makePanelRoot(), cornerRadius: Radius.panel)
            p.contentView = host
            panel = p
            panelHost = host
        }
        controller.panelPage = page
        controller.panelVisible = true
        frameIsExpanded = page.isExpanded
        positionPanel()
        if options.preview != nil {
            // Development preview: show the panel without taking keyboard focus or closing on outside
            // clicks, so screenshots don't interrupt whatever is being typed in another app.
            panel?.orderFrontRegardless()
        } else {
            panel?.makeKeyAndOrderFront(nil)
            installMonitors()
        }
        if options.isDevelopment {
            let note = "panel key=\(panel?.isKeyWindow ?? false) appActive=\(NSApp.isActive)\n"
            try? note.write(to: paths.dataDir.appendingPathComponent("panel-key.log"), atomically: true, encoding: .utf8)
        }
    }

    private func closePanel() {
        guard let panel, panel.isVisible else { return }
        controller.editingIntention = false
        controller.panelVisible = false
        panel.orderOut(nil)
        removeMonitors()
    }

    /// Grows or shrinks the panel when moving between the player and History/Playlist/Settings.
    private func panelPageChanged() {
        guard panel?.isVisible == true else { return }
        let expanded = controller.panelPage.isExpanded
        let animate = expanded != frameIsExpanded
        frameIsExpanded = expanded
        positionPanel(animate: animate)
    }

    private func compactContentHeight(_ height: CGFloat) {
        guard height > 0, !controller.panelPage.isExpanded, abs(height - compactHeight) > 0.5 else { return }
        compactHeight = height
        if panel?.isVisible == true, !frameIsExpanded { positionPanel() }
    }

    private func positionPanel(animate: Bool = false) {
        guard let panel, let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = frameIsExpanded ? Metrics.expandedSize : CGSize(width: Metrics.compactWidth, height: compactHeight)
        var x = buttonFrame.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let top = buttonFrame.minY - 6
        panelHost?.cornerRadius = frameIsExpanded ? Radius.panelExpanded : Radius.panel
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true, animate: animate)
    }

    private func installMonitors() {
        removeMonitors()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true, event.window === self.panel,
                  !self.controller.keyCaptureActive else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
                switch key {
                case "q": NSApp.terminate(nil); return nil
                case ",": self.controller.panelPage = .settings; return nil
                case "w": self.closePanel(); return nil
                case "x": NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil); return nil
                case "c": NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil); return nil
                case "v": NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil); return nil
                case "a": NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil); return nil
                case "z": NSApp.sendAction(Selector(("undo:")), to: nil, from: nil); return nil
                default: break
                }
            }
            // Space: play / pause, as in music apps. A text field being edited keeps its spaces.
            if event.keyCode == 49, flags.isEmpty, !self.controller.editingIntention, !(self.panel?.firstResponder is NSTextView) {
                self.controller.togglePlay()
                return nil
            }
            // Esc: a text field being edited gets it first; otherwise back to the player, then close.
            if event.keyCode == 53, self.controller.editingIntention == false, !(self.panel?.firstResponder is NSTextView) {
                if self.controller.panelPage != .main { self.controller.panelPage = .main } else { self.closePanel() }
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideMonitor = nil
        keyMonitor = nil
    }

    // MARK: Development previews

    /// `--preview main|sound|timer|history|day|library|playlist|playlist-why|playlist-hidden|library-song|settings` opens the
    /// real panel on that page (`day`: today in History; `library-song`: the playlist as the player's song row opens it;
    /// `playlist-why` / `playlist-hidden`: with the ⓘ card / Not playing open).
    private func showPreview(_ page: String) {
        let pages: [String: FocusController.PanelPage] = ["main": .main, "sound": .sound, "timer": .sound,
                                                          "history": .history, "library": .library, "playlist": .library,
                                                          "playlist-why": .library, "playlist-hidden": .library,
                                                          "history-month": .history, "history-daystart": .history, "history-card": .history,
                                                          "history-month-prev": .history,
                                                          "settings": .settings]
        switch page {
        case "day":
            openPanel(page: .history)
            controller.showHistory(day: LedgerStore.dayLabel(for: Date(), startHour: settings.dayStartHour))
        case "main-notice":
            openPanel(page: .main)
            controller.previewAutoPause(.otherSound, app: "Chrome")
        case "library-song":
            openPanel(page: .library)
            controller.openPlaylist()
        case let p where p.hasPrefix("settings-"):
            // settings-pause, settings-menubar, settings-keys, settings-history, settings-learn (Playback, learning marked)
            let part = String(p.dropFirst("settings-".count))
            openPanel(page: .settings)
            if part == "learn" { controller.openSettings(.playback, focus: "learn") }
            else if let page = FocusController.SettingsPage(rawValue: part) { controller.openSettings(page, focus: part == "pause" ? "pause.other" : nil) }
        default:
            openPanel(page: pages[page] ?? .main)
            if page == "history-month" || page == "history-month-prev" { controller.historyMonth = true }
        }
    }
}

extension LaunchOptions {
    var isDevelopment: Bool { dataDir != nil || preview != nil || openPanel || scenario || pageTour }
}
