import Accelerate
import AVFoundation
import Foundation

// Checks for Sources/Audio. Run with Scripts/check-audio-engine.sh.
// Offline checks drive FocusRenderCore directly (deterministic). The real-time check runs the
// actual AVAudioEngine with the mixer output and the engine volume at 0 (nothing audible).

// MARK: - Reporting

final class CheckLog {
    private(set) var outcomes: [(name: String, passed: Bool)] = []

    func section(_ title: String) {
        print("\n=== \(title)")
    }

    func note(_ text: String) {
        print("      \(text)")
    }

    func expect(_ name: String, _ passed: Bool, _ detail: String) {
        print("  [\(passed ? "PASS" : "FAIL")] \(name): \(detail)")
        outcomes.append((name, passed))
    }
}

func f(_ value: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", value) }
func sci(_ value: Double) -> String { String(format: "%.2e", value) }
func amplitudeDB(_ ratio: Double) -> Double { 20 * log10(ratio) }
func powerDB(_ ratio: Double) -> Double { 10 * log10(ratio) }

// MARK: - Audio data

struct Stereo {
    var left: [Float]
    var right: [Float]
    var count: Int { left.count }

    init(left: [Float], right: [Float]) {
        self.left = left
        self.right = right
    }

    init(reserving capacity: Int) {
        left = []
        right = []
        left.reserveCapacity(capacity)
        right.reserveCapacity(capacity)
    }

    func slice(_ range: Range<Int>) -> Stereo {
        Stereo(left: Array(left[range]), right: Array(right[range]))
    }

    func scaled(_ gain: Float) -> Stereo {
        Stereo(left: left.map { $0 * gain }, right: right.map { $0 * gain })
    }

    var doubles: (left: [Double], right: [Double]) {
        (left.map(Double.init), right.map(Double.init))
    }
}

enum AudioIO {
    static func read(_ url: URL, start: Int = 0, frames: Int? = nil) throws -> Stereo {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(file.length)
        let first = min(max(0, start), total)
        let count = min(frames ?? (total - first), total - first)
        file.framePosition = AVAudioFramePosition(first)
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                       frameCapacity: AVAudioFrameCount(count)) else {
            return Stereo(left: [], right: [])
        }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        let n = Int(buffer.frameLength)
        let channels = buffer.floatChannelData!
        let rightIndex = buffer.format.channelCount > 1 ? 1 : 0
        return Stereo(left: Array(UnsafeBufferPointer(start: channels[0], count: n)),
                      right: Array(UnsafeBufferPointer(start: channels[rightIndex], count: n)))
    }

    static func frameCount(_ url: URL) throws -> Int {
        Int(try AVAudioFile(forReading: url).length)
    }

    static func writeFloatWAV(_ url: URL, channels: [[Float]], sampleRate: Double) throws {
        let frames = channels[0].count
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels.count,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { buffer.floatChannelData![index].update(from: $0.baseAddress!, count: frames) }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }
}

func maxAbsDifference(_ a: Stereo, _ b: Stereo, range: Range<Int>? = nil) -> Double {
    let span = range ?? 0..<min(a.count, b.count)
    var worst: Float = 0
    for index in span {
        worst = max(worst, abs(a.left[index] - b.left[index]), abs(a.right[index] - b.right[index]))
    }
    return Double(worst)
}

func peak(_ audio: Stereo) -> Double {
    var value: Float = 0
    for index in 0..<audio.count { value = max(value, abs(audio.left[index]), abs(audio.right[index])) }
    return Double(value)
}

func allFinite(_ audio: Stereo) -> Bool {
    audio.left.allSatisfy { $0.isFinite } && audio.right.allSatisfy { $0.isFinite }
}

func maxJump(_ audio: Stereo, range: Range<Int>) -> Double {
    var worst: Float = 0
    for index in range where index > 0 {
        worst = max(worst, abs(audio.left[index] - audio.left[index - 1]), abs(audio.right[index] - audio.right[index - 1]))
    }
    return Double(worst)
}

func rms(_ audio: Stereo, range: Range<Int>) -> Double {
    var sum = 0.0
    for index in range {
        sum += Double(audio.left[index]) * Double(audio.left[index]) + Double(audio.right[index]) * Double(audio.right[index])
    }
    return (sum / Double(2 * range.count)).squareRoot()
}

struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-300)
        let u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

// MARK: - Spectral analysis (Double precision)

enum Spectral {
    private static var setups: [Int: FFTSetupD] = [:]

    static func nextPowerOfTwo(_ n: Int) -> Int {
        var size = 1
        while size < n { size <<= 1 }
        return size
    }

    /// In-place complex FFT; forward is the plain DFT, inverse is unnormalized.
    static func fft(_ real: inout [Double], _ imag: inout [Double], inverse: Bool) {
        let log2n = real.count.trailingZeroBitCount
        let setup: FFTSetupD
        if let cached = setups[log2n] {
            setup = cached
        } else {
            setup = vDSP_create_fftsetupD(vDSP_Length(log2n), FFTRadix(kFFTRadix2))!
            setups[log2n] = setup
        }
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPDoubleSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zipD(setup, &split, 1, vDSP_Length(log2n),
                              FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward))
            }
        }
    }

    /// Zero-phase `_band_mask` in the frequency domain with 1 s reflection padding, like
    /// `split_band` in Scripts/focus_audio.py (independent of the engine's FIR).
    static func idealBand(_ x: [Double], sampleRate: Double) -> [Double] {
        let n = x.count
        let pad = min(Int(sampleRate), n - 1)
        var padded: [Double] = []
        padded.reserveCapacity(n + 2 * pad)
        for index in stride(from: pad, through: 1, by: -1) { padded.append(x[index]) }
        padded.append(contentsOf: x)
        for index in 1...pad { padded.append(x[n - 1 - index]) }
        let size = nextPowerOfTwo(padded.count)
        var real = padded + [Double](repeating: 0, count: size - padded.count)
        var imag = [Double](repeating: 0, count: size)
        fft(&real, &imag, inverse: false)
        for k in 0..<size {
            let bin = k <= size / 2 ? k : size - k
            let gain = FocusBandMask.gain(atHz: Double(bin) * sampleRate / Double(size))
            real[k] *= gain
            imag[k] *= gain
        }
        fft(&real, &imag, inverse: true)
        let scale = 1.0 / Double(size)
        return (0..<n).map { real[pad + $0] * scale }
    }

    static func analyticEnvelope(_ x: [Double]) -> [Double] {
        let n = x.count
        let size = nextPowerOfTwo(n)
        var real = x + [Double](repeating: 0, count: size - n)
        var imag = [Double](repeating: 0, count: size)
        fft(&real, &imag, inverse: false)
        for k in 1..<(size / 2) {
            real[k] *= 2
            imag[k] *= 2
        }
        for k in (size / 2 + 1)..<size {
            real[k] = 0
            imag[k] = 0
        }
        fft(&real, &imag, inverse: true)
        let scale = 1.0 / Double(size)
        return (0..<n).map { (real[$0] * real[$0] + imag[$0] * imag[$0]).squareRoot() * scale }
    }

    struct EnvelopeMetrics {
        let targetAmplitude: Double
        let targetToNearbyMedianDB: Double
        let peakHz: Double
        let modulationIndex: Double
    }

    /// Like `modulation_metrics`: Hilbert envelopes of the selected band, channel-RMS, 1 kHz,
    /// mean removed, Hann window; amplitude spectrum on a 0.05 Hz grid over 8-32 Hz.
    static func envelopeMetrics(bandLeft: [Double], bandRight: [Double], sampleRate: Double,
                                range: Range<Int>, targetHz: Double) -> EnvelopeMetrics {
        let envelopeLeft = analyticEnvelope(bandLeft)
        let envelopeRight = analyticEnvelope(bandRight)
        let decimation = Int(sampleRate / 1000)
        var envelope: [Double] = []
        var index = range.lowerBound
        while index + decimation <= range.upperBound {
            var sum = 0.0
            for j in index..<(index + decimation) {
                sum += (0.5 * (envelopeLeft[j] * envelopeLeft[j] + envelopeRight[j] * envelopeRight[j])).squareRoot()
            }
            envelope.append(sum / Double(decimation))
            index += decimation
        }
        let count = envelope.count
        let mean = envelope.reduce(0, +) / Double(count)
        var weighted = [Double](repeating: 0, count: count)
        var windowSum = 0.0
        for k in 0..<count {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(count - 1))
            weighted[k] = (envelope[k] - mean) * w
            windowSum += w
        }
        func amplitude(_ hz: Double) -> Double {
            let omega = 2 * Double.pi * hz / 1000
            var re = 0.0
            var im = 0.0
            for k in 0..<count {
                re += weighted[k] * cos(omega * Double(k))
                im -= weighted[k] * sin(omega * Double(k))
            }
            return 2 * (re * re + im * im).squareRoot() / windowSum
        }
        var grid: [(hz: Double, amplitude: Double)] = []
        var hz = 8.0
        while hz <= 32.0001 {
            grid.append((hz, amplitude(hz)))
            hz += 0.05
        }
        let target = amplitude(targetHz)
        let nearby = grid.filter { $0.hz >= 12 && $0.hz <= 20 && abs($0.hz - 16) > 1 }.map(\.amplitude).sorted()
        let median = nearby[nearby.count / 2]
        let peakHz = grid.max { $0.amplitude < $1.amplitude }!.hz
        return EnvelopeMetrics(targetAmplitude: target, targetToNearbyMedianDB: amplitudeDB(target / median),
                               peakHz: peakHz, modulationIndex: target / mean)
    }

    struct BandEnergies {
        let below150: Double
        let above1200: Double
        let selected: Double
        let total: Double
    }

    /// Hann-windowed power spectrum sums (positive frequencies) of one channel.
    static func energies(_ x: [Double], sampleRate: Double) -> BandEnergies {
        let n = x.count
        let size = nextPowerOfTwo(n)
        var real = [Double](repeating: 0, count: size)
        var imag = [Double](repeating: 0, count: size)
        for index in 0..<n {
            real[index] = x[index] * (0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(n - 1)))
        }
        fft(&real, &imag, inverse: false)
        var low = 0.0, high = 0.0, selected = 0.0, total = 0.0
        for k in 0...(size / 2) {
            let hz = Double(k) * sampleRate / Double(size)
            let power = real[k] * real[k] + imag[k] * imag[k]
            if hz < 150 { low += power }
            if hz > 1200 { high += power }
            if hz >= 200 && hz <= 1000 { selected += power }
            total += power
        }
        return BandEnergies(below150: low, above1200: high, selected: selected, total: total)
    }

    static func stereoEnergies(_ audio: Stereo, range: Range<Int>, sampleRate: Double) -> BandEnergies {
        let left = energies(audio.left[range].map(Double.init), sampleRate: sampleRate)
        let right = energies(audio.right[range].map(Double.init), sampleRate: sampleRate)
        return BandEnergies(below150: left.below150 + right.below150, above1200: left.above1200 + right.above1200,
                            selected: left.selected + right.selected, total: left.total + right.total)
    }

    /// Hann-windowed single-frequency amplitude.
    static func toneAmplitude(_ x: [Double], sampleRate: Double, hz: Double) -> Double {
        let n = x.count
        let omega = 2 * Double.pi * hz / sampleRate
        var re = 0.0, im = 0.0, windowSum = 0.0
        for index in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(n - 1))
            re += x[index] * w * cos(omega * Double(index))
            im -= x[index] * w * sin(omega * Double(index))
            windowSum += w
        }
        return 2 * (re * re + im * im).squareRoot() / windowSum
    }

    /// sqrt(selected-band energy of `output` / of `base`) per modulation-phase bin.
    /// Phase = frac(hz * (n / fs * timeScale - anchor)).
    static func foldedBandGain(output: (left: [Double], right: [Double]), base: (left: [Double], right: [Double]),
                               sampleRate: Double, hz: Double, anchor: Double, timeScale: Double,
                               range: Range<Int>, bins: Int) -> [Double] {
        var outputEnergy = [Double](repeating: 0, count: bins)
        var baseEnergy = [Double](repeating: 0, count: bins)
        for index in range {
            var phase = hz * (Double(index) / sampleRate * timeScale - anchor)
            phase -= phase.rounded(.down)
            let bin = min(bins - 1, Int(phase * Double(bins)))
            outputEnergy[bin] += output.left[index] * output.left[index] + output.right[index] * output.right[index]
            baseEnergy[bin] += base.left[index] * base.left[index] + base.right[index] * base.right[index]
        }
        return (0..<bins).map { (outputEnergy[$0] / baseEnergy[$0]).squareRoot() }
    }

    /// Phase (radians) of the first harmonic of a folded curve sampled at bin centres.
    static func firstHarmonicPhase(_ curve: [Double]) -> Double {
        var re = 0.0, im = 0.0
        for (k, value) in curve.enumerated() {
            let angle = 2 * Double.pi * (Double(k) + 0.5) / Double(curve.count)
            re += value * cos(angle)
            im -= value * sin(angle)
        }
        return atan2(im, re)
    }

    static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let meanA = a.reduce(0, +) / Double(a.count)
        let meanB = b.reduce(0, +) / Double(b.count)
        var numerator = 0.0, varianceA = 0.0, varianceB = 0.0
        for index in a.indices {
            numerator += (a[index] - meanA) * (b[index] - meanB)
            varianceA += (a[index] - meanA) * (a[index] - meanA)
            varianceB += (b[index] - meanB) * (b[index] - meanB)
        }
        return numerator / (varianceA * varianceB).squareRoot()
    }
}

// MARK: - Offline driver

/// Drives a FocusRenderCore like the worker does, answering `needNext` synchronously.
final class OfflineHarness {
    let core: FocusRenderCore
    private(set) var events: [(event: FocusCoreEvent, renderedFrames: Int)] = []
    private(set) var tracks: [Int: EngineTrack] = [:]
    var nextTrack: ((EngineTrack) -> EngineTrack?)?
    private var serialCounter = 0
    private var rendered = 0
    private var chunkLeft = [Float](repeating: 0, count: 512)
    private var chunkRight = [Float](repeating: 0, count: 512)

    init(depth: Float, crossfade: Double = 8, volume: Float = 1) {
        core = FocusRenderCore()
        core.setEffectDepth(depth, rampSeconds: 0)
        core.setCrossfadeSeconds(crossfade)
        core.setVolume(volume, rampSeconds: 0)
    }

    private func makeSerial() -> Int {
        serialCounter += 1
        return serialCounter
    }

    @discardableResult
    func start(_ track: EngineTrack, fadeIn: Double = 0, startTime: Double = 0) -> Int {
        let serial = makeSerial()
        tracks[serial] = track
        core.start(track: track, serial: serial, fadeIn: fadeIn, startTime: startTime)
        processEvents()
        return serial
    }

    @discardableResult
    func skip(to track: EngineTrack, crossfade: Double) -> Int {
        let serial = makeSerial()
        tracks[serial] = track
        core.skip(to: track, serial: serial, crossfade: crossfade)
        processEvents()
        return serial
    }

    func render(frames: Int, into output: inout Stereo) {
        var done = 0
        while done < frames {
            let count = min(512, frames - done)
            chunkLeft.withUnsafeMutableBufferPointer { left in
                chunkRight.withUnsafeMutableBufferPointer { right in
                    core.render(left: left.baseAddress!, right: right.baseAddress!, frames: count)
                }
            }
            output.left.append(contentsOf: chunkLeft[0..<count])
            output.right.append(contentsOf: chunkRight[0..<count])
            done += count
            rendered += count
            processEvents()
        }
    }

