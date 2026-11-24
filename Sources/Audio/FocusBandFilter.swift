import Accelerate
import Foundation

/// The selected band of `Scripts/focus_audio.py` (`_band_mask`): a 216-984 Hz carrier with
/// 32 Hz raised-cosine shoulders, so +/-16 Hz sidebands stay inside the nominal 200-1000 Hz.
enum FocusBandMask {
    static let carrierLowerHz = 216.0
    static let carrierUpperHz = 984.0
    static let shoulderHz = 32.0

    /// Same piecewise definition as `_band_mask`.
    static func gain(atHz frequency: Double) -> Double {
        let lower = carrierLowerHz
        let upper = carrierUpperHz
        let shoulder = shoulderHz
        if frequency >= lower && frequency < lower + shoulder {
            return 0.5 - 0.5 * cos(Double.pi * (frequency - lower) / shoulder)
        }
        if frequency >= lower + shoulder && frequency <= upper - shoulder {
            return 1
        }
        if frequency > upper - shoulder && frequency <= upper {
            return 0.5 - 0.5 * cos(Double.pi * (upper - frequency) / shoulder)
        }
        return 0
    }

    /// Exact continuous-time impulse response of the zero-phase mask. A raised-cosine edge is a
    /// brick-wall edge at the shoulder centre convolved with a half-cosine of the shoulder width,
    /// so the response is a band-pass sinc times that half-cosine's transform.
    static func impulseResponse(atSeconds t: Double) -> Double {
        let lowEdge = carrierLowerHz + shoulderHz / 2
        let highEdge = carrierUpperHz - shoulderHz / 2
        let rectangular: Double
        if t == 0 {
            rectangular = 2 * (highEdge - lowEdge)
        } else {
            rectangular = (sin(2 * Double.pi * highEdge * t) - sin(2 * Double.pi * lowEdge * t)) / (Double.pi * t)
        }
        let x = 2 * shoulderHz * t
        let denominator = 1 - x * x
        let shoulderTransform = abs(denominator) < 1e-9
            ? Double.pi / 4
            : cos(Double.pi * shoulderHz * t) / denominator
        return rectangular * shoulderTransform
    }
}

/// Linear-phase FIR for the selected band: the mask's impulse response sampled at the audio
/// rate (frequency sampling of the exact mask), truncated with a light Tukey taper.
/// 8191 taps at 48 kHz: group delay 4095 frames (85.3 ms). Shared, immutable after init.
final class FocusBandFIR {
    static let standard = FocusBandFIR(sampleRate: FocusAudioFormat.sampleRate)

    let sampleRate: Double
    let tapCount: Int
    /// Frames between an input sample and its centred filter output.
    let groupDelay: Int
    let fftLength: Int
    /// New input frames per overlap-save block.
    let hop: Int
    let log2Length: vDSP_Length
    let coefficients: [Float]
    let setup: FFTSetup
    /// Kernel spectrum in vDSP packed format, pre-scaled so one forward + inverse pass is exact.
    let kernelReal: UnsafeMutablePointer<Float>
    let kernelImag: UnsafeMutablePointer<Float>

