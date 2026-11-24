import AppKit
import Combine
import SwiftUI

/// The single source of truth for playback, timers and recording.
@MainActor
final class FocusController: ObservableObject {
    enum Run { case idle, playing, paused }
    enum PauseReason { case user, away, call, timer, headphones, otherSound }
    enum PomoPhase: Equatable { case focus, shortBreak, longBreak }
    /// main and sound fit the small panel; history, the playlist (`library`) and settings grow it under the menu bar.
    enum PanelPage {
        /// `sound` is the one Timer & Sound page; the big clock and ··· both open it.
        case main, sound, history, library, settings
        var isExpanded: Bool { self == .history || self == .library || self == .settings }
    }
    /// The five parts of Settings (its left list).
    enum SettingsPage: String, CaseIterable { case playback, pause, menubar, keys, history }

    let settings: AppSettings
    let library: LibraryStore
    let ledger: LedgerStore
    let options: LaunchOptions

    @Published private(set) var run: Run = .idle
    @Published private(set) var pauseReason: PauseReason = .user
    @Published private(set) var musicChoice: MusicChoice
    @Published private(set) var currentTrack: Track?
    @Published private(set) var effect: EffectChoice
    @Published private(set) var now = Date()
    @Published private(set) var intention = ""
    /// The app whose sound paused the music (shown in the notice).
    @Published private(set) var otherSoundApp: String?
    @Published var editingIntention = false
    @Published var panelPage: PanelPage = .main {
        didSet {
            // Coming back to History, the playlist or Settings later starts from their usual view.
            if panelPage != .history { historyDay = nil; historyMonth = false }
            if panelPage != .library { libraryFocus = nil }
            if panelPage != .settings { settingsFocus = nil }
        }
    }
    /// History shows the month calendar instead of the week strip.
    @Published var historyMonth = false
    /// The part of Settings on show, and a card to mark when Settings was opened for it (`pause.other`).
    @Published var settingsPage: SettingsPage = .playback
    @Published var settingsFocus: String?
    /// The day History shows (its day label), or nil for the month calendar.
    @Published var historyDay: Date?
    /// The song the playlist scrolls to when it opens (the one playing, from the main song row).
    @Published var libraryFocus: String?
    /// Animations run only while the panel is on screen.
    @Published var panelVisible = false
    /// True while Settings is recording a new shortcut, so the panel lets every key through.
    var keyCaptureActive = false

    @Published private(set) var pomoPhase: PomoPhase = .focus
    @Published private(set) var pomoRound = 1
    @Published private(set) var timerFinished = false

    var onTick: (() -> Void)?

    private let engine = FocusAudioEngine()
    private let away = AwayMonitor()
    private let calls = CallMonitor()
    private let outputs = OutputDeviceMonitor()
    private let otherSound = OtherSoundMonitor()
    private let media = MediaKeys()
    private let hotKey = HotKey()
    private var ticker: Timer?
    private var lastTick = Date()
    private var lastCheckpoint = Date()
    private var engineNeedsStart = true
    /// A place on the progress bar chosen while the music is stopped: the next start begins there.
    private var pendingStart: Double?
    /// The last jump on the bar while playing. Until the new place is heard (a moment), the bar stays there
    /// instead of flicking back to 0.
    private var lastSeek: (seconds: Double, at: Date)?
    /// Songs that gave way because another song was chosen (a playlist row, a genre chip), not skipped:
    /// their early end doesn't count as a skip for learning.
    private var choseOver: Set<String> = []
    private var recent: [String] = []
    private var history: [String] = []
    private var cancellables: Set<AnyCancellable> = []

    /// Seconds counted as work during this app run; drives timers that only run while recording.
    private var workClock: TimeInterval = 0
    private var timerStartWork: TimeInterval?
    private var pomoFocusStartWork: TimeInterval = 0
    private var pomoBreakEnd: Date?
    private var pomoBreakRemaining: TimeInterval?

