import Accelerate
import Foundation

/// Equal-power crossfade gain of one voice, as a function of the output stream frame.
/// Fade-in is sin(pi/2 p); fade-out is g0 cos(pi/2 p), where g0 is the gain at the moment the
/// fade-out began (so a fade-out that interrupts a fade-in keeps the total power constant).
struct FocusVoiceEnvelope {
    private(set) var fadeInStart: Int64 = 0
    private(set) var fadeInLength = 0
    private(set) var fadeOutStart: Int64?
    private(set) var fadeOutLength = 0
    private(set) var fadeOutFrom: Float = 1
    /// The voice left because the user skipped it.
    var skipped = false

    var isFadingOut: Bool { fadeOutStart != nil }
    var fadeOutEnd: Int64? { fadeOutStart.map { $0 + Int64(fadeOutLength) } }

    func gain(at frame: Int64) -> Float {
        if let start = fadeOutStart {
            guard fadeOutLength > 0 else { return 0 }
            let progress = Double(frame - start) / Double(fadeOutLength)
            if progress >= 1 { return 0 }
            return fadeOutFrom * Float(cos(Double.pi / 2 * max(0, progress)))
        }
        if fadeInLength > 0 {
            let progress = Double(frame - fadeInStart) / Double(fadeInLength)
            if progress < 1 { return Float(sin(Double.pi / 2 * max(0, progress))) }
        }
        return 1
    }

    mutating func beginFadeIn(at frame: Int64, length: Int) {
        fadeInStart = frame
        fadeInLength = max(0, length)
    }

    mutating func beginFadeOut(at frame: Int64, length: Int) {
        fadeOutFrom = gain(at: frame)
        fadeOutStart = frame
        fadeOutLength = max(0, length)
    }

    /// True when the gain is exactly 1 for the whole range.
    func isUnity(from frame: Int64, count: Int) -> Bool {
        fadeOutStart == nil && (fadeInLength == 0 || frame >= fadeInStart + Int64(fadeInLength))
    }

    func fill(_ gains: UnsafeMutablePointer<Float>, from frame: Int64, count: Int) {
        let n = vDSP_Length(count)
        var count32 = Int32(count)
        var low: Float = 0
        var high = Float.pi / 2
        if let start = fadeOutStart {
            guard fadeOutLength > 0 else {
                vDSP_vclr(gains, 1, n)
                return
            }
            var first = Float(Double(frame - start) / Double(fadeOutLength) * Double.pi / 2)
            var step = Float(Double.pi / 2 / Double(fadeOutLength))
            vDSP_vramp(&first, &step, gains, 1, n)
            vDSP_vclip(gains, 1, &low, &high, gains, 1, n)
            vvcosf(gains, gains, &count32)
            var from = fadeOutFrom
            vDSP_vsmul(gains, 1, &from, gains, 1, n)
        } else if fadeInLength > 0 {
            var first = Float(Double(frame - fadeInStart) / Double(fadeInLength) * Double.pi / 2)
            var step = Float(Double.pi / 2 / Double(fadeInLength))
            vDSP_vramp(&first, &step, gains, 1, n)
            vDSP_vclip(gains, 1, &low, &high, gains, 1, n)
            vvsinf(gains, gains, &count32)
        } else {
            var one: Float = 1
            vDSP_vfill(&one, gains, 1, n)
        }
    }
}

/// Scratch shared by all voices of one core (worker thread only).
final class FocusVoiceScratch {
    let capacity: Int
    let modulation: UnsafeMutablePointer<Float>
    let product: UnsafeMutablePointer<Float>
    /// The incoming side of a loop seam, the two seam gains and their power correction.
    let seamLeft: UnsafeMutablePointer<Float>
    let seamRight: UnsafeMutablePointer<Float>
    let seamIn: UnsafeMutablePointer<Float>
    let seamOut: UnsafeMutablePointer<Float>
    let seamNorm: UnsafeMutablePointer<Float>
    private let storage: UnsafeMutablePointer<Float>

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity * 7)
        storage.initialize(repeating: 0, count: capacity * 7)
        modulation = storage
        product = storage + capacity
        seamLeft = storage + capacity * 2
        seamRight = storage + capacity * 3
        seamIn = storage + capacity * 4
        seamOut = storage + capacity * 5
        seamNorm = storage + capacity * 6
    }

    deinit {
        storage.deallocate()
    }
}

