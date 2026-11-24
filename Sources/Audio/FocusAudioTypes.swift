import Foundation

/// One local music file in the play queue, with the metadata the focus effect needs.
public struct EngineTrack: Equatable, Sendable {
    public let id: String
    public let url: URL
    /// Loudness-normalization gain, applied before the effect.
    public let gainDB: Float
    /// Amplitude-modulation rate in Hz. `nil` means the effect is never applied to this track.
    public let modulationHz: Double?
    /// Beat-grid phase anchor in seconds of track time (0 if unknown).
    public let beatOffsetSeconds: Double
    /// The repeatable middle, in seconds of track time (both nil: the track plays once).
    public let loopStartSeconds: Double?
    public let loopEndSeconds: Double?
    /// How alike the audio on the two sides of the loop seam is (-1...1, measured by the library
    /// build). The seam crossfade keeps its power flat for it; 0 gives plain cos/sin gains.
    public let loopSeamCorrelation: Double
    /// Beat times in seconds of file time for a track whose tempo drifts: the pulse then follows
    /// them, `pulseCyclesPerBeat` cycles per beat (`FocusBeatMap`). nil: a steady pulse at
    /// `modulationHz` from `beatOffsetSeconds`.
    public let beatTimes: [Double]?
    public let pulseCyclesPerBeat: Int

    public init(id: String, url: URL, gainDB: Float, modulationHz: Double?, beatOffsetSeconds: Double,
                loopStartSeconds: Double? = nil, loopEndSeconds: Double? = nil, loopSeamCorrelation: Double = 0,
                beatTimes: [Double]? = nil, pulseCyclesPerBeat: Int = 0) {
        self.id = id
        self.url = url
        self.gainDB = gainDB
        self.modulationHz = modulationHz
        self.beatOffsetSeconds = beatOffsetSeconds
        self.loopStartSeconds = loopStartSeconds
        self.loopEndSeconds = loopEndSeconds
        self.loopSeamCorrelation = loopSeamCorrelation
        self.beatTimes = beatTimes
        self.pulseCyclesPerBeat = pulseCyclesPerBeat
    }

    /// How long one play of this track lasts when tracks play for at least `minimumSeconds`:
    /// the file plus whole loop passes, as the engine plans it. `fileSeconds` is the file's length.
    public func playSeconds(fileSeconds: Double, minimumSeconds: Double) -> Double {
        let rate = FocusAudioFormat.sampleRate
        guard fileSeconds.isFinite, fileSeconds > 0, minimumSeconds.isFinite else { return max(0, fileSeconds) }
        let fileFrames = Int((fileSeconds * rate).rounded())
        let seam = 2 * Int((FocusRenderCore.loopSeamSeconds / 2 * rate).rounded())
        guard let loop = FocusLoopPlan(track: self, fileFrames: fileFrames, sampleRate: rate, seamFrames: seam) else {
            return fileSeconds
        }
        let target = Int((min(max(minimumSeconds, 0), 86_400) * rate).rounded())
        let repeats = loop.repeats(toReach: target, fileFrames: fileFrames)
        return Double(fileFrames + repeats * loop.period) / rate
    }
}

/// Strength of the beat-synced amplitude modulation.
public enum EffectLevel: Int, CaseIterable, Sendable {
    case off = 0, low, medium, high

    /// Peak attenuation of the selected band (0 = no effect).
    public var depth: Float {
        switch self {
        case .off: return 0
        case .low: return 0.18
        case .medium: return 0.36
        case .high: return 0.54
        }
    }
}

/// All calls arrive on the main thread, asynchronously (never from inside an engine method).
public protocol FocusAudioEngineDelegate: AnyObject {
    /// Asked about 10 s before the automatic crossfade needs the next track, and again
    /// (with the failed track as `current`) when a track cannot be opened.
    func audioEngineNextTrack(_ engine: FocusAudioEngine, after current: EngineTrack) -> EngineTrack?
    /// `start`/`skip` targets are announced right away; automatic successors when their
    /// crossfade becomes audible.
    func audioEngine(_ engine: FocusAudioEngine, didBecomeCurrent track: EngineTrack)
    /// Sent when the track has gone silent. `listenedSeconds` counts the frames of this
    /// track that were played, fades and loop passes included. `stop()` does not send it.
    func audioEngine(_ engine: FocusAudioEngine, didFinish track: EngineTrack, listenedSeconds: Double, skipped: Bool)
    func audioEngine(_ engine: FocusAudioEngine, didFail error: Error, track: EngineTrack?)
    /// The output device in use disappeared while `pausesWhenOutputLost` was on, so the engine
    /// paused itself instead of carrying on through another output. `uid` names that device.
    func audioEngine(_ engine: FocusAudioEngine, didPauseForLostOutput uid: String)
}

public extension FocusAudioEngineDelegate {
    func audioEngine(_ engine: FocusAudioEngine, didPauseForLostOutput uid: String) {}
}

public enum FocusAudioEngineError: Error, LocalizedError, CustomStringConvertible {
    case cannotOpenFile(url: URL, reason: String)
    case unsupportedAudio(url: URL, reason: String)
    case decodingFailed(url: URL, reason: String)
    case outputUnavailable(reason: String)

    public var description: String {
        switch self {
        case .cannotOpenFile(let url, let reason):
            return "Cannot open \(url.lastPathComponent): \(reason)"
        case .unsupportedAudio(let url, let reason):
            return "Unsupported audio in \(url.lastPathComponent): \(reason)"
        case .decodingFailed(let url, let reason):
            return "Decoding \(url.lastPathComponent) failed: \(reason)"
        case .outputUnavailable(let reason):
            return "Audio output unavailable: \(reason)"
        }
    }

    public var errorDescription: String? { description }
}

/// The engine renders and mixes at one fixed rate; AVAudioEngine's mixer converts to the device rate.
enum FocusAudioFormat {
    static let sampleRate: Double = 48_000
}
