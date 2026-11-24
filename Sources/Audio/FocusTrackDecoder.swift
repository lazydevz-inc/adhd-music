import AVFoundation
import Foundation

/// Reads a local WAV/FLAC (anything AVAudioFile opens) as 48 kHz stereo Float32.
/// Mono is copied to both channels; for more channels the first two are used. Other sample
/// rates go through AVAudioConverter. Used only on the render worker thread.
final class FocusTrackDecoder {
    let url: URL
    let outputSampleRate: Double
    let sourceSampleRate: Double
    let sourceChannelCount: Int
    /// Length in output frames. Scheduling (crossfade start, effect window) uses this number;
    /// a converter that delivers a few frames more or less is padded or truncated to it.
    let frameCount: Int

    private let file: AVAudioFile
    private let readBuffer: AVAudioPCMBuffer
    private let converter: AVAudioConverter?
    private let convertedBuffer: AVAudioPCMBuffer?
    private var convertedOffset = 0
    private var convertedAvailable = 0
    private var sourceExhausted = false
    private var converterFinished = false
    private var inputError: Error?

    init(url: URL, outputSampleRate: Double, chunkFrames: Int) throws {
        guard url.isFileURL else {
            throw FocusAudioEngineError.cannotOpenFile(url: url, reason: "not a local file URL")
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw FocusAudioEngineError.cannotOpenFile(url: url, reason: error.localizedDescription)
        }
        let format = file.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate >= 8_000, format.sampleRate <= 384_000,
              format.channelCount >= 1, file.length > 0 else {
            throw FocusAudioEngineError.unsupportedAudio(
                url: url, reason: "\(format.channelCount) ch, \(format.sampleRate) Hz, \(file.length) frames")
        }
        self.url = url
        self.file = file
        self.outputSampleRate = outputSampleRate
        self.sourceSampleRate = format.sampleRate
        self.sourceChannelCount = Int(format.channelCount)

        if format.sampleRate == outputSampleRate {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames)) else {
                throw FocusAudioEngineError.unsupportedAudio(url: url, reason: "cannot allocate a read buffer")
            }
            readBuffer = buffer
            converter = nil
            convertedBuffer = nil
            frameCount = Int(file.length)
        } else {
            guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate,
                                                   channels: format.channelCount, interleaved: false),
                  let converter = AVAudioConverter(from: format, to: outputFormat),
                  let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192),
                  let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(chunkFrames)) else {
                throw FocusAudioEngineError.unsupportedAudio(
                    url: url, reason: "no sample-rate converter from \(format.sampleRate) Hz")
            }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            self.converter = converter
            readBuffer = input
            convertedBuffer = converted
            frameCount = Int((Double(file.length) * outputSampleRate / format.sampleRate).rounded())
        }
    }

    /// Positions the next read at `frame` (output frames).
    func seek(toFrame frame: Int) {
        let clamped = max(0, min(frame, frameCount))
        if let converter {
            file.framePosition = AVAudioFramePosition((Double(clamped) * sourceSampleRate / outputSampleRate).rounded())
            converter.reset()
            convertedOffset = 0
            convertedAvailable = 0
            sourceExhausted = false
            converterFinished = false
        } else {
            file.framePosition = AVAudioFramePosition(clamped)
        }
    }

    /// Reads up to `frames` frames. Returns fewer only at the end of the file.
    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) throws -> Int {
        converter == nil
            ? try readNative(left: left, right: right, frames: frames)
            : try readConverted(left: left, right: right, frames: frames)
    }

    private func readNative(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) throws -> Int {
        var written = 0
        while written < frames {
            let remaining = Int(file.length - file.framePosition)
            if remaining <= 0 { break }
            let request = min(frames - written, Int(readBuffer.frameCapacity), remaining)
            do {
                try file.read(into: readBuffer, frameCount: AVAudioFrameCount(request))
            } catch {
                throw FocusAudioEngineError.decodingFailed(url: url, reason: error.localizedDescription)
            }
            let got = Int(readBuffer.frameLength)
            if got == 0 { break }
            Self.copyChannels(readBuffer, offset: 0, count: got, left: left + written, right: right + written)
            written += got
        }
        return written
    }

    private func readConverted(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) throws -> Int {
        guard let converter, let convertedBuffer else { return 0 }
        var written = 0
        while written < frames {
            if convertedOffset < convertedAvailable {
                let take = min(frames - written, convertedAvailable - convertedOffset)
                Self.copyChannels(convertedBuffer, offset: convertedOffset, count: take,
                                  left: left + written, right: right + written)
                convertedOffset += take
                written += take
                continue
            }
            if converterFinished { break }
            convertedBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: convertedBuffer, error: &conversionError) { [unowned self] requested, inputStatus in
                self.supplyInput(requested: requested, status: inputStatus)
            }
            if let inputError {
                throw FocusAudioEngineError.decodingFailed(url: url, reason: inputError.localizedDescription)
            }
            if status == .error {
                throw FocusAudioEngineError.decodingFailed(
                    url: url, reason: conversionError?.localizedDescription ?? "sample-rate conversion failed")
            }
            convertedOffset = 0
            convertedAvailable = Int(convertedBuffer.frameLength)
            if status == .endOfStream || (status == .inputRanDry && convertedAvailable == 0) {
                converterFinished = true
            }
        }
        return written
    }

    private func supplyInput(requested: AVAudioPacketCount,
                             status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        let remaining = Int(file.length - file.framePosition)
        if sourceExhausted || remaining <= 0 {
            sourceExhausted = true
            status.pointee = .endOfStream
            return nil
        }
        let count = max(1, min(Int(requested), Int(readBuffer.frameCapacity), remaining))
        do {
            try file.read(into: readBuffer, frameCount: AVAudioFrameCount(count))
        } catch {
            inputError = error
            sourceExhausted = true
            status.pointee = .endOfStream
            return nil
        }
        if readBuffer.frameLength == 0 {
            sourceExhausted = true
            status.pointee = .endOfStream
            return nil
        }
        status.pointee = .haveData
        return readBuffer
    }

    private static func copyChannels(_ buffer: AVAudioPCMBuffer, offset: Int, count: Int,
                                     left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        guard count > 0, let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        left.update(from: channels[0] + offset, count: count)
        right.update(from: channels[channelCount > 1 ? 1 : 0] + offset, count: count)
    }
}
