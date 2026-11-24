import Accelerate
import Foundation

/// Things the core reports while rendering. `audibleFrame` is the output-stream frame at which
/// the event is heard; the real-time engine delivers it once playback reaches that frame.
enum FocusCoreEvent {
    case becameAudible(serial: Int, frame: Int64)
    case finished(serial: Int, frame: Int64, listenedFrames: Int, skipped: Bool)
    /// A prepared successor (or a late answer) was dropped without ever playing.
    case discarded(serial: Int)
    /// The core needs the track that follows `after`. `replacing`: `after` failed to open as a
    /// start/skip target and its replacement should become current right away.
    case needNext(after: Int, replacing: Bool)
    case pauseCompleted(token: Int, frame: Int64)
    case ended(frame: Int64)
    case failed(serial: Int, error: Error)

    var audibleFrame: Int64? {
        switch self {
        case .becameAudible(_, let frame), .finished(_, let frame, _, _), .pauseCompleted(_, let frame), .ended(let frame):
            return frame
        case .discarded, .needNext, .failed:
            return nil
        }
    }
}

/// `frames` consecutive output frames starting at `streamFrame` played `serial` from `trackFrame`.
struct FocusPositionLogEntry {
    let serial: Int
    let streamFrame: Int64
    let trackFrame: Int
    var frames: Int
}

/// A parameter that moves to a target over a number of frames, linearly or along a raised cosine.
struct FocusRamp {
    private(set) var value: Float
    private var origin: Float
    private var target: Float
    private var length = 0
    private var elapsed = 0
    private var smooth = false

    init(value: Float) {
        self.value = value
        origin = value
        target = value
    }

    var isRamping: Bool { elapsed < length }
    var framesRemaining: Int { max(0, length - elapsed) }

    mutating func jump(to newValue: Float) {
        value = newValue
        origin = newValue
        target = newValue
        length = 0
        elapsed = 0
    }

    mutating func set(_ newTarget: Float, frames: Int, smooth: Bool) {
        guard frames > 0 else {
            jump(to: newTarget)
            return
        }
        origin = value
        target = newTarget
        length = frames
        elapsed = 0
        self.smooth = smooth
    }

    /// Writes the value for each of the next `count` frames and advances.
    mutating func fill(_ out: UnsafeMutablePointer<Float>, count: Int) {
        for index in 0..<count {
            if elapsed < length {
                elapsed += 1
                if elapsed == length {
                    value = target
                } else {
                    let progress = Double(elapsed) / Double(length)
                    let shaped = smooth ? 0.5 - 0.5 * cos(Double.pi * progress) : progress
                    value = origin + (target - origin) * Float(shaped)
                }
            }
            out[index] = value
        }
    }
}

/// The complete DSP and mixing path, independent of AVAudioEngine so it can render offline.
///
/// Per track: decode, loudness gain, FIR band split, beat-synced effect (own beat grid), then an
/// equal-power crossfade envelope; background noise joins the mix after the effect, and the mix
/// gets volume x duck x play/pause fade. A track with loop points repeats its loop region inside
/// its voice until `minimumTrackSeconds` (see `FocusTrackVoice`), so here it is one longer track.
/// Commands apply at the current output position (`streamFrame`). Not thread-safe: one thread
/// drives it.
final class FocusRenderCore {
    enum Transport: Equatable {
        case idle, playing, pausing, paused, ended
    }

    private enum PendingMode {
        case next
        case start(fadeIn: Double)
        case skip(crossfade: Double)
    }

    static let maxSubBlock = 512
    /// Shortest ramp for mid-stream pause/resume/skip, so "immediate" never clicks.
    static let declickSeconds = 0.005
    /// Fade-in used when a successor arrives after its predecessor already ended.
    static let lateFadeInSeconds = 0.5
    /// Equal-power crossfade at each loop seam, centred on the seam (law in `FocusLoopPlan`). The
    /// loop points are bar lines aligned by cross-correlation, so the two sides play the same
    /// beat: 1 s is long enough that a change of chord voicing or reverb tail reads as a blend
    /// rather than a cut, and short enough that only about two beats (at 90-130 BPM) are heard
    /// from both positions at once.
    static let loopSeamSeconds = 1.0
    private static let chunkCapacity = 4096