/// The repeatable middle of a track and where its seams fall on a voice's timeline (frames).
///
/// Timeline frame v plays file frame v until the first seam. Seam k (k = 1, 2, ...) is centred on
/// v = end + (k - 1) * period: over `seam` frames the file around `end` fades out while the file
/// around `start` fades in, both read at their own file positions. After the last seam the file
/// plays on to its natural end, so a play with n repeats lasts fileFrames + n * period.
///
/// Seam gains, p = frames into the seam / seam, theta = pi/2 p:
///     out = cos(theta) / n,  in = sin(theta) / n,  n = sqrt(1 + r sin(2 theta))
/// so out^2 + in^2 + 2 r out in = 1: equal power for two sides with correlation r (the library
/// build measures r over the seam). r = 0 is the plain cos/sin law; aligned drums that coincide
/// on both sides (r > 0) would otherwise swell by 10 log10(1 + r) dB in the middle of the seam.
struct FocusLoopPlan: Equatable {
    /// Correlations the seam law accepts; the library build clamps to the same range.
    static let correlationRange: ClosedRange<Double> = -0.3...0.9

    let start: Int
    let end: Int
    let seam: Int
    let correlation: Float
    var period: Int { end - start }
    var halfSeam: Int { seam / 2 }

    /// nil unless the track has loop points whose seams fit inside the file with room to spare.
    init?(track: EngineTrack, fileFrames: Int, sampleRate: Double, seamFrames: Int) {
        guard let startSeconds = track.loopStartSeconds, let endSeconds = track.loopEndSeconds,
              startSeconds.isFinite, endSeconds.isFinite, seamFrames >= 2 else { return nil }
        let half = seamFrames / 2
        let start = Int((startSeconds * sampleRate).rounded())
        let end = Int((endSeconds * sampleRate).rounded())
        guard start - half >= 0, end + half <= fileFrames, end - start >= 4 * half else { return nil }
        self.start = start
        self.end = end
        seam = 2 * half
        let r = track.loopSeamCorrelation.isFinite ? track.loopSeamCorrelation : 0
        correlation = Float(min(max(r, Self.correlationRange.lowerBound), Self.correlationRange.upperBound))
    }

    /// Timeline frame where seam `k` (1-based) begins.
    func seamBegin(_ k: Int) -> Int { end - halfSeam + (k - 1) * period }

    /// Seams that have begun at or before timeline frame `frame`, if the loop went on forever.
    func seamsBegun(by frame: Int) -> Int {
        frame < end - halfSeam ? 0 : (frame - (end - halfSeam)) / period + 1
    }

    /// Fewest repeats that make the play last at least `target` frames.
    func repeats(toReach target: Int, fileFrames: Int) -> Int {
        guard target > fileFrames else { return 0 }
        return (target - fileFrames + period - 1) / period
    }
}

/// One read position in a track's file: decode -> loudness gain -> (FIR band split) ->
/// beat-synced effect. Output frame m (file time m / fs) is
///     y[m] = x[m] - depth(m) * shape(m) * window(m) * band[m]
///     shape(m) = 0.5 * (1 - cos(2 pi f (m / fs - beatOffset)))
/// where band = FIR(x) centred on m (the FIR's group delay is compensated by pre-rolling the
/// filter, so the dry path is exactly x[m]) and window is `effect_window` from focus_audio.py
/// (0.25 s raised-cosine ramps at the file's start and end). Everything follows file time, so a
/// head that jumps back for a loop stays in phase with the music's beat.
final class FocusReadHead {
    let frameCount: Int
    private(set) var position: Int
    private(set) var failure: Error?

    private let decoder: FocusTrackDecoder
    private let channels: (left: FocusOverlapSaveChannel, right: FocusOverlapSaveChannel)?
    private let plainLeft: UnsafeMutablePointer<Float>
    private let plainRight: UnsafeMutablePointer<Float>
    private let sampleRate: Double
    private let modulationHz: Double?
    private let beatOffsetSeconds: Double
    /// Set when the pulse follows the track's beats instead of a steady grid.
    private let beatMap: FocusBeatMap?
    private let gain: Float
    private let effectFadeFrames: Int
    private let hop: Int
    private let groupDelay: Int
    private var inputFrame: Int
    private var blockFirstFrame = 0
    private var hasBlock = false
    private var decoderDrained = false

