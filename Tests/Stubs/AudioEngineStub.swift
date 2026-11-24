import Foundation

// Compile-only stand-in for Sources/Audio while the real engine is being built.
public struct EngineTrack: Equatable, Sendable {
    public let id: String
    public let url: URL
    public let gainDB: Float
    public let modulationHz: Double?
    public let beatOffsetSeconds: Double
    public let loopStartSeconds: Double?
    public let loopEndSeconds: Double?
    public let loopSeamCorrelation: Double
    public let beatTimes: [Double]?
    public let pulseCyclesPerBeat: Int
    public init(id: String, url: URL, gainDB: Float, modulationHz: Double?, beatOffsetSeconds: Double,
                loopStartSeconds: Double? = nil, loopEndSeconds: Double? = nil, loopSeamCorrelation: Double = 0,
                beatTimes: [Double]? = nil, pulseCyclesPerBeat: Int = 0) {
        self.id = id; self.url = url; self.gainDB = gainDB; self.modulationHz = modulationHz; self.beatOffsetSeconds = beatOffsetSeconds
        self.loopStartSeconds = loopStartSeconds; self.loopEndSeconds = loopEndSeconds; self.loopSeamCorrelation = loopSeamCorrelation
        self.beatTimes = beatTimes; self.pulseCyclesPerBeat = pulseCyclesPerBeat
    }
    public func playSeconds(fileSeconds: Double, minimumSeconds: Double) -> Double {
        guard let start = loopStartSeconds, let end = loopEndSeconds, end - start >= 2, minimumSeconds > fileSeconds else { return fileSeconds }
        return fileSeconds + ((minimumSeconds - fileSeconds) / (end - start)).rounded(.up) * (end - start)
    }
}

public enum EffectLevel: Int, CaseIterable, Sendable {
    case off = 0, low, medium, high
    public var depth: Float { [0, 0.18, 0.36, 0.54][rawValue] }
}

public enum FocusNoiseKind: Int, CaseIterable, Sendable {
    case off = 0, rain, brown, pink, white, ocean, stream
    public var isRecording: Bool { self == .rain || self == .ocean || self == .stream }
}

public protocol FocusAudioEngineDelegate: AnyObject {
    func audioEngineNextTrack(_ engine: FocusAudioEngine, after current: EngineTrack) -> EngineTrack?
    func audioEngine(_ engine: FocusAudioEngine, didBecomeCurrent track: EngineTrack)
    func audioEngine(_ engine: FocusAudioEngine, didFinish track: EngineTrack, listenedSeconds: Double, skipped: Bool)
    func audioEngine(_ engine: FocusAudioEngine, didFail error: Error, track: EngineTrack?)
    func audioEngine(_ engine: FocusAudioEngine, didPauseForLostOutput uid: String)
}

public extension FocusAudioEngineDelegate {
    func audioEngine(_ engine: FocusAudioEngine, didPauseForLostOutput uid: String) {}
}

public final class FocusAudioEngine {
    public weak var delegate: FocusAudioEngineDelegate?
    public init() {}
    public var crossfadeSeconds: Double = 8
    public var minimumTrackSeconds: Double = 1800
    public private(set) var isPlaying = false
    public private(set) var currentTrack: EngineTrack?
    public var currentTime: TimeInterval { 0 }
    public var underrunCount: Int { 0 }
    public var configurationRestartCount: Int { 0 }
    public func start(with track: EngineTrack, fadeIn: TimeInterval) { currentTrack = track; isPlaying = true }
    public func start(with track: EngineTrack, fadeIn: TimeInterval, startTime: TimeInterval) { currentTrack = track; isPlaying = true }
    public func pause(fade: TimeInterval, completion: (() -> Void)?) { isPlaying = false; completion?() }
    public func resume(fade: TimeInterval) { isPlaying = true }
    public func stop() { isPlaying = false }
    public func skip(to track: EngineTrack, crossfade: TimeInterval) { currentTrack = track }
    public func setEffectLevel(_ level: EffectLevel) {}
    public func setVolume(_ volume: Float) {}
    public func setDuck(_ factor: Float, ramp: TimeInterval) {}
    public func setNoise(_ kind: FocusNoiseKind, level: Float) {}
    func simulateOutputLossForTesting() {}
    public var pausesWhenOutputLost = false
    public var noiseRecordings: [FocusNoiseKind: URL] = [:]
    public private(set) var lostOutputUID: String?
}
