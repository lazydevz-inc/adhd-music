import AudioToolbox
import Foundation
import os
import Synchronization

/// Lock-free single-producer / single-consumer ring of interleaved stereo Float32 frames.
/// The producer is the render worker; the consumer is the Core Audio render callback.
/// Indices are total frame counts (never wrap in practice); slot = index & mask.
final class FocusAudioRing {
    let capacityFrames: Int
    /// Plain pointers only: safe to capture in the real-time render block.
    let view: FocusAudioRingView
    private let samples: UnsafeMutablePointer<Float>
    private let counters: UnsafeMutablePointer<Atomic<Int>>

    init(capacityFrames: Int) {
        precondition(capacityFrames.nonzeroBitCount == 1, "Ring capacity must be a power of two")
        self.capacityFrames = capacityFrames
        samples = .allocate(capacity: capacityFrames * 2)
        samples.initialize(repeating: 0, count: capacityFrames * 2)
        counters = .allocate(capacity: FocusAudioRingView.counterSlots)
        for slot in 0..<FocusAudioRingView.counterSlots {
            (counters + slot).initialize(to: Atomic(0))
        }
        view = FocusAudioRingView(samples: samples, counters: counters, capacity: capacityFrames)
    }

    deinit {
        counters.deinitialize(count: FocusAudioRingView.counterSlots)
        counters.deallocate()
        samples.deallocate()
    }

    // MARK: Producer side

    /// Frames written but not yet consumed.
    var fillLevel: Int { view.writeIndex - view.readIndex }

    /// Appends interleaved frames. The caller keeps `fillLevel + frames <= capacityFrames`.
    func write(_ source: UnsafePointer<Float>, frames: Int) {
        view.write(source, frames: frames)
    }

    /// Underruns are counted only while the producer says data is expected.
    func setProducerActive(_ active: Bool) {
        view.counters[FocusAudioRingView.activeSlot].store(active ? 1 : 0, ordering: .releasing)
    }

    // MARK: Observers

    var readIndex: Int { view.readIndex }
    var underrunCount: Int { view.counters[FocusAudioRingView.underrunSlot].load(ordering: .relaxed) }
    var underrunFrames: Int { view.counters[FocusAudioRingView.underrunFrameSlot].load(ordering: .relaxed) }
}

struct FocusAudioRingView {
    // Separate 128-byte lines for the producer- and consumer-owned counters.
    static let writeSlot = 0
    static let readSlot = 16
    static let underrunSlot = 32
    static let activeSlot = 48
    static let underrunFrameSlot = 64
    static let counterSlots = 80

    let samples: UnsafeMutablePointer<Float>
    let counters: UnsafeMutablePointer<Atomic<Int>>
    let capacity: Int
    /// Byte offset of `mBuffers` in AudioBufferList, computed once off the audio thread.
    let buffersOffset: Int

    init(samples: UnsafeMutablePointer<Float>, counters: UnsafeMutablePointer<Atomic<Int>>, capacity: Int) {
        self.samples = samples
        self.counters = counters
        self.capacity = capacity
        buffersOffset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers) ?? 8
    }

    var writeIndex: Int { counters[Self.writeSlot].load(ordering: .acquiring) }
    var readIndex: Int { counters[Self.readSlot].load(ordering: .acquiring) }

    func write(_ source: UnsafePointer<Float>, frames: Int) {
        let mask = capacity - 1
        let start = counters[Self.writeSlot].load(ordering: .relaxed)
        var slot = start & mask
        var copied = 0
        while copied < frames {
            let run = min(frames - copied, capacity - slot)
            (samples + 2 * slot).update(from: source + 2 * copied, count: 2 * run)
            copied += run
            slot = (slot + run) & mask
        }
        counters[Self.writeSlot].store(start + frames, ordering: .releasing)
    }

    /// Real-time render callback body: copy, zero-fill on underrun. Only raw memory access and
    /// atomics: no locks, allocation, retain/release, metadata lookups or ObjC messaging.
    func render(isSilence: UnsafeMutablePointer<ObjCBool>, frameCount: UInt32,
                bufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let requested = Int(frameCount)
        let raw = UnsafeMutableRawPointer(bufferList)
        let bufferCount = Int(raw.load(as: UInt32.self))
        let buffers = (raw + buffersOffset).assumingMemoryBound(to: AudioBuffer.self)
        guard bufferCount >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
            var index = 0
            while index < bufferCount {
                if let data = buffers[index].mData { memset(data, 0, Int(buffers[index].mDataByteSize)) }
                index += 1
            }
            isSilence.pointee = true
            return 0
        }
        let written = counters[Self.writeSlot].load(ordering: .acquiring)
        let read = counters[Self.readSlot].load(ordering: .relaxed)
        let take = max(0, min(requested, written - read))
        let mask = capacity - 1
        var slot = read & mask
        var copied = 0
        while copied < take {
            let run = min(take - copied, capacity - slot)
            var source = samples + 2 * slot
            for index in copied..<(copied + run) {
                left[index] = source[0]
                right[index] = source[1]
                source += 2
            }
            copied += run
            slot = (slot + run) & mask
        }
        if take < requested {
            (left + take).update(repeating: 0, count: requested - take)
            (right + take).update(repeating: 0, count: requested - take)
            if counters[Self.activeSlot].load(ordering: .acquiring) != 0 {
                counters[Self.underrunSlot].wrappingAdd(1, ordering: .relaxed)
                counters[Self.underrunFrameSlot].wrappingAdd(requested - take, ordering: .relaxed)
            }
            if take == 0 { isSilence.pointee = true }
        }
        counters[Self.readSlot].store(read + take, ordering: .releasing)
        return 0
    }
}

/// os_unfair_lock for non-real-time threads (main <-> worker).
final class FocusUnfairLock {
    private let lock: os_unfair_lock_t

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return try body()
    }
}
