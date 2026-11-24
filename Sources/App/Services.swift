import AppKit
import Carbon.HIToolbox
import CoreAudio
import CoreMediaIO
import MediaPlayer
import ServiceManagement

// MARK: - Screen lock / sleep

/// Reports when the person steps away (screen locked, display or system asleep) and comes back.
@MainActor
final class AwayMonitor {
    var onChange: ((Bool) -> Void)?
    private(set) var isAway = false
    private var locked = false, systemAsleep = false, screensAsleep = false
    private var tokens: [NSObjectProtocol] = []

    init() {
        let dnc = DistributedNotificationCenter.default()
        tokens.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.locked = true; self?.evaluate() }
        })
        tokens.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.locked = false; self?.evaluate() }
        })
        let wnc = NSWorkspace.shared.notificationCenter
        tokens.append(wnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemAsleep = true; self?.evaluate() }
        })
        tokens.append(wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemAsleep = false; self?.evaluate() }
        })
        tokens.append(wnc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensAsleep = true; self?.evaluate() }
        })
        tokens.append(wnc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensAsleep = false; self?.evaluate() }
        })
    }

    private func evaluate() {
        let away = locked || systemAsleep || screensAsleep
        guard away != isAway else { return }
        isAway = away
        onChange?(away)
    }
}

// MARK: - Calls (microphone or camera in use by another app)

final class CallMonitor {
    var onChange: ((Bool) -> Void)?
    private(set) var inCall = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "focus.callmonitor")
    private let ownPID = getpid()

    /// Apple background services that keep the microphone open without a call.
    private let ignoredBundlePrefixes = ["com.apple.corespeech", "com.apple.siri", "com.apple.assistant", "com.apple.SpeechRecognitionCore",
                                         "com.apple.voicetrigger", "com.apple.accessibility", "com.apple.dictation", "com.apple.audio.AudioComponentRegistrar"]

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 2.0)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if inCall {
            inCall = false
            DispatchQueue.main.async { self.onChange?(false) }
        }
    }

    private func poll() {
        let active = microphoneInUseByOthers() || cameraInUse()
        guard active != inCall else { return }
        inCall = active
        DispatchQueue.main.async { self.onChange?(active) }
    }

    func microphoneInUseByOthers() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return false }
        for object in objects {
            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(object, &runningAddress, 0, nil, &runningSize, &running) == noErr, running != 0 else { continue }
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid == ownPID { continue }
            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleID = ""
            if AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr, let value = bundle?.takeRetainedValue() {
                bundleID = value as String
            }
            if ignoredBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) { continue }
            return true
        }
        return false
    }

    func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &used, &devices) == noErr else { return false }
        for device in devices {
            var runningAddress = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                           mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                                           mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var running: UInt32 = 0
            var runningUsed: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &runningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &runningUsed, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }
}

// MARK: - Other apps playing sound (YouTube, videos, meetings)