    let sampleRate: Double
    let fir: FocusBandFIR
    /// How long before the crossfade the core asks for the next track.
    var nextTrackLookaheadSeconds: Double = 10
    var recordsPositionLog = false

    private(set) var streamFrame: Int64 = 0
    private(set) var transport: Transport = .idle
    private(set) var voices: [FocusTrackVoice] = []
    private(set) var crossfadeSeconds: Double = 8
    /// A track with loop points repeats its loop until its play lasts at least this long, then
    /// plays out to its natural end. 0 = every track plays once.
    private(set) var minimumTrackSeconds: Double = 1800

    private var preparedNext: FocusTrackVoice?
    private var awaitingAnswerAfter: Int?
    private var pendingMode: PendingMode = .next
    private var requestedNextFor: Int?
    private var noSuccessorFor: Int?

    private var playFade = FocusRamp(value: 0)
    private var volume = FocusRamp(value: 1)
    private var duck = FocusRamp(value: 1)
    private var depth = FocusRamp(value: 0)
    private let noise: FocusNoiseGenerator
    private var noiseGain = FocusRamp(value: 0)
    /// The noise being rendered; a different requested kind waits in `pendingNoise` until this one has faded out.
    private var noiseKind: FocusNoiseKind = .off
    private var pendingNoise: FocusNoiseKind?
    private var noiseTarget: Float = 0
    /// Files for the recorded kinds; the open one plays while `noiseKind` is a recorded kind.
    private var noiseRecordings: [FocusNoiseKind: URL] = [:]
    private var recording: FocusNoiseRecording?
    private var pauseToken = 0
    private var lastFinishedFrame: Int64 = 0

    private var events: [FocusCoreEvent] = []
    private var positionLog: [FocusPositionLogEntry] = []

    private let scratch: FocusVoiceScratch
    private let buffers: UnsafeMutablePointer<Float>
    private let mixLeft: UnsafeMutablePointer<Float>
    private let mixRight: UnsafeMutablePointer<Float>
    private let voiceLeft: UnsafeMutablePointer<Float>
    private let voiceRight: UnsafeMutablePointer<Float>
    private let gains: UnsafeMutablePointer<Float>
    private let depthValues: UnsafeMutablePointer<Float>
    private let master: UnsafeMutablePointer<Float>
    private let masterTerm: UnsafeMutablePointer<Float>
    private let noiseGains: UnsafeMutablePointer<Float>
    private let chunkLeft: UnsafeMutablePointer<Float>
    private let chunkRight: UnsafeMutablePointer<Float>

    init(sampleRate: Double = FocusAudioFormat.sampleRate, fir: FocusBandFIR = .standard) {
        precondition(fir.sampleRate == sampleRate, "FIR designed for a different sample rate")
        self.sampleRate = sampleRate
        self.fir = fir
        scratch = FocusVoiceScratch(capacity: Self.maxSubBlock)
        noise = FocusNoiseGenerator(sampleRate: sampleRate)
        let block = Self.maxSubBlock
        let total = block * 9 + Self.chunkCapacity * 2
        buffers = .allocate(capacity: total)
        buffers.initialize(repeating: 0, count: total)
        mixLeft = buffers
        mixRight = buffers + block
        voiceLeft = buffers + block * 2
        voiceRight = buffers + block * 3
        gains = buffers + block * 4
        depthValues = buffers + block * 5
        master = buffers + block * 6
        masterTerm = buffers + block * 7
        noiseGains = buffers + block * 8
        chunkLeft = buffers + block * 9
        chunkRight = buffers + block * 9 + Self.chunkCapacity
        events.reserveCapacity(16)
        positionLog.reserveCapacity(16)
    }

    deinit {
        buffers.deallocate()
    }

    /// Playing or fading toward a pause: the output stream has to keep moving.
    var wantsOutput: Bool { transport == .playing || transport == .pausing }
    var currentDepth: Float { depth.value }
    var voiceSerials: [Int] { voices.map(\.serial) }
    var preparedNextSerial: Int? { preparedNext?.serial }

