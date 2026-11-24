import Accelerate
import CoreAudio
import Darwin
import Foundation
import os

// MARK: - Permission to hear other apps

/// macOS asks once before an app may hear other apps' sound (System Settings › Privacy & Security ›
/// Screen & System Audio Recording › System Audio Recording Only). Core Audio has no public call to
/// check or ask for it, so this calls TCC directly; without TCC's functions it is `.unavailable`.
/// The Mac App Store build (`-D MAS_BUILD`) leaves TCC out entirely (public APIs only): there it is
/// always `.unavailable`, the first tap brings up the system's question, and `OtherSoundProbe` tells a
/// refused permission from the taps themselves.
enum OtherAppAudioPermission {
    enum Status: String { case granted, denied, notDetermined, unavailable }

    #if MAS_BUILD
    static var status: Status { .unavailable }
    static func request(_ done: @escaping @Sendable (Bool) -> Void) { DispatchQueue.main.async { done(false) } }
    #else
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    nonisolated(unsafe) private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unavailable }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// Shows the system's question while it is unanswered; `done` gets the answer on the main queue.
    static func request(_ done: @escaping @Sendable (Bool) -> Void) {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessRequest") else {
            DispatchQueue.main.async { done(false) }
            return
        }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }
    #endif
}

// MARK: - How loud another app is

/// Hears one process's sound through a private Core Audio tap (the process keeps playing as usual)
/// and adds up how long it was actually audible. Browsers keep silent sound output open — YouTube's
/// home page does for 5–25 s at a time with no video playing — so "output is running" is not
/// "sound is playing".
final class ProcessSoundMeter: @unchecked Sendable {
    /// Quieter than -60 dBFS counts as silence.
    static let audibleLevel: Float = 0.001

    struct Heard {
        /// Seconds of the tapped sound that came in since the last reading.
        var seconds: Double
        /// Of those, seconds louder than `audibleLevel`.
        var audible: Double
        /// Of those, seconds with any sample other than exact zero. A tap without the permission
        /// to hear other apps delivers exact zeros forever, so this is how a refusal shows.
        var signal: Double
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let sampleRate: Double
    private let frames = OSAllocatedUnfairLock(initialState: (heard: 0, audible: 0, signal: 0))

    /// Nil when Core Audio refuses the tap; the caller then falls back to "output running".
    init?(process: AudioObjectID, queue: DispatchQueue) {
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.uuid = UUID()
        description.name = "Focus Music · other sound"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != AudioObjectID(kAudioObjectUnknown) else { return nil }
        tapID = tap

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                       mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &format) == noErr,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mSampleRate > 0 else {
            sampleRate = 0
            invalidate()
            return nil
        }
        sampleRate = format.mSampleRate

        // A private aggregate device holding only the tap: no microphone or speaker is opened, so
        // Bluetooth headphones stay in their music mode.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Focus Music · other sound",
            kAudioAggregateDeviceUIDKey: "app.adhdmusic.othersound." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]]
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr else {
            invalidate()
            return nil
        }
        deviceID = device

        let frames = self.frames
        let level = Self.audibleLevel
        let ioBlock: AudioDeviceIOBlock = { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var peak: Float = 0
            var count = 0
            for buffer in buffers {
                guard let data = buffer.mData, buffer.mDataByteSize >= 4 else { continue }
                let samples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                var bufferPeak: Float = 0
                vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &bufferPeak, vDSP_Length(samples))
                peak = max(peak, bufferPeak)
                count = max(count, samples / max(1, Int(buffer.mNumberChannels)))
            }
            guard count > 0 else { return }
            let heard = count, loud = peak >= level, any = peak > 0
            frames.withLock { state in
                state.heard += heard
                if loud { state.audible += heard }
                if any { state.signal += heard }
            }
        }
        var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue, ioBlock) == noErr, let proc else {
            invalidate()
            return nil
        }
        procID = proc
        guard AudioDeviceStart(device, proc) == noErr else {
            invalidate()
            return nil
        }
    }

    /// What came in since the last reading.
    func take() -> Heard {
        let counted = frames.withLock { state -> (heard: Int, audible: Int, signal: Int) in
            defer { state = (0, 0, 0) }
            return state
        }
        return Heard(seconds: Double(counted.heard) / sampleRate, audible: Double(counted.audible) / sampleRate,
                     signal: Double(counted.signal) / sampleRate)
    }

    func invalidate() {
        if deviceID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = AudioObjectID(kAudioObjectUnknown)
            procID = nil
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { invalidate() }
}