/// Reports when another Mac app has been playing sound for about 2 s (YouTube in a browser, a
/// video, a meeting) and when it is quiet again: 3 s after its sound output closes, or after 6 s of
/// silence while the output stays open (a quiet moment in a video). Only apps people open count:
/// system sounds, background helpers without an app, and Simulator processes are ignored.
///
/// "Sound" means sound you can hear: browsers keep silent output open (YouTube's home page does with
/// no video playing), so each app's output is measured through a tap. Without the permission to hear
/// other apps, any running output counts, as before.
///
/// Where the permission can't be read (the Mac App Store build has no TCC), the taps themselves show
/// it: see `OtherSoundProbe.TapTrust`. A refusal is handled quietly, never with a warning.
@MainActor
final class OtherSoundMonitor {
    /// The app's name while it plays, nil once it is quiet.
    var onChange: ((String?) -> Void)?
    private(set) var source: String?
    /// Listening only happens while it matters: the music plays, or waits for another app to go quiet.
    var isNeeded = false {
        didSet {
            guard isNeeded != oldValue else { return }
            if isNeeded { refreshPermission(ask: false) } else { reset() }
            syncProbe()
        }
    }
    /// Development: one line per check (`--sound-log`), ending with `logState()`.
    var logURL: URL?
    var logState: (() -> String)?
    private(set) var permission: OtherAppAudioPermission.Status = .notDetermined
    /// Whether the taps are known to hear other apps (only checked where `permission` is `.unavailable`).
    private(set) var tapTrust: OtherSoundProbe.TapTrust = .unknown
    /// This app's music is playing and can be heard (not muted, volume above 0). Only then can a tap on
    /// it show whether taps hear anything at all.
    var ownSoundAudible = false {
        didSet {
            guard ownSoundAudible != oldValue else { return }
            let probe = self.probe, audible = ownSoundAudible
            queue.async { probe.ownSoundAudible = audible }
        }
    }
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "focus.othersound")
    private lazy var probe = OtherSoundProbe(queue: queue)
    private let ownPID = getpid()
    private var heard = 0
    private var quiet = 0
    private var asked = false

    func start() {
        guard timer == nil else { return }
        refreshPermission(ask: true)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        let own = ownPID
        let probe = self.probe
        t.setEventHandler { [weak self] in
            guard let readings = probe.poll(excluding: own) else { return }
            let trust = probe.trust
            Task { @MainActor in self?.update(readings, trust: trust) }
        }
        t.resume()
        timer = t
        syncProbe()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        let probe = self.probe
        queue.async { probe.configure(listening: false, measuring: false, verify: false) }
        heard = 0
        quiet = 0
        if source != nil {
            source = nil
            onChange?(nil)
        }
    }

    /// Asks macOS once (at start) for the permission to hear other apps, then measures if granted.
    private func refreshPermission(ask: Bool) {
        guard timer != nil || ask else { return }
        permission = OtherAppAudioPermission.status
        log("permission \(permission.rawValue)")
        guard permission == .notDetermined, ask, !asked else { return }
        asked = true
        OtherAppAudioPermission.request { [weak self] granted in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.permission = granted ? .granted : .denied
                self.log("permission asked → \(self.permission.rawValue)")
                self.syncProbe()
            }
        }
    }

    private func syncProbe() {
        let listening = timer != nil && isNeeded
        // Unavailable: TCC can't be asked; the tap itself then brings up the system's question, and the
        // taps show whether it was allowed.
        let measuring = permission == .granted || permission == .unavailable
        let verify = permission == .unavailable
        let probe = self.probe
        queue.async { probe.configure(listening: listening, measuring: measuring, verify: verify) }
    }

    private func reset() {
        heard = 0
        quiet = 0
        source = nil
    }

    private func update(_ readings: [OtherSoundProbe.Reading], trust: OtherSoundProbe.TapTrust) {
        if trust != tapTrust {
            tapTrust = trust
            log(trust == .refused ? "taps hear only silence, even this app's music → running output counts as sound"
                                  : "taps hear sound → measuring how loud other apps are")
        }
        guard timer != nil, isNeeded else { return }
        if let app = readings.first(where: { $0.sounding })?.app {
            quiet = 0
            heard += 1
            if source == nil && heard >= 2 || source != nil && source != app {
                source = app
                log("→ paused for \(app)")
                onChange?(app)
            }
        } else {
            heard = 0
            quiet += 1
            let stillOpen = readings.contains { $0.app == source }
            if source != nil && quiet >= (stillOpen ? 6 : 3) {
                log("→ quiet again")
                source = nil
                onChange?(nil)
            }
        }
        if !readings.isEmpty {
            log(readings.map(\.description).joined(separator: ", ") + " heard=\(heard) quiet=\(quiet) source=\(source ?? "-")")
        }
    }

    private func log(_ line: String) {
        guard let logURL else { return }
        let stamp = Self.logTime.string(from: Date())
        let data = Data("\(stamp) \(line) | \(logState?() ?? "")\n".utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    private static let logTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.S"
        return formatter
    }()

    /// Process objects (not this one) whose sound output is running right now, with their bundle IDs.
    nonisolated static func processesPlayingSound(excluding ownPID: pid_t) -> [(object: AudioObjectID, bundleID: String)] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        var playing: [(object: AudioObjectID, bundleID: String)] = []
        for object in objects {
            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(object, &runningAddress, 0, nil, &runningSize, &running) == noErr, running != 0 else { continue }
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid == ownPID { continue }
            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr, let value = bundle?.takeRetainedValue() {
                playing.append((object, value as String))
            }
        }
        return playing
    }

    /// The name of the open Mac app behind a sound-playing process, or nil when it isn't one
    /// (system sounds, Simulator apps, this app in any of its builds). Helpers map to their app:
    /// com.google.Chrome.helper → Google Chrome; Safari's media process → Safari.
    /// The ids of this app's other builds (local, dev and the shared one from Scripts/share/share.env),
    /// written into Info.plist by Scripts/build-app.sh, so a fork with its own app id is still itself.
    nonisolated private static let siblingIDs: Set<String> =
        Set((Bundle.main.object(forInfoDictionaryKey: "FocusSiblingIDs") as? [String]) ?? [])

    nonisolated static func appName(for bundleID: String) -> String? {
        if bundleID.hasPrefix("app.adhdmusic") || siblingIDs.contains(bundleID) { return nil }
        if bundleID.hasPrefix("com.apple.WebKit") {
            return NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first?.localizedName
        }
        var parts = bundleID.split(separator: ".").map(String.init)
        while parts.count >= 2 {
            let candidate = parts.joined(separator: ".")
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: candidate).first(where: { $0.activationPolicy == .regular }) {
                return app.localizedName ?? candidate
            }
            parts.removeLast()
        }
        return nil
    }
}