    init(decoder: FocusTrackDecoder, track: EngineTrack, fir: FocusBandFIR, startFrame requestedStart: Int) {
        self.decoder = decoder
        sampleRate = fir.sampleRate
        hop = fir.hop
        groupDelay = fir.groupDelay
        frameCount = decoder.frameCount

        if let hz = track.modulationHz, hz.isFinite, hz > 0, hz <= 100 {
            modulationHz = hz
            channels = (FocusOverlapSaveChannel(fir: fir), FocusOverlapSaveChannel(fir: fir))
        } else {
            modulationHz = nil
            channels = nil
        }
        beatOffsetSeconds = track.beatOffsetSeconds.isFinite ? track.beatOffsetSeconds : 0
        beatMap = modulationHz == nil ? nil
            : FocusBeatMap(seconds: track.beatTimes, cyclesPerBeat: track.pulseCyclesPerBeat, sampleRate: fir.sampleRate)
        let gainDB = track.gainDB.isFinite ? min(max(track.gainDB, -60), 24) : 0
        gain = gainDB == 0 ? 1 : Float(pow(10.0, Double(gainDB) / 20.0))
        effectFadeFrames = min(Int((0.25 * fir.sampleRate).rounded()), frameCount / 4)

        plainLeft = .allocate(capacity: hop)
        plainLeft.initialize(repeating: 0, count: hop)
        plainRight = .allocate(capacity: hop)
        plainRight.initialize(repeating: 0, count: hop)

        position = max(0, min(requestedStart, frameCount))
        // The FIR needs `groupDelay` frames of real input before the first output frame.
        inputFrame = channels == nil ? position : max(0, position - groupDelay)
        if inputFrame > 0 { decoder.seek(toFrame: inputFrame) }
    }

    deinit {
        plainLeft.deallocate()
        plainRight.deallocate()
    }

    /// Moves the read position to `frame`; the next output frame is exact (FIR pre-rolled again).
    func seek(toFrame frame: Int) {
        position = max(0, min(frame, frameCount))
        inputFrame = channels == nil ? position : max(0, position - groupDelay)
        decoder.seek(toFrame: inputFrame)
        hasBlock = false
        decoderDrained = false
        if inputFrame == 0, let pair = channels {
            // Near the file start the filter reads silence before frame 0, as on a fresh start.
            pair.left.clearHistory()
            pair.right.clearHistory()
        }
    }