    init(settings: AppSettings, library: LibraryStore, ledger: LedgerStore, options: LaunchOptions) {
        self.settings = settings
        self.library = library
        self.ledger = ledger
        self.options = options
        musicChoice = settings.defaultMusic
        effect = settings.defaultEffect
        engine.delegate = self
        engine.noiseRecordings = Self.noiseRecordingURLs()
        engine.setEffectLevel(EffectLevel(rawValue: effect.rawValue) ?? .medium)
        engine.setVolume(options.muted ? 0 : Float(options.volume ?? settings.volume))
        engine.setNoise(Self.noiseKind(settings.noise), level: Float(settings.noiseLevel))
        engine.pausesWhenOutputLost = settings.pauseWhenHeadphonesOff
        engine.minimumTrackSeconds = Track.minimumPlaySeconds
        // Shuffle remembers what played before the app was last closed.
        recent = ledger.recentTracks()
        currentTrack = upNext(after: nil)

        away.onChange = { [weak self] isAway in self?.handleAway(isAway) }
        calls.onChange = { [weak self] inCall in self?.handleCall(inCall) }
        if settings.pauseDuringCalls { calls.start() }
        outputs.onChange = { [weak self] in self?.handleOutputChange() }
        outputs.start()
        otherSound.onChange = { [weak self] app in self?.handleOtherSound(app) }
        if settings.pauseForOtherSound { otherSound.start() }

        media.onToggle = { [weak self] in self?.togglePlay() }
        media.onPlay = { [weak self] in self?.play() }
        media.onPause = { [weak self] in self?.pause(.user) }
        media.onNext = { [weak self] in self?.nextTrack() }
        media.onPrevious = { [weak self] in self?.previousTrack() }
        media.onSeek = { [weak self] seconds in self?.seek(to: seconds) }
        registerHotKey()

        settings.$pauseDuringCalls.dropFirst().sink { [weak self] on in
            if on { self?.calls.start() } else { self?.calls.stop() }
        }.store(in: &cancellables)
        settings.$hotKeyCode.combineLatest(settings.$hotKeyModifiers).dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.registerHotKey() }
        }.store(in: &cancellables)
        settings.$volume.dropFirst().sink { [weak self] value in
            guard let self, !self.options.muted else { return }
            self.engine.setVolume(Float(value))
            DispatchQueue.main.async { self.syncOtherSoundNeed() }
        }.store(in: &cancellables)
        settings.$noise.combineLatest(settings.$noiseLevel).dropFirst().sink { [weak self] kind, level in
            self?.engine.setNoise(Self.noiseKind(kind), level: Float(level))
        }.store(in: &cancellables)
        settings.$pauseForOtherSound.dropFirst().sink { [weak self] on in
            guard let self else { return }
            if on { self.otherSound.start() } else { self.otherSound.stop() }
        }.store(in: &cancellables)
        // Other apps are listened to only while the music plays or waits for them to go quiet.
        // Read the state after both values have changed (play() and pause() set them one by one).
        $run.combineLatest($pauseReason).sink { [weak self] _, _ in
            DispatchQueue.main.async { self?.syncOtherSoundNeed() }
        }.store(in: &cancellables)
        settings.$pauseWhenHeadphonesOff.dropFirst().sink { [weak self] on in
            guard let self else { return }
            self.engine.pausesWhenOutputLost = on
            if !on && self.run == .paused && self.pauseReason == .headphones { self.pauseReason = .user }
        }.store(in: &cancellables)
        settings.$mediaKeys.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateMedia() }
        }.store(in: &cancellables)
        library.$tracks.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.libraryChanged() }
        }.store(in: &cancellables)

        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(ticker!, forMode: .common)
        updateMedia()
    }

    private func registerHotKey() {
        hotKey.register(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers) { [weak self] in
            Task { @MainActor in self?.togglePlay() }
        }
    }

    // MARK: Derived state

    var strings: Strings { settings.strings }
    var isPlaying: Bool { run == .playing }
    var inBreak: Bool { settings.playMode == .pomodoro && pomoPhase != .focus && run != .idle }
    var isRecording: Bool { run == .playing && !inBreak }
    var dayInterval: DateInterval { LedgerStore.dayInterval(containing: now, startHour: settings.dayStartHour) }
    var todaySeconds: TimeInterval { ledger.seconds(in: dayInterval, now: now) }
    var todayRows: [DayRow] { ledger.rows(in: dayInterval, now: now) }
    var hasTracks: Bool { !library.playable(for: musicChoice).isEmpty }

    var timerRemaining: TimeInterval? {
        guard settings.playMode == .timer, run != .idle, !timerFinished else { return nil }
        let minutes = settings.timerChoice.presetMinutes ?? max(1, settings.customTimerMinutes)
        let used = timerStartWork.map { workClock - $0 } ?? 0
        return max(0, TimeInterval(minutes * 60) - used)
    }

    var pomoRemaining: TimeInterval? {
        guard settings.playMode == .pomodoro, run != .idle else { return nil }
        switch pomoPhase {
        case .focus:
            return max(0, TimeInterval(settings.pomodoroMinutes.focus * 60) - (workClock - pomoFocusStartWork))
        case .shortBreak, .longBreak:
            if let remaining = pomoBreakRemaining { return remaining }
            return max(0, (pomoBreakEnd ?? now).timeIntervalSince(now))
        }
    }

    /// Text for the chip under the big clock: what the timer will do, or how long is left.
    var timerChipText: String {
        let s = strings
        switch settings.playMode {
        case .noLimit:
            return s.modes[0].0
        case .timer:
            if let remaining = timerRemaining { return s.timerLeft(Fmt.clock(remaining)) }
            return s.timerIdle(settings.timerChoice.presetMinutes ?? max(1, settings.customTimerMinutes))
        case .pomodoro:
            if pomoRemaining != nil { return statusLabel }
            let minutes = settings.pomodoroMinutes
            return s.pomodoroIdle(minutes.focus, minutes.rest)
        }
    }

    /// True while a timer or pomodoro is counting down, which tints the chip.
    var timerCounting: Bool { timerRemaining != nil || pomoRemaining != nil }

    var statusLabel: String {
        let s = strings
        if let remaining = pomoRemaining {
            switch pomoPhase {
            case .focus: return s.focusRound(pomoRound, Fmt.clock(remaining))
            case .shortBreak: return s.breakLeft(Fmt.clock(remaining))
            case .longBreak: return s.longBreakLeft(Fmt.clock(remaining))
            }
        }
        if let remaining = timerRemaining {
            return s.timerLeft(Fmt.clock(remaining))
        }
        return ""
    }

    var menuBarText: String? {
        guard settings.menuBarStyle == .todayTotal else { return nil }
        if inBreak, let remaining = pomoRemaining { return strings.breakWord + " " + Fmt.clock(remaining) }
        let total = todaySeconds
        return total >= 1 || run != .idle ? Fmt.clock(total) : nil
    }

    var menuBarTag: String? {
        guard run == .paused else { return nil }
        switch pauseReason {
        case .call: return strings.onCall
        case .away: return strings.away
        case .headphones: return strings.headphonesOff
        case .otherSound: return strings.otherSoundTag
        default: return nil
        }
    }

    // MARK: Tick

    private func tick() {
        let date = Date()
        if isRecording { workClock += date.timeIntervalSince(lastTick) }
        lastTick = date
        now = date

        if settings.playMode == .timer, run == .playing, let remaining = timerRemaining, remaining <= 0 { finishTimer() }
        if settings.playMode == .pomodoro, run == .playing { advancePomodoro() }
        if date.timeIntervalSince(lastCheckpoint) >= 30 {
            ledger.checkpoint(at: date)
            lastCheckpoint = date
        }
        onTick?()
    }

    // MARK: Playback

    func togglePlay() { isPlaying ? pause(.user) : play() }

    func play() {
        guard run != .playing else { return }
        if currentTrack == nil || currentTrack?.status == .removed || !(library.playable(for: musicChoice).contains { $0.id == currentTrack?.id }) {
            currentTrack = upNext(after: currentTrack?.id)
            engineNeedsStart = true
            pendingStart = nil
        }
        guard currentTrack != nil else { return }
        let fade = settings.fadeInOut ? 1.5 : 0
        if run == .idle || timerFinished {
            timerStartWork = workClock
            timerFinished = false
            if settings.playMode == .pomodoro && run == .idle {
                pomoPhase = .focus
                pomoRound = 1
                pomoFocusStartWork = workClock
            }
        }
        if timerStartWork == nil { timerStartWork = workClock }
        let breakSilent = inBreak && settings.breakMusic == .pause
        if !breakSilent { startOrResume(fade: fade) }
        if let remaining = pomoBreakRemaining {
            pomoBreakEnd = Date().addingTimeInterval(remaining)
            pomoBreakRemaining = nil
        }
        if inBreak && settings.breakMusic == .quieter { engine.setDuck(0.3, ramp: 1) }
        run = .playing
        pauseReason = .user
        syncRecording()
        updateMedia()
    }

    func pause(_ reason: PauseReason) {
        guard run == .playing else { return }
        let fade: TimeInterval
        switch reason {
        case .user: fade = settings.fadeInOut ? 1.0 : 0
        case .timer: fade = settings.fadeInOut ? 4.0 : 0
        case .away, .call, .headphones, .otherSound: fade = 0.3
        }
        engine.pause(fade: fade, completion: nil)
        markPaused(reason)
    }

    private func markPaused(_ reason: PauseReason) {
        if inBreak, let end = pomoBreakEnd { pomoBreakRemaining = max(0, end.timeIntervalSince(Date())) }
        run = .paused
        pauseReason = reason
        syncRecording()
        updateMedia()
    }

    private func syncRecording() {
        if isRecording {
            if !ledger.isRecording {
                ledger.beginPlay(intention: intention, genre: currentTrack?.genre.rawValue, track: currentTrack?.id)
            }
        } else if ledger.isRecording {
            ledger.endPlay()
        }
        lastTick = Date()
    }

    func engineTrack(_ track: Track) -> EngineTrack {
        EngineTrack(id: track.id, url: track.url, gainDB: Float(track.gainDb),
                    modulationHz: track.modulationHz, beatOffsetSeconds: track.beatOffset,
                    loopStartSeconds: track.loopStart, loopEndSeconds: track.loopEnd,
                    loopSeamCorrelation: track.loopSeamCorrelation,
                    beatTimes: track.beatTimes, pulseCyclesPerBeat: track.pulseCyclesPerBeat)
    }

    /// Starts the current song (where the progress bar was set, if it was) or carries on where it paused.
    private func startOrResume(fade: TimeInterval) {
        guard let track = currentTrack else { return }
        if engineNeedsStart || pendingStart != nil {
            engine.start(with: engineTrack(track), fadeIn: fade, startTime: pendingStart ?? 0)
            if engineNeedsStart { noteStarted(track) }
            engineNeedsStart = false
        } else {
            engine.resume(fade: fade)
        }
        pendingStart = nil
    }

    private func noteStarted(_ track: Track) {
        recent.append(track.id)
        if recent.count > 60 { recent.removeFirst(recent.count - 60) }
        if history.last != track.id { history.append(track.id) }
        if history.count > 50 { history.removeFirst(history.count - 50) }
        library.markPlayed(track.id)
    }

    /// The song after `id`: shuffling, a weighted pick among the songs not heard lately (♥ more often, see
    /// `LibraryStore.pickNext`); otherwise the playlist's order.
    private func upNext(after id: String?) -> Track? {
        if settings.shuffle {
            return library.pickNext(for: musicChoice, avoiding: recent + [id ?? ""], learn: settings.learnFromSkips)
        }
        return library.nextInOrder(after: id, for: musicChoice, sort: settings.playlistSort)
    }

    func nextTrack() {
        guard let next = upNext(after: currentTrack?.id) else { return }
        go(to: next)
    }

    /// Shuffling: the song played before (in what is chosen to play). In order: the one above in the playlist.
    /// Going back (or starting the song over) is a choice, not a skip, so it doesn't teach "plays less".
    func previousTrack() {
        if !settings.shuffle {
            if let previous = library.previousInOrder(before: currentTrack?.id, for: musicChoice, sort: settings.playlistSort),
               previous.id != currentTrack?.id {
                noteChosenOver()
                go(to: previous)
            }
            return
        }
        if history.count >= 2 {
            history.removeLast()
            if let id = history.last, let track = library.playable(for: musicChoice).first(where: { $0.id == id }) {
                history.removeLast()
                noteChosenOver()
                go(to: track)
                return
            }
        }
        if let current = currentTrack, run == .playing {
            noteChosenOver()
            engine.skip(to: engineTrack(current), crossfade: 0.5)
        }
    }

    /// A playlist row: that song now, from its start (or play/pause when it is the one playing).
    func playTrack(_ id: String) {
        guard let track = library.track(id), track.status != .removed else { return }
        if track.id == currentTrack?.id {
            if run != .playing { play() }
            return
        }
        noteChosenOver()
        go(to: track)
        if run != .playing { play() }
    }

    /// The song that is heard now is being replaced by a choice, not skipped (see `choseOver`).
    private func noteChosenOver() {
        guard run == .playing, !engineNeedsStart, let id = currentTrack?.id else { return }
        choseOver.insert(id)
    }

    /// Where the song is now in its 30-minute play (the bar's place while it waits to start).
    var playPosition: Double {
        if let pendingStart { return pendingStart }
        if engineNeedsStart { return 0 }
        let heard = engine.currentTime
        if let jump = lastSeek, Date().timeIntervalSince(jump.at) < 1.5, abs(heard - jump.seconds) > 2 { return jump.seconds }
        return heard
    }

    /// The progress bar: go to `seconds` in the play. Stopped, the place waits for the next start.
    func seek(to seconds: Double) {
        guard let track = currentTrack else { return }
        let target = min(max(0, seconds), max(0, track.playLength - 1))
        let audible = run == .playing && !engineNeedsStart && !(inBreak && settings.breakMusic == .pause)
        if audible {
            engine.start(with: engineTrack(track), fadeIn: 0.15, startTime: target)
            pendingStart = nil
            lastSeek = (target, Date())
        } else {
            pendingStart = target
        }
        updateMedia()
    }

    func setShuffle(_ on: Bool) { settings.shuffle = on }
    func setRepeatOne(_ on: Bool) { settings.repeatOne = on }
    func setSort(_ sort: PlaylistSort) { settings.playlistSort = sort }

    private func go(to track: Track) {
        currentTrack = track
        pendingStart = nil
        lastSeek = nil
        if run == .playing && !engineNeedsStart {
            engine.skip(to: engineTrack(track), crossfade: 1.5)
            noteStarted(track)
        } else {
            if run == .paused { engine.stop() }
            engineNeedsStart = true
        }
        if ledger.isRecording {
            ledger.split(intention: intention, genre: track.genre.rawValue)
            ledger.noteTrack(track.id)
        }
        updateMedia()
    }

    func cycleMusic(_ step: Int) {
        let all = MusicChoice.allCases
        let index = (all.firstIndex(of: musicChoice)! + step + all.count) % all.count
        setMusic(all[index])
    }

    /// Mix or one genre: the main ‹ Mix › and the playlist's chips. A song outside it gives way.
    func setMusic(_ choice: MusicChoice) {
        guard choice != musicChoice else { return }
        musicChoice = choice
        if let current = currentTrack, choice.genre == nil || choice.genre == current.genre { return }
        if let next = upNext(after: nil) {
            noteChosenOver()
            go(to: next)
        }
    }

    func toggleLike() {
        guard let id = currentTrack?.id else { return }
        toggleLike(id)
    }

    func toggleLike(_ id: String) {
        library.toggleLike(id)
        if currentTrack?.id == id { currentTrack = library.track(id) }
    }

    /// The eye on a playlist row: the song stops coming up (Not playing). The one playing moves on.
    func dontPlay(_ id: String) { library.remove(id) }

    /// "Play again" in Not playing.
    func playAgain(_ id: String) { library.restore(id) }

    func setEffect(_ choice: EffectChoice) {
        effect = choice
        engine.setEffectLevel(EffectLevel(rawValue: choice.rawValue) ?? .medium)
    }

    // MARK: Intention

    func setIntention(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        intention = trimmed
        if ledger.isRecording { ledger.split(intention: trimmed, genre: currentTrack?.genre.rawValue) }
    }

    // MARK: Timer & Pomodoro

    func setPlayMode(_ mode: PlayMode) {
        settings.playMode = mode
        timerFinished = false
        timerStartWork = run == .idle ? nil : workClock
        if mode == .pomodoro {
            pomoPhase = .focus
            pomoRound = 1
            pomoFocusStartWork = workClock
            pomoBreakEnd = nil
            pomoBreakRemaining = nil
            engine.setDuck(1, ramp: 0.5)
        } else if inBreakAudioAltered {
            restoreBreakAudio()
        }
        syncRecording()
    }

    func setTimerChoice(_ choice: TimerChoice) {
        settings.timerChoice = choice
        timerFinished = false
        timerStartWork = run == .idle ? nil : workClock
    }

    func setPomodoroPreset(_ preset: PomodoroPreset) {
        settings.pomodoroPreset = preset
        if pomoPhase == .focus { pomoFocusStartWork = workClock }
    }

    private var inBreakAudioAltered: Bool { pomoPhase != .focus }

    private func restoreBreakAudio() {
        pomoPhase = .focus
        pomoBreakEnd = nil
        pomoBreakRemaining = nil
        engine.setDuck(1, ramp: 1)
        if run == .playing && settings.breakMusic == .pause { startOrResume(fade: 1.5) }
    }

    private func finishTimer() {
        timerFinished = true
        timerStartWork = nil
        if settings.timerEndAction == .stop { pause(.timer) }
    }

    private func advancePomodoro() {
        guard let remaining = pomoRemaining, remaining <= 0 else { return }
        switch pomoPhase {
        case .focus:
            let long = settings.longBreakEvery4 && pomoRound % 4 == 0
            pomoPhase = long ? .longBreak : .shortBreak
            let minutes = long ? 15 : settings.pomodoroMinutes.rest
            pomoBreakEnd = Date().addingTimeInterval(TimeInterval(minutes * 60))
            if settings.breakMusic == .pause {
                engine.pause(fade: settings.fadeInOut ? 3 : 0, completion: nil)
            } else {
                engine.setDuck(0.3, ramp: 3)
            }
            syncRecording()
        case .shortBreak, .longBreak:
            pomoRound += 1
            pomoPhase = .focus
            pomoFocusStartWork = workClock
            pomoBreakEnd = nil
            if settings.breakMusic == .pause {
                startOrResume(fade: engineNeedsStart ? 2 : (settings.fadeInOut ? 3 : 0))
            } else {
                engine.setDuck(1, ramp: 3)
            }
            syncRecording()
        }
    }

    // MARK: Away & calls

    private func handleAway(_ isAway: Bool) {
        if isAway {
            // Locking or sleeping the Mac cancels a wait for headphones: no music starts later by surprise.
            if run == .paused && pauseReason == .headphones { pauseReason = .user }
            guard settings.pauseWhenAway, run == .playing else { return }
            pause(.away)
            ledger.beginGap(reason: "away")
        } else if run == .paused && pauseReason == .away {
            ledger.endGap()
            resumeAfterAutoPause()
        }
    }

    private func handleCall(_ inCall: Bool) {
        if inCall {
            guard settings.pauseDuringCalls, run == .playing else { return }
            pause(.call)
            ledger.beginGap(reason: "call")
        } else if run == .paused && pauseReason == .call {
            ledger.endGap()
            resumeAfterAutoPause()
        }
    }

    /// After a call, stepping away or another app's sound: play, unless something else that
    /// pauses the music still holds; then wait for that instead.
    private func resumeAfterAutoPause() {
        if settings.pauseWhenHeadphonesOff && !lostOutputIsBack {
            waitFor(.headphones)
        } else if settings.pauseWhenAway && away.isAway {
            waitFor(.away)
            ledger.beginGap(reason: "away")
        } else if settings.pauseDuringCalls && calls.inCall {
            waitFor(.call)
            ledger.beginGap(reason: "call")
        } else if settings.pauseForOtherSound && otherSound.source != nil {
            waitFor(.otherSound)
        } else {
            play()
        }
    }

    /// Development: the main panel as it looks right after the music stopped by itself (`--preview main-notice`).
    func previewAutoPause(_ reason: PauseReason, app: String? = nil) {
        if let app { otherSoundApp = app }
        run = .paused
        pauseReason = reason
    }

    private func waitFor(_ reason: PauseReason) {
        pauseReason = reason
        updateMedia()
    }

    // MARK: Other apps' sound

    private func syncOtherSoundNeed() {
        otherSound.isNeeded = run == .playing || (run == .paused && pauseReason == .otherSound)
        otherSound.ownSoundAudible = run == .playing && !options.muted && (options.volume ?? settings.volume) > 0
    }

    /// Development: writes what the other-sound check hears each second (`--sound-log`).
    func logOtherSound(to url: URL) {
        try? "".write(to: url, atomically: true, encoding: .utf8)
        otherSound.logURL = url
        otherSound.logState = { [weak self] in
            guard let self else { return "" }
            return "run=\(self.run) reason=\(self.pauseReason) permission=\(self.otherSound.permission.rawValue) tap=\(self.otherSound.tapTrust.rawValue) engineRestarts=\(self.engine.configurationRestartCount) underruns=\(self.engine.underrunCount)"
        }
    }

    /// Another app started playing sound (YouTube, a video, a meeting) or went quiet again.
    private func handleOtherSound(_ app: String?) {
        if let app { otherSoundApp = app }
        if app != nil {
            guard settings.pauseForOtherSound, run == .playing else { return }
            pause(.otherSound)
        } else if run == .paused && pauseReason == .otherSound {
            resumeAfterAutoPause()
        }
    }

    // MARK: Headphones

    /// The Mac's sound output changed: if the headphones that left are the output again, carry on.
    private func handleOutputChange() {
        guard run == .paused, pauseReason == .headphones, lostOutputIsBack else { return }
        play()
    }

    /// False while the device the music was playing on is gone and is not the Mac's output again.
    private var lostOutputIsBack: Bool {
        guard let lost = engine.lostOutputUID else { return true }
        return OutputDeviceMonitor.defaultOutputUID() == lost
    }

    /// The looped nature recordings in the app's Resources/Noise (Scripts/build-app.sh copies them in).
    static func noiseRecordingURLs(bundle: Bundle = .main) -> [FocusNoiseKind: URL] {
        var urls: [FocusNoiseKind: URL] = [:]
        for (kind, name) in [(FocusNoiseKind.rain, "rain"), (.ocean, "ocean"), (.stream, "stream")] {
            if let url = bundle.url(forResource: name, withExtension: "flac", subdirectory: "Noise") { urls[kind] = url }
        }
        return urls
    }

    static func noiseKind(_ choice: NoiseChoice) -> FocusNoiseKind {
        switch choice {
        case .off: return .off
        case .rain: return .rain
        case .ocean: return .ocean
        case .stream: return .stream
        case .brown: return .brown
        case .pink: return .pink
        case .white: return .white
        }
    }

    // MARK: Library changes

    private func libraryChanged() {
        if let id = currentTrack?.id, let fresh = library.track(id) {
            currentTrack = fresh
            // "Don't play" on the song that is on: the next one takes its place (and plays if it was playing).
            if fresh.status == .removed, let next = upNext(after: id), next.id != id { go(to: next) }
        }
        if currentTrack == nil { currentTrack = upNext(after: nil) }
    }

    func applyLanguage() { objectWillChange.send(); updateMedia() }

    // MARK: Panel navigation

    /// History on a day (its label), or on the month calendar when nil.
    /// History on the week holding `day` (today when nil), that day open.
    func showHistory(day: Date?) {
        historyDay = day
        panelPage = .history
    }

    /// Settings on one part, optionally with a card marked (the player's notice opens the pause it names).
    func openSettings(_ page: SettingsPage, focus: String? = nil) {
        settingsPage = page
        panelPage = .settings
        settingsFocus = focus
    }

    /// The playlist, scrolled to `id` (default: the song that is on).
    func openPlaylist(focus id: String? = nil) {
        panelPage = .library
        libraryFocus = id ?? currentTrack?.id
    }

    // MARK: Media keys

    private func updateMedia() {
        // A song plays for about 30 minutes, its middle repeating.
        let duration = currentTrack?.playLength ?? 0
        media.update(mode: settings.mediaKeys, playing: isPlaying, title: currentTrack?.title,
                     elapsed: playPosition, duration: duration)
    }

    // MARK: Development hooks

    func debugAway(_ isAway: Bool) { handleAway(isAway) }
    func debugOutputChange() { handleOutputChange() }
    func debugHeadphonesOut() { engine.simulateOutputLossForTesting() }
    func debugOtherSound(_ app: String?) { handleOtherSound(app) }
    func debugCall(_ inCall: Bool) { handleCall(inCall) }

    var debugState: String {
        let rows = ledger.rows(in: dayInterval, now: Date())
        return "run=\(run) reason=\(pauseReason) music=\(musicChoice.rawValue) track=\(currentTrack?.id ?? "-") "
            + "engine(playing=\(engine.isPlaying) track=\(engine.currentTrack?.id ?? "-") t=\(String(format: "%.2f", engine.currentTime)) underruns=\(engine.underrunCount)) "
            + "bar=\(String(format: "%.1f", playPosition)) shuffle=\(settings.shuffle) repeat=\(settings.repeatOne) "
            + "effect=\(effect) recording=\(ledger.isRecording) today=\(Fmt.clock(todaySeconds)) rows=\(rows.count) "
            + "lastRow=\(rows.last.map { "\($0.kind) \(Fmt.timeOfDay($0.start))-\(Fmt.timeOfDay($0.end)) '\($0.intention)' \($0.genre ?? "")" } ?? "-")"
    }

    func shutdown() {
        if ledger.isRecording { ledger.endPlay() }
        ledger.endGap()
        engine.stop()
        hotKey.unregister()
        outputs.stop()
        otherSound.stop()
    }
}

