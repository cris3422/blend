// Blend mixer (originally written for Pocket Deck): two decks inside ONE AVAudioEngine, so both songs run off the same render clock and can't drift apart.
//
//   deck A chain (PDEngine) -> deck A output -+
//                                              +-> main mixer (master volume) -> speakers
//   deck B chain (PDEngine) -> deck B output -+       (a tap here records the whole mix)
//
// The crossfader sets each deck's fadeGain with an equal-power curve (no dip in loudness in the middle).
import AVFoundation

public final class PDMixer {
    public let engine = AVAudioEngine()
    public let decks: [PDEngine]

    /// 0 = only deck A, 1 = only deck B, 0.5 = both.
    public var crossfade: Float = 0.5 { didSet { crossfade = max(0, min(1, crossfade)); applyFade() } }
    public var masterVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = max(0, min(1, newValue)) }
    }

    // MARK: position lock (sync)
    // Matching speeds is not enough: AVAudioUnitTimePitch rounds its rate (0.96 runs ~0.1% off, 60 ms a minute).
    // So the follower is steered by where both songs actually are: target = anchorF + ratio × (leaderPos − anchorL),
    // and its speed is nudged (at most ±2%) to close the gap within about a second. Big gaps (> 0.25 s) re-phase at once.
    public struct Follow {
        public var follower: Int, leader: Int
        public var ratio: Double             // follower source seconds per leader source second (e.g. 125 → 120 BPM: 0.96)
        public var anchorLeader: Double, anchorFollower: Double
        public init(follower: Int, leader: Int, ratio: Double, anchorLeader: Double, anchorFollower: Double) {
            self.follower = follower; self.leader = leader; self.ratio = ratio; self.anchorLeader = anchorLeader; self.anchorFollower = anchorFollower
        }
    }
    public var follow: Follow?
    public private(set) var syncError: Double = 0   // follower seconds behind (+) or ahead (−) of the target, last tick
    var timer: Timer?

    /// The time-stretcher holds about this much source audio inside it (measured; the unit itself reports 0). Positions are
    /// read where the player feeds the stretcher, so what you hear lags by this. Both decks lag the same amount of source,
    /// which maps to different heard times when their ratio isn't 1, hence the (1 − ratio) term.
    public static var stretchLag: Double = 0.16

    /// Where the follower should be, read at the stretcher input, for the leader's current position.
    public func target(_ f: Follow) -> Double {
        f.anchorFollower + f.ratio * (decks[f.leader].position - f.anchorLeader) + PDMixer.stretchLag * (1 - f.ratio)
    }

    public func syncTick() {
        guard let f = follow else { return }
        let L = decks[f.leader], F = decks[f.follower]
        guard L.isSounding, F.isSounding else { return }   // a deck waiting for its downbeat isn't steered yet
        let base = Float(f.ratio) * L.speed
        let err = target(f) - F.position
        syncError = err
        if abs(err) > 0.25 { try? F.play(from: target(f) + 0.06 * Double(base), at: engine.isInManualRenderingMode ? nil : soon()); F.speed = base; return }
        let corr = max(-0.02, min(0.02, err / 0.5))   // close the gap in about half a second
        F.speed = base * Float(1 + corr)
    }

    private var recordFile: AVAudioFile?
    private let recLock = NSLock()
    private var tapOn = false

    public init() {
        decks = [PDEngine(shared: engine), PDEngine(shared: engine)]
        for (i, d) in decks.enumerated() { engine.connect(d.output, to: engine.mainMixerNode, fromBus: 0, toBus: i, format: PDEngine.chainFormat) }
        applyFade()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.syncTick() }
    }

    /// Equal-power: A = cos(x·π/2), B = sin(x·π/2). Both at about -3 dB in the middle, full at the ends.
    public static func fadeGains(_ x: Float) -> (Float, Float) { (cos(x * .pi / 2), sin(x * .pi / 2)) }
    func applyFade() { let (a, b) = PDMixer.fadeGains(crossfade); decks[0].fadeGain = a; decks[1].fadeGain = b }

    public func start() throws { if !engine.isRunning { engine.prepare(); try engine.start() } }

    /// A start time a little in the future on the shared clock, for starting decks together.
    public func soon(_ seconds: Double = 0.06) -> AVAudioTime {
        AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: seconds))
    }

    /// Start (or restart) deck `i` at source position `from` seconds, exactly at the shared time `at`.
    public func play(_ i: Int, from: Double? = nil, at: AVAudioTime? = nil) throws {
        try start()
        try decks[i].play(from: from, at: at ?? soon())
    }

    // MARK: recording the whole mix (both decks, after the crossfader and master volume)

    public var isRecording: Bool { recLock.lock(); defer { recLock.unlock() }; return recordFile != nil }

    public func startRecording(to url: URL) throws {
        try start()
        let fmt = engine.mainMixerNode.outputFormat(forBus: 0)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate, AVNumberOfChannelsKey: fmt.channelCount,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        recLock.lock(); recordFile = f; recLock.unlock()
        if !tapOn {
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
                guard let self else { return }
                self.recLock.lock(); let f = self.recordFile; self.recLock.unlock()
                try? f?.write(from: buf)
            }
            tapOn = true
        }
    }

    @discardableResult public func stopRecording() -> URL? {
        recLock.lock(); let url = recordFile?.url; recordFile = nil; recLock.unlock()
        if tapOn { engine.mainMixerNode.removeTap(onBus: 0); tapOn = false }
        return url
    }

    // MARK: offline render of the shared engine (tests: proves both decks share one clock)

    /// Renders `seconds` of the whole mix offline, both decks starting at frame 0 of their songs.
    public func renderOffline(seconds: Double, rate: Double = 44100) throws -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        engine.stop()
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        defer { engine.stop(); engine.disableManualRenderingMode() }
        try engine.start()
        for d in decks where !d.stemNames.isEmpty { try d.play(from: 0, at: nil) }
        let total = AVAudioFrameCount(seconds * rate)
        let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: total)!
        let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var chunks = 0
        while out.frameLength < total {
            chunks += 1; syncTick()   // every 93 ms of audio (the realtime timer ticks every 50 ms)
            let n = min(4096, total - out.frameLength)
            guard try engine.renderOffline(n, to: buf) == .success else { continue }
            for c in 0..<2 { memcpy(out.floatChannelData![c] + Int(out.frameLength), buf.floatChannelData![c], Int(buf.frameLength) * 4) }
            out.frameLength += buf.frameLength
        }
        for d in decks { d.stop() }
        return out
    }
}