    /// Writes up to `frames` processed frames (effect applied, no envelope). Returns fewer frames
    /// when the file ends (or fails) inside the range.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                depth: UnsafePointer<Float>, depthActive: Bool, scratch: FocusVoiceScratch) -> Int {
        var produced = 0
        while produced < frames && position < frameCount {
            do {
                while !hasBlock || position >= blockFirstFrame + hop {
                    try loadNextBlock()
                }
            } catch {
                failure = error
                position = frameCount
                break
            }
            let offset = position - blockFirstFrame
            let count = min(frames - produced, hop - offset, frameCount - position)
            let outLeft = left + produced
            let outRight = right + produced
            if let pair = channels {
                let channelLeft = pair.left
                let channelRight = pair.right
                let dryLeft = channelLeft.alignedDry + offset
                let dryRight = channelRight.alignedDry + offset
                if depthActive, let hz = modulationHz {
                    let modulation = scratch.modulation
                    if let beatMap {
                        beatMap.fill(modulation, firstFrame: position, count: count)
                    } else {
                        fillShape(modulation, hz: hz, firstFrame: position, count: count)
                    }
                    vDSP_vmul(modulation, 1, depth + produced, 1, modulation, 1, vDSP_Length(count))
                    applyEffectWindow(modulation, firstFrame: position, count: count)
                    vDSP_vmul(modulation, 1, channelLeft.bandOutput + offset, 1, scratch.product, 1, vDSP_Length(count))
                    vDSP_vsub(scratch.product, 1, dryLeft, 1, outLeft, 1, vDSP_Length(count))
                    vDSP_vmul(modulation, 1, channelRight.bandOutput + offset, 1, scratch.product, 1, vDSP_Length(count))
                    vDSP_vsub(scratch.product, 1, dryRight, 1, outRight, 1, vDSP_Length(count))
                } else {
                    outLeft.update(from: dryLeft, count: count)
                    outRight.update(from: dryRight, count: count)
                }
            } else {
                outLeft.update(from: plainLeft + offset, count: count)
                outRight.update(from: plainRight + offset, count: count)
            }
            position += count
            produced += count
        }
        return produced
    }

    /// shape = 0.5 - 0.5 cos(2 pi f (t - beatOffset)), t = frame / fs.
    private func fillShape(_ out: UnsafeMutablePointer<Float>, hz: Double, firstFrame: Int, count: Int) {
        let cycles = hz * (Double(firstFrame) / sampleRate - beatOffsetSeconds)
        var phase = Float(2 * Double.pi * (cycles - cycles.rounded(.down)))
        var step = Float(2 * Double.pi * hz / sampleRate)
        vDSP_vramp(&phase, &step, out, 1, vDSP_Length(count))
        var count32 = Int32(count)
        vvcosf(out, out, &count32)
        var scale: Float = -0.5
        var offset: Float = 0.5
        vDSP_vsmsa(out, 1, &scale, &offset, out, 1, vDSP_Length(count))
    }

    /// `effect_window`: raised-cosine ramp (linspace(0, pi, F) incl. both ends) over the first
    /// and last F frames, F = min(round(0.25 fs), frames // 4); the end ramp wins on overlap.
    private func applyEffectWindow(_ values: UnsafeMutablePointer<Float>, firstFrame: Int, count: Int) {
        let fade = effectFadeFrames
        guard fade >= 2 else { return }
        let tailStart = frameCount - fade
        guard firstFrame < fade || firstFrame + count > tailStart else { return }
        let denominator = Double(fade - 1)
        for index in 0..<count {
            let frame = firstFrame + index
            let rampIndex: Int
            if frame >= tailStart {
                rampIndex = frameCount - 1 - frame
            } else if frame < fade {
                rampIndex = frame
            } else {
                continue
            }
            values[index] *= Float(0.5 - 0.5 * cos(Double.pi * Double(rampIndex) / denominator))
        }
    }

    private func loadNextBlock() throws {
        if let pair = channels {
            if hasBlock {
                pair.left.shift()
                pair.right.shift()
            }
            try decodeInput(left: pair.left.inputSlot, right: pair.right.inputSlot)
            pair.left.filter()
            pair.right.filter()
            // Block outputs correspond to file frames [inputFrame - groupDelay, ... + hop).
            blockFirstFrame = inputFrame - groupDelay
        } else {
            try decodeInput(left: plainLeft, right: plainRight)
            blockFirstFrame = inputFrame
        }
        inputFrame += hop
        hasBlock = true
    }

    /// Fills `hop` input frames starting at `inputFrame`, gain applied; zeros past the end.
    private func decodeInput(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) throws {
        var valid = 0
        let wanted = min(hop, max(0, frameCount - inputFrame))
        if wanted > 0 && !decoderDrained {
            valid = try decoder.read(left: left, right: right, frames: wanted)
            if valid < wanted { decoderDrained = true }
        }
        if valid < hop {
            (left + valid).update(repeating: 0, count: hop - valid)
            (right + valid).update(repeating: 0, count: hop - valid)
        }
        if gain != 1 && valid > 0 {
            var scale = gain
            vDSP_vsmul(left, 1, &scale, left, 1, vDSP_Length(valid))
            vDSP_vsmul(right, 1, &scale, right, 1, vDSP_Length(valid))
        }
    }
}

/// The pulse phase of a track whose tempo drifts, taken from its beat map (file time).
///
/// Between beats k and k+1 the phase runs linearly: phase = c * (k + (m - b_k) / (b_{k+1} - b_k)),
/// m and b in output frames, c pulse cycles per beat; before the first and after the last beat
/// the first and last intervals carry on. The shape is 0.5 * (1 - cos(2 pi phase)), so the
/// pulse is at rest on every beat, as the steady grid is at `beatOffsetSeconds + k / bpm`.
struct FocusBeatMap {
    let beats: [Double]
    let cyclesPerBeat: Double