    func drainEvents() -> [FocusCoreEvent] {
        guard !events.isEmpty else { return [] }
        let drained = events
        events.removeAll(keepingCapacity: true)
        return drained
    }

    func drainPositionLog() -> [FocusPositionLogEntry] {
        guard !positionLog.isEmpty else { return [] }
        let drained = positionLog
        positionLog.removeAll(keepingCapacity: true)
        return drained
    }

    // MARK: - Commands (apply at `streamFrame`)

    /// Hard start of a new queue. `startTime` > 0 starts inside the track (used by checks).
    func start(track: EngineTrack, serial: Int, fadeIn: Double, startTime: Double = 0) {
        voices.removeAll()
        preparedNext = nil
        awaitingAnswerAfter = nil
        requestedNextFor = nil
        noSuccessorFor = nil
        pendingMode = .next
        transport = .playing
        playFade.jump(to: 0)
        playFade.set(1, frames: frames(fadeIn), smooth: true)
        do {
            voices = [try makeVoice(track, serial: serial, startTime: startTime)]
        } catch {
            requestReplacement(failedSerial: serial, error: error, mode: .start(fadeIn: fadeIn))
        }
    }

    func pause(fade: Double, token: Int) {
        pauseToken = token
        switch transport {
        case .playing, .pausing:
            transport = .pausing
            playFade.set(0, frames: max(frames(fade), frames(Self.declickSeconds)), smooth: true)
        case .paused, .idle, .ended:
            emit(.pauseCompleted(token: token, frame: streamFrame))
        }
    }

    func resume(fade: Double) {
        guard transport == .paused || transport == .pausing else { return }
        transport = .playing
        playFade.set(1, frames: max(frames(fade), frames(Self.declickSeconds)), smooth: true)
    }

    /// Equal-power crossfade from everything audible into `track`. While paused the new track
    /// simply replaces the old one and starts with the resume fade.
    func skip(to track: EngineTrack, serial: Int, crossfade: Double) {
        guard transport != .idle && transport != .ended else {
            start(track: track, serial: serial, fadeIn: crossfade)
            return
        }
        discardPreparedNext()
        do {
            let voice = try makeVoice(track, serial: serial, startTime: 0)
            transition(to: voice, crossfade: crossfade)
        } catch {
            requestReplacement(failedSerial: serial, error: error, mode: .skip(crossfade: crossfade))
        }
    }

    /// Answer to `.needNext(after:)`. `nil` means there is no next track.
    func setNext(_ track: EngineTrack?, serial: Int, after: Int) {
        guard let awaited = awaitingAnswerAfter, awaited == after else {
            if track != nil { emit(.discarded(serial: serial)) }
            return
        }
        awaitingAnswerAfter = nil
        let mode = pendingMode
        pendingMode = .next
        guard let track else {
            switch mode {
            case .next:
                noSuccessorFor = after
            case .start:
                break
            case .skip(let crossfade):
                // The user left the current track and nothing can replace it.
                let length = max(frames(crossfade), frames(Self.declickSeconds))
                dominant?.envelope.skipped = true
                for voice in voices where !voice.envelope.isFadingOut {
                    voice.envelope.beginFadeOut(at: streamFrame, length: min(length, voice.remainingFrames))
                }
            }
            endIfNothingLeft()
            return
        }
        let voice: FocusTrackVoice
        do {
            voice = try makeVoice(track, serial: serial, startTime: 0)
        } catch {
            requestReplacement(failedSerial: serial, error: error, mode: mode)
            return
        }
        switch mode {
        case .start(let fadeIn):
            voices = [voice]
            if transport == .playing {
                playFade.jump(to: 0)
                playFade.set(1, frames: frames(fadeIn), smooth: true)
            }
        case .skip(let crossfade):
            transition(to: voice, crossfade: crossfade)
        case .next:
            if dominant != nil {
                preparedNext = voice
            } else {
                voice.envelope.beginFadeIn(at: streamFrame, length: frames(Self.lateFadeInSeconds))
                voices.append(voice)
            }
        }
    }

