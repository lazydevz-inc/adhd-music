import AVFoundation
import Foundation

/// Continuous local-music player with beat-synced amplitude modulation, built on AVAudioEngine.
///
/// Threads: the public API is used from the main thread. A render worker thread decodes,
/// applies gain, the effect, crossfades, fades, volume and duck (`FocusRenderCore`), and fills
/// a lock-free ring of about 0.26 s; the AVAudioSourceNode render block only copies from it.
/// Commands therefore take effect after that buffer (about a quarter second), and positions
/// and delegate events follow what has actually been played.
public final class FocusAudioEngine {
    public weak var delegate: FocusAudioEngineDelegate?

    /// Automatic crossfade length between consecutive tracks (equal power), in seconds.
    public var crossfadeSeconds: Double = 8 {
        didSet {
            if !crossfadeSeconds.isFinite || crossfadeSeconds < 0 { crossfadeSeconds = oldValue }
            session?.worker.post(.crossfade(crossfadeSeconds))
        }
    }

    /// A track with loop points repeats its loop region (equal-power seams) until it has played
    /// at least this long, then plays out to its natural end; the delegate still sees one track.
    /// 0 = every track plays once. Changing it re-plans the playing track from its next seam.
    public var minimumTrackSeconds: Double = 1800 {
        didSet {
            if !minimumTrackSeconds.isFinite || minimumTrackSeconds < 0 { minimumTrackSeconds = oldValue }
            session?.worker.post(.minimumTrackSeconds(minimumTrackSeconds))
        }
    }

    public private(set) var isPlaying = false
    public private(set) var currentTrack: EngineTrack?

    /// When the output device in use disappears (headphones unplugged, AirPods put away or taken
    /// by a phone), pause instead of carrying on through whatever the Mac switched to.
    public var pausesWhenOutputLost = false
    /// Looped recordings for the recorded noise kinds (rain, ocean, stream), read by sessions
    /// started after it is set. A recorded kind without a file stays silent.
    public var noiseRecordings: [FocusNoiseKind: URL] = [:]
    /// UID of the device that disappeared while in use (only with `pausesWhenOutputLost`).
    /// Cleared by `resume`, `start` and `stop`.
    public private(set) var lostOutputUID: String?

    /// Audible position in the current play of `currentTrack`, in seconds, loop passes included
    /// (0 until it is heard).
    public var currentTime: TimeInterval {
        guard let session, let serial = currentSerial else { return 0 }
        return session.worker.audibleSeconds(serial: serial) ?? 0
    }

    /// Render callbacks that found the buffer short while audio was expected, since `init`.
    public var underrunCount: Int {
        underrunsFromEndedSessions + (session?.ring.underrunCount ?? 0)
    }

    static let ringCapacityFrames = 16_384      // 0.341 s at 48 kHz
    static let ringTargetFrames = 12_288        // 0.256 s kept buffered
    static let maximumConsecutiveFailures = 3

    /// Checks only: silences the AVAudioEngine mixer output (set before `start`).
    var outputMutedForTesting = false
    private(set) var configurationRestartCount = 0
    /// Core Audio questions asked at a device change; the checks replace it.
    var outputProbe = FocusOutputProbe.system

    private final class Session {
        let id: Int
        let ring: FocusAudioRing
        let worker: FocusRenderWorker
        var engine: AVAudioEngine?
        var node: AVAudioSourceNode?
        var outputRunning = false
        var observer: NSObjectProtocol?

        init(id: Int, ring: FocusAudioRing, worker: FocusRenderWorker) {
            self.id = id
            self.ring = ring
            self.worker = worker
        }
    }

    private var session: Session?
    private var sessionCounter = 0
    private var serialCounter = 0
    private var tracks: [Int: EngineTrack] = [:]
    private var announced: Set<Int> = []
    private var failedSerials: Set<Int> = []
    private var currentSerial: Int?
    private var consecutiveFailures = 0
    private var pauseToken = 0
    private var skipsPosted = 0
    private var pendingPauseCompletions: [() -> Void] = []
    private var underrunsFromEndedSessions = 0
    private var effectLevel: EffectLevel = .medium
    private var volume: Float = 1
    private var duckFactor: Float = 1
    private var noiseKind: FocusNoiseKind = .off
    private var noiseLevel: Float = 0.6
    /// The device the output was last started or moved on.
    private var outputDevice: FocusOutputDevice?
    /// Paused because the device vanished mid-play: the ring still holds audio meant for it.
    private var restartOnResume = false

    public init() {}

    deinit {
        teardownSession(callPauseCompletions: false)
    }

    // MARK: - Transport