    /// nil unless there are at least two finite, strictly increasing beats and c > 0.
    init?(seconds: [Double]?, cyclesPerBeat: Int, sampleRate: Double) {
        guard let seconds, seconds.count >= 2, cyclesPerBeat > 0, cyclesPerBeat <= 64 else { return nil }
        var frames: [Double] = []
        frames.reserveCapacity(seconds.count)
        for second in seconds {
            guard second.isFinite else { return nil }
            let frame = second * sampleRate
            if let last = frames.last, frame <= last { return nil }
            frames.append(frame)
        }
        beats = frames
        self.cyclesPerBeat = Double(cyclesPerBeat)
    }

    /// Index of the interval used at frame m: -1 before the first beat (it extrapolates interval 0),
    /// count - 1 after the last (it extrapolates the last interval).
    func interval(at frame: Double) -> Int {
        if frame < beats[0] { return -1 }
        var low = 0, high = beats.count - 1
        if frame >= beats[high] { return high }
        while high - low > 1 {
            let middle = (low + high) / 2
            if beats[middle] <= frame { low = middle } else { high = middle }
        }
        return low
    }

    /// Pulse cycles of the interval k: its first beat (in frames) and frames per cycle.
    private func segment(_ k: Int) -> (anchor: Double, beatIndex: Double, framesPerBeat: Double) {
        let last = beats.count - 1
        if k < 0 { return (beats[0], 0, beats[1] - beats[0]) }
        if k >= last { return (beats[last], Double(last), beats[last] - beats[last - 1]) }
        return (beats[k], Double(k), beats[k + 1] - beats[k])
    }

    /// Phase in cycles at output frame m.
    func phase(at frame: Double) -> Double {
        let s = segment(interval(at: frame))
        return cyclesPerBeat * (s.beatIndex + (frame - s.anchor) / s.framesPerBeat)
    }

    /// Writes the pulse shape 0.5 * (1 - cos(2 pi phase)) for `count` frames from `firstFrame`.
    func fill(_ out: UnsafeMutablePointer<Float>, firstFrame: Int, count: Int) {
        var done = 0
        while done < count {
            let frame = Double(firstFrame + done)
            let k = interval(at: frame)
            let s = segment(k)
            // Frames until the next beat (the end of this interval); the extrapolated ends run on.
            var span = count - done
            if k >= 0 && k < beats.count - 1 {
                span = min(span, max(1, Int((beats[k + 1] - frame).rounded(.up))))
            } else if k < 0 {
                span = min(span, max(1, Int((beats[0] - frame).rounded(.up))))
            }
            let cycles = cyclesPerBeat * (s.beatIndex + (frame - s.anchor) / s.framesPerBeat)
            var start = Float(2 * Double.pi * (cycles - cycles.rounded(.down)))
            var step = Float(2 * Double.pi * cyclesPerBeat / s.framesPerBeat)
            let target = out + done
            vDSP_vramp(&start, &step, target, 1, vDSP_Length(span))
            var count32 = Int32(span)
            vvcosf(target, target, &count32)
            var scale: Float = -0.5
            var offset: Float = 0.5
            vDSP_vsmsa(target, 1, &scale, &offset, target, 1, vDSP_Length(span))
            done += span
        }
    }
}

/// One play of a track, on its own timeline of output frames (`position`, `length`).
///
/// Without a loop plan (or with no repeats) the timeline is the file. With repeats it runs the
/// file up to the first seam, then `repeats` passes of the loop region, each joined by an
/// equal-power seam crossfade between two read heads, then the rest of the file. The core only
/// sees one longer track: one start, one end, `framesPlayed` covering every pass.
final class FocusTrackVoice {
    let track: EngineTrack
    let serial: Int
    let sampleRate: Double
    /// The file's length in output frames.
    let fileFrameCount: Int
    /// This play's length: the file plus `repeats` loop passes.
    private(set) var length: Int
    let startFrame: Int
    private(set) var position: Int
    let loop: FocusLoopPlan?
    /// Loop passes this play will add (never fewer than the seams already begun).
    private(set) var repeats = 0
    /// Seams whose crossfade has begun, the one in progress included.
    private(set) var seamsBegun = 0
    var envelope = FocusVoiceEnvelope()
    var hasStartedOutput = false
    /// Output-stream frame just after the last frame this voice produced.
    var outputEnd: Int64 = 0
    /// Error that ended the voice early (decoding failure).
    private(set) var failure: Error?
    var failureReported = false

