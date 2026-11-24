import AppKit
import SwiftUI

// MARK: - Launch options & paths

struct LaunchOptions {
    var dataDir: URL?
    var preview: String?
    var language: String?
    var muted = false
    /// Development: play at this volume (0…1) instead of the saved one, e.g. 0.03 for a quiet test.
    var volume: Double?
    var seedDemo = false
    var autoplay = false
    var openPanel = false
    var dark = false
    var scenario = false
    var pageTour = false
    var soundLog = false
    /// Website build: look for an update right after launch and install it after 20 quiet seconds (update test).
    var updateSoon = false

    static let current: LaunchOptions = {
        #if MAS_BUILD && !MAS_TEST
        // The Mac App Store build takes no developer options: nothing hidden a reviewer can't reach.
        return LaunchOptions()
        #else
        var options = LaunchOptions()
        let args = CommandLine.arguments
        var index = 1
        while index < args.count {
            let arg = args[index]
            func next() -> String? {
                guard index + 1 < args.count else { return nil }
                index += 1
                return args[index]
            }
            switch arg {
            case "--data-dir": if let v = next() { options.dataDir = URL(fileURLWithPath: (v as NSString).expandingTildeInPath) }
            case "--preview": options.preview = next()
            case "--lang": options.language = next()
            case "--mute": options.muted = true
            case "--volume": if let v = next(), let level = Double(v) { options.volume = min(1, max(0, level)) }
            case "--seed-demo": options.seedDemo = true
            case "--autoplay": options.autoplay = true
            case "--open-panel": options.openPanel = true
            case "--dark": options.dark = true
            case "--scenario": options.scenario = true
            case "--page-tour": options.pageTour = true
            case "--sound-log": options.soundLog = true
            case "--update-soon": options.updateSoon = true
            default: break
            }
            index += 1
        }
        if options.dataDir == nil, let env = ProcessInfo.processInfo.environment["FOCUS_DATA_DIR"], !env.isEmpty {
            options.dataDir = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return options
        #endif
    }()
}

struct AppPaths {
    let dataDir: URL
    /// The songs: the data folder's Library, or the one inside the app (the shared build) when the data folder has none.
    let libraryDir: URL
    var catalogURL: URL { libraryDir.appendingPathComponent("library.json") }
    var libraryStateURL: URL { dataDir.appendingPathComponent("library-state.json") }
    var recordsURL: URL { dataDir.appendingPathComponent("records.json") }

    init(dataDir: URL, libraryDir: URL? = nil) {
        self.dataDir = dataDir
        self.libraryDir = libraryDir ?? dataDir.appendingPathComponent("Library", isDirectory: true)
    }

    static func resolve(_ options: LaunchOptions = .current) -> AppPaths {
        let dir = options.dataDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.dataFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let own = dir.appendingPathComponent("Library", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: own.appendingPathComponent("library.json").path),
           let bundled = AppIdentity.bundledLibrary,
           fm.fileExists(atPath: bundled.appendingPathComponent("library.json").path) {
            return AppPaths(dataDir: dir, libraryDir: bundled)
        }
        return AppPaths(dataDir: dir)
    }
}

/// What differs between the personal build and the shared one, read from the app's Info.plist
/// (Scripts/build-app.sh writes it), so the code stays the same for both.
enum AppIdentity {
    /// The name people see: menu bar tooltip, Quit, Now Playing.
    static let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Focus Music"
    /// The folder under Application Support that holds records, likes and learning.
    static let dataFolder = (Bundle.main.object(forInfoDictionaryKey: "FocusDataFolder") as? String) ?? "Focus Music"
    /// The songs that ship inside the shared build.
    static var bundledLibrary: URL? { Bundle.main.resourceURL?.appendingPathComponent("Library", isDirectory: true) }
}

// MARK: - Enums shared by settings, controller and views

enum AppLanguage: String, CaseIterable, Codable { case en, ko }
/// The playlist's order: by genre (catalog order inside), newest first, liked first or by name.
enum PlaylistSort: String, CaseIterable, Codable { case standard, recent, liked, name }
enum MediaKeyMode: String, CaseIterable, Codable { case whilePlaying, always, off }
enum MenuBarStyle: String, CaseIterable, Codable { case todayTotal, iconOnly }
enum WeekStart: String, CaseIterable, Codable { case monday, sunday }
enum PlayMode: String, CaseIterable, Codable { case noLimit, timer, pomodoro }
enum TimerEndAction: String, CaseIterable, Codable { case stop, keepPlaying }
enum BreakMusic: String, CaseIterable, Codable { case pause, quieter }
enum NoiseChoice: String, CaseIterable, Codable {
    case off, rain, ocean, stream, brown, pink, white

