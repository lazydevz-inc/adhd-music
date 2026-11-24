import Foundation

/// Owns a `FocusRenderCore` on a dedicated thread: applies commands from the main thread, keeps
/// the ring filled, and hands events back once playback has actually reached them.
final class FocusRenderWorker {
    enum Command {
        case start(EngineTrack, serial: Int, fadeIn: Double, startTime: Double)
        case pause(fade: Double, token: Int)
        case resume(fade: Double)
        case skip(EngineTrack, serial: Int, crossfade: Double)
        case setNext(EngineTrack?, serial: Int, after: Int)
        case effectDepth(Float)
        case volume(Float)
        case duck(Float, ramp: Double)
        case crossfade(Double)
        case noise(FocusNoiseKind, level: Float)
        case minimumTrackSeconds(Double)
    }

    let core: FocusRenderCore
    let ring: FocusAudioRing
    let chunkFrames: Int
    let targetFillFrames: Int

    private let deliver: (FocusCoreEvent, Int) -> Void
    private let lock = FocusUnfairLock()
    private let wake = DispatchSemaphore(value: 0)
    private let exited = DispatchSemaphore(value: 0)
    private var queued: [Command] = []
    private var exitRequested = false
    private var running = false

    // Worker-thread state.
    private var skipsApplied = 0
    private let scratch: UnsafeMutablePointer<Float>
    /// Events waiting to be heard, stamped with `skipsApplied` at the moment the core emitted them.
    private var timedEvents: [(event: FocusCoreEvent, skipsApplied: Int)] = []
    private var timedHead = 0
    private var positionQueue: [FocusPositionLogEntry] = []
    private var positionHead = 0
    private var latestPositions: [Int: FocusPositionLogEntry] = [:]

    // Published to the main thread under `lock`.
    private var publishedSeconds: [Int: Double] = [:]

    /// `deliver` runs on the worker thread and must hop to the main thread itself. Its second
    /// argument is the number of `.skip` commands the core had applied when it emitted the event
    /// (lets the engine spot an `.ended` that a later skip has superseded).
    init(core: FocusRenderCore, ring: FocusAudioRing, chunkFrames: Int = 512, targetFillFrames: Int,
         deliver: @escaping (FocusCoreEvent, Int) -> Void) {
        precondition(targetFillFrames + chunkFrames <= ring.capacityFrames)
        self.core = core
        self.ring = ring
        self.chunkFrames = chunkFrames
        self.targetFillFrames = targetFillFrames
        self.deliver = deliver
        scratch = .allocate(capacity: chunkFrames * 2)
        scratch.initialize(repeating: 0, count: chunkFrames * 2)
    }

    deinit {
        scratch.deallocate()
    }

    func start() {
        guard !running else { return }
        running = true
        core.recordsPositionLog = true
        let thread = Thread { [self] in self.run() }
        thread.name = "FocusAudioEngine.render"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func post(_ command: Command) {
        lock.withLock { queued.append(command) }
        wake.signal()
    }

    /// Stops the thread and waits for it (bounded).
    func stopAndWait() {
        guard running else { return }
        lock.withLock { exitRequested = true }
        wake.signal()
        _ = exited.wait(timeout: .now() + 2)
        running = false
    }

    /// Audible position of `serial` in seconds, if it has been heard.
    func audibleSeconds(serial: Int) -> Double? {
        lock.withLock { publishedSeconds[serial] }
    }

    // MARK: - Worker thread

    private func run() {
        while true {
            var commands: [Command] = []
            var shouldExit = false
            lock.withLock {
                commands = queued
                queued.removeAll(keepingCapacity: true)
                shouldExit = exitRequested
            }
            if shouldExit { break }
            for command in commands { apply(command) }
            absorbCoreOutput()
            fillRing()
            deliverReachedEvents()
            let waitSeconds: Double
            if core.wantsOutput {
                waitSeconds = 0.004
            } else {
                waitSeconds = timedHead < timedEvents.count ? 0.01 : 0.2
            }
            _ = wake.wait(timeout: .now() + waitSeconds)
        }
        ring.setProducerActive(false)
        exited.signal()
    }

    private func apply(_ command: Command) {
        switch command {
        case .start(let track, let serial, let fadeIn, let startTime):
            core.start(track: track, serial: serial, fadeIn: fadeIn, startTime: startTime)
        case .pause(let fade, let token):
            core.pause(fade: fade, token: token)
        case .resume(let fade):
            core.resume(fade: fade)
        case .skip(let track, let serial, let crossfade):
            skipsApplied += 1
            core.skip(to: track, serial: serial, crossfade: crossfade)
        case .setNext(let track, let serial, let after):
            core.setNext(track, serial: serial, after: after)
        case .effectDepth(let depth):
            core.setEffectDepth(depth)
        case .volume(let value):
            core.setVolume(value)
        case .duck(let factor, let ramp):
            core.setDuck(factor, rampSeconds: ramp)
        case .crossfade(let seconds):
            core.setCrossfadeSeconds(seconds)
        case .noise(let kind, let level):
            core.setNoise(kind, level: level)
        case .minimumTrackSeconds(let seconds):
            core.setMinimumTrackSeconds(seconds)
        }
    }

    private func fillRing() {
        while core.wantsOutput && ring.fillLevel + chunkFrames <= targetFillFrames {
            core.render(into: scratch, frames: chunkFrames)
            ring.write(scratch, frames: chunkFrames)
            absorbCoreOutput()
        }
        // Underruns count only once the ring has been primed and while output is expected.
        ring.setProducerActive(core.wantsOutput)
    }

    private func absorbCoreOutput() {
        for event in core.drainEvents() {
            if event.audibleFrame != nil {
                timedEvents.append((event, skipsApplied))
            } else {
                deliver(event, skipsApplied)
            }
        }
        let log = core.drainPositionLog()
        if !log.isEmpty { positionQueue.append(contentsOf: log) }
    }

    private func deliverReachedEvents() {
        let consumed = Int64(ring.readIndex)
        // Positions first: every entry of a track starts before its `finished` frame, so a
        // finished track is never re-added below.
        while positionHead < positionQueue.count && positionQueue[positionHead].streamFrame <= consumed {
            let entry = positionQueue[positionHead]
            positionHead += 1
            latestPositions[entry.serial] = entry
        }
        if positionHead > 256 && positionHead * 2 > positionQueue.count {
            positionQueue.removeFirst(positionHead)
            positionHead = 0
        }

        while timedHead < timedEvents.count {
            let (event, stamp) = timedEvents[timedHead]
            guard let frame = event.audibleFrame, frame <= consumed else { break }
            timedHead += 1
            if case .finished(let serial, _, _, _) = event {
                latestPositions.removeValue(forKey: serial)
            }
            deliver(event, stamp)
        }
        if timedHead > 64 && timedHead * 2 > timedEvents.count {
            timedEvents.removeFirst(timedHead)
            timedHead = 0
        }

        var snapshot: [Int: Double] = [:]
        for (serial, entry) in latestPositions {
            let advanced = min(Int(consumed - entry.streamFrame), entry.frames)
            snapshot[serial] = Double(entry.trackFrame + max(0, advanced)) / core.sampleRate
        }
        lock.withLock { publishedSeconds = snapshot }
    }
}