    func render(frames: Int) -> Stereo {
        var output = Stereo(reserving: frames)
        render(frames: frames, into: &output)
        return output
    }

    func processEvents() {
        var batch = core.drainEvents()
        while !batch.isEmpty {
            for event in batch {
                events.append((event, rendered))
                if case .needNext(let after, _) = event {
                    let previous = tracks[after]!
                    if let next = nextTrack?(previous) {
                        let serial = makeSerial()
                        tracks[serial] = next
                        core.setNext(next, serial: serial, after: after)
                    } else {
                        core.setNext(nil, serial: 0, after: after)
                    }
                }
            }
            batch = core.drainEvents()
        }
    }

    func describe(_ event: FocusCoreEvent) -> String {
        func name(_ serial: Int) -> String { tracks[serial]?.id ?? "#\(serial)" }
        switch event {
        case .becameAudible(let serial, let frame): return "becameAudible(\(name(serial)) @\(frame))"
        case .finished(let serial, let frame, let listened, let skipped):
            return "finished(\(name(serial)) @\(frame), listened \(listened) frames, skipped \(skipped))"
        case .discarded(let serial): return "discarded(\(name(serial)))"
        case .needNext(let after, let replacing): return "needNext(after \(name(after)), replacing \(replacing))"
        case .pauseCompleted(let token, let frame): return "pauseCompleted(token \(token) @\(frame))"
        case .ended(let frame): return "ended(@\(frame))"
        case .failed(let serial, let error): return "failed(\(name(serial)): \(error))"
        }
    }
}

// MARK: - Environment

final class CheckEnvironment {
    let root: URL
    let sampleRate = FocusAudioFormat.sampleRate
    let temporary: URL
    let electronic: URL
    let electronic2: URL
    let grooves: URL
    let referenceOff: URL
    let referenceMedium: URL
    let originalAnchor: Double
    let referenceAnchor: Double
    let preparedSpeedFactor: Double
    private var syntheticURL: URL?

    init(root: URL) {
        self.root = root
        electronic = root.appendingPathComponent("Audio/TestFixtures/electronic-a.wav")
        electronic2 = root.appendingPathComponent("Audio/TestFixtures/electronic-b.wav")
        grooves = root.appendingPathComponent("Audio/TestFixtures/grooves-a.wav")
        let comparisons = root.appendingPathComponent("Audio/TestFixtures/comparisons")
        referenceOff = comparisons.appendingPathComponent("electronic-a-prepared-off.wav")
        referenceMedium = comparisons.appendingPathComponent("electronic-a-prepared-medium.wav")
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-audio-checks-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        // Beat anchors from the project's beat-grid review (fallbacks are the recorded values).
        var original = 0.1142985007299498
        var reference = 0.11712033833074528
        var speed = 0.9999791666666666
        let review = root.appendingPathComponent("Research/beat-grid-review.json")
        if let data = try? Data(contentsOf: review),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let fixed = json["originalFixed120Hypothesis"] as? [String: Any],
               let value = fixed["risingAttackGridAnchorSeconds"] as? Double { original = value }
            if let fixed = json["preparedFixed120Hypothesis"] as? [String: Any],
               let value = fixed["risingAttackGridAnchorSeconds"] as? Double { reference = value }
            if let preparation = json["preparation"] as? [String: Any],
               let value = preparation["actualConstantSpeedFactor"] as? Double { speed = value }
        }
        originalAnchor = original
        referenceAnchor = reference
        preparedSpeedFactor = speed
    }

    /// The songs in Audio/TestFixtures (not in the repository) that checks 1, 4b, 5-8, 10c, 10j and 11 play.
    var missingSongFixtures: [URL] {
        [electronic, electronic2, grooves].filter { !FileManager.default.fileExists(atPath: $0.path) }
    }
    var hasSongFixtures: Bool { missingSongFixtures.isEmpty }

    func cleanup() {
        try? FileManager.default.removeItem(at: temporary)
    }

    func track(_ id: String, _ url: URL, gainDB: Float = 0, hz: Double? = 16, offset: Double = 0) -> EngineTrack {
        EngineTrack(id: id, url: url, gainDB: gainDB, modulationHz: hz, beatOffsetSeconds: offset)
    }

    func loopTrack(_ id: String, _ url: URL, start: Double, end: Double, correlation: Double = 0,
                   gainDB: Float = 0, hz: Double? = 16, offset: Double = 0) -> EngineTrack {
        EngineTrack(id: id, url: url, gainDB: gainDB, modulationHz: hz, beatOffsetSeconds: offset,
                    loopStartSeconds: start, loopEndSeconds: end, loopSeamCorrelation: correlation)
    }

    /// Loop points of the electronic-a fixture from Scripts/build_library.py (loop_points
    /// version 1): 148 bars, seam correlation 0.101.
    let electronicLoop = (start: 26.104449, end: 322.104492, correlation: 0.101)

    /// `seconds` of stereo Gaussian noise (0.1 rms), or `pattern` seconds of it repeated.
    func noiseFile(_ name: String, seconds: Double, seed: UInt64, pattern: Double? = nil) throws -> (URL, Stereo) {
        var rng = SplitMix64(state: seed)
        let frames = Int(seconds * sampleRate)
        let unique = pattern.map { Int($0 * sampleRate) } ?? frames
        let baseLeft = (0..<unique).map { _ in Float(0.1 * rng.gaussian()) }
        let baseRight = (0..<unique).map { _ in Float(0.1 * rng.gaussian()) }
        let left = (0..<frames).map { baseLeft[$0 % unique] }
        let right = (0..<frames).map { baseRight[$0 % unique] }
        let url = temporary.appendingPathComponent("\(name).wav")
        try AudioIO.writeFloatWAV(url, channels: [left, right], sampleRate: sampleRate)
        return (url, Stereo(left: left, right: right))
    }

    /// 12 s stereo test mix: in-band tones + 300-900 Hz noise, plus 60/110 Hz, 2/5 kHz tones and
    /// 1.5-8 kHz noise outside the band.
    func synthetic() throws -> URL {
        if let syntheticURL { return syntheticURL }
        let frames = Int(12 * sampleRate)
        var rng = SplitMix64(state: 0x5EED)
        func bandNoise(_ low: Double, _ high: Double, rms target: Double) -> [Double] {
            let size = Spectral.nextPowerOfTwo(frames)
            var real = (0..<size).map { _ in rng.gaussian() }
            var imag = [Double](repeating: 0, count: size)
            Spectral.fft(&real, &imag, inverse: false)
            for k in 0..<size {
                let bin = k <= size / 2 ? k : size - k
                let hz = Double(bin) * sampleRate / Double(size)
                if hz < low || hz > high {
                    real[k] = 0
                    imag[k] = 0
                }
            }
            Spectral.fft(&real, &imag, inverse: true)
            var samples = Array(real[0..<frames])
            let current = (samples.reduce(0) { $0 + $1 * $1 } / Double(frames)).squareRoot()
            samples = samples.map { $0 * target / current }
            return samples
        }
        let tones: [(hz: Double, amplitude: Double)] = [
            (300, 0.10), (470, 0.08), (730, 0.06),   // selected band
            (60, 0.10), (110, 0.08),                 // below 150 Hz
            (2000, 0.05), (5000, 0.10),              // above 1.2 kHz
        ]
        var channels: [[Float]] = []
        for channel in 0..<2 {
            let inBand = bandNoise(300, 900, rms: 0.03)
            let high = bandNoise(1500, 8000, rms: 0.02)
            var samples = [Float](repeating: 0, count: frames)
            for index in 0..<frames {
                let t = Double(index) / sampleRate
                var value = inBand[index] + high[index]
                for (number, tone) in tones.enumerated() {
                    let phase = Double(number) * 0.7 + Double(channel) * 1.3
                    value += tone.amplitude * sin(2 * Double.pi * tone.hz * t + phase)
                }
                samples[index] = Float(value)
            }
            channels.append(samples)
        }
        let url = temporary.appendingPathComponent("synthetic-mix.wav")
        try AudioIO.writeFloatWAV(url, channels: channels, sampleRate: sampleRate)
        syntheticURL = url
        return url
    }
}

// MARK: - Checks