    /// Hard start of `track` (replaces anything playing), fading in over `fadeIn` seconds.
    public func start(with track: EngineTrack, fadeIn: TimeInterval) {
        start(with: track, fadeIn: fadeIn, startTime: 0)
    }

    /// `startTime` > 0 starts inside the play, loop passes included (restarts, the Library
    /// preview's seek bar, checks); `currentTime` then counts on from it.
    public func start(with track: EngineTrack, fadeIn: TimeInterval, startTime: TimeInterval) {
        assert(Thread.isMainThread, "FocusAudioEngine is main-thread only")
        teardownSession(callPauseCompletions: true)
        tracks.removeAll()
        announced.removeAll()
        failedSerials.removeAll()
        restartOnResume = false
        lostOutputUID = nil
        let serial = makeSerial()
        tracks[serial] = track
        announced.insert(serial)
        currentSerial = serial
        currentTrack = track
        isPlaying = true
        consecutiveFailures = 0
        pauseToken += 1
        announceLater(track)

        sessionCounter += 1
        let id = sessionCounter
        let core = FocusRenderCore()
        core.setVolume(volume, rampSeconds: 0)
        core.setDuck(duckFactor, rampSeconds: 0)
        core.setEffectDepth(effectLevel.depth, rampSeconds: 0)
        core.setNoiseRecordings(noiseRecordings)
        core.setNoise(noiseKind, level: noiseLevel, rampSeconds: 0)
        core.setCrossfadeSeconds(crossfadeSeconds)
        core.setMinimumTrackSeconds(minimumTrackSeconds)
        let ring = FocusAudioRing(capacityFrames: Self.ringCapacityFrames)
        skipsPosted = 0
        let worker = FocusRenderWorker(core: core, ring: ring, targetFillFrames: Self.ringTargetFrames) { [weak self] event, skipsApplied in
            DispatchQueue.main.async { self?.handle(event, sessionID: id, skipsApplied: skipsApplied) }
        }
        let newSession = Session(id: id, ring: ring, worker: worker)
        session = newSession
        worker.post(.start(track, serial: serial, fadeIn: sanitized(fadeIn), startTime: sanitized(startTime)))
        worker.start()
        do {
            try startOutput(for: newSession)
        } catch {
            teardownSession(callPauseCompletions: true)
            isPlaying = false
            currentTrack = nil
            currentSerial = nil
            tracks.removeAll()
            announced.removeAll()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.audioEngine(self, didFail: error, track: track)
            }
        }
    }

    /// Fades out over `fade` seconds and holds the position. `completion` runs on the main
    /// thread once the fade has been heard; it is dropped if `resume` comes first, and called
    /// by `stop`/a new `start`.
    public func pause(fade: TimeInterval, completion: (() -> Void)?) {
        assert(Thread.isMainThread, "FocusAudioEngine is main-thread only")
        guard let session else {
            if let completion { DispatchQueue.main.async(execute: completion) }
            return
        }
        isPlaying = false
        pauseToken += 1
        if let completion { pendingPauseCompletions.append(completion) }
        session.worker.post(.pause(fade: sanitized(fade), token: pauseToken))
    }

    /// Continues from the paused position, fading in over `fade` seconds.
    public func resume(fade: TimeInterval) {
        assert(Thread.isMainThread, "FocusAudioEngine is main-thread only")
        guard let session, !isPlaying else { return }
        lostOutputUID = nil
        if restartOnResume, let track = currentTrack {
            // Held when the device vanished: the ring still holds audio rendered for it, so
            // start again from what was last heard.
            let position = currentTime
            start(with: track, fadeIn: fade, startTime: position)
            return
        }
        isPlaying = true
        pauseToken += 1
        pendingPauseCompletions.removeAll()
        if !session.outputRunning, let engine = session.engine {
            do {
                try engine.start()
                session.outputRunning = true
            } catch {
                reportOutputFailure(error)
                return
            }
        }
        session.worker.post(.resume(fade: sanitized(fade)))
    }

    /// Stops output immediately and forgets the queue. No `didFinish` is sent.
    public func stop() {
        assert(Thread.isMainThread, "FocusAudioEngine is main-thread only")
        teardownSession(callPauseCompletions: true)
        isPlaying = false
        currentTrack = nil
        currentSerial = nil
        tracks.removeAll()
        announced.removeAll()
        failedSerials.removeAll()
        restartOnResume = false
        lostOutputUID = nil
    }

    /// Equal-power crossfade into `track` over `crossfade` seconds (the skipped track reports
    /// `skipped: true`). While paused, `track` replaces the current one and waits for `resume`.
    public func skip(to track: EngineTrack, crossfade: TimeInterval) {
        assert(Thread.isMainThread, "FocusAudioEngine is main-thread only")
        guard let session else {
            start(with: track, fadeIn: crossfade)
            return
        }
        let serial = makeSerial()
        tracks[serial] = track
        announced.insert(serial)
        currentSerial = serial
        currentTrack = track
        consecutiveFailures = 0
        announceLater(track)
        skipsPosted += 1
        session.worker.post(.skip(track, serial: serial, crossfade: sanitized(crossfade)))
    }

    /// Ramps the effect depth over 0.5 s; the track position is unaffected.
    public func setEffectLevel(_ level: EffectLevel) {
        effectLevel = level
        session?.worker.post(.effectDepth(level.depth))
    }

    /// 0...1, ramped over 0.2 s.
    public func setVolume(_ volume: Float) {
        let value = volume.isFinite ? min(max(volume, 0), 1) : 0
        self.volume = value
        session?.worker.post(.volume(value))
    }

    /// Background noise under the music; `level` is the 0...1 slider value. Ramped.
    public func setNoise(_ kind: FocusNoiseKind, level: Float) {
        noiseKind = kind
        noiseLevel = level.isFinite ? min(max(level, 0), 1) : 0
        session?.worker.post(.noise(kind, level: noiseLevel))
    }

    /// 1 = normal; e.g. 0.3 = quieter. Ramped linearly over `ramp` seconds.
    public func setDuck(_ factor: Float, ramp: TimeInterval) {
        let value = factor.isFinite ? min(max(factor, 0), 1) : 1
        duckFactor = value
        session?.worker.post(.duck(value, ramp: sanitized(ramp)))
    }

    // MARK: - Checks support

    var consumedFramesForTesting: Int { session?.ring.readIndex ?? 0 }
    var isOutputRunningForTesting: Bool { session?.outputRunning ?? false }

    func simulateConfigurationChangeForTesting() {
        guard let engine = session?.engine else { return }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }

    /// Dev scenario: behave as if the device in use had just been disconnected.
    func simulateOutputLossForTesting() {
        guard let session else { return }
        let real = outputProbe
        outputProbe = FocusOutputProbe(current: { FocusOutputDevice(id: 0, uid: "simulated-speakers") }, isConnected: { _ in false })
        handleConfigurationChange(sessionID: session.id)
        outputProbe = real
    }

    // MARK: - Output

    private static let renderFormat = AVAudioFormat(standardFormatWithSampleRate: FocusAudioFormat.sampleRate, channels: 2)!

    private func startOutput(for session: Session) throws {
        let engine = AVAudioEngine()
        let view = session.ring.view
        let node = AVAudioSourceNode(format: Self.renderFormat) { isSilence, _, frameCount, bufferList in
            view.render(isSilence: isSilence, frameCount: frameCount, bufferList: bufferList)
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: Self.renderFormat)
        if outputMutedForTesting { engine.mainMixerNode.outputVolume = 0 }
        session.engine = engine
        session.node = node
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw FocusAudioEngineError.outputUnavailable(reason: error.localizedDescription)
        }
        session.outputRunning = true
        outputDevice = outputProbe.current()
        let id = session.id
        session.observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigurationChange(sessionID: id)
        }
    }

    /// Device change (headphones in/out, sample-rate change): AVAudioEngine has stopped itself.
    /// Rebuild the output connections and restart; the ring and worker are untouched, so the
    /// position continues where the device left off. If the device in use has disappeared and
    /// `pausesWhenOutputLost` is on, stay stopped and pause instead.
    private func handleConfigurationChange(sessionID: Int) {
        guard let session, session.id == sessionID, let engine = session.engine, let node = session.node else { return }
        configurationRestartCount += 1
        let shouldRun = session.outputRunning
        let previous = outputDevice
        let current = outputProbe.current()
        outputDevice = current
        var lost: FocusOutputDevice?
        if let previous, previous.uid != current?.uid, !outputProbe.isConnected(previous) { lost = previous }
        engine.stop()
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: Self.renderFormat)
        let device = engine.outputNode.outputFormat(forBus: 0)
        if device.sampleRate > 0, device.channelCount > 0,
           let format = AVAudioFormat(standardFormatWithSampleRate: device.sampleRate, channels: device.channelCount) {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        }
        if outputMutedForTesting { engine.mainMixerNode.outputVolume = 0 }
        engine.prepare()
        if let lost, pausesWhenOutputLost {
            lostOutputUID = lost.uid
            session.outputRunning = false
            guard isPlaying else { return }
            isPlaying = false
            pauseToken += 1
            restartOnResume = true
            session.worker.post(.pause(fade: 0, token: pauseToken))
            let uid = lost.uid
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.audioEngine(self, didPauseForLostOutput: uid)
            }
            return
        }
        guard shouldRun else { return }
        do {
            try engine.start()
            session.outputRunning = true
        } catch {
            session.outputRunning = false
            reportOutputFailure(error)
        }
    }

    private func reportOutputFailure(_ error: Error) {
        let track = currentTrack
        restartOnResume = false
        teardownSession(callPauseCompletions: true)
        isPlaying = false
        currentTrack = nil
        currentSerial = nil
        tracks.removeAll()
        announced.removeAll()
        let wrapped = FocusAudioEngineError.outputUnavailable(reason: error.localizedDescription)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.audioEngine(self, didFail: wrapped, track: track)
        }
    }

    private func teardownSession(callPauseCompletions: Bool) {
        guard let ending = session else { return }
        session = nil
        if let observer = ending.observer { NotificationCenter.default.removeObserver(observer) }
        ending.engine?.stop()
        if let node = ending.node { ending.engine?.detach(node) }
        ending.worker.stopAndWait()
        ending.node = nil
        ending.engine = nil
        ending.outputRunning = false
        underrunsFromEndedSessions += ending.ring.underrunCount
        let completions = pendingPauseCompletions
        pendingPauseCompletions.removeAll()
        if callPauseCompletions {
            for completion in completions { DispatchQueue.main.async(execute: completion) }
        }
    }

    // MARK: - Events (main thread)

    private func handle(_ event: FocusCoreEvent, sessionID: Int, skipsApplied: Int) {
        guard let session, session.id == sessionID else { return }
        switch event {
        case .becameAudible(let serial, _):
            guard let track = tracks[serial] else { return }
            consecutiveFailures = 0
            if announced.contains(serial) { return }
            // A successor superseded by a newer start/skip is not announced.
            if let current = currentSerial, serial < current { return }
            announced.insert(serial)
            currentSerial = serial
            currentTrack = track
            delegate?.audioEngine(self, didBecomeCurrent: track)

        case .finished(let serial, _, let listenedFrames, let skipped):
            failedSerials.remove(serial)
            guard let track = tracks.removeValue(forKey: serial) else { return }
            if announced.remove(serial) != nil {
                delegate?.audioEngine(self, didFinish: track,
                                      listenedSeconds: Double(listenedFrames) / FocusAudioFormat.sampleRate,
                                      skipped: skipped)
            }

        case .discarded(let serial):
            tracks.removeValue(forKey: serial)
            announced.remove(serial)

        case .needNext(let after, let replacing):
            answerNextTrack(after: after, replacing: replacing, session: session)

        case .failed(let serial, let error):
            consecutiveFailures += 1
            failedSerials.insert(serial)
            delegate?.audioEngine(self, didFail: error, track: tracks[serial])

        case .pauseCompleted(let token, _):
            guard token == pauseToken, !isPlaying else { return }
            if session.outputRunning, let engine = session.engine {
                engine.pause()
                session.outputRunning = false
            }
            let completions = pendingPauseCompletions
            pendingPauseCompletions.removeAll()
            for completion in completions { completion() }

        case .ended:
            // The core emitted this before a skip the main thread has since posted: that skip
            // restarts playback, so this end is stale.
            guard skipsApplied == skipsPosted else { return }
            teardownSession(callPauseCompletions: true)
            isPlaying = false
            currentTrack = nil
            currentSerial = nil
            tracks.removeAll()
            announced.removeAll()
            failedSerials.removeAll()
        }
    }

    private func answerNextTrack(after: Int, replacing: Bool, session: Session) {
        let previous = tracks[after]
        var next: EngineTrack?
        if consecutiveFailures < Self.maximumConsecutiveFailures, let previous {
            next = delegate?.audioEngineNextTrack(self, after: previous)
        }
        // The delegate may have stopped or restarted the engine.
        guard let current = self.session, current === session else { return }
        if failedSerials.remove(after) != nil {
            tracks.removeValue(forKey: after)
            announced.remove(after)
        }
        guard let next else {
            current.worker.post(.setNext(nil, serial: 0, after: after))
            return
        }
        let serial = makeSerial()
        tracks[serial] = next
        if replacing && currentSerial == after {
            announced.insert(serial)
            currentSerial = serial
            currentTrack = next
            delegate?.audioEngine(self, didBecomeCurrent: next)
        }
        current.worker.post(.setNext(next, serial: serial, after: after))
    }

    // MARK: - Helpers

    private func makeSerial() -> Int {
        serialCounter += 1
        return serialCounter
    }

    private func announceLater(_ track: EngineTrack) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.audioEngine(self, didBecomeCurrent: track)
        }
    }

    private func sanitized(_ seconds: TimeInterval) -> Double {
        seconds.isFinite ? max(0, seconds) : 0
    }
}