/// Works on the monitor's queue: finds the open apps whose sound output runs and, with permission,
/// measures each one through its own tap (kept while that output runs).
final class OtherSoundProbe: @unchecked Sendable {
    struct Reading: CustomStringConvertible {
        let app: String
        let sounding: Bool
        /// What the tap heard in the last second; nil when it isn't measured.
        let heard: ProcessSoundMeter.Heard?

        var description: String {
            guard let heard else { return "\(app): running\(sounding ? " → sound" : "")" }
            return String(format: "%@: %.2fs heard %.2fs audible%@", app, heard.seconds, heard.audible, sounding ? " → sound" : "")
        }
    }

    /// At least this much audible sound in a one-second check counts as sound.
    static let soundingSeconds = 0.3

    /// Whether taps hear other apps, where the permission can't be read (`verify`). Any sample other
    /// than zero proves the permission. Measured on macOS 26.2 (11/24): a refused or unanswered tap
    /// delivers nothing at all, which the two-check rule in `poll` already turns into "running output
    /// counts". Others report refused taps that deliver exact zeros instead, which look like an app
    /// keeping a silent output open; then a short tap on this app's own music (playing and audible)
    /// settles it: zeros there too mean refused, and running output counts as sound.
    enum TapTrust: String { case unknown, proven, refused }

    private struct Entry {
        var meter: ProcessSoundMeter?
        /// The tap is still being made. Making the first one waits while macOS asks for the permission
        /// (about 90 s when nobody answers, measured 11/24), so it happens on `startQueue` and the
        /// checks go on meanwhile.
        var starting = true
        var checks = 0
    }

    /// The monitor's queue, where `configure` and `poll` run.
    private let queue: DispatchQueue
    private let startQueue = DispatchQueue(label: "focus.othersound.start", qos: .utility)

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    private var listening = false
    private var measuring = false
    private var verify = false
    private var meters: [AudioObjectID: Entry] = [:]
    private let levelQueue = DispatchQueue(label: "focus.othersound.level", qos: .utility)
    private(set) var trust: TapTrust = .unknown
    var ownSoundAudible = false
    private var ownCheck: (meter: ProcessSoundMeter, checks: Int)?
    private var lastOwnCheck: Date?

    func configure(listening: Bool, measuring: Bool, verify: Bool) {
        self.listening = listening
        self.measuring = measuring
        self.verify = verify
        if !(listening && measuring) { closeMeters() }
    }

    /// Nil while nothing needs to listen.
    func poll(excluding ownPID: pid_t) -> [Reading]? {
        guard listening else { return nil }
        var readings: [Reading] = []
        var open = Set<AudioObjectID>()
        var onlyZeros = false
        for process in OtherSoundMonitor.processesPlayingSound(excluding: ownPID) {
            guard let app = OtherSoundMonitor.appName(for: process.bundleID) else { continue }
            guard measuring else {
                readings.append(Reading(app: app, sounding: true, heard: nil))
                continue
            }
            open.insert(process.object)
            var entry = meters[process.object] ?? startMeter(for: process.object, app: app)
            entry.checks += 1
            meters[process.object] = entry
            guard let meter = entry.meter else {
                // Still starting (macOS may be asking for the permission) or refused by Core Audio:
                // after the two checks any new tap gets, the running output counts.
                readings.append(Reading(app: app, sounding: !entry.starting || entry.checks > 2, heard: nil))
                continue
            }
            let heard = meter.take()
            if heard.signal > 0 { trust = .proven }
            if verify && trust != .proven && heard.seconds > 0 { onlyZeros = true }
            // The first check starts the tap. After that, a tap that hears nothing at all is not
            // working (no permission yet, or a refused device); then the running output counts.
            let working = heard.seconds > 0 || entry.checks <= 2
            let hears = working && !(verify && trust == .refused)
            readings.append(Reading(app: app, sounding: hears ? heard.audible >= Self.soundingSeconds : true, heard: heard))
        }
        for (object, entry) in meters where !open.contains(object) {
            entry.meter?.invalidate()
            meters[object] = nil
        }
        checkOwnSound(needed: onlyZeros, ownPID: ownPID)
        return readings
    }