@main
struct AudioEngineChecks {
    static func main() {
        let root: URL
        if CommandLine.arguments.count > 1 {
            root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        } else {
            root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        }
        let environment = CheckEnvironment(root: root)
        let log = CheckLog()
        let fir = FocusBandFIR.standard
        print("Focus audio engine checks — FIR \(fir.tapCount) taps, group delay \(fir.groupDelay) frames "
              + "(\(f(Double(fir.groupDelay) / fir.sampleRate * 1000, 1)) ms), FFT \(fir.fftLength), hop \(fir.hop)")
        let checks: [(String, (CheckEnvironment, CheckLog) throws -> Void)] = [
            ("1", checkPassThrough),
            ("2", checkSyntheticMix),
            ("3", checkFilterResponse),
            ("4", checkDepthOrdering),
            ("5", checkReferenceComparison),
            ("6", checkCrossfades),
            ("7", checkPerformance),
            ("8", checkRealTime),
            ("9", checkNoise),
            ("10", checkLoop),
            ("11", checkLoopRealTime),
            ("12", checkBeatMap),
        ]
        // FOCUS_AUDIO_CHECKS=1,3,8 runs a subset.
        let selected = ProcessInfo.processInfo.environment["FOCUS_AUDIO_CHECKS"].map {
            Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        let toRun = checks.filter { selected?.contains($0.0) ?? true }
        // Checks 1, 5, 6, 7, 8 and 11 play the songs in Audio/TestFixtures, and so do 4b, 10c and 10j.
        // Without them those are skipped, and the run fails naming each missing file.
        let needSongs: Set<String> = ["1", "5", "6", "7", "8", "11"]
        if toRun.contains(where: { needSongs.contains($0.0) || $0.0 == "4" || $0.0 == "10" }) {
            for url in environment.missingSongFixtures {
                log.expect("fixture \(url.lastPathComponent)", false, "missing \(url.path)")
            }
        }
        for (number, check) in toRun {
            if needSongs.contains(number) && !environment.hasSongFixtures {
                log.section("\(number). Skipped: needs the songs in Audio/TestFixtures")
                continue
            }
            do {
                try check(environment, log)
            } catch {
                log.expect("check \(number) completed", false, "threw \(error)")
            }
        }
        environment.cleanup()
        let failed = log.outcomes.filter { !$0.passed }
        print("\n=== Summary: \(log.outcomes.count - failed.count)/\(log.outcomes.count) passed")
        for failure in failed { print("  FAILED: \(failure.name)") }
        exit(failed.isEmpty ? 0 : 1)
    }

    // 1. Depth 0 / modulationHz nil -> exactly the (group-delay aligned) input.
    static func checkPassThrough(_ env: CheckEnvironment, _ log: CheckLog) throws {
        log.section("1. Pass-through (depth 0, modulationHz nil)")
        let fs = env.sampleRate
        let frames = Int(20 * fs)
        let input = try AudioIO.read(env.electronic, frames: frames)
        log.note("Output is aligned to track time: the FIR's \(FocusBandFIR.standard.groupDelay)-frame group delay is pre-rolled, the dry path is the delayed input.")

        let off = OfflineHarness(depth: 0)
        off.start(env.track("electronic", env.electronic, hz: 16, offset: env.originalAnchor))
        let offDiff = maxAbsDifference(off.render(frames: frames), input)
        log.expect("1a depth 0 (modulationHz 16)", offDiff <= 1e-6, "max |out - in| = \(sci(offDiff)) over 20 s")

        let noHz = OfflineHarness(depth: 0.36)
        noHz.start(env.track("electronic", env.electronic, hz: nil))
        var noHzOut = noHz.render(frames: frames / 2)
        noHz.core.setEffectDepth(0.54)   // level change mid-way must not matter either
        noHz.render(frames: frames - frames / 2, into: &noHzOut)
        let noHzDiff = maxAbsDifference(noHzOut, input)
        log.expect("1b modulationHz nil at medium -> high", noHzDiff <= 1e-6, "max |out - in| = \(sci(noHzDiff))")

        let gainDB: Float = -3.8
        let gain = Float(pow(10.0, Double(gainDB) / 20.0))
        let gained = OfflineHarness(depth: 0)
        gained.start(env.track("electronic", env.electronic, gainDB: gainDB, hz: 16, offset: env.originalAnchor))
        let gainedDiff = maxAbsDifference(gained.render(frames: frames), input.scaled(gain))
        log.expect("1c depth 0 with gainDB -3.8", gainedDiff <= 1e-6, "max |out - gain*in| = \(sci(gainedDiff))")

        let startSeconds = 100.0
        let offset = OfflineHarness(depth: 0)
        offset.start(env.track("electronic", env.electronic, hz: 16), startTime: startSeconds)
        let offsetInput = try AudioIO.read(env.electronic, start: Int(startSeconds * fs), frames: Int(5 * fs))
        let offsetDiff = maxAbsDifference(offset.render(frames: Int(5 * fs)), offsetInput)
        log.expect("1d depth 0 starting at 100 s", offsetDiff <= 1e-6, "max |out - in| = \(sci(offsetDiff))")

        // Decoder conversion path: 44.1 kHz mono -> 48 kHz stereo.
        let rate = 44_100.0
        let toneFrames = Int(3 * rate)
        let tone = (0..<toneFrames).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / rate)) }
        let toneURL = env.temporary.appendingPathComponent("tone-44k1-mono.wav")
        try AudioIO.writeFloatWAV(toneURL, channels: [tone], sampleRate: rate)
        let converted = OfflineHarness(depth: 0.36)
        converted.start(env.track("tone", toneURL, hz: 16))
        let convertedOut = converted.render(frames: Int(3.5 * fs))
        var endedFrame: Int64 = -1
        for item in converted.events { if case .ended(let frame) = item.event { endedFrame = frame } }
        let interior = Int(0.5 * fs)..<Int(2.5 * fs)
        let monoMatch = convertedOut.left == convertedOut.right
        let at1k = Spectral.toneAmplitude(convertedOut.left[interior].map(Double.init), sampleRate: fs, hz: 1000)
        let unconverted = Spectral.toneAmplitude(convertedOut.left[interior].map(Double.init), sampleRate: fs, hz: 1000 * fs / rate)
        log.expect("1e 44.1 kHz mono file", endedFrame == Int64(3 * fs) && monoMatch && abs(amplitudeDB(at1k / 0.5)) < 0.05,
                   "length \(endedFrame) frames (expected \(Int(3 * fs))), L==R \(monoMatch), 1 kHz amplitude \(f(at1k, 4)) (\(f(amplitudeDB(at1k / 0.5), 3)) dB), at \(f(1000 * fs / rate, 1)) Hz \(sci(unconverted)); medium effect leaves a 1 kHz tone alone (out of band)")

        // FLAC (24-bit session file), entered mid-file: decode + seek + FIR pre-roll path.
        let flac = env.root.appendingPathComponent("Audio/Sessions/electronic-30min-continuous.flac")
        if FileManager.default.fileExists(atPath: flac.path) {
            let flacHarness = OfflineHarness(depth: 0)
            flacHarness.start(env.track("flac", flac, hz: 16), startTime: 600)
            let flacOut = flacHarness.render(frames: Int(5 * fs))
            let flacIn = try AudioIO.read(flac, start: Int(600 * fs), frames: Int(5 * fs))
            let flacDiff = maxAbsDifference(flacOut, flacIn)
            log.expect("1f FLAC at 10:00, depth 0", flacDiff <= 1e-6, "max |out - in| = \(sci(flacDiff)) over 5 s")
        } else {
            log.note("1f skipped: \(flac.path) not present")
        }
    }

    // 2. Synthetic mix at medium: 16 Hz envelope peak in-band; out-of-band unchanged.
    static func checkSyntheticMix(_ env: CheckEnvironment, _ log: CheckLog) throws {
        log.section("2. Synthetic mix at medium (in-band tones/noise + out-of-band tones/noise)")
        let fs = env.sampleRate
        let url = try env.synthetic()
        let frames = Int(12 * fs)
        let source = env.track("synthetic", url, hz: 16, offset: 0.137)
        let off = OfflineHarness(depth: 0)
        off.start(source)
        let dry = off.render(frames: frames)
        let medium = OfflineHarness(depth: 0.36)
        medium.start(source)
        let wet = medium.render(frames: frames)
        let interior = Int(1 * fs)..<Int(11 * fs)

        let dryBand = (Spectral.idealBand(dry.doubles.left, sampleRate: fs), Spectral.idealBand(dry.doubles.right, sampleRate: fs))
        let wetBand = (Spectral.idealBand(wet.doubles.left, sampleRate: fs), Spectral.idealBand(wet.doubles.right, sampleRate: fs))
        let dryEnvelope = Spectral.envelopeMetrics(bandLeft: dryBand.0, bandRight: dryBand.1, sampleRate: fs, range: interior, targetHz: 16)
        let wetEnvelope = Spectral.envelopeMetrics(bandLeft: wetBand.0, bandRight: wetBand.1, sampleRate: fs, range: interior, targetHz: 16)
        log.note("off:    16 Hz envelope amplitude \(sci(dryEnvelope.targetAmplitude)), vs nearby median \(f(dryEnvelope.targetToNearbyMedianDB, 1)) dB, largest 8-32 Hz peak \(f(dryEnvelope.peakHz, 2)) Hz")
        log.note("medium: 16 Hz envelope amplitude \(sci(wetEnvelope.targetAmplitude)), vs nearby median \(f(wetEnvelope.targetToNearbyMedianDB, 1)) dB, largest 8-32 Hz peak \(f(wetEnvelope.peakHz, 2)) Hz, modulation index \(f(wetEnvelope.modulationIndex, 4)) (ideal (d/2)/(1-d/2) = \(f(0.18 / 0.82, 4)))")
        log.expect("2a in-band envelope peak at 16 Hz", abs(wetEnvelope.peakHz - 16) <= 0.1 && wetEnvelope.targetToNearbyMedianDB >= 20
                   && wetEnvelope.targetToNearbyMedianDB - dryEnvelope.targetToNearbyMedianDB >= 15,
                   "peak \(f(wetEnvelope.peakHz, 2)) Hz, \(f(wetEnvelope.targetToNearbyMedianDB, 1)) dB above nearby median (off: \(f(dryEnvelope.targetToNearbyMedianDB, 1)) dB)")

        var worstTone = 0.0
        for channel in 0..<2 {
            let a = (channel == 0 ? dry.left : dry.right)[interior].map(Double.init)
            let b = (channel == 0 ? wet.left : wet.right)[interior].map(Double.init)
            let change = amplitudeDB(Spectral.toneAmplitude(b, sampleRate: fs, hz: 5000) / Spectral.toneAmplitude(a, sampleRate: fs, hz: 5000))
            worstTone = max(worstTone, abs(change))
        }
        log.expect("2b 5 kHz tone", worstTone <= 0.5, "largest change \(sci(worstTone)) dB")

        let dryEnergy = Spectral.stereoEnergies(dry, range: interior, sampleRate: fs)
        let wetEnergy = Spectral.stereoEnergies(wet, range: interior, sampleRate: fs)
        let lowChange = powerDB(wetEnergy.below150 / dryEnergy.below150)
        let highChange = powerDB(wetEnergy.above1200 / dryEnergy.above1200)
        log.expect("2c energy below 150 Hz", abs(lowChange) <= 0.5, "change \(sci(lowChange)) dB")
        log.expect("2d energy above 1.2 kHz", abs(highChange) <= 0.5, "change \(sci(highChange)) dB")
        log.note("200-1000 Hz energy change \(f(powerDB(wetEnergy.selected / dryEnergy.selected), 3)) dB (expected about \(f(powerDB(1 - 0.36 + 3 * 0.36 * 0.36 / 8), 3)) dB); whole-signal \(f(powerDB(wetEnergy.total / dryEnergy.total), 3)) dB")
    }

    // 3. FIR magnitude vs `_band_mask`, plus the streaming effect formula vs a direct computation.
    static func checkFilterResponse(_ env: CheckEnvironment, _ log: CheckLog) throws {
        log.section("3. FIR response vs _band_mask, and the effect formula end to end")
        let fir = FocusBandFIR.standard
        let fs = fir.sampleRate
        let size = 1 << 20
        var real = [Double](repeating: 0, count: size)
        var imag = [Double](repeating: 0, count: size)
        for (index, tap) in fir.coefficients.enumerated() { real[index] = Double(tap) }
        Spectral.fft(&real, &imag, inverse: false)
        let delay = Double(fir.groupDelay)
        var maxDeviation = 0.0, maxDeviationHz = 0.0
        var passMin = Double.infinity, passMax = -Double.infinity
        var below150 = 0.0, above1200 = 0.0
        func zeroPhase(_ k: Int) -> Double {
            let angle = 2 * Double.pi * Double(k) * delay / Double(size)
            return real[k] * cos(angle) - imag[k] * sin(angle)
        }
        for k in 0...(size / 2) {
            let hz = Double(k) * fs / Double(size)
            let response = zeroPhase(k)
            let deviation = abs(response - FocusBandMask.gain(atHz: hz))
            if deviation > maxDeviation {
                maxDeviation = deviation
                maxDeviationHz = hz
            }
            if hz >= 248 && hz <= 952 {
                passMin = min(passMin, response)
                passMax = max(passMax, response)
            }
            if hz < 150 { below150 = max(below150, abs(response)) }
            if hz > 1200 { above1200 = max(above1200, abs(response)) }
        }
        func response(at hz: Double) -> Double { zeroPhase(Int((hz * Double(size) / fs).rounded())) }
        let at100 = amplitudeDB(abs(response(at: 100)))
        let at2k = amplitudeDB(abs(response(at: 2000)))
        log.note("edges: " + [216.0, 232, 248, 952, 968, 984].map { "\(Int($0)) Hz \(f(response(at: $0), 4)) (mask \(f(FocusBandMask.gain(atHz: $0), 4)))" }.joined(separator: ", "))
        log.expect("3a max |H - mask| (0-24 kHz)", maxDeviation <= 0.01, "\(sci(maxDeviation)) at \(f(maxDeviationHz, 1)) Hz")
        log.expect("3b passband 248-952 Hz", amplitudeDB(passMax) <= 0.1 && amplitudeDB(passMin) >= -0.1,
                   "\(f(amplitudeDB(passMin), 4)) to +\(f(amplitudeDB(passMax), 4)) dB (max deviation from 1: \(sci(max(passMax - 1, 1 - passMin))))")
        log.expect("3c stopband", at100 <= -60 && at2k <= -60,
                   "100 Hz \(f(at100, 1)) dB, 2 kHz \(f(at2k, 1)) dB, max below 150 Hz \(f(amplitudeDB(below150), 1)) dB, max above 1.2 kHz \(f(amplitudeDB(above1200), 1)) dB")

        // End to end: y = x - depth * shape * window * band, with band = direct (Double) FIR
        // convolution centred on the output frame. Short noise file so both effect ramps are hit.
        let frames = Int(3 * fs)
        var rng = SplitMix64(state: 42)
        let noiseLeft = (0..<frames).map { _ in Float(0.2 * rng.gaussian()) }
        let noiseRight = (0..<frames).map { _ in Float(0.2 * rng.gaussian()) }
        let url = env.temporary.appendingPathComponent("noise-3s.wav")
        try AudioIO.writeFloatWAV(url, channels: [noiseLeft, noiseRight], sampleRate: fs)
        let hz = 16.0, offset = 0.0371, depth = 0.5
        let harness = OfflineHarness(depth: Float(depth))
        harness.start(env.track("noise", url, hz: hz, offset: offset))
        let output = harness.render(frames: frames)
        let taps = fir.coefficients.map(Double.init)
        let fade = min(Int((0.25 * fs).rounded()), frames / 4)
        var worst = 0.0
        var checked = 0
        var positions = Array(stride(from: 0, to: fade + 500, by: 37))
        positions += Array(stride(from: frames / 2 - 2000, to: frames / 2 + 2000, by: 41))
        positions += Array(stride(from: frames - fade - 500, to: frames, by: 37))
        for m in positions {
            for (channel, x) in [noiseLeft, noiseRight].enumerated() {
                var band = 0.0
                for k in 0..<fir.tapCount {
                    let index = m + fir.groupDelay - k
                    if index >= 0 && index < frames { band += taps[k] * Double(x[index]) }
                }
                let t = Double(m) / fs
                let shape = 0.5 * (1 - cos(2 * Double.pi * hz * (t - offset)))
                var window = 1.0
                if m >= frames - fade {
                    window = 0.5 - 0.5 * cos(Double.pi * Double(frames - 1 - m) / Double(fade - 1))
                } else if m < fade {
                    window = 0.5 - 0.5 * cos(Double.pi * Double(m) / Double(fade - 1))
                }
                let expected = Double(x[m]) - depth * shape * window * band
                let actual = Double(channel == 0 ? output.left[m] : output.right[m])
                worst = max(worst, abs(actual - expected))
                checked += 1
            }
        }
        log.expect("3d streaming effect == direct formula", worst <= 2e-6,
                   "max error \(sci(worst)) over \(checked) samples (start ramp, middle, end ramp; depth 0.5, 16 Hz, offset 37.1 ms)")
    }

    // 4. Measured in-band modulation increases off < low < medium < high.
    static func checkDepthOrdering(_ env: CheckEnvironment, _ log: CheckLog) throws {
        log.section("4. Depth ordering")
        let fs = env.sampleRate
        let url = try env.synthetic()
        let frames = Int(12 * fs)
        let interior = Int(1 * fs)..<Int(11 * fs)
        var indices: [Double] = []
        for level in EffectLevel.allCases {
            let harness = OfflineHarness(depth: level.depth)
            harness.start(env.track("synthetic", url, hz: 16, offset: 0.137))
            let output = harness.render(frames: frames)
            let band = (Spectral.idealBand(output.doubles.left, sampleRate: fs), Spectral.idealBand(output.doubles.right, sampleRate: fs))
            let metrics = Spectral.envelopeMetrics(bandLeft: band.0, bandRight: band.1, sampleRate: fs, range: interior, targetHz: 16)
            let d = Double(level.depth)
            indices.append(metrics.modulationIndex)
            log.note("synthetic \(level): 16 Hz modulation index \(f(metrics.modulationIndex, 4)) (ideal \(f((d / 2) / (1 - d / 2), 4))), \(f(metrics.targetToNearbyMedianDB, 1)) dB above nearby median")
        }
        let syntheticOrdered = zip(indices, indices.dropFirst()).allSatisfy { $0 < $1 }
        log.expect("4a synthetic mix ordering", syntheticOrdered, indices.map { f($0, 4) }.joined(separator: " < "))

        // Same on real music: selected-band gain folded on the 16 Hz grid, relative to off.
        guard env.hasSongFixtures else {
            log.note("4b skipped: needs \(env.electronic.path)")
            return
        }
        let musicFrames = Int(20 * fs)
        let range = Int(1 * fs)..<Int(19 * fs)
        var baseBand: (left: [Double], right: [Double])?
        var depths: [Double] = []
        for level in EffectLevel.allCases {
            let harness = OfflineHarness(depth: level.depth)
            harness.start(env.track("electronic", env.electronic, gainDB: -3.8, hz: 16, offset: env.originalAnchor))
            let output = harness.render(frames: musicFrames)
            let band = (left: Spectral.idealBand(output.doubles.left, sampleRate: fs), right: Spectral.idealBand(output.doubles.right, sampleRate: fs))
            if baseBand == nil { baseBand = band }
            let curve = Spectral.foldedBandGain(output: band, base: baseBand!, sampleRate: fs, hz: 16, anchor: env.originalAnchor,
                                                timeScale: 1, range: range, bins: 32)
            let depthDB = amplitudeDB(curve.max()! / curve.min()!)
            depths.append(depthDB)
            let d = Double(level.depth)
            log.note("music \(level): band gain peak-to-trough \(f(depthDB, 3)) dB (ideal \(f(amplitudeDB(1 / (1 - d)), 3)) dB before 32-bin averaging)")
        }
        let musicOrdered = zip(depths, depths.dropFirst()).allSatisfy { $0 < $1 }
        log.expect("4b real music ordering", musicOrdered, depths.map { f($0, 3) + " dB" }.joined(separator: " < "))
    }

    // 5. Real file at medium with gain -3.8 dB vs the offline reference comparison files.
    static func checkReferenceComparison(_ env: CheckEnvironment, _ log: CheckLog) throws {
        log.section("5. Real file (electronic-a, 120 BPM) vs offline reference")
        let fs = env.sampleRate
        let frames = Int(30 * fs)
        let gainDB: Float = -3.8
        let gain = Float(pow(10.0, Double(gainDB) / 20.0))
        let harness = OfflineHarness(depth: EffectLevel.medium.depth)
        harness.start(env.track("electronic", env.electronic, gainDB: gainDB, hz: 16, offset: env.originalAnchor))
        let ours = harness.render(frames: frames)
        let dry = try AudioIO.read(env.electronic, frames: frames).scaled(gain)
        let finite = allFinite(ours)
        let oursPeak = peak(ours)
        log.expect("5a 30 s render sanity", finite && oursPeak <= 1.0,
                   "all finite \(finite), peak \(f(oursPeak, 4)) (\(f(amplitudeDB(oursPeak), 2)) dBFS); dry peak \(f(peak(dry), 4))")

        guard FileManager.default.fileExists(atPath: env.referenceMedium.path),
              FileManager.default.fileExists(atPath: env.referenceOff.path) else {
            log.expect("5b reference files present", false, "missing \(env.referenceMedium.path)")
            return
        }
        let referenceOff = try AudioIO.read(env.referenceOff, frames: frames)
        let referenceMedium = try AudioIO.read(env.referenceMedium, frames: frames)
        log.note("beat anchors: ours \(f(env.originalAnchor * 1000, 3)) ms (original file, fixed-120 fit); reference \(f(env.referenceAnchor * 1000, 3)) ms on the prepared file (speed x\(env.preparedSpeedFactor))")
        log.note("reference = FFT mask on the prepared file + selected-band RMS matching (interior band gain x1.1878); ours = y = dry - depth*shape*band, no RMS matching")

        func band(_ audio: Stereo) -> (left: [Double], right: [Double]) {
            (Spectral.idealBand(audio.doubles.left, sampleRate: fs), Spectral.idealBand(audio.doubles.right, sampleRate: fs))
        }
        let dryBand = band(dry), oursBand = band(ours)
        let refOffBand = band(referenceOff), refMediumBand = band(referenceMedium)
        let range = Int(1 * fs)..<Int(29 * fs)
        let bins = 32
        let oursCurve = Spectral.foldedBandGain(output: oursBand, base: dryBand, sampleRate: fs, hz: 16, anchor: env.originalAnchor,
                                                timeScale: 1, range: range, bins: bins)
        let refCurve = Spectral.foldedBandGain(output: refMediumBand, base: refOffBand, sampleRate: fs, hz: 16, anchor: env.referenceAnchor,
                                               timeScale: 1, range: range, bins: bins)
        let refOnOurGrid = Spectral.foldedBandGain(output: refMediumBand, base: refOffBand, sampleRate: fs, hz: 16, anchor: env.originalAnchor,
                                                   timeScale: env.preparedSpeedFactor, range: range, bins: bins)
        let oursDepth = amplitudeDB(oursCurve.max()! / oursCurve.min()!)
        let refDepth = amplitudeDB(refCurve.max()! / refCurve.min()!)
        let oursMean = oursCurve.reduce(0, +) / Double(bins)
        let refMean = refCurve.reduce(0, +) / Double(bins)
        let correlation = Spectral.pearson(oursCurve, refCurve)
        let normalizedDifference = zip(oursCurve, refCurve).map { abs($0 / oursMean - $1 / refMean) }.max()!
        log.note("folded band gain (32 bins of the 16 Hz cycle): ours " + oursCurve.enumerated().filter { $0.offset % 4 == 0 }.map { f($0.element, 3) }.joined(separator: " ")
                 + " | reference " + refCurve.enumerated().filter { $0.offset % 4 == 0 }.map { f($0.element, 3) }.joined(separator: " "))
        log.expect("5b modulation depth vs reference", abs(oursDepth - refDepth) <= 0.5,
                   "peak-to-trough ours \(f(oursDepth, 3)) dB, reference \(f(refDepth, 3)) dB (difference \(f(oursDepth - refDepth, 3)) dB)")
        log.expect("5c modulation shape vs reference", correlation >= 0.98,
                   "correlation \(f(correlation, 5)), max normalized difference \(f(normalizedDifference, 4)); mean band gain ours \(f(amplitudeDB(oursMean), 2)) dB, reference \(f(amplitudeDB(refMean), 2)) dB (reference RMS matching)")

        // Where the attenuation sits relative to the music: fold the reference on our grid.
        let lagCycles = -(Spectral.firstHarmonicPhase(refOnOurGrid) - Spectral.firstHarmonicPhase(oursCurve)) / (2 * Double.pi)
        let lagMs = (lagCycles - lagCycles.rounded()) / 16 * 1000
        let middle = (Double(range.lowerBound) + Double(range.upperBound)) / 2 / fs
        let expectedMs = (env.preparedSpeedFactor * env.referenceAnchor - env.originalAnchor
                          + (env.preparedSpeedFactor - 1) * middle) * 1000
        log.expect("5d modulation phase vs reference", abs(lagMs - expectedMs) <= 0.5,
                   "reference attenuation lags ours by \(f(lagMs, 3)) ms in music time; anchor difference predicts \(f(expectedMs, 3)) ms")

        let oursEnergy = Spectral.stereoEnergies(ours, range: range, sampleRate: fs)
        let dryEnergy = Spectral.stereoEnergies(dry, range: range, sampleRate: fs)
        let refMediumEnergy = Spectral.stereoEnergies(referenceMedium, range: range, sampleRate: fs)
        let refOffEnergy = Spectral.stereoEnergies(referenceOff, range: range, sampleRate: fs)
        let oursLow = powerDB(oursEnergy.below150 / dryEnergy.below150)
        let oursHigh = powerDB(oursEnergy.above1200 / dryEnergy.above1200)
        let refLow = powerDB(refMediumEnergy.below150 / refOffEnergy.below150)
        let refHigh = powerDB(refMediumEnergy.above1200 / refOffEnergy.above1200)
        log.expect("5e out-of-band unchanged", abs(oursLow) <= 0.5 && abs(oursHigh) <= 0.5,
                   "ours <150 Hz \(sci(oursLow)) dB, >1.2 kHz \(sci(oursHigh)) dB; reference \(sci(refLow)) / \(sci(refHigh)) dB")
        let oursLevel = amplitudeDB(rms(ours, range: range) / rms(dry, range: range))
        let refLevel = amplitudeDB(rms(referenceMedium, range: range) / rms(referenceOff, range: range))
        log.note("whole-signal RMS change: ours \(f(oursLevel, 3)) dB, reference \(f(refLevel, 3)) dB")

        let envelopeRange = Int(1 * fs)..<Int(29 * fs)
        let metrics = [("dry", dryBand), ("ours medium", oursBand), ("reference off", refOffBand), ("reference medium", refMediumBand)].map {
            ($0.0, Spectral.envelopeMetrics(bandLeft: $0.1.left, bandRight: $0.1.right, sampleRate: fs, range: envelopeRange, targetHz: 16))
        }
        log.note("16 Hz envelope line vs nearby median: " + metrics.map { "\($0.0) \(f($0.1.targetToNearbyMedianDB, 1)) dB (index \(f($0.1.modulationIndex, 4)))" }.joined(separator: ", "))
    }

    // 6. Crossfades on real files: equal power, no discontinuities, exact timing; skip; pause.
    static func checkCrossfades(_ env: CheckEnvironment, _ log: CheckLog) throws {
        log.section("6. Crossfades and transport on real files")
        let fs = env.sampleRate
        let gainA: Float = -3.8, gainB: Float = -2.0
        let linearA = Float(pow(10.0, Double(gainA) / 20.0))
        let linearB = Float(pow(10.0, Double(gainB) / 20.0))
        let totalA = try AudioIO.frameCount(env.electronic)
        let lead = Int(20 * fs)
        let crossfade = Int(8 * fs)
        let frames = Int(28 * fs)
        let a = try AudioIO.read(env.electronic, start: totalA - lead, frames: lead).scaled(linearA)
        let b = try AudioIO.read(env.grooves, frames: frames).scaled(linearB)
        let trackA = env.track("A-electronic", env.electronic, gainDB: gainA, hz: 16, offset: env.originalAnchor)
        let trackB = env.track("B-grooves", env.grooves, gainDB: gainB, hz: 16, offset: 0.05)

        func runAuto(depth: Float) -> (Stereo, OfflineHarness) {
            let harness = OfflineHarness(depth: depth, crossfade: 8)
            harness.nextTrack = { _ in trackB }
            harness.start(trackA, startTime: Double(totalA - lead) / fs)
            return (harness.render(frames: frames), harness)
        }
        let (output, harness) = runAuto(depth: 0)
        let xfStart = lead - crossfade
        var expected = Stereo(left: [Float](repeating: 0, count: frames), right: [Float](repeating: 0, count: frames))
        for n in 0..<frames {
            var left = 0.0, right = 0.0
            if n < lead {
                let g = n < xfStart ? 1 : cos(Double.pi / 2 * Double(n - xfStart) / Double(crossfade))
                left += g * Double(a.left[n])
                right += g * Double(a.right[n])
            }
            if n >= xfStart {
                let g = n < lead ? sin(Double.pi / 2 * Double(n - xfStart) / Double(crossfade)) : 1
                left += g * Double(b.left[n - xfStart])
                right += g * Double(b.right[n - xfStart])
            }
            expected.left[n] = Float(left)
            expected.right[n] = Float(right)
        }
        let reconstruction = maxAbsDifference(output, expected)
        let events = harness.events.map { harness.describe($0.event) }
        let expectedEvents = events.contains("becameAudible(B-grooves @\(xfStart))")
            && events.contains("finished(A-electronic @\(lead), listened \(lead) frames, skipped false)")
        log.note("events: " + events.joined(separator: "; "))
        log.expect("6a automatic 8 s crossfade = cos/sin law, ends with track A", reconstruction <= 1e-5 && expectedEvents,
                   "max |out - expected| \(sci(reconstruction)); B audible at \(f(Double(xfStart) / fs, 3)) s, A finished at \(f(Double(lead) / fs, 3)) s = end of file")

        let tailLevels = stride(from: xfStart, to: lead, by: Int(fs)).map { f(amplitudeDB(rms(a, range: $0..<($0 + Int(fs)))), 1) }
        log.note("track A level over its last 8 s (dBFS per second, after gain): " + tailLevels.joined(separator: " "))

        // Equal power, measured: two uncorrelated equal-level noise tracks through the same 8 s
        // automatic crossfade keep a constant level (a linear fade would dip 3 dB mid-way), and
        // gains fitted per 100 ms window follow cos/sin with gA^2 + gB^2 = 1.
        var rng = SplitMix64(state: 2026)
        let noiseFrames = Int(30 * fs)
        var noiseURLs: [URL] = []
        var noise: [Stereo] = []
        for name in ["noise-a", "noise-b"] {
            let left = (0..<noiseFrames).map { _ in Float(0.1 * rng.gaussian()) }
            let right = (0..<noiseFrames).map { _ in Float(0.1 * rng.gaussian()) }
            let url = env.temporary.appendingPathComponent("\(name).wav")
            try AudioIO.writeFloatWAV(url, channels: [left, right], sampleRate: fs)
            noiseURLs.append(url)
            noise.append(Stereo(left: left, right: right))
        }
        let noiseHarness = OfflineHarness(depth: 0, crossfade: 8)
        let noiseB = env.track("noise-b", noiseURLs[1])
        noiseHarness.nextTrack = { _ in noiseB }
        noiseHarness.start(env.track("noise-a", noiseURLs[0]), startTime: Double(noiseFrames - lead) / fs)
        let noiseOutput = noiseHarness.render(frames: frames)
        let reference = rms(noiseOutput, range: 0..<xfStart)
        var worstLevel = 0.0, worstPower = 0.0, worstGain = 0.0
        var window = xfStart
        while window + 4800 <= lead {
            worstLevel = max(worstLevel, abs(amplitudeDB(rms(noiseOutput, range: window..<(window + 4800)) / reference)))
            var saa = 0.0, sbb = 0.0, sab = 0.0, sya = 0.0, syb = 0.0
            for n in window..<(window + 4800) {
                for channel in 0..<2 {
                    let av = Double(channel == 0 ? noise[0].left[noiseFrames - lead + n] : noise[0].right[noiseFrames - lead + n])
                    let bv = Double(channel == 0 ? noise[1].left[n - xfStart] : noise[1].right[n - xfStart])
                    let y = Double(channel == 0 ? noiseOutput.left[n] : noiseOutput.right[n])
                    saa += av * av; sbb += bv * bv; sab += av * bv; sya += y * av; syb += y * bv
                }
            }
            let determinant = saa * sbb - sab * sab
            let ga = (sya * sbb - syb * sab) / determinant
            let gb = (syb * saa - sya * sab) / determinant
            let centre = Double(window + 2400 - xfStart) / Double(crossfade)
            worstPower = max(worstPower, abs(ga * ga + gb * gb - 1))
            worstGain = max(worstGain, abs(ga - cos(Double.pi / 2 * centre)), abs(gb - sin(Double.pi / 2 * centre)))
            window += 4800
        }
        log.expect("6b equal-power law, measured on uncorrelated noise", worstLevel <= 0.3 && worstPower <= 2e-3,
                   "level through the crossfade within \(f(worstLevel, 3)) dB of before (80 windows of 100 ms); fitted max |gA^2 + gB^2 - 1| = \(sci(worstPower)), max gain error vs cos/sin \(sci(worstGain))")

        let region = (xfStart - Int(fs))..<(lead + Int(fs))
        let jumpOut = maxJump(output, range: region)
        let jumpA = maxJump(a, range: (xfStart - Int(fs))..<lead)
        let jumpB = maxJump(b, range: 0..<(crossfade + Int(fs)))
        let bound = 2.0.squareRoot() * max(jumpA, jumpB)
        let (mediumOutput, _) = runAuto(depth: 0.36)
        let jumpMedium = maxJump(mediumOutput, range: region)
        let jumpMediumBefore = maxJump(mediumOutput, range: 0..<(xfStart - Int(fs)))
        log.expect("6c no discontinuities across the crossfade", jumpOut <= bound && jumpMedium <= bound && allFinite(mediumOutput),
                   "max sample step: off \(f(jumpOut, 4)), medium \(f(jumpMedium, 4)) (medium before crossfade \(f(jumpMediumBefore, 4))); bound sqrt(2)*max(step A \(f(jumpA, 4)), step B \(f(jumpB, 4))) = \(f(bound, 4))")

        // User skip: 1.5 s crossfade at 5 s, from A playing at 30 s.
        let skipAt = Int(5 * fs), skipLength = Int(1.5 * fs)
        let a30 = try AudioIO.read(env.electronic, start: Int(30 * fs), frames: Int(10 * fs)).scaled(linearA)
        let skipHarness = OfflineHarness(depth: 0)
        skipHarness.start(trackA, startTime: 30)
        var skipOutput = skipHarness.render(frames: skipAt)
        skipHarness.skip(to: trackB, crossfade: 1.5)
        skipHarness.render(frames: Int(4 * fs), into: &skipOutput)
        var skipWorst = 0.0
        for n in 0..<skipOutput.count {
            for channel in 0..<2 {
                var value = 0.0
                let av = Double(channel == 0 ? a30.left[n] : a30.right[n])
                if n < skipAt {
                    value = av
                } else {
                    let p = Double(n - skipAt) / Double(skipLength)
                    if p < 1 { value += cos(Double.pi / 2 * p) * av }
                    let bv = Double(channel == 0 ? b.left[n - skipAt] : b.right[n - skipAt])
                    value += (p < 1 ? sin(Double.pi / 2 * p) : 1) * bv
                }
                skipWorst = max(skipWorst, abs(value - Double(channel == 0 ? skipOutput.left[n] : skipOutput.right[n])))
            }
        }
        let skipEvents = skipHarness.events.map { skipHarness.describe($0.event) }
        let skipFinished = skipEvents.contains("finished(A-electronic @\(skipAt + skipLength), listened \(skipAt + skipLength) frames, skipped true)")
        log.expect("6d skip: 1.5 s equal-power crossfade", skipWorst <= 1e-5 && skipFinished,
                   "max |out - expected| \(sci(skipWorst)); A reported skipped after \(f(Double(skipAt + skipLength) / fs, 2)) s listened")

        // Skip again during the skip crossfade: three voices, frozen gains, still equal power.
        let trackC = env.track("C-electronic2", env.electronic2, gainDB: 0, hz: 16, offset: 0.2)
        let c = try AudioIO.read(env.electronic2, frames: Int(4 * fs))
        let secondAt = skipAt + Int(0.5 * fs)
        let triple = OfflineHarness(depth: 0)
        triple.start(trackA, startTime: 30)
        var tripleOutput = triple.render(frames: skipAt)
        triple.skip(to: trackB, crossfade: 1.5)
        triple.render(frames: secondAt - skipAt, into: &tripleOutput)
        triple.skip(to: trackC, crossfade: 1.5)
        triple.render(frames: Int(3 * fs), into: &tripleOutput)
        let frozenA = cos(Double.pi / 2 * Double(secondAt - skipAt) / Double(skipLength))
        let frozenB = sin(Double.pi / 2 * Double(secondAt - skipAt) / Double(skipLength))
        var tripleWorst = 0.0
        for n in secondAt..<tripleOutput.count {
            let q = min(1, Double(n - secondAt) / Double(skipLength))
            let outGain = q < 1 ? cos(Double.pi / 2 * q) : 0
            for channel in 0..<2 {
                let av = Double(channel == 0 ? a30.left[n] : a30.right[n])
                let bv = Double(channel == 0 ? b.left[n - skipAt] : b.right[n - skipAt])
                let cv = Double(channel == 0 ? c.left[n - secondAt] : c.right[n - secondAt])
                let value = frozenA * outGain * av + frozenB * outGain * bv + sin(Double.pi / 2 * q) * cv
                tripleWorst = max(tripleWorst, abs(value - Double(channel == 0 ? tripleOutput.left[n] : tripleOutput.right[n])))
            }
        }
        let tripleJump = maxJump(tripleOutput, range: (skipAt - 4800)..<(secondAt + skipLength + 4800))
        log.expect("6e skip during a skip (3 voices)", tripleWorst <= 1e-5,
                   "gains at the 2nd skip A \(f(frozenA, 4)), B \(f(frozenB, 4)) (A^2+B^2 = \(f(frozenA * frozenA + frozenB * frozenB, 6))), then x cos, C x sin; max |out - expected| \(sci(tripleWorst)); max step \(f(tripleJump, 4))")

        // Pause (0.5 s fade) keeps the position; resume (0.5 s fade) continues from it.
        let pauseAt = Int(3 * fs), fadeLength = Int(0.5 * fs), held = Int(1 * fs)
        let a0 = try AudioIO.read(env.electronic, frames: Int(8 * fs)).scaled(linearA)
        let transport = OfflineHarness(depth: 0)
        transport.start(trackA)
        var transportOutput = transport.render(frames: pauseAt)
        transport.core.pause(fade: 0.5, token: 7)
        transport.render(frames: fadeLength + held, into: &transportOutput)
        transport.core.resume(fade: 0.5)
        transport.render(frames: Int(2 * fs), into: &transportOutput)
        var transportWorst = 0.0
        for n in 0..<transportOutput.count {
            var gain = 1.0
            var source = n
            if n >= pauseAt && n < pauseAt + fadeLength {
                gain = 1 - (0.5 - 0.5 * cos(Double.pi * Double(n - pauseAt + 1) / Double(fadeLength)))
            } else if n >= pauseAt + fadeLength && n < pauseAt + fadeLength + held {
                gain = 0
            } else if n >= pauseAt + fadeLength + held {
                let k = n - (pauseAt + fadeLength + held)
                source = pauseAt + fadeLength + k
                gain = k < fadeLength ? 0.5 - 0.5 * cos(Double.pi * Double(k + 1) / Double(fadeLength)) : 1
            }
            for channel in 0..<2 {
                let value = gain * Double(channel == 0 ? a0.left[source] : a0.right[source])
                transportWorst = max(transportWorst, abs(value - Double(channel == 0 ? transportOutput.left[n] : transportOutput.right[n])))
            }
        }
        let pauseEvent = transport.events.map { transport.describe($0.event) }.first { $0.hasPrefix("pauseCompleted") } ?? "none"
        log.expect("6f pause/resume keeps position", transportWorst <= 1e-5 && pauseEvent == "pauseCompleted(token 7 @\(pauseAt + fadeLength))",
                   "max |out - expected| \(sci(transportWorst)); \(pauseEvent); resumed at track \(f(Double(pauseAt + fadeLength) / fs, 3)) s")

        // Unopenable files: start/skip targets are replaced by the next track from the queue.
        let missing = env.track("missing", env.temporary.appendingPathComponent("does-not-exist.wav"))
        let recovery = OfflineHarness(depth: 0.36)
        recovery.nextTrack = { previous in previous.id == "missing" ? trackB : nil }
        recovery.start(missing)
        var recoveryOutput = recovery.render(frames: Int(2 * fs))
        recovery.nextTrack = { previous in previous.id == "missing" ? trackC : nil }
        recovery.skip(to: missing, crossfade: 1.5)
        recovery.render(frames: Int(3 * fs), into: &recoveryOutput)
        let recoveryEvents = recovery.events.map { recovery.describe($0.event) }
        let recovered = recoveryEvents.filter { $0.hasPrefix("failed(missing") }.count == 2
            && recoveryEvents.contains("needNext(after missing, replacing true)")
            && recoveryEvents.contains("becameAudible(B-grooves @0)")
            && recoveryEvents.contains("becameAudible(C-electronic2 @\(Int(2 * fs)))")
            && recoveryEvents.contains("finished(B-grooves @\(Int(3.5 * fs)), listened \(Int(3.5 * fs)) frames, skipped true)")
        log.note("events: " + recoveryEvents.joined(separator: "; "))
        log.expect("6g missing file at start and at skip", recovered && allFinite(recoveryOutput) && peak(recoveryOutput) > 0.01,
                   "start -> B plays from frame 0; skip -> C crossfades in at 2 s, B reported skipped after 3.5 s")
    }

    // 7. Offline speed: 60 s with two tracks overlapping the whole time, effect at medium.
    static func checkPerformance(_ env: CheckEnvironment, _ log: CheckLog) throws {
        log.section("7. Performance")
        let fs = env.sampleRate
        let totalA = try AudioIO.frameCount(env.electronic)
        let frames = Int(60 * fs)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer { output.deallocate() }

        func timeRender(crossfade: Double, startTime: Double, next: EngineTrack?) -> (seconds: Double, maxVoices: Int) {
            let core = FocusRenderCore()
            core.setEffectDepth(EffectLevel.medium.depth, rampSeconds: 0)
            core.setCrossfadeSeconds(crossfade)
            let begin = DispatchTime.now().uptimeNanoseconds
            core.start(track: env.track("A", env.electronic, gainDB: -3.8, hz: 16, offset: env.originalAnchor),
                       serial: 1, fadeIn: 0, startTime: startTime)
            var maxVoices = 0
            var done = 0
            while done < frames {
                for event in core.drainEvents() {
                    if case .needNext(let after, _) = event { core.setNext(next, serial: 2, after: after) }
                }
                core.render(into: output + 2 * done, frames: 512)
                maxVoices = max(maxVoices, core.voices.count)
                done += 512
            }
            return (Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e9, maxVoices)
        }
        let trackB = env.track("B", env.grooves, gainDB: -2, hz: 16, offset: 0.05)
        let overlap = timeRender(crossfade: 60, startTime: Double(totalA) / fs - 60, next: trackB)
        let single = timeRender(crossfade: 8, startTime: 30, next: nil)
        log.expect("7a 60 s, two tracks overlapping, medium", overlap.seconds < 1.0 && overlap.maxVoices == 2,
                   "\(f(overlap.seconds, 3)) s (\(f(60 / overlap.seconds, 0))x real time), up to \(overlap.maxVoices) voices; one track: \(f(single.seconds, 3)) s")
    }

    // 9. Background noise: off leaves the music bit-identical, on adds noise at the calibrated
    //    level, switching kinds fades through silence, and pausing silences it with the music.
    static func checkNoise(_ env: CheckEnvironment, _ log: CheckLog) throws {
        log.section("9. Background noise under the music")
        let fs = env.sampleRate
        let track = env.track("synthetic", try env.synthetic(), hz: 16)
        func render(_ setup: (FocusRenderCore) -> Void, seconds: Double, then: ((OfflineHarness) -> Void)? = nil, more: Double = 0) -> Stereo {
            let harness = OfflineHarness(depth: 0.36)
            setup(harness.core)
            harness.start(track)
            var output = harness.render(frames: Int(seconds * fs))
            if let then {
                then(harness)
                harness.render(frames: Int(more * fs), into: &output)
            }
            return output
        }
        func rmsDB(_ a: Stereo, minus b: Stereo, from start: Double, to end: Double) -> Double {
            var sum = 0.0
            let lo = Int(start * fs), hi = min(Int(end * fs), a.count, b.count)
            for i in lo..<hi {
                let l = Double(a.left[i] - b.left[i]), r = Double(a.right[i] - b.right[i])
                sum += l * l + r * r
            }
            return 10 * log10(max(sum / Double(2 * max(1, hi - lo)), 1e-20))
        }

        let plain = render({ _ in }, seconds: 6)
        let off = render({ $0.setNoise(.off, level: 0.6, rampSeconds: 0) }, seconds: 6)
        log.expect("9a noise off leaves the music untouched", plain.left == off.left && plain.right == off.right, "bit-identical over 6 s")

        // Calibrated levels (gain 1 = -18 LUFS; level 1 = -2 dB): RMS brown about -20.4 dBFS, pink -22.7, white -25.9.
        for (kind, name, expected) in [(FocusNoiseKind.brown, "brown", -20.4), (.pink, "pink", -22.7), (.white, "white", -25.9)] {
            let with = render({ $0.setNoise(kind, level: 1, rampSeconds: 0) }, seconds: 6)
            let level = rmsDB(with, minus: plain, from: 1, to: 6)
            let peak = with.left.map(abs).max() ?? 0
            let finite = !with.left.contains { !$0.isFinite } && !with.right.contains { !$0.isFinite }
            log.expect("9b \(name) at level 100%", abs(level - expected) < 1.5 && peak <= 1 && finite,
                       "noise RMS \(f(level, 2)) dBFS (expected \(f(expected, 1)) ± 1.5), mix peak \(f(Double(peak), 3)), all finite \(finite)")
        }

        let switched = render({ $0.setNoise(.pink, level: 0.6, rampSeconds: 0) }, seconds: 3,
                              then: { $0.core.setNoise(.brown, level: 0.6) }, more: 3)
        let before = rmsDB(switched, minus: plain, from: 2, to: 3)
        let dip = rmsDB(switched, minus: plain, from: 3.22, to: 3.26)
        let after = rmsDB(switched, minus: plain, from: 4, to: 6)
        log.expect("9c pink to brown fades through silence", dip < before - 14 && abs(after - (-20.4 - 9.6)) < 1.5,
                   "pink \(f(before, 1)) dBFS, at the switch \(f(dip, 1)) dBFS, brown \(f(after, 1)) dBFS (expected \(f(-30.0, 1)) at 60%)")

        let paused = render({ $0.setNoise(.pink, level: 0.6, rampSeconds: 0) }, seconds: 2,
                            then: { $0.core.pause(fade: 0.1, token: 1) }, more: 1)
        let tail = paused.left[Int(2.5 * fs)...].allSatisfy { $0 == 0 } && paused.right[Int(2.5 * fs)...].allSatisfy { $0 == 0 }
        log.expect("9d pause silences the noise too", tail, "last 0.5 s all zeros \(tail)")

        // Rain, waves and stream loop a recording whose last frame flows into its first.
        let (loopURL, loopAudio) = try env.noiseFile("noise-loop-a", seconds: 1.5, seed: 91)
        let (otherURL, _) = try env.noiseFile("noise-loop-b", seconds: 2.25, seed: 92)
        let loopFrames = loopAudio.count
        if let recording = FocusNoiseRecording(kind: .rain, url: loopURL, sampleRate: fs, startFrame: loopFrames - 300) {
            let total = loopFrames * 3 + 777
            let played = renderRecording(recording, frames: total)
            let wanted = Stereo(left: (0..<total).map { loopAudio.left[(loopFrames - 300 + $0) % loopFrames] },
                                right: (0..<total).map { loopAudio.right[(loopFrames - 300 + $0) % loopFrames] })
            log.expect("9e a recording loops sample-exactly", played.left == wanted.left && played.right == wanted.right && !recording.failed,
                       "\(total) frames over 4 wraps (uneven blocks) equal the file repeated: \(played.left == wanted.left && played.right == wanted.right)")
        } else {
            log.expect("9e a recording loops sample-exactly", false, "could not open the test loop")
        }

        // The file is 0.1 rms per channel (-20 dBFS); level 100% is 2 dB under gain 1.
        let recorded = render({ $0.setNoiseRecordings([.rain: loopURL]); $0.setNoise(.rain, level: 1, rampSeconds: 0) }, seconds: 4)
        let recordedLevel = rmsDB(recorded, minus: plain, from: 1, to: 4)
        log.expect("9f a recording plays at its own level", abs(recordedLevel - (-22.0)) < 0.3,
                   "noise RMS \(f(recordedLevel, 2)) dBFS (file -20.0, level 100% = -2 dB)")

        let missing = render({ $0.setNoiseRecordings([.rain: loopURL]); $0.setNoise(.ocean, level: 1, rampSeconds: 0) }, seconds: 3)
        log.expect("9g a kind without its file stays silent", missing.left == plain.slice(0..<missing.count).left
                   && missing.right == plain.slice(0..<missing.count).right, "bit-identical to the music alone over 3 s")

        let crossed = render({ $0.setNoiseRecordings([.rain: loopURL, .stream: otherURL]); $0.setNoise(.rain, level: 0.6, rampSeconds: 0) },
                             seconds: 3, then: { $0.core.setNoise(.stream, level: 0.6) }, more: 3)
        let rainLevel = rmsDB(crossed, minus: plain, from: 2, to: 3)
        let gap = rmsDB(crossed, minus: plain, from: 3.22, to: 3.26)
        let streamLevel = rmsDB(crossed, minus: plain, from: 4, to: 6)
        log.expect("9h rain to stream fades through silence", gap < rainLevel - 14 && abs(rainLevel - (-31.6)) < 0.5
                   && abs(streamLevel - (-31.6)) < 0.5,
                   "rain \(f(rainLevel, 1)) dBFS, at the switch \(f(gap, 1)) dBFS, stream \(f(streamLevel, 1)) dBFS (expected -31.6 at 60%)")

        // The app's own loops (Audio/Noise/LoopsShare, bundled by Scripts/build-app.sh): stored at the engine rate, decoded
        // exactly across the wrap, and with no jump there larger than the recording's own.
        for name in ["rain", "ocean", "stream"] {
            let url = env.root.appendingPathComponent("Audio/Noise/LoopsShare/\(name).flac")
            guard let file = try? AVAudioFile(forReading: url),
                  let recording = FocusNoiseRecording(kind: .rain, url: url, sampleRate: fs, startFrame: Int(file.length) - 4_800) else {
                log.expect("9i \(name) loop", false, "missing or unreadable: \(url.path)")
                continue
            }
            let length = Int(file.length)
            let across = renderRecording(recording, frames: 9_600)
            let end = try AudioIO.read(url, start: length - 4_800)
            let start = try AudioIO.read(url, start: 0, frames: 4_800)
            let exact = across.left == end.left + start.left && across.right == end.right + start.right
            let whole = try AudioIO.read(url)
            var steps: [Float] = []
            steps.reserveCapacity(whole.count)
            for i in 1..<whole.count { steps.append(max(abs(whole.left[i] - whole.left[i - 1]), abs(whole.right[i] - whole.right[i - 1]))) }
            let wrapStep = max(abs(whole.left[0] - whole.left[length - 1]), abs(whole.right[0] - whole.right[length - 1]))
            let below = steps.filter { $0 < wrapStep }.count
            let percentile = 100 * Double(below) / Double(max(1, steps.count))
            log.expect("9i \(name) loop", file.fileFormat.sampleRate == fs && recording.frameCount == length && exact && percentile < 99.9,
                       "\(f(Double(length) / fs, 1)) s at \(Int(file.fileFormat.sampleRate)) Hz, wrap decoded exactly \(exact), "
                       + "wrap step at the \(f(percentile, 1))th percentile of the file's own steps")
        }
    }

    /// Plays `frames` of a recording at gain 1 in uneven blocks, as the core's sub-blocks would.
    static func renderRecording(_ recording: FocusNoiseRecording, frames total: Int) -> Stereo {
        var left = [Float](repeating: 0, count: total), right = [Float](repeating: 0, count: total)
        let ones = [Float](repeating: 1, count: 512)
        let blocks = [512, 37, 480, 512, 1, 256]
        var done = 0, index = 0
        while done < total {
            let n = min(blocks[index % blocks.count], total - done)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    ones.withUnsafeBufferPointer { g in
                        recording.render(addingInto: l.baseAddress! + done, r.baseAddress! + done, gains: g.baseAddress!, count: n)
                    }
                }
            }
            done += n
            index += 1
        }
        return Stereo(left: left, right: right)
    }

    // 10. Each track plays for the target by repeating its middle: the timeline (passes, seams,
    //     total), events, bit-identity with looping off, the seam law, the effect's phase across
    //     seams, skip/pause/target changes/starts inside a loop, and a 30-minute play of a real track.

    /// What a looping voice plays at depth 0: file `x` with seams at `end + (k-1) * period`,
    /// gains cos/sin divided by sqrt(1 + r sin 2 theta).
    struct LoopModel {
        let x: Stereo
        let start: Int, end: Int, seam: Int, repeats: Int, correlation: Double
        var period: Int { end - start }
        var length: Int { x.count + repeats * period }

        func seamBegin(_ k: Int) -> Int { end - seam / 2 + (k - 1) * period }

        func value(_ v: Int, right: Bool) -> Double {
            let channel = right ? x.right : x.left
            var begun = 0
            while begun < repeats && v >= seamBegin(begun + 1) { begun += 1 }
            if begun > 0 && v < seamBegin(begun) + seam {
                let theta = Double.pi / 2 * Double(v - seamBegin(begun)) / Double(seam)
                let norm = 1 / (1 + correlation * sin(2 * theta)).squareRoot()
                return norm * (cos(theta) * Double(channel[v - (begun - 1) * period]) + sin(theta) * Double(channel[v - begun * period]))
            }
            return Double(channel[v - begun * period])
        }

        func render(_ range: Range<Int>) -> Stereo {
            Stereo(left: range.map { Float(value($0, right: false)) }, right: range.map { Float(value($0, right: true)) })
        }
    }

    static func checkLoop(_ env: CheckEnvironment, _ log: CheckLog) throws {
        log.section("10. Each track plays for the target by repeating its middle (offline)")
        let fs = env.sampleRate
        let seam = 2 * Int((FocusRenderCore.loopSeamSeconds / 2 * fs).rounded())
        func sec(_ frames: Int) -> String { f(Double(frames) / fs, 3) + " s" }

        // 20 s of noise, loop 4-14 s (10 s), target 50 s -> 3 repeats, exactly 50 s.
        let (noiseURL, noise) = try env.noiseFile("loop-noise", seconds: 20, seed: 77)
        let looped = env.loopTrack("loop", noiseURL, start: 4, end: 14, hz: nil)
        let model = LoopModel(x: noise, start: Int(4 * fs), end: Int(14 * fs), seam: seam, repeats: 3, correlation: 0)
        let total = model.length

        let harness = OfflineHarness(depth: 0)
        harness.core.setMinimumTrackSeconds(50)
        harness.start(looped)
        let output = harness.render(frames: total + Int(fs))
        let expected = model.render(0..<total)
        let structure = maxAbsDifference(output, expected, range: 0..<total)
        let silentAfter = output.left[total...].allSatisfy { $0 == 0 } && output.right[total...].allSatisfy { $0 == 0 }
        let events = harness.events.map { harness.describe($0.event) }
        let audible = events.filter { $0.hasPrefix("becameAudible") }
        let finished = events.filter { $0.hasPrefix("finished") }
        log.note("seams begin at " + (1...3).map { sec(model.seamBegin($0)) }.joined(separator: ", ") + "; events: " + events.joined(separator: "; "))
        log.expect("10a repeats until the target, then the natural end", structure <= 1e-5 && silentAfter && total == Int(50 * fs),
                   "20 s file, loop 4-14 s, target 50 s: 3 passes, \(sec(total)) in all; max |out - model| \(sci(structure)) over every frame (seams cos/sin, \(seam) frames); silent after the end \(silentAfter)")
        log.expect("10b one start and one finish per play", audible == ["becameAudible(loop @0)"]
                   && finished == ["finished(loop @\(total), listened \(total) frames, skipped false)"]
                   && events.contains("ended(@\(total))"),
                   "\(audible.count) becameAudible, \(finished.count) finished (listened \(sec(total)), all passes)")

        // Looping off is today's engine: target 0 with loop points == no loop points, bit for bit,
        // with the effect running; and a looping play is bit-identical to it until the first seam.
        func render(_ track: EngineTrack, target: Double, seconds: Double, depth: Float) -> Stereo {
            let h = OfflineHarness(depth: depth)
            h.core.setMinimumTrackSeconds(target)
            h.start(track)
            return h.render(frames: Int(seconds * fs))
        }
        let electronic = env.electronicLoop
        let realLooped = env.loopTrack("electronic", env.electronic, start: electronic.start, end: electronic.end,
                                       correlation: electronic.correlation, gainDB: -3.8, hz: 16, offset: env.originalAnchor)
        let realPlain = env.track("electronic", env.electronic, gainDB: -3.8, hz: 16, offset: env.originalAnchor)
        if env.hasSongFixtures {
            let offStart = Double(Int(electronic.end * fs) - seam / 2) / fs - 6
            func renderFrom(_ track: EngineTrack, target: Double) -> Stereo {
                let h = OfflineHarness(depth: 0.36)
                h.core.setMinimumTrackSeconds(target)
                h.start(track, startTime: offStart)
                return h.render(frames: Int(10 * fs))
            }
            let zeroTarget = renderFrom(realLooped, target: 0)
            let noLoop = renderFrom(realPlain, target: 1800)
            let looping = renderFrom(realLooped, target: 1800)
            let untilSeam = Int(6 * fs)
            let identical = zeroTarget.left == noLoop.left && zeroTarget.right == noLoop.right
            let prefix = Array(looping.left[0..<untilSeam]) == Array(noLoop.left[0..<untilSeam])
                && Array(looping.right[0..<untilSeam]) == Array(noLoop.right[0..<untilSeam])
            let differs = maxAbsDifference(looping, noLoop, range: untilSeam..<looping.count)
            let shortTarget = render(looped, target: 15, seconds: 21, depth: 0)
            let plainNoise = render(env.track("noise", noiseURL, hz: nil), target: 1800, seconds: 21, depth: 0)
            let belowFile = shortTarget.left == plainNoise.left && shortTarget.right == plainNoise.right
            log.expect("10c target 0 is bit-identical to no looping", identical && prefix && belowFile && differs > 0.01,
                       "real track, medium effect, 10 s across where the first seam would be: target 0 == no loop points (bit-identical \(identical)); looping == no loop up to the seam (bit-identical \(prefix)), then differs (max \(f(differs, 3))); a target shorter than the file plays it once (bit-identical \(belowFile))")
        } else {
            log.note("10c skipped: needs \(env.electronic.path)")
        }

        // The seam law: equal power, measured. Uncorrelated sides (r 0) keep their level; identical
        // sides swell 3 dB under plain cos/sin and stay level with the correlation correction.
        func seamLevels(_ url: URL, correlation: Double, pattern: Bool) -> (inside: Double, outside: Double) {
            let h = OfflineHarness(depth: 0)
            h.core.setMinimumTrackSeconds(30)
            h.start(env.loopTrack("seam", url, start: pattern ? 5 : 4, end: pattern ? 15 : 14, correlation: correlation, hz: nil))
            let out = h.render(frames: Int(17 * fs))
            let centre = Int((pattern ? 15 : 14) * fs)
            let reference = rms(out, range: (centre - Int(2.5 * fs))..<(centre - Int(1.5 * fs)))
            var inside = 0.0, outside = 0.0
            var w = centre - Int(1.5 * fs)
            while w + 4800 <= centre + Int(1.5 * fs) {
                let level = abs(amplitudeDB(rms(out, range: w..<(w + 4800)) / reference))
                if w + 2400 > centre - seam / 2 && w + 2400 < centre + seam / 2 { inside = max(inside, level) } else { outside = max(outside, level) }
                w += 4800
            }
            return (inside, outside)
        }
        let (patternURL, _) = try env.noiseFile("loop-pattern", seconds: 20, seed: 78, pattern: 5)
        let uncorrelated = seamLevels(noiseURL, correlation: 0, pattern: false)
        let identicalPlain = seamLevels(patternURL, correlation: 0, pattern: true)
        let identicalCorrected = seamLevels(patternURL, correlation: 0.9, pattern: true)
        log.expect("10d seam crossfade keeps the power level", uncorrelated.inside <= 0.3 && identicalCorrected.inside <= 0.3
                   && abs(identicalPlain.inside - 3.01) <= 0.3,
                   "largest 100 ms level change inside the seam: uncorrelated sides, r 0: \(f(uncorrelated.inside, 2)) dB (outside \(f(uncorrelated.outside, 2))); identical sides: plain cos/sin \(f(identicalPlain.inside, 2)) dB, with r 0.9 \(f(identicalCorrected.inside, 2)) dB")

        // The effect follows track time on both sides of a seam: y = x - d*shape(t)*window*band
        // with t the file time each side reads (direct FIR convolution, like 3d).
        let (shortURL, short) = try env.noiseFile("loop-effect", seconds: 8, seed: 79)
        let hz = 16.0, offset = 0.0371, depth = 0.5
        let effectHarness = OfflineHarness(depth: Float(depth))
        effectHarness.core.setMinimumTrackSeconds(14)
        effectHarness.start(env.loopTrack("effect", shortURL, start: 2, end: 5, hz: hz, offset: offset))
        let effectOut = effectHarness.render(frames: Int(14 * fs))
        let fir = FocusBandFIR.standard
        let taps = fir.coefficients.map(Double.init)
        let fileFrames = short.count
        let fade = min(Int((0.25 * fs).rounded()), fileFrames / 4)
        func direct(_ m: Int, right: Bool) -> Double {
            let x = right ? short.right : short.left
            var band = 0.0
            for k in 0..<fir.tapCount {
                let index = m + fir.groupDelay - k
                if index >= 0 && index < fileFrames { band += taps[k] * Double(x[index]) }
            }
            let shape = 0.5 * (1 - cos(2 * Double.pi * hz * (Double(m) / fs - offset)))
            var window = 1.0
            if m >= fileFrames - fade {
                window = 0.5 - 0.5 * cos(Double.pi * Double(fileFrames - 1 - m) / Double(fade - 1))
            } else if m < fade {
                window = 0.5 - 0.5 * cos(Double.pi * Double(m) / Double(fade - 1))
            }
            return Double(x[m]) - depth * shape * window * band
        }
        let effectModel = LoopModel(x: short, start: Int(2 * fs), end: Int(5 * fs), seam: seam, repeats: 2, correlation: 0)
        var effectWorst = 0.0, effectChecked = 0
        var probes: [Int] = []
        for centre in [3.0, 5.0, 6.5, 8.0, 10.0] { probes += Array(stride(from: Int((centre - 0.6) * fs), to: Int((centre + 0.6) * fs), by: 211)) }
        probes += Array(stride(from: Int(14 * fs) - fade - 500, to: Int(14 * fs), by: 37))
        for v in probes {
            var begun = 0
            while begun < 2 && v >= effectModel.seamBegin(begun + 1) { begun += 1 }
            for right in [false, true] {
                let value: Double
                if begun > 0 && v < effectModel.seamBegin(begun) + seam {
                    let theta = Double.pi / 2 * Double(v - effectModel.seamBegin(begun)) / Double(seam)
                    value = cos(theta) * direct(v - (begun - 1) * effectModel.period, right: right)
                        + sin(theta) * direct(v - begun * effectModel.period, right: right)
                } else {
                    value = direct(v - begun * effectModel.period, right: right)
                }
                effectWorst = max(effectWorst, abs(value - Double(right ? effectOut.right[v] : effectOut.left[v])))
                effectChecked += 1
            }
        }
        log.expect("10e effect stays in phase with track time across seams", effectWorst <= 5e-6,
                   "8 s noise, loop 2-5 s, 2 repeats, depth 0.5, 16 Hz, offset 37.1 ms: max error vs the direct formula at each side's file time \(sci(effectWorst)) over \(effectChecked) samples (before, in and after both seams, end ramp)")

        // Skip in the middle of a seam: the usual equal-power skip over what the loop plays.
        let (otherURL, other) = try env.noiseFile("loop-other", seconds: 8, seed: 80)
        let skipAt = Int(14 * fs), skipLength = Int(1.5 * fs)
        let skipHarness = OfflineHarness(depth: 0)
        skipHarness.core.setMinimumTrackSeconds(50)
        skipHarness.start(looped)
        var skipOut = skipHarness.render(frames: skipAt)
        skipHarness.skip(to: env.track("other", otherURL, hz: nil), crossfade: 1.5)
        skipHarness.render(frames: Int(3 * fs), into: &skipOut)
        var skipWorst = 0.0
        for n in skipAt..<skipOut.count {
            let p = Double(n - skipAt) / Double(skipLength)
            for right in [false, true] {
                let a = model.value(n, right: right)
                let b = Double(right ? other.right[n - skipAt] : other.left[n - skipAt])
                let value = (p < 1 ? cos(Double.pi / 2 * p) * a : 0) + (p < 1 ? sin(Double.pi / 2 * p) : 1) * b
                skipWorst = max(skipWorst, abs(value - Double(right ? skipOut.right[n] : skipOut.left[n])))
            }
        }
        let skipEvents = skipHarness.events.map { skipHarness.describe($0.event) }
        let skipFinished = skipEvents.filter { $0.hasPrefix("finished(loop") }
        log.expect("10f skip during a seam crossfades as before", skipWorst <= 1e-5
                   && skipFinished == ["finished(loop @\(skipAt + skipLength), listened \(skipAt + skipLength) frames, skipped true)"],
                   "skip at 14.0 s (seam middle), 1.5 s: max |out - (cos * loop + sin * next)| \(sci(skipWorst)); \(skipFinished.first ?? "no finish")")

        // Pause in a seam (0.5 s fade), hold 1 s, resume (0.5 s): the seam picks up where it was.
        let pauseAt = Int(13.8 * fs), fadeLength = Int(0.5 * fs), held = Int(1 * fs)
        let pauseHarness = OfflineHarness(depth: 0)
        pauseHarness.core.setMinimumTrackSeconds(50)
        pauseHarness.start(looped)
        var pauseOut = pauseHarness.render(frames: pauseAt)
        pauseHarness.core.pause(fade: 0.5, token: 3)
        pauseHarness.render(frames: fadeLength + held, into: &pauseOut)
        pauseHarness.core.resume(fade: 0.5)
        pauseHarness.render(frames: Int(2 * fs), into: &pauseOut)
        var pauseWorst = 0.0
        for n in 0..<pauseOut.count {
            var gain = 1.0, source = n
            if n >= pauseAt && n < pauseAt + fadeLength {
                gain = 1 - (0.5 - 0.5 * cos(Double.pi * Double(n - pauseAt + 1) / Double(fadeLength)))
            } else if n >= pauseAt + fadeLength && n < pauseAt + fadeLength + held {
                gain = 0
            } else if n >= pauseAt + fadeLength + held {
                let k = n - (pauseAt + fadeLength + held)
                source = pauseAt + fadeLength + k
                gain = k < fadeLength ? 0.5 - 0.5 * cos(Double.pi * Double(k + 1) / Double(fadeLength)) : 1
            }
            for right in [false, true] {
                pauseWorst = max(pauseWorst, abs(gain * model.value(source, right: right) - Double(right ? pauseOut.right[n] : pauseOut.left[n])))
            }
        }
        log.expect("10g pause and resume inside a seam", pauseWorst <= 1e-5,
                   "pause at 13.8 s (seam 13.5-14.5 s), resumed after 1 s: max |out - model| \(sci(pauseWorst))")

        // Changing the target mid-play re-plans from the next seam on.
        func endFrame(target: Double, change: Double, to newTarget: Double) -> (ended: Int64, listened: Int) {
            let h = OfflineHarness(depth: 0)
            h.core.setMinimumTrackSeconds(target)
            h.start(looped)
            _ = h.render(frames: Int(change * fs))
            h.core.setMinimumTrackSeconds(newTarget)
            _ = h.render(frames: Int((60 - change) * fs))
            var ended: Int64 = -1, listened = -1
            for item in h.events {
                if case .ended(let frame) = item.event { ended = frame }
                if case .finished(_, _, let frames, _) = item.event { listened = frames }
            }
            return (ended, listened)
        }
        let cases: [(String, Double, Double, Double, Double)] = [
            ("50 s -> off after seam 1", 50, 16, 0, 30), ("50 s -> off inside seam 1", 50, 14, 0, 30),
            ("off -> 50 s at 2 s", 0, 2, 50, 50), ("off -> 50 s past the seam point (13.6 s)", 0, 13.6, 50, 20)]
        var targetOK = true
        var targetNotes: [String] = []
        for (name, from, at, to, want) in cases {
            let result = endFrame(target: from, change: at, to: to)
            let ok = result.ended == Int64(want * fs) && result.listened == Int(want * fs)
            targetOK = targetOK && ok
            targetNotes.append("\(name): \(sec(Int(result.ended))) (want \(f(want, 0)) s)")
        }
        log.expect("10h target change mid-play", targetOK, targetNotes.joined(separator: "; "))

        // start(startTime:) inside the loop (a restart where playback was heard).
        let restartAt = 29.0, insideSeam = 24.0
        let restart = OfflineHarness(depth: 0)
        restart.core.setMinimumTrackSeconds(50)
        restart.start(looped, startTime: restartAt)
        let restartOut = restart.render(frames: Int(21.5 * fs))
        let restartDiff = maxAbsDifference(restartOut, model.render(Int(restartAt * fs)..<total), range: 0..<(total - Int(restartAt * fs)))
        var restartEnded: Int64 = -1
        for item in restart.events { if case .ended(let frame) = item.event { restartEnded = frame } }
        let seamStart = OfflineHarness(depth: 0)
        seamStart.core.setMinimumTrackSeconds(50)
        seamStart.start(looped, startTime: insideSeam)
        let seamStartOut = seamStart.render(frames: Int(2 * fs))
        var seamStartWorst = 0.0
        for n in 0..<seamStartOut.count {
            let v = Int(insideSeam * fs) + n
            let wantLeft = v < model.seamBegin(2) + seam ? Double(noise.left[v - 2 * model.period]) : model.value(v, right: false)
            seamStartWorst = max(seamStartWorst, abs(wantLeft - Double(seamStartOut.left[n])))
        }
        log.expect("10i start inside the loop", restartDiff <= 1e-6 && restartEnded == Int64(total - Int(restartAt * fs)) && seamStartWorst <= 1e-6,
                   "start at 29 s (pass 2): max |out - model| \(sci(restartDiff)), ends after \(sec(Int(restartEnded))) (at 50 s); start at 24 s (inside seam 2) plays its incoming side: \(sci(seamStartWorst))")

        // A start in the play-out after the last seam (a seek near the end) plays that ending:
        // 47 s is past where a 4th seam would begin (43.5 s), but the play has 3 passes.
        let tailAt = 47.0
        let tailHarness = OfflineHarness(depth: 0)
        tailHarness.core.setMinimumTrackSeconds(50)
        tailHarness.start(looped, startTime: tailAt)
        let tailFrames = total - Int(tailAt * fs)
        let tailOut = tailHarness.render(frames: tailFrames + Int(fs))
        let tailDiff = maxAbsDifference(tailOut, model.render(Int(tailAt * fs)..<total), range: 0..<tailFrames)
        let tailSilent = tailOut.left[tailFrames...].allSatisfy { $0 == 0 } && tailOut.right[tailFrames...].allSatisfy { $0 == 0 }
        var tailEnded: Int64 = -1
        for item in tailHarness.events { if case .ended(let frame) = item.event { tailEnded = frame } }
        log.expect("10k start in the play-out after the last seam", tailDiff <= 1e-6 && tailSilent && tailEnded == Int64(tailFrames),
                   "start at 47 s: max |out - model| \(sci(tailDiff)), ends after \(sec(Int(tailEnded))) (at 50 s, no extra pass), silent after \(tailSilent)")

        // A whole 30-minute play of a real track with its analysed loop points, medium effect.
        guard env.hasSongFixtures else {
            log.note("10j skipped: needs \(env.electronic.path)")
            return
        }
        let begin = DispatchTime.now().uptimeNanoseconds
        let play = OfflineHarness(depth: EffectLevel.medium.depth)
        play.core.setMinimumTrackSeconds(1800)
        play.start(realLooped)
        let fileFrames2 = try AudioIO.frameCount(env.electronic)
        let s0 = Int((electronic.start * fs).rounded()), e0 = Int((electronic.end * fs).rounded())
        let period = e0 - s0
        let repeats = (Int(1800 * fs) - fileFrames2 + period - 1) / period
        let playLength = fileFrames2 + repeats * period
        let margin = Int(1 * fs)
        var windows: [Int: Stereo] = [:]
        var controls: [Int: Stereo] = [:]
        let centres = (1...repeats).map { e0 + ($0 - 1) * period }
        let controlCentres = centres.map { $0 + Int(32 * fs) }
        var rendered = 0
        while rendered < playLength + Int(fs) {
            let chunk = play.render(frames: Int(fs))
            for (index, centre) in (centres + controlCentres).enumerated() {
                let lo = centre - seam / 2 - margin, hi = centre + seam / 2 + margin
                let a = max(lo, rendered), b = min(hi, rendered + chunk.count)
                guard a < b else { continue }
                let isSeam = index < centres.count
                var buffer = (isSeam ? windows[centre] : controls[centre]) ?? Stereo(reserving: hi - lo)
                buffer.left.append(contentsOf: chunk.left[(a - rendered)..<(b - rendered)])
                buffer.right.append(contentsOf: chunk.right[(a - rendered)..<(b - rendered)])
                if isSeam { windows[centre] = buffer } else { controls[centre] = buffer }
            }
            rendered += chunk.count
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e9
        var playEnded: Int64 = -1, playListened = -1, playAudible = 0, playFinished = 0
        for item in play.events {
            switch item.event {
            case .ended(let frame): playEnded = frame
            case .finished(_, _, let frames, _): playListened = frames; playFinished += 1
            case .becameAudible: playAudible += 1
            default: break
            }
        }
        let gain = Float(pow(10.0, -3.8 / 20.0))
        let dryA = try AudioIO.read(env.electronic, start: e0 - seam / 2 - margin, frames: seam + 2 * margin).scaled(gain)
        let dryB = try AudioIO.read(env.electronic, start: s0 - seam / 2 - margin, frames: seam + 2 * margin).scaled(gain)
        let stepBound = 2.0.squareRoot() / (1 + min(electronic.correlation, 0)).squareRoot() * max(maxJump(dryA, range: 0..<dryA.count), maxJump(dryB, range: 0..<dryB.count))
        let worstStep = centres.compactMap { windows[$0] }.map { maxJump($0, range: 0..<$0.count) }.max() ?? .infinity
        // Level of the seam's middle 0.5 s against the second before and after it.
        func middleLevel(_ audio: Stereo) -> Double {
            let mid = audio.count / 2, quarter = seam / 4
            let around = (rms(audio, range: (mid - 3 * seam / 2)..<(mid - seam / 2)) + rms(audio, range: (mid + seam / 2)..<(mid + 3 * seam / 2))) / 2
            return amplitudeDB(rms(audio, range: (mid - quarter)..<(mid + quarter)) / around)
        }
        let seamLevel = centres.compactMap { windows[$0] }.map(middleLevel)
        let controlLevel = controlCentres.compactMap { controls[$0] }.map(middleLevel)
        let seamList: String = centres.map { sec($0) }.joined(separator: ", ")
        let seamLevelList: String = seamLevel.map { f($0, 2) }.joined(separator: " ")
        let controlLevelList: String = controlLevel.map { f($0, 2) }.joined(separator: " ")
        log.note("30-minute play: seams at \(seamList); middle 0.5 s of each seam vs the second before and after: \(seamLevelList) dB (every pass plays the same audio); same measure on a bar line 32 s later: \(controlLevelList) dB")
        let timelineOK: Bool = playEnded == Int64(playLength) && playLength >= Int(1800 * fs) && playListened == playLength
        let eventsOK: Bool = playAudible == 1 && playFinished == 1
        let seamsOK: Bool = worstStep <= stepBound && windows.count == repeats
        log.expect("10j real track, 30-minute play", timelineOK && eventsOK && seamsOK,
                   "electronic-a, loop \(f(electronic.start, 3))-\(f(electronic.end, 3)) s (\(sec(period))), \(repeats) repeats: played \(sec(playLength)) (target 1800 s), 1 becameAudible, 1 finished listening \(sec(playListened)); max sample step at the seams \(f(worstStep, 4)) <= bound \(f(stepBound, 4)) (sqrt(2) x dry steps); rendered in \(f(seconds, 1)) s")
    }

    // 11. Real-time: the engine crosses a seam without underruns, a restart inside the loop keeps
    //     the timeline, and a changed target plus a skip end the play once.
    // 12. The focus pulse follows a beat map when the tempo drifts: a map of a steady grid sounds
    //     like the steady pulse, a drifting map matches the formula, a broken map falls back.
    static func checkBeatMap(_ env: CheckEnvironment, _ log: CheckLog) throws {
        log.section("12. The focus pulse follows the beat map")
        let fs = env.sampleRate
        let (url, audio) = try env.noiseFile("beat-map", seconds: 8, seed: 81)
        let depth = 0.5
        func render(_ track: EngineTrack) -> Stereo {
            let harness = OfflineHarness(depth: Float(depth))
            harness.core.setMinimumTrackSeconds(0)
            harness.start(track)
            return harness.render(frames: Int(8 * fs))
        }
        func track(_ id: String, hz: Double, offset: Double, beats: [Double]? = nil, cycles: Int = 0) -> EngineTrack {
            EngineTrack(id: id, url: url, gainDB: 0, modulationHz: hz, beatOffsetSeconds: offset,
                        beatTimes: beats, pulseCyclesPerBeat: cycles)
        }
        let steady = render(track("steady", hz: 16, offset: 0.0371))
        let gridBeats = (-1...17).map { 0.0371 + Double($0) * 0.5 }
        let asMap = render(track("map", hz: 16, offset: 0.0371, beats: gridBeats, cycles: 8))
        let sameDiff = maxAbsDifference(steady, asMap)
        log.expect("12a a map of a steady beat sounds like the steady pulse", sameDiff <= 2e-5,
                   "beats every 0.5 s from 37.1 ms, 8 cycles a beat vs 16 Hz from 37.1 ms: max difference \(sci(sameDiff)) over 8 s")

        // Tempo drifting from 0.62 s to 0.50 s a beat (97 -> 120 BPM), 10 cycles a beat.
        var drift: [Double] = [0.11]
        while drift.last! < 8.6 {
            let progress = min(1, drift.last! / 8)
            drift.append(drift.last! + 0.62 + (0.50 - 0.62) * progress)
        }
        let cycles = 10
        let drifting = render(track("drift", hz: 16.2, offset: 0.11, beats: drift, cycles: cycles))
        func phase(_ t: Double) -> Double {
            let b = drift, c = Double(cycles)
            if t < b[0] { return c * (t - b[0]) / (b[1] - b[0]) }
            if t >= b[b.count - 1] { return c * (Double(b.count - 1) + (t - b[b.count - 1]) / (b[b.count - 1] - b[b.count - 2])) }
            var k = 0
            while b[k + 1] <= t { k += 1 }
            return c * (Double(k) + (t - b[k]) / (b[k + 1] - b[k]))
        }
        let fir = FocusBandFIR.standard
        let taps = fir.coefficients.map(Double.init)
        let fileFrames = audio.count
        let fade = min(Int((0.25 * fs).rounded()), fileFrames / 4)
        func direct(_ m: Int, right: Bool) -> Double {
            let x = right ? audio.right : audio.left
            var band = 0.0
            for k in 0..<fir.tapCount {
                let index = m + fir.groupDelay - k
                if index >= 0 && index < fileFrames { band += taps[k] * Double(x[index]) }
            }
            let shape = 0.5 * (1 - cos(2 * Double.pi * phase(Double(m) / fs)))
            var window = 1.0
            if m >= fileFrames - fade {
                window = 0.5 - 0.5 * cos(Double.pi * Double(fileFrames - 1 - m) / Double(fade - 1))
            } else if m < fade {
                window = 0.5 - 0.5 * cos(Double.pi * Double(m) / Double(fade - 1))
            }
            return Double(x[m]) - depth * shape * window * band
        }
        var probes: [Int] = []
        for beat in drift.prefix(14) where beat > 0.3 && beat < 7.6 {
            probes += Array(stride(from: Int((beat - 0.05) * fs), to: Int((beat + 0.05) * fs), by: 97))
        }
        probes += Array(stride(from: Int(0.05 * fs), to: Int(0.4 * fs), by: 131))
        var worst = 0.0, onBeat = 0.0
        for m in probes {
            for right in [false, true] {
                worst = max(worst, abs(direct(m, right: right) - Double(right ? drifting.right[m] : drifting.left[m])))
            }
        }
        for beat in drift where beat > 0.3 && beat < 7.6 {
            let m = Int((beat * fs).rounded())
            onBeat = max(onBeat, 0.5 * (1 - cos(2 * Double.pi * phase(Double(m) / fs))))
        }
        log.expect("12b a drifting map: the pulse follows each beat", worst <= 1e-5 && onBeat <= 1e-3,
                   "beats 0.62 -> 0.50 s, 10 cycles a beat: max error vs the formula \(sci(worst)) over \(probes.count * 2) samples around beats and before the first; pulse at rest on beats (shape <= \(sci(onBeat)))")

        let broken = render(track("broken", hz: 16, offset: 0.0371, beats: [1.0, 1.0, 2.0], cycles: 8))
        let short = render(track("short", hz: 16, offset: 0.0371, beats: [1.0], cycles: 8))
        let noCycles = render(track("zero", hz: 16, offset: 0.0371, beats: gridBeats, cycles: 0))
        let fallback = broken.left == steady.left && short.left == steady.left && noCycles.left == steady.left
            && broken.right == steady.right
        log.expect("12c a broken map falls back to the steady pulse", fallback,
                   "repeated beat, a single beat, 0 cycles: bit-identical to the steady pulse \(fallback)")
    }

    static func checkLoopRealTime(_ env: CheckEnvironment, _ log: CheckLog) throws {
        log.section("11. Looping on the real-time engine (mixer output volume 0, engine volume 0)")
        let keepAlive = Timer(timeInterval: 0.05, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .default)
        defer { keepAlive.invalidate() }
        let recorder = Recorder()
        let engine = FocusAudioEngine()
        engine.outputMutedForTesting = true
        engine.setVolume(0)
        engine.setEffectLevel(.medium)
        engine.delegate = recorder
        let loop = env.electronicLoop
        let trackA = env.loopTrack("A-loop", env.electronic, start: loop.start, end: loop.end, correlation: loop.correlation,
                                   gainDB: -3.8, hz: 16, offset: env.originalAnchor)
        let trackB = env.track("B-grooves", env.grooves, gainDB: -2, hz: 16, offset: 0.05)
        let fileSeconds = Double(try AudioIO.frameCount(env.electronic)) / env.sampleRate

        // Start 2 s before the seam centre; after 4 s the play is 2 s into its first repeat.
        let startAt = loop.end - 2
        engine.start(with: trackA, fadeIn: 0.2, startTime: startAt)
        let started = Date()
        spin(4)
        let wall = Date().timeIntervalSince(started)
        let afterSeam = engine.currentTime
        log.expect("11a crosses a seam", engine.underrunCount == 0 && abs(afterSeam - (startAt + wall)) < 0.15
                   && recorder.current == [trackA.id] && recorder.finished.isEmpty && recorder.failures.isEmpty,
                   "position \(f(startAt, 3)) -> \(f(afterSeam, 3)) s after \(f(wall, 3)) s wall (seam at \(f(loop.end, 3)) s), underruns \(engine.underrunCount), one announcement, no finish")

        // Jump the play past the file's own length, then lose the output device: the restart
        // resumes at the play position (inside a repeat), not at a file position.
        let deep = fileSeconds + 20
        engine.start(with: trackA, fadeIn: 0.1, startTime: deep)
        spin(1)
        let systemProbe = engine.outputProbe
        engine.pausesWhenOutputLost = true
        engine.outputProbe = FocusOutputProbe(current: { FocusOutputDevice(id: 4243, uid: "loop-check-speakers") }, isConnected: { _ in false })
        engine.simulateConfigurationChangeForTesting()
        spin(0.8)
        let held = engine.currentTime
        engine.outputProbe = systemProbe
        engine.resume(fade: 0.2)
        spin(1)
        let resumed = engine.currentTime
        engine.pausesWhenOutputLost = false
        log.expect("11b restart inside a repeat keeps the play position", engine.isPlaying && held > fileSeconds && resumed > held + 0.7
                   && resumed < held + 1.2 && engine.underrunCount == 0,
                   "play position \(f(held, 3)) s (file is \(f(fileSeconds, 1)) s) -> \(f(resumed, 3)) s after resuming for 1 s, underruns \(engine.underrunCount)")

        // Target off mid-play, then a skip: one finish for the looping play. The restart above
        // began a new play at `held`, so it counts from there, plus the 1 s skip crossfade.
        recorder.finished.removeAll()
        engine.minimumTrackSeconds = 0
        spin(0.5)
        let beforeSkip = engine.currentTime
        engine.skip(to: trackB, crossfade: 1)
        spin(2)
        let finishedA = recorder.finished.filter { $0.id == trackA.id }
        let expectedListen = beforeSkip - held + 1
        log.expect("11c target change and skip", finishedA.count == 1 && finishedA[0].skipped && engine.currentTrack == trackB
                   && abs(finishedA[0].listened - expectedListen) < 0.4 && engine.underrunCount == 0,
                   "A finished \(finishedA.count)x, skipped \(finishedA.first.map { String($0.skipped) } ?? "-"), listened \(f(finishedA.first?.listened ?? -1, 3)) s (expected about \(f(expectedListen, 3)) s since the restart at \(f(held, 3)) s); now \(engine.currentTrack?.id ?? "-")")
        engine.stop()
    }

    // 8. Real AVAudioEngine, muted: underruns, pause/resume, skip, effect, duck, device change,
    //    automatic transition with delegate calls.
    final class Recorder: FocusAudioEngineDelegate {
        let begin = Date()
        var nextQueue: [EngineTrack] = []
        var asked: [String] = []
        var current: [String] = []
        var finished: [(id: String, listened: Double, skipped: Bool)] = []
        var failures: [String] = []
        var lostOutputs: [String] = []

        var elapsed: String { f(Date().timeIntervalSince(begin), 2) }

        func audioEngineNextTrack(_ engine: FocusAudioEngine, after current: EngineTrack) -> EngineTrack? {
            asked.append(current.id)
            return nextQueue.isEmpty ? nil : nextQueue.removeFirst()
        }

        func audioEngine(_ engine: FocusAudioEngine, didBecomeCurrent track: EngineTrack) {
            current.append(track.id)
        }

        func audioEngine(_ engine: FocusAudioEngine, didFinish track: EngineTrack, listenedSeconds: Double, skipped: Bool) {
            finished.append((track.id, listenedSeconds, skipped))
        }

        func audioEngine(_ engine: FocusAudioEngine, didFail error: Error, track: EngineTrack?) {
            failures.append("\(track?.id ?? "-"): \(error)")
        }

        func audioEngine(_ engine: FocusAudioEngine, didPauseForLostOutput uid: String) {
            lostOutputs.append(uid)
        }
    }

    static func spin(_ seconds: Double, until condition: (() -> Bool)? = nil) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let condition, condition() { return }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    static func checkRealTime(_ env: CheckEnvironment, _ log: CheckLog) throws {
        log.section("8. Real-time AVAudioEngine smoke test (mixer output volume 0, engine volume 0)")
        let fs = env.sampleRate
        let keepAlive = Timer(timeInterval: 0.05, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .default)
        defer { keepAlive.invalidate() }

        let recorder = Recorder()
        let engine = FocusAudioEngine()
        engine.outputMutedForTesting = true
        engine.setVolume(0)
        engine.setEffectLevel(.medium)
        engine.delegate = recorder
        let trackA = env.track("A-electronic", env.electronic, gainDB: -3.8, hz: 16, offset: env.originalAnchor)
        let trackB = env.track("B-grooves", env.grooves, gainDB: -2, hz: 16, offset: 0.05)

        engine.start(with: trackA, fadeIn: 0.5)
        let started = Date()
        spin(5)
        let elapsed = Date().timeIntervalSince(started)
        let time5 = engine.currentTime
        let consumed = engine.consumedFramesForTesting
        log.expect("8a 5 s playback, one track", engine.underrunCount == 0 && engine.isPlaying && abs(time5 - elapsed) < 0.15
                   && engine.currentTrack == trackA && recorder.failures.isEmpty,
                   "underruns \(engine.underrunCount), currentTime \(f(time5, 3)) s after \(f(elapsed, 3)) s wall, \(consumed) frames consumed (\(f(Double(consumed) / fs, 3)) s), didBecomeCurrent \(recorder.current)")

        engine.setEffectLevel(.high)
        spin(0.6)
        var pauseCompleted = false
        let pauseCalled = Date()
        engine.pause(fade: 0.3) { pauseCompleted = true }
        spin(2, until: { pauseCompleted })
        let pauseLatency = Date().timeIntervalSince(pauseCalled)
        let pausedTime = engine.currentTime
        spin(0.7)
        let pausedLater = engine.currentTime
        log.expect("8b pause(fade 0.3)", pauseCompleted && !engine.isPlaying && abs(pausedLater - pausedTime) < 1e-9 && !engine.isOutputRunningForTesting,
                   "completion after \(f(pauseLatency, 3)) s (ring 0.256 s + fade 0.3 s), position held at \(f(pausedTime, 3)) s, output device paused \(!engine.isOutputRunningForTesting)")

        engine.resume(fade: 0.3)
        spin(1)
        let resumedTime = engine.currentTime
        log.expect("8c resume(fade 0.3)", engine.isPlaying && resumedTime > pausedTime + 0.7 && resumedTime < pausedTime + 1.1 && engine.underrunCount == 0,
                   "position \(f(pausedTime, 3)) -> \(f(resumedTime, 3)) s after 1 s, underruns \(engine.underrunCount)")

        engine.skip(to: trackB, crossfade: 1.5)
        let immediate = engine.currentTrack == trackB
        spin(2.5)
        let skipFinished = recorder.finished.first { $0.id == trackA.id }
        log.expect("8d skip(crossfade 1.5)", immediate && engine.currentTrack == trackB && skipFinished?.skipped == true
                   && engine.currentTime > 1.9 && engine.currentTime < 2.6,
                   "currentTrack switched at once \(immediate); A finished skipped=\(skipFinished.map { String($0.skipped) } ?? "-") listened \(f(skipFinished?.listened ?? -1, 2)) s; B at \(f(engine.currentTime, 3)) s after 2.5 s")

        engine.setDuck(0.3, ramp: 0.5)
        spin(0.7)
        engine.setDuck(1, ramp: 0.5)
        engine.setEffectLevel(.off)
        spin(0.7)
        engine.setEffectLevel(.medium)

        let beforeChange = engine.currentTime
        let changeAt = Date()
        engine.simulateConfigurationChangeForTesting()
        spin(1)
        let afterChange = engine.currentTime
        let changeWall = Date().timeIntervalSince(changeAt)
        log.expect("8e device configuration change", engine.configurationRestartCount == 1 && engine.isOutputRunningForTesting
                   && abs((afterChange - beforeChange) - changeWall) < 0.2 && engine.underrunCount == 0,
                   "restarts \(engine.configurationRestartCount), position \(f(beforeChange, 3)) -> \(f(afterChange, 3)) s over \(f(changeWall, 3)) s wall (continues, no reset), underruns \(engine.underrunCount)")

        // The output device in use vanishes (AirPods put away): hold the position, no sound elsewhere.
        let systemProbe = engine.outputProbe
        let vanished = FocusOutputProbe(current: { FocusOutputDevice(id: 4242, uid: "check-speakers") }, isConnected: { _ in false })
        engine.pausesWhenOutputLost = true
        engine.outputProbe = vanished
        let beforeLoss = engine.currentTime
        engine.simulateConfigurationChangeForTesting()
        spin(0.8)
        let heldAt = engine.currentTime
        spin(0.5)
        let heldLater = engine.currentTime
        log.expect("8e2 output device lost while playing", !engine.isPlaying && engine.lostOutputUID != nil && recorder.lostOutputs.count == 1
                   && !engine.isOutputRunningForTesting && abs(heldLater - heldAt) < 1e-9 && abs(heldAt - beforeLoss) < 0.05,
                   "paused \(!engine.isPlaying), lost \(engine.lostOutputUID ?? "-"), delegate \(recorder.lostOutputs.count)x, output stopped \(!engine.isOutputRunningForTesting), position \(f(beforeLoss, 3)) -> held \(f(heldAt, 3)) / \(f(heldLater, 3)) s")

        engine.outputProbe = systemProbe
        engine.resume(fade: 0.3)
        spin(1)
        let afterReturn = engine.currentTime
        log.expect("8e3 resume once the device is back", engine.isPlaying && engine.lostOutputUID == nil && afterReturn > heldAt + 0.6
                   && afterReturn < heldAt + 1.2 && engine.underrunCount == 0 && engine.currentTrack == trackB,
                   "position \(f(heldAt, 3)) -> \(f(afterReturn, 3)) s after 1 s (restarted where it was heard), underruns \(engine.underrunCount)")

        var pausedForLoss = false
        engine.pause(fade: 0.1) { pausedForLoss = true }
        spin(1.5, until: { pausedForLoss })
        engine.outputProbe = vanished
        recorder.lostOutputs.removeAll()
        engine.simulateConfigurationChangeForTesting()
        spin(0.3)
        let rememberedWhilePaused = engine.lostOutputUID != nil && !engine.isPlaying && recorder.lostOutputs.isEmpty
        engine.outputProbe = systemProbe
        engine.resume(fade: 0.2)
        spin(0.6)
        log.expect("8e4 device lost while already paused", rememberedWhilePaused && engine.isPlaying && engine.lostOutputUID == nil && engine.underrunCount == 0,
                   "remembered without a second pause \(rememberedWhilePaused), plays again \(engine.isPlaying), underruns \(engine.underrunCount)")
        engine.pausesWhenOutputLost = false

        // Automatic transition: start 8 s before the end of A with a 3 s crossfade.
        engine.crossfadeSeconds = 3
        recorder.nextQueue = [trackB]
        recorder.current.removeAll()
        recorder.finished.removeAll()
        let totalA = try AudioIO.frameCount(env.electronic)
        engine.start(with: trackA, fadeIn: 0.2, startTime: Double(totalA) / fs - 8)
        spin(4.5)
        let beforeTransition = engine.currentTrack?.id ?? "-"
        spin(4.5)
        let finishedA = recorder.finished.first { $0.id == trackA.id }
        log.expect("8f automatic crossfade with delegate", recorder.asked.last == trackA.id && recorder.current == [trackA.id, trackB.id]
                   && engine.currentTrack == trackB && finishedA != nil && finishedA!.skipped == false && abs(finishedA!.listened - 8) < 0.01,
                   "asked next after \(recorder.asked.last ?? "-"); current at 4.5 s \(beforeTransition), announcements \(recorder.current); A finished listened \(f(finishedA?.listened ?? -1, 3)) s skipped \(finishedA.map { String($0.skipped) } ?? "-"); B at \(f(engine.currentTime, 3)) s")

        // Skip to a missing file: didFail, the delegate is asked after it, its answer plays.
        let missing = env.track("missing", env.temporary.appendingPathComponent("does-not-exist.wav"))
        let trackC = env.track("C-electronic2", env.electronic2, gainDB: -3, hz: 16, offset: 0.2)
        recorder.nextQueue = [trackC]
        recorder.current.removeAll()
        engine.skip(to: missing, crossfade: 1)
        spin(2)
        let failedMissing = recorder.failures.contains { $0.hasPrefix("missing:") }
        log.expect("8g skip to a missing file", failedMissing && recorder.asked.last == "missing" && engine.currentTrack == trackC
                   && engine.isPlaying && engine.currentTime > 1.2 && recorder.current == ["missing", trackC.id],
                   "didFail for missing \(failedMissing), asked next after \(recorder.asked.last ?? "-"), now \(engine.currentTrack?.id ?? "-") at \(f(engine.currentTime, 3)) s, announcements \(recorder.current)")
        recorder.failures.removeAll()

        // Queue runs out (delegate returns nil) and the user skips just after the core has rendered
        // the end but before it is heard: the skip must win over the stale end.
        engine.crossfadeSeconds = 0
        recorder.nextQueue = []
        engine.start(with: trackA, fadeIn: 0, startTime: Double(totalA) / fs - 2)
        spin(1.85)
        engine.skip(to: trackB, crossfade: 0.5)
        spin(2)
        log.expect("8h skip right after the queue ran out", engine.isPlaying && engine.currentTrack == trackB && engine.currentTime > 1.5,
                   "playing \(engine.isPlaying), current \(engine.currentTrack?.id ?? "-") at \(f(engine.currentTime, 3)) s")

        engine.stop()
        log.expect("8i stop and totals", !engine.isPlaying && engine.currentTrack == nil && engine.underrunCount == 0 && recorder.failures.isEmpty,
                   "underruns over the whole run \(engine.underrunCount), delegate failures \(recorder.failures)")
    }
}