    /// The pictures on the Timer & Sound page: recordings first, then noise colours. Off is the switch.
    static let pictured: [NoiseChoice] = [.rain, .ocean, .stream, .brown, .pink, .white]

    /// A looped nature recording rather than generated noise.
    var isRecording: Bool { self == .rain || self == .ocean || self == .stream }
}

enum Genre: String, CaseIterable, Codable {
    case lofi, grooves, electronic
    var display: String {
        switch self {
        case .lofi: return "Lo-fi"
        case .grooves: return "Grooves"
        case .electronic: return "Electronic"
        }
    }
}

enum MusicChoice: String, CaseIterable, Codable {
    case mix, lofi, grooves, electronic
    var display: String {
        switch self {
        case .mix: return "Mix"
        case .lofi: return "Lo-fi"
        case .grooves: return "Grooves"
        case .electronic: return "Electronic"
        }
    }
    var genre: Genre? {
        switch self {
        case .mix: return nil
        case .lofi: return .lofi
        case .grooves: return .grooves
        case .electronic: return .electronic
        }
    }
}

/// Timer presets. `custom` uses `AppSettings.customTimerMinutes`.
enum TimerChoice: String, CaseIterable, Codable {
    case m25, m45, m60, m90, custom
    var presetMinutes: Int? {
        switch self {
        case .m25: return 25
        case .m45: return 45
        case .m60: return 60
        case .m90: return 90
        case .custom: return nil
        }
    }
}

enum PomodoroPreset: String, CaseIterable, Codable {
    case p25_5, p50_10, custom
}

enum EffectChoice: Int, CaseIterable, Codable {
    case off = 0, low, medium, high
}

// MARK: - Colors (the app's palette is in DesignSystem.swift)

extension Color {
    init(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        var number: UInt64 = 0
        Scanner(string: value).scanHexInt64(&number)
        let r = Double((number >> 16) & 0xFF) / 255
        let g = Double((number >> 8) & 0xFF) / 255
        let b = Double(number & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Formatting

enum Fmt {
    static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    /// h:mm:ss when an hour or more, otherwise m:ss.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? "\(h):\(pad(m)):\(pad(s))" : "\(m):\(pad(s))"
    }

    /// Duration in words: 2h 56m / 2시간 56분.
    static func duration(_ seconds: TimeInterval, ko: Bool) -> String {
        let minutes = max(0, Int((seconds / 60).rounded(.down)))
        let h = minutes / 60, m = minutes % 60
        if ko {
            if h == 0 { return "\(m)분" }
            return m == 0 ? "\(h)시간" : "\(h)시간 \(m)분"
        }
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    static func hm(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded(.down)))
        return "\(minutes / 60):\(pad(minutes % 60))"
    }

    static func timeOfDay(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return "\(pad(c.hour ?? 0)):\(pad(c.minute ?? 0))"
    }

    static func clockTime(_ date: Date, ko: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: ko ? "ko_KR" : "en_US")
        f.dateFormat = ko ? "a h:mm" : "h:mm a"
        return f.string(from: date)
    }

    static func dayShort(_ date: Date, ko: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: ko ? "ko_KR" : "en_US")
        f.dateFormat = ko ? "M월 d일" : "MMM d"
        return f.string(from: date)
    }

    static func dayLong(_ date: Date, ko: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: ko ? "ko_KR" : "en_US")
        f.dateFormat = ko ? "M월 d일 EEEE" : "EEEE, MMMM d"
        return f.string(from: date)
    }

    static func dayWithWeekday(_ date: Date, ko: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: ko ? "ko_KR" : "en_US")
        f.dateFormat = ko ? "M월 d일 (E)" : "EEE, MMM d"
        return f.string(from: date)
    }

    static func month(_ date: Date, ko: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: ko ? "ko_KR" : "en_US")
        f.dateFormat = ko ? "yyyy년 M월" : "MMMM yyyy"
        return f.string(from: date)
    }

    /// Month name alone: November / 11월.
    static func monthOnly(_ date: Date, ko: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: ko ? "ko_KR" : "en_US")
        f.dateFormat = ko ? "M월" : "MMMM"
        return f.string(from: date)
    }

    static func trackLength(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return "\(total / 60):\(pad(total % 60))"
    }
}

// MARK: - JSON helpers

enum JSONStore {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try encoder().encode(value)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Focus Music: failed to write \(url.lastPathComponent): \(error)")
        }
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder().decode(type, from: data)
        } catch {
            NSLog("Focus Music: failed to read \(url.lastPathComponent): \(error)")
            return nil
        }
    }
}
