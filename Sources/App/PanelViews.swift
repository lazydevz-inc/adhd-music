import AppKit
import SwiftUI

/// Track colours drifting slowly behind the panel content while music plays.
struct AmbientBackground: View {
    let colors: [Color]
    let active: Bool
    let opacity: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let bases: [(CGFloat, CGFloat, CGFloat)] = [(86, 118, 230), (236, 150, 210), (160, 236, 250)]
    private let freq: [(Double, Double, Double)] = [(1, 1.3, 0.8), (1.25, 0.9, 1.1), (0.85, 1.15, 1.35)]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate * 0.5
            ZStack(alignment: .topLeading) {
                ForEach(0..<3, id: \.self) { i in
                    let b = bases[i], f = freq[i]
                    let x = b.0 + 46 * CGFloat(sin(t * f.0 + Double(i) * 2.1))
                    let y = b.1 + 36 * CGFloat(cos(t * f.1 + Double(i) * 1.7))
                    let scale = 1 + 0.12 * sin(t * f.2 + Double(i))
                    Circle()
                        .fill(colors.indices.contains(i) ? colors[i] : .blue)
                        .frame(width: b.2, height: b.2)
                        .scaleEffect(scale)
                        .position(x: x, y: y)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .blur(radius: 40)
            .opacity(opacity)
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 1.2), value: colors.map { $0.description })
    }
}

// MARK: - Panel root

struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelRoot: View {
    @ObservedObject var c: FocusController
    @ObservedObject var settings: AppSettings
    @ObservedObject var library: LibraryStore
    var showAmbient = true

    var body: some View {
        if c.panelPage.isExpanded {
            ExpandedPanel(c: c, settings: settings, library: library)
                .frame(width: Metrics.expandedSize.width, height: Metrics.expandedSize.height)
        } else {
            ZStack(alignment: .top) {
                if c.panelPage == .main, showAmbient, let track = c.currentTrack {
                    AmbientBackground(colors: track.colors,
                                      active: c.isPlaying && !c.inBreak && c.panelVisible,
                                      opacity: c.isPlaying && !c.inBreak ? 0.5 : (c.todaySeconds > 0 ? 0.26 : 0.16))
                }
                Group {
                    switch c.panelPage {
                    case .sound: TimerSoundPanel(c: c, settings: settings)
                    default: MainPanel(c: c, settings: settings)
                    }
                }
                .padding(Metrics.compactInsets)
            }
            .frame(width: Metrics.compactWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height) })
        }
    }
}

// MARK: - Main page

struct MainPanel: View {
    @ObservedObject var c: FocusController
    @ObservedObject var settings: AppSettings
    @State private var draft = ""
    @FocusState private var intentFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the pointer is over. Icon buttons keep their own hover.
    @State private var hover: Hover?

    /// Everything clickable on this page answers the pointer: grey shows where there is no shape
    /// (the date, the ⋯ menu, the task line, the song, the Today card), and where there is a shape
    /// it gets stronger (the timer chip, the play button's ring).
    private enum Hover { case date, menu, clock, intention, check, play, song, today }

    private func setHover(_ target: Hover, _ inside: Bool) {
        withAnimation(Motion.hover) {
            if inside { hover = target } else if hover == target { hover = nil }
        }
    }

    var body: some View {
        let s = c.strings
        // Groups keep their own inner gaps; 12 between groups.
        VStack(spacing: Metrics.compactSpacing) {
            header(s)
            VStack(spacing: 8) {
                clockButton(s)
                intentionRow(s).frame(height: 26)
            }
            VStack(spacing: 6) {
                transportRow(s)
                if hasNotice { noticeRow(s).frame(height: 28) }
            }
            VStack(spacing: 10) {
                musicRow(s)
                trackRow(s)
            }
            todayCard(s)
        }
        // The task line and the field swap places, so the one that left can't say the pointer went away.
        .onChange(of: c.editingIntention) {
            if hover == .intention || hover == .check { hover = nil }
        }
    }

