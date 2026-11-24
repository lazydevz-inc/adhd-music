import SwiftUI

/// The grown panel's Playlist page. One list of every song that can play: the chips choose what
/// plays (the same choice as the player's ‹ Mix ›), the sort menu sets the order, and a player bar runs along
/// the bottom with a full-width progress bar and shuffle / "this song only" beside the play button. Why the
/// music helps is the same for every song, so it sits behind ⓘ instead of on every row.
struct PlaylistView: View {
    @ObservedObject var c: FocusController
    @ObservedObject var settings: AppSettings
    @ObservedObject var library: LibraryStore
    @State private var showHidden = false
    @State private var showWhy = false
    /// Spot on the progress bar while it is dragged (fraction of the song), so the time beside it follows.
    @State private var scrub: Double?

    var body: some View {
        let s = c.strings
        let songs = library.ordered(for: c.musicChoice, sort: settings.playlistSort)
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                toolbar(s, count: songs.count)
                    .padding(.trailing, 16)
                list(s, songs: songs)
            }
            .padding(.top, 12)
            .padding(.leading, 16)
            Hairline()
            playerBar(s)
        }
    }

    // MARK: Toolbar

    private func toolbar(_ s: Strings, count: Int) -> some View {
        HStack(spacing: 2) {
            Segmented(options: MusicChoice.allCases.map { ($0, $0.display) }, selection: c.musicChoice, hPadding: 10,
                      notes: MusicChoice.allCases.map { "\(library.playable(for: $0).count)" }) { c.setMusic($0) }
                .accessibilityLabel(s.whatPlays)
            Spacer(minLength: 12)
            Text(status(s, count: count))
                .font(AppFont.caption)
                .foregroundStyle(settings.repeatOne ? AnyShapeStyle(Palette.accentText) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .padding(.trailing, 8)
            sortMenu(s)
            RoundIconButton(systemName: "info.circle", label: s.whyAria, size: 15,
                            tint: showWhy ? Palette.accentText : nil, quiet: true) { showWhy.toggle() }
                .popover(isPresented: $showWhy, arrowEdge: .bottom) {
                    WhyCard(s: s, count: library.tracks.count) { showWhy = false }
                }
        }
        .frame(height: 30)
    }

    /// What happens after this song: shuffled, the list's order, or the same song again.
    private func status(_ s: Strings, count: Int) -> String {
        if settings.repeatOne { return s.statusRepeat }
        return settings.shuffle ? s.statusShuffled(count) : s.statusInOrder(count)
    }

    private func sortMenu(_ s: Strings) -> some View {
        Menu {
            Picker(s.sortLabel, selection: Binding(get: { settings.playlistSort }, set: { c.setSort($0) })) {
                ForEach(PlaylistSort.allCases, id: \.self) { Text(s.sortName($0)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(s.sortLabel).foregroundStyle(.secondary)
                Text(s.sortShort(settings.playlistSort)).fontWeight(.semibold)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(AppFont.body)
            .padding(.horizontal, 8)
            .frame(height: Metrics.iconButton)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverFill(RoundedRectangle(Radius.control))
        .help(s.sortLabel)
    }

    // MARK: List

    private func list(_ s: Strings, songs: [Track]) -> some View {
        // Default order on Mix reads best in genre groups; any other order is one list (with the genre beside
        // each song on Mix, since the groups are gone).
        let grouped = settings.playlistSort == .standard && c.musicChoice == .mix
        let showGenre = !grouped && c.musicChoice == .mix
        let hidden = library.hiddenTracks()
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if grouped {
                        ForEach(Genre.allCases, id: \.self) { genre in
                            let rows = songs.filter { $0.genre == genre }
                            if !rows.isEmpty {
                                Text("\(genre.display) · \(rows.count)")
                                    .font(AppFont.captionStrong).foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .frame(height: 26, alignment: .bottomLeading)
                                ForEach(rows) { row($0, s, showGenre: false) }
                            }
                        }
                    } else {
                        ForEach(songs) { row($0, s, showGenre: showGenre) }
                    }
                    if songs.isEmpty {
                        Text(s.playlistEmpty).font(AppFont.body).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    if !hidden.isEmpty { hiddenSection(s, hidden) }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 14)
            }
            .onAppear {
                // Development captures: `--preview playlist-why` / `playlist-hidden` open those parts.
                if c.options.preview == "playlist-why" { showWhy = true }
                if c.options.preview == "playlist-hidden" { showHidden = true }
                // Opened from the player's song row: the song that is on comes into view.
                guard let id = c.libraryFocus ?? c.currentTrack?.id else { return }
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func row(_ track: Track, _ s: Strings, showGenre: Bool) -> some View {
        PlaylistRow(track: track, isNow: track.id == c.currentTrack?.id, playing: c.isPlaying, showGenre: showGenre,
                    ko: settings.ko, s: s,
                    onPlay: { c.playTrack(track.id) },
                    onLike: { c.toggleLike(track.id) },
                    onHide: { c.dontPlay(track.id) })
            .id(track.id)
    }

    @ViewBuilder private func hiddenSection(_ s: Strings, _ hidden: [Track]) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { showHidden.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: showHidden ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold)).frame(width: 10)
                Text("\(s.notPlaying) · \(hidden.count)")
            }
            .font(AppFont.captionStrong).foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .hoverFill(RoundedRectangle(Radius.control))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        if showHidden {
            ForEach(hidden) { track in
                HStack(spacing: 10) {
                    CoverView(colors: track.colors, size: 28, image: track.coverURL).opacity(0.45)
                    Text(track.title).font(AppFont.label).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer(minLength: 8)
                    Button { c.playAgain(track.id) } label: {
                        Text(s.playAgain).font(AppFont.bodyStrong).foregroundStyle(Palette.accentText)
                            .padding(.horizontal, 10)
                            .frame(height: Metrics.pillHeight)
                            .hoverFill(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6)
                .frame(height: 40)
                .id("hidden-" + track.id)
            }
        }
    }

    // MARK: Player bar

    private func playerBar(_ s: Strings) -> some View {
        let track = c.currentTrack
        let length = track?.playLength ?? 0
        let position = min(c.playPosition, length)
        let shown = scrub.map { $0 * length } ?? position
        return VStack(spacing: 0) {
            SeekBar(value: length > 0 ? position / length : 0, height: 4, enabled: track != nil && length > 0,
                    onScrub: { scrub = $0 }) { fraction in c.seek(to: fraction * length) }
                .accessibilityLabel(s.songPosition)
                .padding(.horizontal, 16)
                .padding(.top, 9)
            HStack(spacing: 16) {
                nowPlaying(s, track).frame(maxWidth: .infinity, alignment: .leading)
                transport(s)
                Text(length > 0 ? "\(Fmt.trackLength(shown)) / \(Fmt.trackLength(length))" : "")
                    .font(AppFont.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 74)
        .background(Palette.card)
    }

    @ViewBuilder private func nowPlaying(_ s: Strings, _ track: Track?) -> some View {
        if let track {
            HStack(spacing: 10) {
                CoverView(colors: track.colors, size: 40, image: track.coverURL)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(AppFont.labelStrong).lineLimit(1)
                    if let vibe = track.vibe(ko: settings.ko) {
                        Text(vibe).font(AppFont.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                RoundIconButton(systemName: track.liked ? "heart.fill" : "heart", label: s.like, size: 14,
                                tint: track.liked ? Palette.heart : nil) { c.toggleLike(track.id) }
            }
        } else {
            Text(s.noTracks).font(AppFont.body).foregroundStyle(.secondary)
        }
    }

    /// Shuffle and "this song only" on both sides of previous · play · next, as music players place them.
    private func transport(_ s: Strings) -> some View {
        let hasSong = c.currentTrack != nil
        return HStack(spacing: 6) {
            modeButton("shuffle", label: s.shuffle, on: settings.shuffle, s) { c.setShuffle(!settings.shuffle) }
            RoundIconButton(systemName: "backward.end.fill", label: s.prevTrack, size: 14, diameter: 30) { c.previousTrack() }
                .disabled(!hasSong)
            PlayCircle(playing: c.isPlaying, label: c.isPlaying ? s.pause : s.play, action: c.togglePlay)
                .disabled(!(c.hasTracks || c.run != .idle))
            RoundIconButton(systemName: "forward.end.fill", label: s.nextTrack, size: 14, diameter: 30) { c.nextTrack() }
                .disabled(!hasSong)
            modeButton("repeat.1", label: s.repeatOne, on: settings.repeatOne, s) { c.setRepeatOne(!settings.repeatOne) }
        }
    }

    /// Teal with a dot underneath while on, grey while off.
    private func modeButton(_ icon: String, label: String, on: Bool, _ s: Strings, action: @escaping () -> Void) -> some View {
        RoundIconButton(systemName: icon, label: "\(label) · \(s.onOff(on))", size: 14, weight: .semibold, diameter: 30,
                        tint: on ? Palette.accentText : nil, quiet: !on, action: action)
            .overlay(alignment: .bottom) {
                if on {
                    Circle().fill(Palette.accentText).frame(width: 4, height: 4)
                        .padding(.bottom, 1)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Parts

/// One song: cover and title play it; ♥ and "don't play" show while the pointer is over the row
/// (♥ stays once it is on). The song that is on is tinted teal with bars on its cover.
private struct PlaylistRow: View {
    let track: Track
    let isNow: Bool
    let playing: Bool
    let showGenre: Bool
    let ko: Bool
    let s: Strings
    let onPlay: () -> Void
    let onLike: () -> Void
    let onHide: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onPlay) {
                HStack(spacing: 10) {
                    cover
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(track.title).font(AppFont.labelStrong).lineLimit(1)
                                .foregroundStyle(isNow ? AnyShapeStyle(Palette.accentText) : AnyShapeStyle(.primary))
                            if track.isNew && !isNow {
                                Text(s.newTag).font(AppFont.microStrong).foregroundStyle(Palette.accentText)
                            }
                        }
                        if let vibe = track.vibe(ko: ko) {
                            Text(vibe).font(AppFont.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if showGenre {
                        Text(track.genre.display).font(AppFont.caption).foregroundStyle(.tertiary)
                            .frame(width: 74, alignment: .leading)
                    }
                }
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(s.playSong(track.title))
            .accessibilityLabel(s.playSong(track.title))
            RoundIconButton(systemName: track.liked ? "heart.fill" : "heart", label: s.like, size: 13,
                            tint: track.liked ? Palette.heart : nil, quiet: true, action: onLike)
                .opacity(track.liked || hovering ? 1 : 0)
            RoundIconButton(systemName: "eye.slash", label: s.dontPlay, size: 13, quiet: true, action: onHide)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 6)
        .background {
            if isNow {
                RoundedRectangle(Radius.control).fill(Palette.accentWash)
            } else if hovering {
                RoundedRectangle(Radius.control).fill(Palette.hover)
            }
        }
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
    }

    private var cover: some View {
        CoverView(colors: track.colors, size: 32, image: track.coverURL)
            .overlay {
                if isNow {
                    // Three bars on whole points (10 in, 9 up), so they stay sharp on a 1x screen.
                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(32 * 0.225).fill(Color.black.opacity(0.5))
                        HStack(alignment: .bottom, spacing: 2) {
                            ForEach(Array([9.0, 14.0, 6.0].enumerated()), id: \.offset) { _, height in
                                RoundedRectangle(1).fill(Color.white).frame(width: 3, height: height)
                            }
                        }
                        .opacity(playing ? 1 : 0.6)
                        .padding(.leading, 10)
                        .padding(.bottom, 9)
                    }
                }
            }
    }
}

/// The bar's play button: a teal circle (the one filled button on the page), darker under the pointer.
private struct PlayCircle: View {
    let playing: Bool
    let label: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .offset(x: playing ? 0 : 1.5)
                .frame(width: 38, height: 38)
                .background {
                    ZStack {
                        Circle().fill(Palette.accent)
                        if hovering && isEnabled { Circle().fill(Color.black.opacity(0.12)) }
                    }
                }
                .contentShape(Circle())
                .animation(Motion.hover, value: hovering)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Behind ⓘ: the four things every song is made with, and why each helps.
private struct WhyCard: View {
    let s: Strings
    let count: Int
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(s.whyTitle).font(.system(size: 13, weight: .bold))
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Text(s.close).font(AppFont.bodyStrong).foregroundStyle(Palette.accentText)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .hoverFill(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.trailing, -8)
            }
            Text(s.whySub(count)).font(AppFont.caption).foregroundStyle(.secondary).padding(.top, -6)
            reason("waveform", s.reasonPulse)
            reason("mic.slash", s.reasonVoice)
            reason("water.waves", s.reasonCalm)
            reason("repeat", s.reasonLoop)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 360)
    }

    private func reason(_ icon: String, _ text: (String, String)) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accentText)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(text.0).font(AppFont.bodyStrong).frame(minHeight: 20, alignment: .leading)
                Text(text.1).font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