    init(sampleRate: Double, tapCount: Int = 8191, fftLength: Int = 32768, taperFraction: Double = 0.2) {
        precondition(tapCount > 1 && tapCount % 2 == 1, "Linear-phase type I FIR needs an odd length")
        precondition(fftLength.nonzeroBitCount == 1 && fftLength > tapCount, "FFT length must be a power of two above the tap count")
        self.sampleRate = sampleRate
        self.tapCount = tapCount
        self.groupDelay = tapCount / 2
        self.fftLength = fftLength
        self.hop = fftLength - tapCount + 1
        self.log2Length = vDSP_Length(fftLength.trailingZeroBitCount)

        var taps = [Float](repeating: 0, count: tapCount)
        for index in 0..<tapCount {
            let t = Double(index - tapCount / 2) / sampleRate
            let window = Self.tukey(index: index, count: tapCount, fraction: taperFraction)
            taps[index] = Float(FocusBandMask.impulseResponse(atSeconds: t) / sampleRate * window)
        }
        coefficients = taps

        guard let setup = vDSP_create_fftsetup(log2Length, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP could not create an FFT setup")
        }
        self.setup = setup
        let half = fftLength / 2
        kernelReal = .allocate(capacity: half)
        kernelImag = .allocate(capacity: half)
        kernelReal.initialize(repeating: 0, count: half)
        kernelImag.initialize(repeating: 0, count: half)

        let padded = UnsafeMutablePointer<Float>.allocate(capacity: fftLength)
        padded.initialize(repeating: 0, count: fftLength)
        taps.withUnsafeBufferPointer { padded.update(from: $0.baseAddress!, count: tapCount) }
        var split = DSPSplitComplex(realp: kernelReal, imagp: kernelImag)
        padded.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2Length, FFTDirection(kFFTDirection_Forward))
        // vDSP's forward real FFT is 2x the DFT and the inverse is N x the inverse DFT,
        // so (2X)(2H)s through the inverse gives 4sN (x*h): s = 1 / (4N).
        var scale = Float(1.0 / (4.0 * Double(fftLength)))
        vDSP_vsmul(kernelReal, 1, &scale, kernelReal, 1, vDSP_Length(half))
        vDSP_vsmul(kernelImag, 1, &scale, kernelImag, 1, vDSP_Length(half))
        padded.deallocate()
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        kernelReal.deallocate()
        kernelImag.deallocate()
    }

    /// Symmetric Tukey window (same as scipy.signal.windows.tukey).
    static func tukey(index: Int, count: Int, fraction: Double) -> Double {
        guard fraction > 0, count > 1 else { return 1 }
        let x = Double(index) / Double(count - 1)
        if x < fraction / 2 {
            return 0.5 * (1 + cos(2 * Double.pi / fraction * (x - fraction / 2)))
        }
        if x > 1 - fraction / 2 {
            return 0.5 * (1 + cos(2 * Double.pi / fraction * (x - 1 + fraction / 2)))
        }
        return 1
    }
}

/// One channel of FFT overlap-save convolution with `FocusBandFIR`.
///
/// Fill `inputSlot` with the next `hop` input samples, call `filter()`, then read `hop` frames
/// from `alignedDry` and `bandOutput`: they are time-aligned (dry delayed by the group delay).
/// Call `shift()` before filling the next block.
final class FocusOverlapSaveChannel {
    let fir: FocusBandFIR
    /// [0, taps - 1): carried input; [taps - 1, fftLength): this block's new input.
    private let history: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>
    private let output: UnsafeMutablePointer<Float>

    init(fir: FocusBandFIR) {
        self.fir = fir
        history = .allocate(capacity: fir.fftLength)
        history.initialize(repeating: 0, count: fir.fftLength)
        output = .allocate(capacity: fir.fftLength)
        output.initialize(repeating: 0, count: fir.fftLength)
        real = .allocate(capacity: fir.fftLength / 2)
        real.initialize(repeating: 0, count: fir.fftLength / 2)
        imag = .allocate(capacity: fir.fftLength / 2)
        imag.initialize(repeating: 0, count: fir.fftLength / 2)
    }

    deinit {
        history.deallocate()
        output.deallocate()
        real.deallocate()
        imag.deallocate()
    }

    var inputSlot: UnsafeMutablePointer<Float> { history + (fir.tapCount - 1) }
    /// Input delayed by the group delay, aligned sample-for-sample with `bandOutput`.
    var alignedDry: UnsafePointer<Float> { UnsafePointer(history + fir.groupDelay) }
    var bandOutput: UnsafePointer<Float> { UnsafePointer(output + (fir.tapCount - 1)) }

    func filter() {
        let half = fir.fftLength / 2
        var split = DSPSplitComplex(realp: real, imagp: imag)
        history.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(fir.setup, &split, 1, fir.log2Length, FFTDirection(kFFTDirection_Forward))
        // Packed format: element 0 holds DC (real) and Nyquist (imag), both purely real.
        let dc = real[0] * fir.kernelReal[0]
        let nyquist = imag[0] * fir.kernelImag[0]
        var kernel = DSPSplitComplex(realp: fir.kernelReal, imagp: fir.kernelImag)
        withUnsafeMutablePointer(to: &split) { data in
            withUnsafePointer(to: &kernel) { kernelPointer in
                vDSP_zvmul(data, 1, kernelPointer, 1, data, 1, vDSP_Length(half), 1)
            }
        }
        real[0] = dc
        imag[0] = nyquist
        vDSP_fft_zrip(fir.setup, &split, 1, fir.log2Length, FFTDirection(kFFTDirection_Inverse))
        output.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
        }
    }

    /// Keeps the last taps - 1 inputs as the next block's history.
    func shift() {
        memmove(history, history + fir.hop, (fir.tapCount - 1) * MemoryLayout<Float>.stride)
    }

    /// Forgets the carried input, as before a file's first block.
    func clearHistory() {
        history.update(repeating: 0, count: fir.fftLength)
    }
}