    func setEffectDepth(_ value: Float, rampSeconds: Double = 0.5) {
        let clamped = value.isFinite ? min(max(value, 0), 1) : 0
        depth.set(clamped, frames: frames(rampSeconds), smooth: true)
    }

    func setVolume(_ value: Float, rampSeconds: Double = 0.2) {
        let clamped = value.isFinite ? min(max(value, 0), 1) : 0
        volume.set(clamped, frames: frames(rampSeconds), smooth: false)
    }

    func setDuck(_ factor: Float, rampSeconds: Double) {
        let clamped = factor.isFinite ? min(max(factor, 0), 1) : 1
        duck.set(clamped, frames: frames(rampSeconds), smooth: false)
    }

    /// Background noise under the music; `level` is the 0...1 slider value. Changing the level
    /// ramps; switching to another kind fades the current one out first.
    func setNoise(_ kind: FocusNoiseKind, level: Float, rampSeconds: Double = 0.4) {
        noiseTarget = kind == .off ? 0 : FocusNoiseGenerator.gain(forLevel: level)
        if noiseKind == .off {
            // Nothing audible yet: start the new kind from silence.
            pendingNoise = nil
            noiseGain.jump(to: 0)
            guard kind != .off, noiseTarget > 0 else { return }
            useNoise(kind)
            noiseGain.set(noiseTarget, frames: frames(rampSeconds), smooth: true)
        } else if kind == noiseKind {
            pendingNoise = nil
            noiseGain.set(noiseTarget, frames: frames(rampSeconds), smooth: true)
        } else {
            // Another kind, or off: fade the current one out first (`finishNoiseChange` switches).
            pendingNoise = kind
            noiseGain.set(0, frames: frames(0.25), smooth: true)
        }
    }

    /// Where the recorded kinds (rain, ocean, stream) are; a kind without a usable file is silent.
    func setNoiseRecordings(_ urls: [FocusNoiseKind: URL]) {
        noiseRecordings = urls
    }

    /// Makes `kind` the noise being rendered, opening its recording when it is one.
    private func useNoise(_ kind: FocusNoiseKind) {
        noiseKind = kind
        guard kind.isRecording else {
            recording = nil
            return
        }
        if recording?.kind != kind {
            recording = noiseRecordings[kind].flatMap { FocusNoiseRecording(kind: kind, url: $0, sampleRate: sampleRate) }
        }
    }

    func setCrossfadeSeconds(_ seconds: Double) {
        crossfadeSeconds = seconds.isFinite ? min(max(seconds, 0), 120) : 8
    }

    /// Applies to the playing track (from its next seam on) and to every track after it.
    func setMinimumTrackSeconds(_ seconds: Double) {
        minimumTrackSeconds = seconds.isFinite ? min(max(seconds, 0), 86_400) : 0
        let target = frames(minimumTrackSeconds)
        for voice in voices where !voice.envelope.isFadingOut { voice.setLoopTarget(target) }
        preparedNext?.setLoopTarget(target)
    }

    func stop() {
        voices.removeAll()
        preparedNext = nil
        awaitingAnswerAfter = nil
        requestedNextFor = nil
        noSuccessorFor = nil
        pendingMode = .next
        transport = .idle
        playFade.jump(to: 0)
    }

    // MARK: - Rendering