// MARK: - Engine delegate

extension FocusController: @preconcurrency FocusAudioEngineDelegate {
    func audioEngineNextTrack(_ engine: FocusAudioEngine, after current: EngineTrack) -> EngineTrack? {
        // "This song only": the same song again after its 30 minutes.
        if settings.repeatOne, let same = library.track(current.id), same.status != .removed {
            return engineTrack(same)
        }
        guard let next = upNext(after: current.id) else {
            return library.track(current.id).map(engineTrack)
        }
        return engineTrack(next)
    }

    func audioEngine(_ engine: FocusAudioEngine, didBecomeCurrent track: EngineTrack) {
        guard let fresh = library.track(track.id) else { return }
        let genreChanged = currentTrack?.genre != fresh.genre
        currentTrack = fresh
        noteStarted(fresh)
        if genreChanged && ledger.isRecording { ledger.split(intention: intention, genre: fresh.genre.rawValue) }
        if ledger.isRecording { ledger.noteTrack(fresh.id) }
        updateMedia()
    }

    func audioEngine(_ engine: FocusAudioEngine, didFinish track: EngineTrack, listenedSeconds: Double, skipped: Bool) {
        if choseOver.remove(track.id) != nil && skipped { return }
        guard settings.learnFromSkips, let item = library.track(track.id) else { return }
        let early = skipped && listenedSeconds < 60
        // Heard to the end: 80% of the whole play (about 24 of its 30 minutes), not of the shorter file.
        let completed = !skipped || listenedSeconds >= max(60, item.playLength * 0.8)
        if early || completed {
            library.recordListen(track.id, listened: listenedSeconds, skipped: early, completed: completed && !early)
        }
    }

    func audioEngine(_ engine: FocusAudioEngine, didPauseForLostOutput uid: String) {
        // The engine has already stopped the sound; mirror it so the panel says why.
        guard run == .playing else { return }
        markPaused(.headphones)
    }

    func audioEngine(_ engine: FocusAudioEngine, didFail error: Error, track: EngineTrack?) {
        // The engine asks for a replacement by itself (audioEngineNextTrack), so nothing to do but log.
        NSLog("Focus Music: playback failed for \(track?.id ?? "-"): \(error)")
    }
}