    private func startMeter(for object: AudioObjectID, app: String) -> Entry {
        let levelQueue = self.levelQueue, queue = self.queue
        startQueue.async { [weak self] in
            let meter = ProcessSoundMeter(process: object, queue: levelQueue)
            queue.async { self?.started(object, meter: meter, app: app) }
        }
        return Entry()
    }

    private func started(_ object: AudioObjectID, meter: ProcessSoundMeter?, app: String) {
        guard var entry = meters[object], entry.starting else {
            meter?.invalidate() // its app went quiet, or listening stopped, while it started
            return
        }
        if meter == nil { NSLog("Focus Music: could not listen to \(app)'s sound; counting its output as sound") }
        entry.meter = meter
        entry.starting = false
        entry.checks = 0
        meters[object] = entry
    }

    /// Taps this app's own music for a few seconds while another app's tap gives only zeros.
    private func checkOwnSound(needed: Bool, ownPID: pid_t) {
        guard needed, ownSoundAudible else { return endOwnCheck() }
        guard var check = ownCheck else {
            // A refusal is checked again at most once a minute, in case it was allowed in System Settings.
            if trust == .refused, let last = lastOwnCheck, Date().timeIntervalSince(last) < 60 { return }
            lastOwnCheck = Date()
            if let own = Self.processObject(pid: ownPID), let meter = ProcessSoundMeter(process: own, queue: levelQueue) {
                ownCheck = (meter, 0)
            }
            return
        }
        check.checks += 1
        let heard = check.meter.take()
        ownCheck = check
        if heard.signal > 0 {
            trust = .proven
            endOwnCheck()
        } else if heard.seconds > 0.5 && check.checks >= 2 {
            trust = .refused
            endOwnCheck()
        } else if check.checks >= 5 {
            endOwnCheck() // no frames: can't tell this time
        }
    }

    private func endOwnCheck() {
        ownCheck?.meter.invalidate()
        ownCheck = nil
    }

    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &qualifier,
                                         &size, &object) == noErr, object != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return object
    }

    private func closeMeters() {
        for entry in meters.values { entry.meter?.invalidate() }
        meters.removeAll()
        endOwnCheck()
    }
}

// MARK: - Global shortcut (Carbon hot key, no accessibility permission needed)

final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var action: (() -> Void)?

    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        unregister()
        HotKey.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &eventType, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x464F4355), id: 1) // 'FOCU'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
    }

    static func display(keyCode: Int, modifiers: Int) -> String {
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        return text + keyName(keyCode)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var value = 0
        if flags.contains(.command) { value |= cmdKey }
        if flags.contains(.option) { value |= optionKey }
        if flags.contains(.control) { value |= controlKey }
        if flags.contains(.shift) { value |= shiftKey }
        return value
    }

    private static func keyName(_ code: Int) -> String {
        let names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "↩", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10"
        ]
        return names[code] ?? "#\(code)"
    }
}

// MARK: - Media keys and Now Playing

@MainActor
final class MediaKeys {
    var onToggle: (() -> Void)?
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    /// Control Center's progress bar was dragged to this many seconds into the song.
    var onSeek: ((Double) -> Void)?
    private var installed = false

    private func install() {
        guard !installed else { return }
        installed = true
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.onToggle?(); return .success }
        center.playCommand.addTarget { [weak self] _ in self?.onPlay?(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.onPause?(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.onNext?(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.onPrevious?(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.onSeek?(event.positionTime)
            return .success
        }
    }

    func update(mode: MediaKeyMode, playing: Bool, title: String?, elapsed: Double, duration: Double) {
        let center = MPRemoteCommandCenter.shared()
        let info = MPNowPlayingInfoCenter.default()
        let active = mode == .always || (mode == .whilePlaying && playing)
        if active { install() }
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand, center.nextTrackCommand,
                        center.previousTrackCommand, center.changePlaybackPositionCommand] {
            command.isEnabled = active
        }
        guard active else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: title ?? AppIdentity.name,
            MPMediaItemPropertyArtist: AppIdentity.name,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
        info.playbackState = playing ? .playing : .paused
    }
}

// MARK: - Login item & Dock

enum SystemIntegration {
    @discardableResult
    static func setOpenAtLogin(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled {
                try service.unregister()
            }
            return true
        } catch {
            NSLog("Focus Music: login item change failed: \(error)")
            return false
        }
    }

    static var openAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func applyDock(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }
}
