import Accelerate
import Foundation

/// Background noise played under the music.
public enum FocusNoiseKind: Int, CaseIterable, Sendable {
    case off = 0, rain, brown, pink, white, ocean, stream

    /// Played from a looped nature recording (`FocusNoiseRecording`); the others are generated.
    public var isRecording: Bool { self == .rain || self == .ocean || self == .stream }
}

/// Live stereo noise for `FocusRenderCore`: brown, pink and white. It is generated sample by
/// sample, so it never loops. (Rain, ocean and stream are recordings: `FocusNoiseRecording`.)
///
/// At gain 1 each kind measures about -18 LUFS, the library's loudness target, so the level
/// slider is relative to the music (`gain(forLevel:)`). Not thread-safe: one thread drives it.
final class FocusNoiseGenerator {
    /// Slider value 0...1 to a linear gain: 0 is silent, 0.5 sits 14 dB under the music, 1 sits 2 dB under it.
    static func gain(forLevel level: Float) -> Float {
        guard level.isFinite, level > 0.001 else { return 0 }
        return powf(10, (-26 + 24 * min(level, 1)) / 20)
    }

    /// Output scale that brings each kind to about -18 LUFS at gain 1 (measured with ffmpeg ebur128).
    static let brownCalibration: Float = 4.315
    static let pinkCalibration: Float = 0.4786
    static let whiteCalibration: Float = 0.1514

    private let sampleRate: Float
    private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15

    init(sampleRate: Double) {
        let rate = Float(sampleRate)
        self.sampleRate = rate
        brownPole = expf(-2 * .pi * 50 / rate)
        dcPole = 1 / (1 + 2 * .pi * 20 / rate)
    }

    /// Adds `count` frames of `kind` into the buffers, each frame scaled by `gains[i]`.
    /// Recorded kinds add nothing here.
    func render(_ kind: FocusNoiseKind, addingInto left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>,
                gains: UnsafePointer<Float>, count: Int) {
        switch kind {
        case .off, .rain, .ocean, .stream: return
        case .brown: renderBrown(left, right, gains, count)
        case .pink: renderPink(left, right, gains, count)
        case .white: renderWhite(left, right, gains, count)
        }
    }

    // MARK: - Pink and white noise

    // Pink: Paul Kellet's refined filter (equal energy per octave), the two channels sharing most
    // of the noise like brown. White: flat noise with a gentle roll-off above 9 kHz so it hisses
    // less, independent per channel.
    private var pinkCommon = PinkRefined(), pinkL = PinkRefined(), pinkR = PinkRefined()
    private var whiteLowL: Float = 0, whiteLowR: Float = 0
    private lazy var whitePole: Float = expf(-2 * .pi * 9000 / sampleRate)

    private struct PinkRefined {
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0

        @inline(__always) mutating func next(_ white: Float) -> Float {
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            b3 = 0.86650 * b3 + white * 0.3104856
            b4 = 0.55000 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.0168980
            let out = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
            b6 = white * 0.115926
            return out * 0.11
        }
    }

    private func renderPink(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>,
                            _ gains: UnsafePointer<Float>, _ count: Int) {
        let scale = Self.pinkCalibration
        for index in 0..<count {
            let common = pinkCommon.next(uniform())
            let l = 0.8 * common + 0.6 * pinkL.next(uniform())
            let r = 0.8 * common + 0.6 * pinkR.next(uniform())
            let gain = gains[index] * scale
            left[index] += l * gain
            right[index] += r * gain
        }
    }

    private func renderWhite(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>,
                             _ gains: UnsafePointer<Float>, _ count: Int) {
        let scale = Self.whiteCalibration
        let pole = whitePole
        for index in 0..<count {
            whiteLowL = pole * whiteLowL + (1 - pole) * uniform()
            whiteLowR = pole * whiteLowR + (1 - pole) * uniform()
            let gain = gains[index] * scale
            left[index] += whiteLowL * gain
            right[index] += whiteLowR * gain
        }
    }

    // MARK: - Random numbers (xorshift64*)

    @inline(__always) private func next() -> UInt64 {
        seed ^= seed >> 12
        seed ^= seed << 25
        seed ^= seed >> 27
        return seed &* 2_685_821_657_736_338_717
    }

