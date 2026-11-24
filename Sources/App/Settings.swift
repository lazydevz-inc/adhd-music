import AppKit
import Combine

/// User preferences, persisted in UserDefaults. Keys are prefixed with `v2.` so the old prototype's
/// preferences under the same bundle id never collide.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var language: AppLanguage { didSet { save(language.rawValue, "language") } }
    @Published var openAtLogin: Bool { didSet { save(openAtLogin, "openAtLogin") } }
    @Published var showInDock: Bool { didSet { save(showInDock, "showInDock") } }
    @Published var hotKeyCode: Int { didSet { save(hotKeyCode, "hotKeyCode") } }
    @Published var hotKeyModifiers: Int { didSet { save(hotKeyModifiers, "hotKeyModifiers") } }
    @Published var mediaKeys: MediaKeyMode { didSet { save(mediaKeys.rawValue, "mediaKeys") } }

    @Published var pauseWhenAway: Bool { didSet { save(pauseWhenAway, "pauseWhenAway") } }
    @Published var pauseDuringCalls: Bool { didSet { save(pauseDuringCalls, "pauseDuringCalls") } }
    @Published var learnFromSkips: Bool { didSet { save(learnFromSkips, "learnFromSkips") } }
    @Published var pauseWhenHeadphonesOff: Bool { didSet { save(pauseWhenHeadphonesOff, "pauseWhenHeadphonesOff") } }
    @Published var pauseForOtherSound: Bool { didSet { save(pauseForOtherSound, "pauseForOtherSound") } }

    @Published var menuBarStyle: MenuBarStyle { didSet { save(menuBarStyle.rawValue, "menuBarStyle") } }
    @Published var defaultMusic: MusicChoice { didSet { save(defaultMusic.rawValue, "defaultMusic") } }
    @Published var defaultEffect: EffectChoice { didSet { save(defaultEffect.rawValue, "defaultEffect") } }
    @Published var fadeInOut: Bool { didSet { save(fadeInOut, "fadeInOut") } }
    @Published var dayStartHour: Int { didSet { save(dayStartHour, "dayStartHour") } }
    @Published var weekStart: WeekStart { didSet { save(weekStart.rawValue, "weekStart") } }

    // Session preferences (remembered between launches)
    @Published var volume: Double { didSet { save(volume, "volume") } }
    @Published var playMode: PlayMode { didSet { save(playMode.rawValue, "playMode") } }
    @Published var timerChoice: TimerChoice { didSet { save(timerChoice.rawValue, "timerChoice") } }
    @Published var customTimerMinutes: Int { didSet { save(customTimerMinutes, "customTimerMinutes") } }
    @Published var timerEndAction: TimerEndAction { didSet { save(timerEndAction.rawValue, "timerEndAction") } }
    @Published var pomodoroPreset: PomodoroPreset { didSet { save(pomodoroPreset.rawValue, "pomodoroPreset") } }
    @Published var customFocusMinutes: Int { didSet { save(customFocusMinutes, "customFocusMinutes") } }
    @Published var customBreakMinutes: Int { didSet { save(customBreakMinutes, "customBreakMinutes") } }
    @Published var longBreakEvery4: Bool { didSet { save(longBreakEvery4, "longBreakEvery4") } }
    @Published var breakMusic: BreakMusic { didSet { save(breakMusic.rawValue, "breakMusic") } }
    /// The playlist: its order, and how the next song is chosen.
    @Published var playlistSort: PlaylistSort { didSet { save(playlistSort.rawValue, "playlistSort") } }
    /// On: a weighted pick (♥ more often, early skips less). Off: the playlist's order.
    @Published var shuffle: Bool { didSet { save(shuffle, "shuffle") } }
    /// "This song only": the song starts over instead of moving on after its 30 minutes.
    @Published var repeatOne: Bool { didSet { save(repeatOne, "repeatOne") } }
    @Published var noise: NoiseChoice {
        didSet {
            save(noise.rawValue, "noise")
            if noise != .off && noisePick != noise { noisePick = noise }
        }
    }
    /// The last sound chosen, so the Noise switch turns that one back on.
    @Published var noisePick: NoiseChoice { didSet { save(noisePick.rawValue, "noisePick") } }
    @Published var noiseLevel: Double { didSet { save(noiseLevel, "noiseLevel") } }

    init(defaults: UserDefaults = .standard, languageOverride: String? = nil) {
        self.defaults = defaults
        func s(_ key: String) -> String? { defaults.string(forKey: "v2." + key) }
        func b(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: "v2." + key) == nil ? fallback : defaults.bool(forKey: "v2." + key) }
        func i(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: "v2." + key) == nil ? fallback : defaults.integer(forKey: "v2." + key) }
        func d(_ key: String, _ fallback: Double) -> Double { defaults.object(forKey: "v2." + key) == nil ? fallback : defaults.double(forKey: "v2." + key) }

        language = AppLanguage(rawValue: languageOverride ?? s("language") ?? "en") ?? .en
        // The Mac App Store build starts with it off; the person turns it on in Settings (App Review 2.4.5(iii)).
        #if MAS_BUILD
        openAtLogin = b("openAtLogin", false)
        #else
        openAtLogin = b("openAtLogin", true)
        #endif
        showInDock = b("showInDock", false)
        hotKeyCode = i("hotKeyCode", 3)              // kVK_ANSI_F
        hotKeyModifiers = i("hotKeyModifiers", 2304) // cmdKey | optionKey (Carbon)
        mediaKeys = MediaKeyMode(rawValue: s("mediaKeys") ?? "") ?? .whilePlaying

        pauseWhenAway = b("pauseWhenAway", true)
        pauseDuringCalls = b("pauseDuringCalls", true)
        learnFromSkips = b("learnFromSkips", true)
        pauseWhenHeadphonesOff = b("pauseWhenHeadphonesOff", true)
        pauseForOtherSound = b("pauseForOtherSound", true)

        menuBarStyle = MenuBarStyle(rawValue: s("menuBarStyle") ?? "") ?? .todayTotal
        defaultMusic = MusicChoice(rawValue: s("defaultMusic") ?? "") ?? .mix
        defaultEffect = EffectChoice(rawValue: i("defaultEffect", EffectChoice.high.rawValue)) ?? .high
        fadeInOut = b("fadeInOut", true)
        dayStartHour = i("dayStartHour", 6)
        weekStart = WeekStart(rawValue: s("weekStart") ?? "") ?? .monday

        volume = d("volume", 1.0)
        if !defaults.bool(forKey: "v2.migration.volume100") {
            // 2026-11-22: default volume is 100%. Apply it once to the installed copy too.
            defaults.set(true, forKey: "v2.migration.volume100")
            defaults.set(1.0, forKey: "v2.volume")
            volume = 1.0
        }
        playMode = PlayMode(rawValue: s("playMode") ?? "") ?? .noLimit
        timerChoice = TimerChoice(rawValue: s("timerChoice") ?? "") ?? .m45
        customTimerMinutes = i("customTimerMinutes", 50)
        timerEndAction = TimerEndAction(rawValue: s("timerEndAction") ?? "") ?? .stop
        pomodoroPreset = PomodoroPreset(rawValue: s("pomodoroPreset") ?? "") ?? .p25_5
        customFocusMinutes = i("customFocusMinutes", 40)
        customBreakMinutes = i("customBreakMinutes", 8)
        longBreakEvery4 = b("longBreakEvery4", true)
        breakMusic = BreakMusic(rawValue: s("breakMusic") ?? "") ?? .pause
        playlistSort = PlaylistSort(rawValue: s("playlistSort") ?? "") ?? .standard
        shuffle = b("shuffle", true)
        repeatOne = b("repeatOne", false)
        let savedNoise = NoiseChoice(rawValue: s("noise") ?? "") ?? .off
        let savedPick = NoiseChoice(rawValue: s("noisePick") ?? "") ?? .off
        noise = savedNoise
        noisePick = savedPick != .off ? savedPick : (savedNoise != .off ? savedNoise : .rain)
        noiseLevel = d("noiseLevel", 0.6)
    }

    var ko: Bool { language == .ko }
    var strings: Strings { Strings(ko: ko) }

    var pomodoroMinutes: (focus: Int, rest: Int) {
        switch pomodoroPreset {
        case .p25_5: return (25, 5)
        case .p50_10: return (50, 10)
        case .custom: return (max(5, customFocusMinutes), max(1, customBreakMinutes))
        }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: "v2." + key)
    }
}