    /// Renders `frames` stereo frames, interleaved L R L R.
    func render(into interleaved: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            let count = min(Self.chunkCapacity, frames - done)
            render(left: chunkLeft, right: chunkRight, frames: count)
            var split = DSPSplitComplex(realp: chunkLeft, imagp: chunkRight)
            (interleaved + 2 * done).withMemoryRebound(to: DSPComplex.self, capacity: count) {
                vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(count))
            }
            done += count
        }
    }

    /// Renders `frames` frames into separate channel buffers. Paused/idle/ended renders silence.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            let remaining = frames - done
            guard wantsOutput else {
                vDSP_vclr(left + done, 1, vDSP_Length(remaining))
                vDSP_vclr(right + done, 1, vDSP_Length(remaining))
                streamFrame += Int64(remaining)
                return
            }
            resolveBoundaries()
            let count = max(1, min(Self.maxSubBlock, remaining, framesUntilBoundary()))
            let blockStart = streamFrame
            renderSubBlock(left: left + done, right: right + done, count: count)
            streamFrame += Int64(count)
            done += count
            afterSubBlock(blockStart: blockStart)
        }
    }

    // MARK: - Internals

    /// The newest voice that is not leaving.
    private var dominant: FocusTrackVoice? {
        guard let last = voices.last, !last.envelope.isFadingOut else { return nil }
        return last
    }

    private func frames(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * sampleRate).rounded())
    }

    private func emit(_ event: FocusCoreEvent) {
        events.append(event)
    }

    /// `startTime` is a position in the play (loop passes included), as `currentTime` reports it.
    private func makeVoice(_ track: EngineTrack, serial: Int, startTime: Double) throws -> FocusTrackVoice {
        let startFrame = startTime.isFinite && startTime > 0 ? Int((startTime * sampleRate).rounded()) : 0
        return try FocusTrackVoice(track: track, serial: serial, fir: fir, startFrame: startFrame,
                                   loopTarget: frames(minimumTrackSeconds),
                                   seamFrames: 2 * frames(Self.loopSeamSeconds / 2))
    }

    private func crossfadeStart(for voice: FocusTrackVoice) -> Int {
        voice.length - min(frames(crossfadeSeconds), voice.length / 2)
    }

    private func requestReplacement(failedSerial: Int, error: Error, mode: PendingMode) {
        emit(.failed(serial: failedSerial, error: error))
        awaitingAnswerAfter = failedSerial
        pendingMode = mode
        let replacing: Bool
        if case .next = mode { replacing = false } else { replacing = true }
        emit(.needNext(after: failedSerial, replacing: replacing))
    }

    private func discardPreparedNext() {
        guard let next = preparedNext else { return }
        preparedNext = nil
        emit(.discarded(serial: next.serial))
    }

    private func transition(to voice: FocusTrackVoice, crossfade: Double) {
        discardPreparedNext()
        awaitingAnswerAfter = nil
        requestedNextFor = nil
        noSuccessorFor = nil
        pendingMode = .next
        dominant?.envelope.skipped = true
        if transport == .paused {
            for old in voices { finish(old) }
            voices = [voice]
            return
        }
        let length = max(frames(crossfade), frames(Self.declickSeconds))
        // Every outgoing voice restarts its fade from its current gain with the same length, so
        // sum(g_out^2) cos^2 + sin^2 stays 1 (shortened only if a track runs out first).
        for old in voices {
            old.envelope.beginFadeOut(at: streamFrame, length: min(length, old.remainingFrames))
        }
        voice.envelope.beginFadeIn(at: streamFrame, length: length)
        voices.append(voice)
    }

    private func finish(_ voice: FocusTrackVoice) {
        let frame = voice.hasStartedOutput
            ? min(voice.outputEnd, voice.envelope.fadeOutEnd ?? voice.outputEnd)
            : streamFrame
        lastFinishedFrame = max(lastFinishedFrame, frame)
        emit(.finished(serial: voice.serial, frame: frame, listenedFrames: voice.framesPlayed,
                       skipped: voice.envelope.skipped))
    }

    /// `frame`: where the audio actually stopped (the last voice's end inside a sub-block).
    private func endIfNothingLeft(at frame: Int64? = nil) {
        guard transport != .idle && transport != .ended else { return }
        if voices.isEmpty && preparedNext == nil && awaitingAnswerAfter == nil {
            transport = .ended
            emit(.ended(frame: frame ?? streamFrame))
        }
    }

    private func maybeRequestNext() {
        guard let current = dominant, preparedNext == nil, awaitingAnswerAfter == nil,
              requestedNextFor != current.serial, noSuccessorFor != current.serial else { return }
        let threshold = crossfadeStart(for: current) - Int(nextTrackLookaheadSeconds * sampleRate)
        guard current.position >= threshold else { return }
        requestedNextFor = current.serial
        awaitingAnswerAfter = current.serial
        pendingMode = .next
        emit(.needNext(after: current.serial, replacing: false))
    }

    /// Starts due crossfades at exactly the current frame and asks for successors.
    private func resolveBoundaries() {
        if voices.isEmpty, let next = preparedNext {
            // The predecessor ended with a zero-length crossfade: hard cut, as configured.
            preparedNext = nil
            voices = [next]
        }
        if let current = dominant, let next = preparedNext {
            let start = crossfadeStart(for: current)
            if current.position >= start {
                let remaining = current.remainingFrames
                // On time, both fades last exactly until the outgoing track ends (equal power).
                // A late successor gets at least a short fade-in.
                let incoming = current.position == start ? remaining : max(remaining, frames(Self.lateFadeInSeconds))
                preparedNext = nil
                current.envelope.beginFadeOut(at: streamFrame, length: remaining)
                next.envelope.beginFadeIn(at: streamFrame, length: incoming)
                voices.append(next)
            }
        }
        maybeRequestNext()
    }

    private func framesUntilBoundary() -> Int {
        var limit = Int.max
        if let current = dominant, preparedNext != nil {
            let start = crossfadeStart(for: current)
            if current.position < start { limit = start - current.position }
        }
        for voice in voices {
            if let end = voice.envelope.fadeOutEnd {
                limit = min(limit, max(1, Int(end - streamFrame)))
            }
        }
        if transport == .pausing {
            limit = min(limit, max(1, playFade.framesRemaining))
        }
        return limit
    }

    private func renderSubBlock(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        let n = vDSP_Length(count)
        let blockStart = streamFrame
        let depthActive = fillDepth(count)
        vDSP_vclr(mixLeft, 1, n)
        vDSP_vclr(mixRight, 1, n)
        for voice in voices {
            let before = voice.position
            let produced = voice.render(left: voiceLeft, right: voiceRight, frames: count,
                                        depth: depthValues, depthActive: depthActive, scratch: scratch)
            guard produced > 0 else { continue }
            voice.outputEnd = blockStart + Int64(produced)
            if !voice.hasStartedOutput {
                voice.hasStartedOutput = true
                emit(.becameAudible(serial: voice.serial, frame: blockStart))
            }
            if recordsPositionLog {
                logPosition(serial: voice.serial, streamFrame: blockStart, trackFrame: before, frames: produced)
            }
            let p = vDSP_Length(produced)
            if voice.envelope.isUnity(from: blockStart, count: produced) {
                vDSP_vadd(voiceLeft, 1, mixLeft, 1, mixLeft, 1, p)
                vDSP_vadd(voiceRight, 1, mixRight, 1, mixRight, 1, p)
            } else {
                voice.envelope.fill(gains, from: blockStart, count: produced)
                vDSP_vma(voiceLeft, 1, gains, 1, mixLeft, 1, mixLeft, 1, p)
                vDSP_vma(voiceRight, 1, gains, 1, mixRight, 1, mixRight, 1, p)
            }
        }
        let noiseOn = renderNoise(count)
        applyMaster(count)
        if noiseOn {
            softLimit(mixLeft, count)
            softLimit(mixRight, count)
        }
        left.update(from: mixLeft, count: count)
        right.update(from: mixRight, count: count)
    }

    private func afterSubBlock(blockStart: Int64) {
        var index = 0
        while index < voices.count {
            let voice = voices[index]
            if let failure = voice.failure, !voice.failureReported {
                voice.failureReported = true
                emit(.failed(serial: voice.serial, error: failure))
            }
            let fadeDone = voice.envelope.fadeOutEnd.map { $0 <= streamFrame } ?? false
            if voice.isFinished || fadeDone {
                voices.remove(at: index)
                finish(voice)
            } else {
                index += 1
            }
        }
        if transport == .pausing && !playFade.isRamping && playFade.value <= 0 {
            transport = .paused
            emit(.pauseCompleted(token: pauseToken, frame: streamFrame))
        }
        endIfNothingLeft(at: max(lastFinishedFrame, blockStart))
    }

    /// Adds the background noise into the mix. Returns true when noise was added (a recorded
    /// kind whose file could not be opened adds nothing).
    private func renderNoise(_ count: Int) -> Bool {
        guard noiseKind != .off else { return false }
        if noiseGain.isRamping {
            noiseGain.fill(noiseGains, count: count)
        } else if noiseGain.value > 0 {
            var value = noiseGain.value
            vDSP_vfill(&value, noiseGains, 1, vDSP_Length(count))
        } else {
            finishNoiseChange()
            return false
        }
        var added = true
        if noiseKind.isRecording {
            if let recording {
                recording.render(addingInto: mixLeft, mixRight, gains: noiseGains, count: count)
            } else {
                added = false
            }
        } else {
            noise.render(noiseKind, addingInto: mixLeft, mixRight, gains: noiseGains, count: count)
        }
        if !noiseGain.isRamping && noiseGain.value == 0 { finishNoiseChange() }
        return added
    }

    /// The old noise has faded out: start the requested one, or stop.
    private func finishNoiseChange() {
        if let next = pendingNoise {
            pendingNoise = nil
            useNoise(next)
            if next != .off { noiseGain.set(noiseTarget, frames: frames(0.4), smooth: true) }
        } else if noiseTarget == 0 {
            useNoise(.off)
        }
    }

    /// Music alone stays under 0.95 (true peak at most -1 dBFS). With noise on top, the rare
    /// peaks above that are rounded off toward 1 instead of clipping.
    private func softLimit(_ buffer: UnsafeMutablePointer<Float>, _ count: Int) {
        for index in 0..<count {
            let x = buffer[index]
            let size = abs(x)
            if size > 0.95 {
                let rounded = 0.95 + 0.05 * tanhf((size - 0.95) / 0.05)
                buffer[index] = x < 0 ? -rounded : rounded
            }
        }
    }

    /// Returns false when the depth is exactly zero for the whole sub-block.
    private func fillDepth(_ count: Int) -> Bool {
        if depth.isRamping {
            depth.fill(depthValues, count: count)
            return true
        }
        guard depth.value != 0 else { return false }
        var value = depth.value
        vDSP_vfill(&value, depthValues, 1, vDSP_Length(count))
        return true
    }

    private func applyMaster(_ count: Int) {
        let n = vDSP_Length(count)
        if !volume.isRamping && !duck.isRamping && !playFade.isRamping {
            var gain = volume.value * duck.value * playFade.value
            if gain != 1 {
                vDSP_vsmul(mixLeft, 1, &gain, mixLeft, 1, n)
                vDSP_vsmul(mixRight, 1, &gain, mixRight, 1, n)
            }
            return
        }
        fillRamp(&volume, into: master, count: count)
        fillRamp(&duck, into: masterTerm, count: count)
        vDSP_vmul(master, 1, masterTerm, 1, master, 1, n)
        fillRamp(&playFade, into: masterTerm, count: count)
        vDSP_vmul(master, 1, masterTerm, 1, master, 1, n)
        vDSP_vmul(mixLeft, 1, master, 1, mixLeft, 1, n)
        vDSP_vmul(mixRight, 1, master, 1, mixRight, 1, n)
    }

    private func fillRamp(_ ramp: inout FocusRamp, into out: UnsafeMutablePointer<Float>, count: Int) {
        if ramp.isRamping {
            ramp.fill(out, count: count)
        } else {
            var value = ramp.value
            vDSP_vfill(&value, out, 1, vDSP_Length(count))
        }
    }

    private func logPosition(serial: Int, streamFrame: Int64, trackFrame: Int, frames: Int) {
        if let index = positionLog.lastIndex(where: { $0.serial == serial }) {
            let entry = positionLog[index]
            if entry.streamFrame + Int64(entry.frames) == streamFrame && entry.trackFrame + entry.frames == trackFrame {
                positionLog[index].frames += frames
                return
            }
        }
        positionLog.append(FocusPositionLogEntry(serial: serial, streamFrame: streamFrame,
                                                 trackFrame: trackFrame, frames: frames))
    }
}