    /// Uniform in [-1, 1).
    @inline(__always) private func uniform() -> Float {
        Float(Int32(truncatingIfNeeded: Int64(bitPattern: next()) >> 40)) / 8_388_608
    }

    // MARK: - Brown noise

    // White noise through a one-pole low-pass at 50 Hz (falls 6 dB per octave above it), then a
    // 20 Hz high-pass so nothing drifts below hearing. The two channels share most of the noise
    // (correlation about 0.6) so it stays wide without pulling on the ears.
    private let brownPole: Float
    private let dcPole: Float
    private var brownCommon: Float = 0
    private var brownL: Float = 0
    private var brownR: Float = 0
    private var dcInL: Float = 0, dcOutL: Float = 0, dcInR: Float = 0, dcOutR: Float = 0

    private func renderBrown(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>,
                             _ gains: UnsafePointer<Float>, _ count: Int) {
        let pole = brownPole
        let input = 1 - pole
        let scale = Self.brownCalibration
        for index in 0..<count {
            brownCommon = pole * brownCommon + input * uniform()
            brownL = pole * brownL + input * uniform()
            brownR = pole * brownR + input * uniform()
            let rawL = 0.8 * brownCommon + 0.6 * brownL
            let rawR = 0.8 * brownCommon + 0.6 * brownR
            dcOutL = dcPole * (dcOutL + rawL - dcInL)
            dcInL = rawL
            dcOutR = dcPole * (dcOutR + rawR - dcInR)
            dcInR = rawR
            let gain = gains[index] * scale
            left[index] += dcOutL * gain
            right[index] += dcOutR * gain
        }
    }
}

/// A nature recording (rain, ocean, stream) played as an endless loop under the music.
///
/// Each loop file has its seam baked in, so its last frame flows into its first, and is stored
/// at the engine rate: wrapping is a plain seek to frame 0, sample-exact,
/// with no converter state in between. Each file measures -18 LUFS, so gain 1 sits where the
/// generated kinds do. A play starts at a random point so the same seconds do not open every
/// time. Worker thread only (it reads the file).
final class FocusNoiseRecording {
    let kind: FocusNoiseKind
    /// Loop length in output frames.
    let frameCount: Int
    /// A read failed: the recording stays silent from then on.
    private(set) var failed = false
    private(set) var position: Int

    private static let chunk = 1024
    private let decoder: FocusTrackDecoder
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>

    /// nil when the file cannot be opened or is shorter than a second. `startFrame` nil = random.
    init?(kind: FocusNoiseKind, url: URL, sampleRate: Double, startFrame: Int? = nil) {
        guard let decoder = try? FocusTrackDecoder(url: url, outputSampleRate: sampleRate, chunkFrames: Self.chunk),
              decoder.frameCount >= Int(sampleRate) else { return nil }
        self.kind = kind
        self.decoder = decoder
        frameCount = decoder.frameCount
        left = .allocate(capacity: Self.chunk)
        left.initialize(repeating: 0, count: Self.chunk)
        right = .allocate(capacity: Self.chunk)
        right.initialize(repeating: 0, count: Self.chunk)
        let start = min(max(startFrame ?? Int.random(in: 0..<decoder.frameCount), 0), decoder.frameCount - 1)
        position = start
        if start > 0 { decoder.seek(toFrame: start) }
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// Adds `count` frames into the buffers, frame i scaled by `gains[i]`.
    func render(addingInto outLeft: UnsafeMutablePointer<Float>, _ outRight: UnsafeMutablePointer<Float>,
                gains: UnsafePointer<Float>, count: Int) {
        var done = 0
        var emptyReads = 0
        while done < count && !failed {
            let wanted = min(count - done, Self.chunk, frameCount - position)
            let got: Int
            do {
                got = try decoder.read(left: left, right: right, frames: wanted)
            } catch {
                failed = true
                break
            }
            if got > 0 {
                let n = vDSP_Length(got)
                vDSP_vma(left, 1, gains + done, 1, outLeft + done, 1, outLeft + done, 1, n)
                vDSP_vma(right, 1, gains + done, 1, outRight + done, 1, outRight + done, 1, n)
                position += got
                done += got
                emptyReads = 0
            } else {
                emptyReads += 1
                if emptyReads > 1 { failed = true }
            }
            if position >= frameCount || got < wanted {
                // The end of the loop flows into its first frame.
                decoder.seek(toFrame: 0)
                position = 0
            }
        }
    }
}
