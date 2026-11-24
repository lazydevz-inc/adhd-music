import AppKit
import SwiftUI

/// Settings in the grown panel: five parts on the left, like the Mac's System Settings, and one
/// page at a time on the right where choices are pictures (covers, the pulse wave, the real menu bar, keys).
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: FocusController
    @ObservedObject var library: LibraryStore
    @State private var recording = false
    @State private var keyMonitor: Any?
    @State private var loginError = false

    private var s: Strings { settings.strings }
    private var page: FocusController.SettingsPage { controller.settingsPage }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Metrics.sidebarWidth)
                .background(Palette.sidebar)
            Hairline(vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.settingsPages[index]).font(AppFont.heading)
                        Text(s.settingsDescs[index]).font(AppFont.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 16)
                    switch page {
                    case .playback: playbackPage
                    case .pause: pausePage
                    case .menubar: menuBarPage
                    case .keys: keysPage
                    case .history: historyPage
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .alert(s.loginFailed, isPresented: $loginError) { Button("OK", role: .cancel) {} }
        .onAppear {
            // Show what macOS actually has, not just the saved preference.
            let actual = SystemIntegration.openAtLoginEnabled
            if settings.openAtLogin != actual { settings.openAtLogin = actual }
        }
        .onDisappear { stopRecording() }
        .onChange(of: controller.settingsPage) { stopRecording() }
    }

    private var index: Int { FocusController.SettingsPage.allCases.firstIndex(of: page) ?? 0 }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(FocusController.SettingsPage.allCases.enumerated()), id: \.element) { i, part in
                NavRow(title: s.settingsPages[i], icon: Self.icons[i], selected: part == page) {
                    controller.settingsPage = part
                    controller.settingsFocus = nil
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Text(s.language).font(AppFont.caption).foregroundStyle(.secondary)
                Segmented(options: [(AppLanguage.en, "English"), (.ko, "한국어")], selection: settings.language, fill: true) {
                    settings.language = $0
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(Metrics.sidebarInsets)
    }

    static let icons = ["play.fill", "pause.fill", "menubar.rectangle", "keyboard", "calendar"]

    // MARK: Playback

    private var playbackPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(s.musicAtStart)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(MusicChoice.allCases, id: \.self) { choice in
                    PictureTile(selected: settings.defaultMusic == choice, height: 58) {
                        HStack(spacing: 9) {
                            MusicCover(choice: choice, library: library)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(choice.display).font(AppFont.labelStrong).lineLimit(1)
                                Text(s.songs(library.playable(for: choice).count)).font(AppFont.caption).foregroundStyle(.secondary)
                            }
                        }
                    } action: { settings.defaultMusic = choice }
                }
            }
            sectionTitle(s.pulseAtStart).padding(.top, 14)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(EffectChoice.allCases, id: \.self) { level in
                    PictureTile(selected: settings.defaultEffect == level, height: 62) {
                        VStack(alignment: .leading, spacing: 6) {
                            PulseWave(depth: PulseWave.depth(for: level), bars: 30, barsPerPulse: 4)
                                .fill(settings.defaultEffect == level ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Color.primary.opacity(0.3)))
                                .frame(height: 16)
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(s.effectNames[level.rawValue]).font(AppFont.bodyStrong)
                                Text(s.pulseLevelHints[level.rawValue]).font(AppFont.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    } action: { settings.defaultEffect = level }
                }
            }
            Text(s.pulseWhy).font(AppFont.caption).foregroundStyle(.secondary).padding(.top, 6)

            VStack(spacing: 0) {
                CardToggleRow(title: s.fadeInOut, caption: s.fadeWhy, isOn: $settings.fadeInOut)
                let marked = controller.settingsFocus == "learn"
                let lower = UnevenRoundedRectangle(bottomLeadingRadius: Radius.card, bottomTrailingRadius: Radius.card)
                VStack(spacing: 0) {
                    CardToggleRow(title: s.learnRow.0, caption: s.learnRow.1, isOn: $settings.learnFromSkips, divider: true)
                    lessPlayedRow
                        .padding(.horizontal, Metrics.cardPadding).padding(.bottom, 10)
                }
                .background { if marked { lower.fill(Palette.raised) } }
                .overlay { if marked { lower.strokeBorder(Palette.accentFocus, lineWidth: 2) } }
            }
            .cardBackground()
            .padding(.top, 14)
        }
    }

    private var lessPlayedRow: some View {
        let less = library.lessPlayed()
        return HStack(spacing: 8) {
            Text(s.lessNow).font(AppFont.caption).foregroundStyle(.secondary).lineLimit(1)
            if less.isEmpty {
                Text(s.noneLess).font(AppFont.body)
                Spacer()
            } else {
                ForEach(less.prefix(3)) { track in
                    HStack(spacing: 5) {
                        CoverView(colors: track.colors, size: 22, image: track.coverURL)
                        Text(track.title).font(AppFont.body).lineLimit(1)
                    }
                }
                if less.count > 3 { Text(s.andMore(less.count - 3)).font(AppFont.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 6)
                Button(s.clearLearning) { library.clearLearning(less.map(\.id)) }
                    .buttonStyle(.plain).font(AppFont.bodyStrong).foregroundStyle(Palette.accentText)
                    .padding(.horizontal, 8).frame(height: 24)
                    .hoverFill(RoundedRectangle(Radius.small))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(RoundedRectangle(Radius.control).fill(Palette.track.opacity(0.45)))
    }

    // MARK: Pauses by itself

    private var pausePage: some View {
        let keys = ["pause.away", "pause.call", "pause.other", "pause.phones"]
        let icons = ["lock", "video", "speaker.wave.2", "headphones"]
        let bindings = [$settings.pauseWhenAway, $settings.pauseDuringCalls, $settings.pauseForOtherSound, $settings.pauseWhenHeadphonesOff]
        return VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                ForEach(0..<4, id: \.self) { i in
                    let marked = controller.settingsFocus == keys[i]
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: icons[i]).font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Palette.accentText)
                                .frame(width: 32, height: 32)
                                .background(RoundedRectangle(Radius.control).fill(Palette.accentWash))
                            Spacer()
                            Toggle("", isOn: bindings[i]).labelsHidden().focusSwitch()
                                .accessibilityLabel(s.pauseCards[i].0)
                        }
                        Text(s.pauseCards[i].0).font(AppFont.labelStrong)
                        Text(s.pauseCards[i].1).font(AppFont.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
                    .background(RoundedRectangle(Radius.card + 2).fill(marked ? Palette.raised : Palette.card))
                    .overlay { if marked { RoundedRectangle(Radius.card + 2).strokeBorder(Palette.accentFocus, lineWidth: 2) } }
                }
            }
            sectionTitle(s.seenOnPlayer).padding(.top, 18)
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2").font(.system(size: 11))
                    Text(s.noticeSample).font(AppFont.body)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).frame(height: 26)
                .background(Capsule().fill(Palette.track))
                Text(s.noticeOpensHere).font(AppFont.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Menu bar & startup

    private var menuBarPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                ForEach(Array(MenuBarStyle.allCases.enumerated()), id: \.element) { i, style in
                    PictureTile(selected: settings.menuBarStyle == style, height: 96) {
                        VStack(alignment: .leading, spacing: 10) {
                            MenuBarSample(showsTotal: style == .todayTotal, total: controller.todaySeconds, ko: settings.ko)
                            HStack(spacing: 8) {
                                RadioDot(on: settings.menuBarStyle == style)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.menuBarOptions[i].0).font(AppFont.labelStrong)
                                    Text(s.menuBarOptions[i].1).font(AppFont.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } action: { settings.menuBarStyle = style }
                }
            }
            VStack(spacing: 0) {
                CardToggleRow(title: s.openAtLogin, caption: s.openAtLoginWhy, isOn: Binding(get: { settings.openAtLogin }, set: { value in
                    if SystemIntegration.setOpenAtLogin(value) { settings.openAtLogin = value } else { loginError = true }
                }))
                CardToggleRow(title: s.showInDock, caption: s.showInDockWhy, isOn: $settings.showInDock, divider: true)
            }
            .cardBackground()
            .padding(.top, 14)
        }
    }

    // MARK: Keyboard

    private var keysPage: some View {
        let display = HotKey.display(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
        let modifierGlyphs = Set("⌃⌥⇧⌘")
        let mods = display.filter { modifierGlyphs.contains($0) }.map(String.init)
        let key = String(display.filter { !modifierGlyphs.contains($0) })
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    if recording {
                        Keycap(text: s.pressKeys, tint: Palette.accentText)
                    } else {
                        ForEach(mods + [key], id: \.self) { Keycap(text: $0) }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.shortcutTitle).font(AppFont.labelStrong)
                    Text(s.shortcutWhy).font(AppFont.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(s.change) { recording ? stopRecording() : startRecording() }
                    .buttonStyle(.plain).font(AppFont.bodyStrong).foregroundStyle(Palette.accentText)
                    .padding(.horizontal, 8).frame(height: 26)
                    .hoverFill(RoundedRectangle(Radius.control))
            }
            .padding(14)
            .background(RoundedRectangle(Radius.card + 2).fill(recording ? Palette.raised : Palette.card))
            .overlay { if recording { RoundedRectangle(Radius.card + 2).strokeBorder(Palette.accentFocus, lineWidth: 2) } }

            HStack(spacing: 14) {
                Keycap(text: "space", wide: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.spaceTitle).font(AppFont.labelStrong)
                    Text(s.spaceWhy).font(AppFont.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(RoundedRectangle(Radius.card + 2).fill(Palette.card))

            HStack(spacing: 14) {
                Keycap(symbol: "playpause.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.mediaKeys).font(AppFont.labelStrong)
                    Text(s.mediaWhy).font(AppFont.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Segmented(options: [(MediaKeyMode.whilePlaying, s.mediaOptions[0]), (.always, s.mediaOptions[1]), (.off, s.mediaOptions[2])],
                          selection: settings.mediaKeys) { settings.mediaKeys = $0 }
                    .fixedSize()
            }
            .padding(14)
            .background(RoundedRectangle(Radius.card + 2).fill(Palette.card))
        }
    }

    // MARK: History

    private var historyPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(s.dayStartsAt).font(AppFont.labelStrong)
                    Spacer()
                    Segmented(options: [0, 3, 4, 5, 6, 7, 8].map { ($0, s.hourShort($0)) }, selection: settings.dayStartHour, hPadding: 7) {
                        settings.dayStartHour = $0
                    }
                    .fixedSize()
                }
                DayBoundary(hour: settings.dayStartHour, height: 18)
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        ForEach([0, 12, 18, 24], id: \.self) { h in
                            Text("\(h)").font(AppFont.micro).foregroundStyle(.tertiary)
                                .position(x: h == 0 ? 4 : (h == 24 ? geo.size.width - 6 : geo.size.width * CGFloat(h) / 24), y: 6)
                        }
                        if settings.dayStartHour > 0 {
                            Text("\(settings.dayStartHour)").font(AppFont.microStrong).foregroundStyle(Palette.accentText)
                                .position(x: geo.size.width * CGFloat(settings.dayStartHour) / 24, y: 6)
                        }
                    }
                }
                .frame(height: 12)
                Text(s.dayStartWhy(settings.dayStartHour)).font(AppFont.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(RoundedRectangle(Radius.card + 2).fill(controller.settingsFocus == "day" ? Palette.raised : Palette.card))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.weekStartsOn).font(AppFont.label)
                    Text(s.weekStartWhy).font(AppFont.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Segmented(options: [(WeekStart.monday, s.weekOptions[0]), (.sunday, s.weekOptions[1])], selection: settings.weekStart) {
                    settings.weekStart = $0
                }
                .fixedSize()
            }
            .padding(.horizontal, 14).frame(minHeight: 52)
            .background(RoundedRectangle(Radius.card + 2).fill(Palette.card))

            HStack(spacing: 7) {
                Image(systemName: "calendar").font(.system(size: 11))
                Text(s.alsoInHistory)
            }
            .font(AppFont.caption).foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }

    // MARK: Parts

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(AppFont.bodyStrong).foregroundStyle(.secondary).padding(.bottom, 6)
    }

    // MARK: Shortcut recording

    private func startRecording() {
        stopRecording()
        recording = true
        controller.keyCaptureActive = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            let modifiers = HotKey.carbonModifiers(from: event.modifierFlags)
            guard modifiers != 0 else { return nil }
            settings.hotKeyCode = Int(event.keyCode)
            settings.hotKeyModifiers = modifiers
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        controller.keyCaptureActive = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - Pieces

private struct NavRow: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(Radius.small).fill(selected ? Palette.accent : Palette.accent.opacity(0.55)))
                Text(title).font(AppFont.label).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.sidebarItemInset)
            .frame(height: 34)
            .background {
                if selected { RoundedRectangle(Radius.control).fill(Palette.raised).shadow(color: .black.opacity(0.08), radius: 1, y: 1) }
                else if hovering { RoundedRectangle(Radius.control).fill(Palette.hover) }
            }
            .contentShape(RoundedRectangle(Radius.control))
            .animation(Motion.hover, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A choice drawn as a picture card: raised with a teal edge when chosen, darker under the pointer.
private struct PictureTile<Content: View>: View {
    let selected: Bool
    let height: CGFloat
    @ViewBuilder let content: () -> Content
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                .background {
                    RoundedRectangle(Radius.card).fill(selected ? Palette.raised : Palette.card)
                    if hovering && !selected { RoundedRectangle(Radius.card).fill(Palette.hover.opacity(0.6)) }
                }
                .overlay { if selected { RoundedRectangle(Radius.card).strokeBorder(Palette.accentFocus, lineWidth: 1.5) } }
                .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 4, y: 2)
                .contentShape(RoundedRectangle(Radius.card))
                .animation(Motion.hover, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Mix shows four covers; a genre shows its first song's cover.
private struct MusicCover: View {
    let choice: MusicChoice
    let library: LibraryStore

    var body: some View {
        let songs = library.playable(for: choice)
        if choice == .mix {
            let picks = Genre.allCases.compactMap { g in songs.first { $0.genre == g } } + songs.dropFirst(3).prefix(1)
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow { cover(picks, 0); cover(picks, 1) }
                GridRow { cover(picks, 2); cover(picks, 3) }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(8))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        } else if let first = songs.first {
            CoverView(colors: first.colors, size: 38, image: first.coverURL)
        } else {
            RoundedRectangle(8).fill(Palette.track).frame(width: 38, height: 38)
        }
    }

    @ViewBuilder private func cover(_ picks: [Track], _ i: Int) -> some View {
        if picks.indices.contains(i), let url = picks[i].coverURL, let image = CoverImages.shared.image(url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 19, height: 19).clipped()
        } else {
            Rectangle().fill(Palette.track).frame(width: 19, height: 19)
        }
    }
}