    var framesPlayed: Int { position - startFrame }
    var remainingFrames: Int { max(0, length - position) }
    var isFinished: Bool { position >= length }

    private let fir: FocusBandFIR
    private var head: FocusReadHead
    /// The second read position a seam fades in; idle between seams.
    private var spare: FocusReadHead?
    private var inSeam = false

    /// `startFrame` and `loopTarget` are timeline frames; `loopTarget` 0 plays the file once.
    init(track: EngineTrack, serial: Int, fir: FocusBandFIR, startFrame requestedStart: Int = 0,
         loopTarget: Int = 0, seamFrames: Int = 0) throws {
        self.track = track
        self.serial = serial
        self.fir = fir
        sampleRate = fir.sampleRate
        let decoder = try FocusTrackDecoder(url: track.url, outputSampleRate: fir.sampleRate, chunkFrames: fir.hop)
        fileFrameCount = decoder.frameCount
        loop = FocusLoopPlan(track: track, fileFrames: fileFrameCount, sampleRate: fir.sampleRate, seamFrames: seamFrames)

        let requested = max(0, requestedStart)
        var begun = 0
        var repeats = 0
        if let loop {
            // A start inside the loop (a restart where playback was heard, a seek) keeps that pass.
            // Past the last planned seam the timeline is the file playing out to its end, not
            // another pass, as long as the start lies inside the planned play.
            let planned = loop.repeats(toReach: loopTarget, fileFrames: fileFrameCount)
            begun = loop.seamsBegun(by: requested)
            if begun > planned && requested < fileFrameCount + planned * loop.period { begun = planned }
            repeats = max(planned, begun)
        }
        let length = fileFrameCount + repeats * (loop?.period ?? 0)
        self.length = length
        self.repeats = repeats
        seamsBegun = begun
        startFrame = min(requested, length)
        position = startFrame
        // A start inside a seam plays only its incoming side.
        head = FocusReadHead(decoder: decoder, track: track, fir: fir,
                             startFrame: startFrame - begun * (loop?.period ?? 0))
        if repeats > begun && !prepareSpare() {
            self.repeats = begun
            self.length = fileFrameCount + begun * (loop?.period ?? 0)
        }
    }

    /// Re-plans the remaining passes for a new target; seams already begun stay, and no seam is
    /// added once the point where the next one would begin has passed.
    func setLoopTarget(_ target: Int) {
        guard let loop, failure == nil, !isFinished else { return }
        var wanted = max(loop.repeats(toReach: target, fileFrames: fileFrameCount), seamsBegun)
        if wanted > seamsBegun && position > loop.seamBegin(seamsBegun + 1) { wanted = seamsBegun }
        if wanted > seamsBegun && !prepareSpare() { wanted = seamsBegun }
        repeats = wanted
        length = fileFrameCount + wanted * loop.period
    }