    private func header(_ s: Strings) -> some View {
        HStack {
            dateButton(s)
            Spacer()
            Menu {
                Button(s.timerAndSound) { c.panelPage = .sound }
                Divider()
                Button(s.menuHistory) { c.showHistory(day: nil) }
                Button(s.menuPlaylist) { c.openPlaylist() }
                Button(s.menuSettings) { c.panelPage = .settings }.keyboardShortcut(",")
                Divider()
                Button(s.menuQuit) { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: Metrics.iconButton, height: Metrics.iconButton)
            .foregroundStyle(hover == .menu ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .background { if hover == .menu { Circle().fill(Palette.hover) } }
            .contentShape(Circle())
            .onHover { setHover(.menu, $0) }
            .help(s.menu)
            // Pulls the hit area into the margin so the dots line up with the content edge.
            .padding(.trailing, -6)
        }
        .frame(height: Metrics.iconButton)
    }

    /// "Today · Nov 23 ›" opens this month in History.
    private func dateButton(_ s: Strings) -> some View {
        let lifted = hover == .date
        return Button { c.showHistory(day: nil) } label: {
            HStack(spacing: 3) {
                Text(s.todayDate(LedgerStore.dayLabel(for: c.now, startHour: settings.dayStartHour)))
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).opacity(lifted ? 1 : 0.6)
            }
            .font(AppFont.body)
            .foregroundStyle(lifted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.leading, 8).padding(.trailing, 6)
            .frame(height: 26)
            .background { if lifted { RoundedRectangle(Radius.control).fill(Palette.hover) } }
            .contentShape(RoundedRectangle(Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { setHover(.date, $0) }
        .help(s.dateAria)
        .accessibilityLabel(s.dateAria)
        // Pulls the grey shape into the margin so the text stays on the content edge.
        .padding(.leading, -8)
    }

    /// Today's total; the whole block opens Timer & Sound. Under the pointer the chip turns white and the time darkens a step.
    private func clockButton(_ s: Strings) -> some View {
        let lifted = hover == .clock
        return Button { c.panelPage = .sound } label: {
            VStack(spacing: 7) {
                Text(Fmt.clock(c.todaySeconds))
                    .font(AppFont.clock)
                    .monospacedDigit()
                    .tracking(-1)
                    .foregroundStyle(clockStyle(lifted))
                    .animation(.easeInOut(duration: 0.25), value: c.isPlaying)
                timerChip(lifted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { setHover(.clock, $0) }
        .help(s.chipAria)
        .accessibilityLabel(s.chipAria)
    }

    private func clockStyle(_ lifted: Bool) -> AnyShapeStyle {
        if c.isPlaying && !c.inBreak { return AnyShapeStyle(Color.primary) }
        let base = c.todaySeconds >= 1 ? 0.42 : 0.22
        return AnyShapeStyle(Color.primary.opacity(lifted ? base + 0.22 : base))
    }

    /// Play mode at a glance under the big clock. `lifted`: white with dark text and the arrow a step right.
    private func timerChip(_ lifted: Bool) -> some View {
        let counting = c.timerCounting
        return HStack(spacing: 5) {
            Image(systemName: "timer").font(.system(size: 10, weight: .semibold))
            Text(c.timerChipText).font(AppFont.captionStrong).monospacedDigit().lineLimit(1)
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                .opacity(lifted ? 1 : 0.6)
                .offset(x: lifted ? 2 : 0)
        }
        .padding(.leading, 9).padding(.trailing, 7)
        .frame(height: 22)
        .foregroundStyle(counting || lifted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .background(Capsule().fill(counting ? (lifted ? Palette.accentWashHover : Palette.accentWash)
                                            : (lifted ? Palette.raised : Palette.chip)))
        .overlay(Capsule().strokeBorder(counting ? Palette.accentEdge : Palette.line, lineWidth: 1))
    }

    /// Under the pointer the ring brightens and thickens and the button grows a little.
    private func playButton(_ s: Strings) -> some View {
        let enabled = c.hasTracks || c.run != .idle
        let lifted = hover == .play && enabled
        return ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !(c.isPlaying && !c.inBreak && c.panelVisible) || reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let breathing = c.isPlaying && !c.inBreak && !reduceMotion
                Circle()
                    .strokeBorder(Palette.accent.opacity((c.isPlaying && !c.inBreak ? 0.4 : 0.18) + (lifted ? 0.32 : 0)),
                                  lineWidth: lifted ? 1.5 : 1)
                    .frame(width: 126, height: 126)
                    .scaleEffect(breathing ? 1 + 0.03 * (1 - cos(t * .pi)) : 1)
            }
            Button(action: c.togglePlay) {
                Image(systemName: c.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .regular))
                    .offset(x: c.isPlaying ? 0 : 3)
                    .frame(width: 104, height: 104)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .glassEffect(.regular.interactive(), in: Circle())
            .scaleEffect(lifted ? 1.03 : 1)
            .onHover { setHover(.play, $0) }
            .accessibilityLabel(c.isPlaying ? s.pause : s.play)
            .disabled(!enabled)
        }
        .frame(width: 128, height: 134)
    }

    /// Previous and next sit on both sides of the play button, so the three read as one set of playback buttons.
    private func transportRow(_ s: Strings) -> some View {
        HStack(spacing: 12) {
            RoundIconButton(systemName: "backward.end.fill", label: s.prevTrack, size: 20,
                            diameter: Metrics.transportButton) { c.previousTrack() }
                .disabled(c.currentTrack == nil)
            playButton(s)
            RoundIconButton(systemName: "forward.end.fill", label: s.nextTrack, size: 20,
                            diameter: Metrics.transportButton) { c.nextTrack() }
                .disabled(c.currentTrack == nil)
        }
    }

    private var hasNotice: Bool { c.run == .paused && [.call, .away, .headphones, .otherSound].contains(c.pauseReason) }

    @ViewBuilder private func intentionRow(_ s: Strings) -> some View {
        if c.editingIntention {
            HStack(spacing: 6) {
                TextField(s.intentPlaceholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(AppFont.body)
                    .focused($intentFocused)
                    .onSubmit(commitIntention)
                Button(action: commitIntention) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background {
                            ZStack {
                                RoundedRectangle(Radius.small).fill(Palette.accent)
                                if hover == .check { RoundedRectangle(Radius.small).fill(Palette.hover) }
                            }
                        }
                }
                .buttonStyle(.plain)
                .onHover { setHover(.check, $0) }
                .accessibilityLabel(s.done)
            }
            .padding(.leading, 10).padding(.trailing, 3)
            .frame(width: 250, height: 26)
            .background(RoundedRectangle(Radius.control).fill(Palette.raised))
            .overlay(RoundedRectangle(Radius.control).strokeBorder(Palette.accentFocus, lineWidth: 2))
            .onAppear { intentFocused = true }
            .onExitCommand { c.editingIntention = false }
        } else {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button {
                    draft = c.intention
                    c.editingIntention = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil").font(.system(size: 11))
                        Text(c.intention.isEmpty ? s.intentPlaceholder : c.intention).lineLimit(1).truncationMode(.tail)
                    }
                    .font(c.intention.isEmpty ? AppFont.body : AppFont.bodyStrong)
                    .foregroundStyle(c.intention.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 26)
                    .background {
                        // Teal once a task is set; the hover grey lies on top of either.
                        ZStack {
                            RoundedRectangle(Radius.control).fill(c.intention.isEmpty ? Color.clear : Palette.accentWash)
                            if hover == .intention { RoundedRectangle(Radius.control).fill(Palette.hover) }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { setHover(.intention, $0) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 270)
        }
    }

    private func commitIntention() {
        c.setIntention(draft)
        c.editingIntention = false
    }

    /// Shown only while a call, stepping away or disconnected headphones have paused the music.
    /// Why the music stopped by itself. Clicking it opens that pause in Settings, so a rule that gets in the
    /// way is one click from being turned off.
    private func noticeRow(_ s: Strings) -> some View {
        let notice: (icon: String, text: String, card: String)
        switch c.pauseReason {
        case .call: notice = ("video", s.callNotice, "pause.call")
        case .headphones: notice = ("headphones", s.headphonesNotice, "pause.phones")
        case .otherSound: notice = ("speaker.wave.2", s.otherSoundNotice(c.otherSoundApp ?? "—"), "pause.other")
        default: notice = ("lock", s.awayNotice, "pause.away")
        }
        return Button { c.openSettings(.pause, focus: notice.card) } label: {
            HStack(spacing: 6) {
                Image(systemName: notice.icon).font(.system(size: 11))
                Text(notice.text).font(AppFont.body).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 26)
            .background(Capsule().fill(Palette.track))
            .hoverFill(Capsule())
        }
        .buttonStyle(.plain)
        .help(s.changeInSettings)
    }

    private func musicRow(_ s: Strings) -> some View {
        HStack(spacing: 4) {
            RoundIconButton(systemName: "chevron.left", label: s.prevMusic, size: 13, weight: .medium, quiet: true) { c.cycleMusic(-1) }
            HStack(spacing: 6) {
                // How the next song is chosen, as the playlist's bar sets it: shuffled, this song again, or in order.
                if let mode = playModeIcon { Image(systemName: mode).font(.system(size: 12, weight: .semibold)) }
                Text(c.musicChoice.display).font(AppFont.labelStrong)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 128, minHeight: 30)
            RoundIconButton(systemName: "chevron.right", label: s.nextMusic, size: 13, weight: .medium, quiet: true) { c.cycleMusic(1) }
        }
    }

    private var playModeIcon: String? {
        if settings.repeatOne { return "repeat.1" }
        return settings.shuffle ? "shuffle" : nil
    }

    @ViewBuilder private func trackRow(_ s: Strings) -> some View {
        if let track = c.currentTrack {
            // Cover and title on the left, the heart on the right: the cover sits under the previous button's
            // icon and the heart right under the music row's ›.
            HStack(spacing: 10) {
                // Cover and title open the playlist at this song. No › here: the heart owns the right end, and
                // the grey shape under the pointer already says the row opens something.
                Button { c.openPlaylist() } label: {
                    HStack(spacing: 10) {
                        CoverView(colors: track.colors, size: 40, image: track.coverURL)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title).font(AppFont.bodyStrong).lineLimit(1)
                                .foregroundStyle(c.isPlaying ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            Text(track.genre.display).font(AppFont.caption).foregroundStyle(.secondary)
                        }
                    }
                    // The grey always runs to just before the heart, whatever the title's length.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                    .background { if hover == .song { RoundedRectangle(Radius.songRow).fill(Palette.hover) } }
                    .contentShape(RoundedRectangle(Radius.songRow))
                }
                .buttonStyle(.plain)
                .onHover { setHover(.song, $0) }
                .help(s.openPlaylist)
                .accessibilityLabel(s.openPlaylist)
                // The grey shape reaches around the cover and title without moving them or growing the row.
                .padding(-4)
                // Takes the free width itself: a Spacer would add a second 10pt gap and cut the longest titles short.
                .frame(maxWidth: .infinity, alignment: .leading)
                RoundIconButton(systemName: track.liked ? "heart.fill" : "heart", label: s.like, size: 15,
                                tint: track.liked ? Palette.heart : nil, action: c.toggleLike)
            }
            .padding(.leading, Metrics.songRowInset)
            .padding(.trailing, Metrics.songRowHeartInset)
        } else {
            Text(s.noTracks).font(AppFont.body).foregroundStyle(.secondary).frame(height: 40)
        }
    }

    /// Today's timeline; opens today in History.
    private func todayCard(_ s: Strings) -> some View {
        Button { c.showHistory(day: LedgerStore.dayLabel(for: c.now, startHour: settings.dayStartHour)) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(s.today).font(AppFont.bodyStrong)
                    Spacer()
                    HStack(spacing: 2) {
                        Text(s.history)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                }
                DayBar(rows: c.todayRows, dayStart: c.dayInterval.start, now: c.now)
            }
            // Text on top, the bar at the bottom: 10 above the title reads like the 12 below the bar.
            .padding(EdgeInsets(top: Metrics.cardTextEdge, leading: Metrics.cardPadding,
                                bottom: Metrics.cardPadding, trailing: Metrics.cardPadding))
            .background { if hover == .today { RoundedRectangle(Radius.card).fill(Palette.hover) } }
            .cardBackground(.glass)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { setHover(.today, $0) }
        .accessibilityLabel(s.historyAria)
    }
}

// MARK: - Expanded panel (History, Playlist, Settings)

/// The panel grows under the menu bar instead of opening separate windows. ‹ or Esc returns to the player.
struct ExpandedPanel: View {
    @ObservedObject var c: FocusController
    @ObservedObject var settings: AppSettings
    @ObservedObject var library: LibraryStore

    var body: some View {
        let s = c.strings
        VStack(spacing: 0) {
            ZStack {
                Segmented(options: [(FocusController.PanelPage.history, s.history), (.library, s.playlist), (.settings, s.settings)],
                          selection: c.panelPage, height: Metrics.segmentedLarge, hPadding: 14) { c.panelPage = $0 }
                    .accessibilityLabel(s.sections)
                HStack {
                    BackButton(label: s.backToPlayer) { c.panelPage = .main }
                    Spacer()
                }
                .padding(.leading, 8)
            }
            .frame(height: Metrics.headerHeight)
            Hairline()
            Group {
                switch c.panelPage {
                case .history: HistoryView(c: c, settings: settings, ledger: c.ledger, library: library)
                case .library: PlaylistView(c: c, settings: settings, library: library)
                default: SettingsView(settings: settings, controller: c, library: library)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}