/// A strip of the menu bar with the app's item, as it will look.
private struct MenuBarSample: View {
    let showsTotal: Bool
    let total: TimeInterval
    let ko: Bool

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            HStack(spacing: 4) {
                Image(nsImage: MenuBarIcon.image(size: 14)).renderingMode(.template)
                if showsTotal { Text(Fmt.clock(max(1, total))).monospacedDigit() }
            }
            .padding(.horizontal, 6).frame(height: 20)
            .background(RoundedRectangle(5).fill(Color.white.opacity(0.24)))
            Image(systemName: "wifi").font(.system(size: 11, weight: .semibold))
            Text(Fmt.clockTime(Date(), ko: ko))
        }
        .font(AppFont.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(7).fill(LinearGradient(colors: Palette.menuBarSample, startPoint: .leading, endPoint: .trailing)))
    }
}

/// A key drawn as a key: used for the shortcut and Space.
private struct Keycap: View {
    var text = ""
    var symbol: String? = nil
    var wide = false
    var tint: Color? = nil

    var body: some View {
        Group {
            if let symbol { Image(systemName: symbol).font(.system(size: 14, weight: .semibold)) }
            else { Text(text).font(text.count > 2 ? AppFont.body : .system(size: 16, weight: .semibold)) }
        }
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(text == "space" ? .secondary : .primary))
            .padding(.horizontal, wide ? 44 : 10)
            .frame(minWidth: 40, minHeight: 40)
            .background(RoundedRectangle(8).fill(Palette.raised))
            .overlay(RoundedRectangle(8).strokeBorder(Palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
    }
}