    /// Writes up to `frames` processed frames (effect applied, crossfade envelope not applied).
    /// Returns fewer frames when the play ends (or fails) inside the range.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                depth: UnsafePointer<Float>, depthActive: Bool, scratch: FocusVoiceScratch) -> Int {
        guard let loop, repeats > 0 else {
            // One pass through the file, exactly as without a loop.
            let produced = head.render(left: left, right: right, frames: frames, depth: depth,
                                       depthActive: depthActive, scratch: scratch)
            position += produced
            if let error = head.failure { fail(error) }
            return produced
        }
        var produced = 0
        while produced < frames && position < length {
            let wanted = frames - produced
            if inSeam {
                let begin = loop.seamBegin(seamsBegun)
                let count = min(wanted, begin + loop.seam - position)
                guard let incoming = spare else {
                    fail(FocusAudioEngineError.decodingFailed(url: track.url, reason: "loop seam without a second reader"))
                    break
                }
                let outgoing = head.render(left: left + produced, right: right + produced, frames: count,
                                           depth: depth + produced, depthActive: depthActive, scratch: scratch)
                let entering = incoming.render(left: scratch.seamLeft, right: scratch.seamRight, frames: count,
                                               depth: depth + produced, depthActive: depthActive, scratch: scratch)
                guard outgoing == count, entering == count else {
                    fail(head.failure ?? incoming.failure
                         ?? FocusAudioEngineError.decodingFailed(url: track.url, reason: "loop seam ran past the end of the file"))
                    break
                }
                mixSeam(left: left + produced, right: right + produced, count: count,
                        offset: position - begin, loop: loop, scratch: scratch)
                position += count
                produced += count
                if position == begin + loop.seam {
                    spare = head
                    head = incoming
                    inSeam = false
                }
            } else {
                var count = wanted
                if seamsBegun < repeats {
                    let untilSeam = loop.seamBegin(seamsBegun + 1) - position
                    if untilSeam < 0 {
                        // Never planned that way; play out rather than stall the render thread.
                        repeats = seamsBegun
                        length = fileFrameCount + repeats * loop.period
                        continue
                    }
                    count = min(count, untilSeam)
                }
                if count > 0 {
                    let got = head.render(left: left + produced, right: right + produced, frames: count,
                                          depth: depth + produced, depthActive: depthActive, scratch: scratch)
                    position += got
                    produced += got
                    if got < count {
                        if let error = head.failure {
                            fail(error)
                        } else if position < length {
                            fail(FocusAudioEngineError.decodingFailed(url: track.url, reason: "file ended before its loop"))
                        }
                        break
                    }
                }
                if seamsBegun < repeats && position == loop.seamBegin(seamsBegun + 1) {
                    guard let incoming = spare else {
                        fail(FocusAudioEngineError.decodingFailed(url: track.url, reason: "loop seam without a second reader"))
                        break
                    }
                    incoming.seek(toFrame: loop.start - loop.halfSeam)
                    seamsBegun += 1
                    inSeam = true
                }
            }
        }
        return produced
    }

    /// The seam law of `FocusLoopPlan` applied to the outgoing side (in `left`/`right`) and the
    /// incoming side (in the scratch), `offset` frames into the seam.
    private func mixSeam(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int,
                         offset: Int, loop: FocusLoopPlan, scratch: FocusVoiceScratch) {
        let n = vDSP_Length(count)
        var count32 = Int32(count)
        var first = Float(Double(offset) / Double(loop.seam) * Double.pi / 2)
        var step = Float(Double.pi / 2 / Double(loop.seam))
        vDSP_vramp(&first, &step, scratch.seamOut, 1, n)
        vvsinf(scratch.seamIn, scratch.seamOut, &count32)
        vvcosf(scratch.seamOut, scratch.seamOut, &count32)
        if loop.correlation != 0 {
            // 1 / sqrt(1 + 2 r cos sin) on both gains.
            var twiceR = 2 * loop.correlation
            var one: Float = 1
            vDSP_vmul(scratch.seamIn, 1, scratch.seamOut, 1, scratch.seamNorm, 1, n)
            vDSP_vsmsa(scratch.seamNorm, 1, &twiceR, &one, scratch.seamNorm, 1, n)
            vvrsqrtf(scratch.seamNorm, scratch.seamNorm, &count32)
            vDSP_vmul(scratch.seamIn, 1, scratch.seamNorm, 1, scratch.seamIn, 1, n)
            vDSP_vmul(scratch.seamOut, 1, scratch.seamNorm, 1, scratch.seamOut, 1, n)
        }
        vDSP_vmul(left, 1, scratch.seamOut, 1, left, 1, n)
        vDSP_vma(scratch.seamLeft, 1, scratch.seamIn, 1, left, 1, left, 1, n)
        vDSP_vmul(right, 1, scratch.seamOut, 1, right, 1, n)
        vDSP_vma(scratch.seamRight, 1, scratch.seamIn, 1, right, 1, right, 1, n)
    }

    /// Opens the second reader the seams need (worker thread, outside the audio callback).
    private func prepareSpare() -> Bool {
        if spare != nil { return true }
        guard let loop,
              let decoder = try? FocusTrackDecoder(url: track.url, outputSampleRate: fir.sampleRate, chunkFrames: fir.hop),
              decoder.frameCount == fileFrameCount else { return false }
        spare = FocusReadHead(decoder: decoder, track: track, fir: fir, startFrame: loop.start - loop.halfSeam)
        return true
    }

    private func fail(_ error: Error) {
        failure = error
        position = length
    }
}
