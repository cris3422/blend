// Blend audio engine (originally written for Pocket Deck): native DSP on AVAudioEngine, separate from the UI.
//
// Graph (one chain per stem, then a shared master chain):
//   stem player -> stem EQ -> stem reverb -> stem mixer (volume / mute / solo / pan) -+
//   ... one per stem ..............................................................  +-> stem bus
//   stem bus -> time/pitch (speed with pitch kept, pitch on its own) -> master EQ -> master reverb
//            -> deck output (deck volume x crossfade gain) -> main mixer -> output   (a tap after the master reverb feeds meters)
// The deck chain runs at a fixed 44.1 kHz; stem mixers convert each song's own rate. That way loading a song only adds
// mixer inputs and never rewires the chain, which matters when two decks share one engine (PDMixer): one clock, no drift.
//
// Sources are never modified: stems are read from files with scheduleSegment, and every setting is a
// node parameter, so a render is always "original + settings". The same graph renders offline for export.
import AVFoundation
import Accelerate

public enum EQType: String, Codable { case parametric, lowShelf, highShelf, highPass, lowPass }

public struct EQBandSetting: Codable, Equatable {
    public var type: EQType = .parametric
    public var frequency: Float = 1000      // Hz
    public var gain: Float = 0              // dB, -24...24 (ignored by pass filters)
    public var bandwidth: Float = 1         // octaves, 0.05...5
    public var bypass: Bool = true
    public init(type: EQType = .parametric, frequency: Float = 1000, gain: Float = 0, bandwidth: Float = 1, bypass: Bool = true) {
        self.type = type; self.frequency = frequency; self.gain = gain; self.bandwidth = bandwidth; self.bypass = bypass
    }
}

public enum EngineError: Error, CustomStringConvertible {
    case noStems, mismatchedStems(String), unknownStem(String), notLoaded, renderFailed(String)
    public var description: String {
        switch self {
        case .noStems: return "no stems to load"
        case .mismatchedStems(let s): return "stems don't line up: \(s)"
        case .unknownStem(let s): return "no stem named \(s)"
        case .notLoaded: return "nothing loaded"
        case .renderFailed(let s): return "render failed: \(s)"
        }
    }
}

public final class PDEngine {
    public static let eqBandCount = 5

    final class Stem {
        let name: String
        let file: AVAudioFile
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: PDEngine.eqBandCount)
        let reverb = AVAudioUnitReverb()
        let mixer = AVAudioMixerNode()
        var volume: Float = 1, mute = false, solo = false
        init(name: String, file: AVAudioFile) { self.name = name; self.file = file }
    }

    public let engine: AVAudioEngine
    /// true when this deck lives in a PDMixer's engine with another deck (export then renders on a private copy)
    public let isShared: Bool
    /// the deck's last stage; PDMixer connects it to its own main-mixer bus
    public let output = AVAudioMixerNode()
    public static let chainFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let stemBus = AVAudioMixerNode()
    public let timePitch = AVAudioUnitTimePitch()
    let masterEQ = AVAudioUnitEQ(numberOfBands: PDEngine.eqBandCount)
    let masterReverb = AVAudioUnitReverb()
    /// Blend's simple effects: one-knob filter (high-pass one way, low-pass the other) and a beat-synced echo
    let fxFilter = AVAudioUnitEQ(numberOfBands: 2)
    let fxEcho = AVAudioUnitDelay()
    var stems: [Stem] = []

    public private(set) var sampleRate: Double = 44100
    public private(set) var lengthFrames: AVAudioFramePosition = 0
    var startFrame: AVAudioFramePosition = 0
    var pausedFrame: AVAudioFramePosition = 0
    public private(set) var isPlaying = false

    // live recording + meters share one tap on the master chain's last stage (before the listening volume)
    private var recordFile: AVAudioFile?
    private let tapLock = NSLock()
    public var onLevels: (([Float], [Float], [Float]) -> Void)?   // (48 spectrum bands 0...1, 128 scope samples -1...1, [rms L, rms R, peak L, peak R] dBFS)
    private var fft: vDSP.FFT<DSPSplitComplex>?

    public init(shared: AVAudioEngine? = nil) {
        engine = shared ?? AVAudioEngine(); isShared = shared != nil
        engine.attach(stemBus); engine.attach(timePitch); engine.attach(masterEQ); engine.attach(masterReverb); engine.attach(fxFilter); engine.attach(fxEcho); engine.attach(output)
        fxFilter.bands[0].filterType = .highPass; fxFilter.bands[1].filterType = .lowPass
        for b in fxFilter.bands { b.bypass = true; b.bandwidth = 0.7 }
        fxEcho.wetDryMix = 0; fxEcho.feedback = 35; fxEcho.lowPassCutoff = 9000; fxEcho.delayTime = 0.25
        masterReverb.loadFactoryPreset(.largeHall); masterReverb.wetDryMix = 0
        resetEQ(masterEQ)
        let f = PDEngine.chainFormat
        engine.connect(stemBus, to: timePitch, format: f)
        engine.connect(timePitch, to: masterEQ, format: f)
        engine.connect(masterEQ, to: masterReverb, format: f)
        engine.connect(masterReverb, to: fxFilter, format: f)
        engine.connect(fxFilter, to: fxEcho, format: f)
        engine.connect(fxEcho, to: output, format: f)
        if !isShared { engine.connect(output, to: engine.mainMixerNode, format: f) }
    }

    public var stemNames: [String] { stems.map(\.name) }
    public var duration: Double { Double(lengthFrames) / sampleRate }

    // MARK: loading

    /// Load one or more time-aligned stems (all from the same source, same length and rate).
    /// A song with no separation is loaded as a single stem called "mix".
    public func load(stems list: [(name: String, url: URL)]) throws {
        guard !list.isEmpty else { throw EngineError.noStems }
        stop()
        for s in stems { engine.detach(s.player); engine.detach(s.eq); engine.detach(s.reverb); engine.detach(s.mixer) }
        stems = []
        var rate: Double? = nil, length: AVAudioFramePosition = 0
        for (name, url) in list {
            let f = try AVAudioFile(forReading: url)
            if let r = rate, abs(r - f.processingFormat.sampleRate) > 0.5 { throw EngineError.mismatchedStems("\(name) is \(f.processingFormat.sampleRate) Hz, others \(r) Hz") }
            rate = f.processingFormat.sampleRate
            length = max(length, f.length)
            stems.append(Stem(name: name, file: f))
        }
        sampleRate = rate ?? 44100
        lengthFrames = length
        startFrame = 0; pausedFrame = 0
        let busFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        for s in stems {
            engine.attach(s.player); engine.attach(s.eq); engine.attach(s.reverb); engine.attach(s.mixer)
            s.reverb.loadFactoryPreset(.mediumHall); s.reverb.wetDryMix = 0
            resetEQ(s.eq)
            engine.connect(s.player, to: s.eq, format: s.file.processingFormat)
            engine.connect(s.eq, to: s.reverb, format: s.file.processingFormat)
            engine.connect(s.reverb, to: s.mixer, format: s.file.processingFormat)
            engine.connect(s.mixer, to: stemBus, format: busFormat)
        }
        applyMix()
    }

    // MARK: transport (real time)

    public func startRealtime() throws {
        if !isShared, engine.isInManualRenderingMode { engine.stop(); engine.disableManualRenderingMode() }
        installTap()
        if !engine.isRunning { engine.prepare(); try engine.start() }
    }

    /// Start every stem on the same future host time so they stay sample-locked. Pass `at` to start on a shared time
    /// (PDMixer uses it to start or re-phase one deck against the other).
    public func play(from seconds: Double? = nil, at: AVAudioTime? = nil) throws {
        guard !stems.isEmpty else { throw EngineError.notLoaded }
        try startRealtime()
        let from = seconds.map { AVAudioFramePosition($0 * sampleRate) } ?? pausedFrame
        schedule(from: from)
        let start = at ?? AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        if engine.isInManualRenderingMode { for s in stems { s.player.play() } }   // offline renders start at once
        else { for s in stems { s.player.play(at: start) } }
        isPlaying = true
    }

    public func pause() {
        guard isPlaying else { return }
        pausedFrame = currentFrame
        for s in stems { s.player.stop() }
        isPlaying = false
    }

    public func stop() {
        for s in stems { s.player.stop() }
        isPlaying = false; pausedFrame = 0
    }

    public func seek(to seconds: Double) throws {
        let f = max(0, min(lengthFrames, AVAudioFramePosition(seconds * sampleRate)))
        if isPlaying { pausedFrame = f; for s in stems { s.player.stop() }; isPlaying = false; try play() }
        else { pausedFrame = f }
    }

    /// Position in the source, in frames (speed changes don't change the source clock).
    public var currentFrame: AVAudioFramePosition {
        guard isPlaying, let p = stems.first?.player, let nt = p.lastRenderTime, nt.isSampleTimeValid || nt.isHostTimeValid,
              let pt = p.playerTime(forNodeTime: nt) else { return pausedFrame }   // a fresh node can report an invalid time; asking with it crashes
        return min(lengthFrames, startFrame + max(0, pt.sampleTime))
    }
    public var position: Double { Double(currentFrame) / sampleRate }
    /// false while a scheduled start (play(at:)) hasn't been reached yet
    public var isSounding: Bool {
        guard isPlaying, let p = stems.first?.player, let nt = p.lastRenderTime, nt.isSampleTimeValid || nt.isHostTimeValid,
              let pt = p.playerTime(forNodeTime: nt) else { return false }
        return pt.sampleTime >= 0
    }

    private func schedule(from frame: AVAudioFramePosition) {
        startFrame = max(0, min(frame, lengthFrames))
        for s in stems {
            s.player.stop()
            let remaining = AVAudioFrameCount(max(0, s.file.length - startFrame))
            if remaining > 0 { s.player.scheduleSegment(s.file, startingFrame: startFrame, frameCount: remaining, at: nil) }
        }
    }

    // MARK: speed + pitch (master, so every stem stays in sync)

    /// Playback speed with pitch kept, 0.25...4.0.
    public var speed: Float { get { timePitch.rate } set { timePitch.rate = max(0.25, min(4, newValue)) } }
    /// Pitch shift in semitones, independent of speed, -24...24.
    public var pitchSemitones: Float { get { timePitch.pitch / 100 } set { timePitch.pitch = max(-2400, min(2400, newValue * 100)) } }

    // MARK: Blend effects

    /// One knob, -1...1: below 0 sweeps a low-pass down (muffled), above 0 sweeps a high-pass up (thin). 0 = off.
    public var filter: Float = 0 {
        didSet {
            filter = max(-1, min(1, filter))
            let lp = fxFilter.bands[1], hp = fxFilter.bands[0]
            if abs(filter) < 0.02 { lp.bypass = true; hp.bypass = true; return }
            if filter < 0 { hp.bypass = true; lp.bypass = false; lp.frequency = 20000 * pow(150 / 20000, -filter) }   // 20 kHz -> 150 Hz
            else { lp.bypass = true; hp.bypass = false; hp.frequency = 20 * pow(6000 / 20, filter) }                  // 20 Hz -> 6 kHz
        }
    }
    /// Echo: time in seconds (the page sends beat fractions converted with the song's BPM), feedback 0...90 %, mix 0...100 %.
    public func setEcho(time: Float, feedback: Float, mix: Float) {
        fxEcho.delayTime = TimeInterval(max(0.01, min(2, time))); fxEcho.feedback = max(0, min(90, feedback)); fxEcho.wetDryMix = max(0, min(100, mix))
    }

    // MARK: per-stem mix

    func stem(_ name: String) throws -> Stem {
        guard let s = stems.first(where: { $0.name == name }) else { throw EngineError.unknownStem(name) }
        return s
    }
    public func setVolume(_ name: String, _ v: Float) throws { try stem(name).volume = max(0, min(2, v)); applyMix() }
    public func setMute(_ name: String, _ on: Bool) throws { try stem(name).mute = on; applyMix() }
    public func setSolo(_ name: String, _ on: Bool) throws { try stem(name).solo = on; applyMix() }
    public func setPan(_ name: String, _ p: Float) throws { try stem(name).mixer.pan = max(-1, min(1, p)) }
    public func setStemReverb(_ name: String, wet: Float) throws { try stem(name).reverb.wetDryMix = max(0, min(100, wet)) }
    public func setStemEQ(_ name: String, band: Int, _ b: EQBandSetting) throws { try apply(b, to: stem(name).eq, band: band) }

    /// Deck volume. The heard level is volume x fadeGain (the crossfader's share for this deck, set by PDMixer).
    public var masterVolume: Float = 1 { didSet { masterVolume = max(0, min(1, masterVolume)); output.outputVolume = masterVolume * fadeGain } }
    public var fadeGain: Float = 1 { didSet { output.outputVolume = masterVolume * fadeGain } }
    public func setMasterEQ(band: Int, _ b: EQBandSetting) { apply(b, to: masterEQ, band: band) }
    public func setMasterReverb(wet: Float, preset: AVAudioUnitReverbPreset? = nil) {
        if let p = preset { masterReverb.loadFactoryPreset(p) }
        masterReverb.wetDryMix = max(0, min(100, wet))
    }

    func applyMix() {
        let anySolo = stems.contains { $0.solo }
        for s in stems {
            let audible = anySolo ? s.solo : !s.mute
            s.mixer.outputVolume = audible ? s.volume : 0
        }
    }

    func resetEQ(_ eq: AVAudioUnitEQ) {
        let defaults: [(AVAudioUnitEQFilterType, Float)] = [(.lowShelf, 90), (.parametric, 250), (.parametric, 1000), (.parametric, 3500), (.highShelf, 9000)]
        for (i, band) in eq.bands.enumerated() {
            band.filterType = defaults[i].0; band.frequency = defaults[i].1; band.gain = 0; band.bandwidth = 1; band.bypass = false
        }
        eq.globalGain = 0
    }

    func apply(_ b: EQBandSetting, to eq: AVAudioUnitEQ, band: Int) {
        guard eq.bands.indices.contains(band) else { return }
        let p = eq.bands[band]
        let types: [EQType: AVAudioUnitEQFilterType] = [.parametric: .parametric, .lowShelf: .lowShelf, .highShelf: .highShelf, .highPass: .highPass, .lowPass: .lowPass]
        p.filterType = types[b.type] ?? .parametric
        p.frequency = max(20, min(Float(sampleRate / 2 - 100), b.frequency))
        p.gain = max(-24, min(24, b.gain))
        p.bandwidth = max(0.05, min(5, b.bandwidth))
        p.bypass = b.bypass
    }

    // MARK: offline render + export (same graph, so the file is exactly what you hear)

    public enum ExportFormat { case wav, m4a }

    /// Renders the current mix, with every setting, from `from` seconds to the end (or `seconds` long), plus a reverb tail.
    @discardableResult
    public func export(to url: URL, format: ExportFormat = .wav, from: Double = 0, seconds: Double? = nil, tail: Double = 2.0) throws -> AVAudioFramePosition {
        guard !stems.isEmpty else { throw EngineError.notLoaded }
        if isShared { return try offlineCopy().export(to: url, format: format, from: from, seconds: seconds, tail: tail) }
        let wasPlaying = isPlaying, resumeAt = position
        stop(); removeTap(); engine.stop()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        defer {
            engine.stop(); engine.disableManualRenderingMode()
            if wasPlaying { try? play(from: resumeAt) }
        }
        let startF = AVAudioFramePosition(from * sampleRate)
        let srcFrames = seconds.map { AVAudioFramePosition($0 * sampleRate) } ?? (lengthFrames - startF)
        schedule(from: startF)
        if seconds != nil {   // trim the scheduled segments to the requested span
            for s in stems { s.player.stop(); let n = AVAudioFrameCount(max(0, min(srcFrames, s.file.length - startF))); if n > 0 { s.player.scheduleSegment(s.file, startingFrame: startF, frameCount: n, at: nil) } }
        }
        installTap()
        try engine.start()
        for s in stems { s.player.play() }
        let total = AVAudioFramePosition(Double(srcFrames) / Double(speed)) + AVAudioFramePosition(tail * sampleRate)
        let settings: [String: Any] = format == .wav
            ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
        let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var done: AVAudioFramePosition = 0
        while done < total {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(buf.frameCapacity), total - done))
            let status = try engine.renderOffline(n, to: buf)
            switch status {
            case .success: try out.write(from: buf); done += AVAudioFramePosition(buf.frameLength)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext: continue
            case .error: throw EngineError.renderFailed("render status error at frame \(done)")
            @unknown default: throw EngineError.renderFailed("unknown render status")
            }
        }
        for s in stems { s.player.stop() }
        removeTap()
        return done
    }

    /// A private engine with the same song, stems and every setting, for offline renders that mustn't stop the shared engine.
    public func offlineCopy() throws -> PDEngine {
        let c = PDEngine()
        try c.load(stems: stems.map { (name: $0.name, url: $0.file.url) })
        c.speed = speed; c.pitchSemitones = pitchSemitones
        c.masterReverb.wetDryMix = masterReverb.wetDryMix
        c.filter = filter; c.setEcho(time: Float(fxEcho.delayTime), feedback: fxEcho.feedback, mix: fxEcho.wetDryMix)
        copyEQ(masterEQ, to: c.masterEQ)
        for (a, b) in zip(stems, c.stems) {
            b.volume = a.volume; b.mute = a.mute; b.solo = a.solo; b.mixer.pan = a.mixer.pan; b.reverb.wetDryMix = a.reverb.wetDryMix
            copyEQ(a.eq, to: b.eq)
        }
        c.applyMix()
        return c
    }
    func copyEQ(_ a: AVAudioUnitEQ, to b: AVAudioUnitEQ) {
        for (x, y) in zip(a.bands, b.bands) { y.filterType = x.filterType; y.frequency = x.frequency; y.gain = x.gain; y.bandwidth = x.bandwidth; y.bypass = x.bypass }
        b.globalGain = a.globalGain
    }

    // MARK: live recording of the mix (everything you hear, in real time)

    public func startRecording(to url: URL) throws {
        let fmt = masterReverb.outputFormat(forBus: 0)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate, AVNumberOfChannelsKey: fmt.channelCount,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        tapLock.lock(); recordFile = f; tapLock.unlock()
        installTap()
    }
    @discardableResult public func stopRecording() -> URL? {
        tapLock.lock(); let url = recordFile?.url; recordFile = nil; tapLock.unlock()
        return url
    }
    public var isRecording: Bool { tapLock.lock(); defer { tapLock.unlock() }; return recordFile != nil }

    private var tapInstalled = false
    private func installTap() {
        guard !tapInstalled else { return }
        masterReverb.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buf, _ in
            guard let self else { return }
            self.tapLock.lock(); let f = self.recordFile; self.tapLock.unlock()
            if let f { try? f.write(from: buf) }
            if self.onLevels != nil { self.meter(buf) }
        }
        tapInstalled = true
    }
    private func removeTap() { if tapInstalled { masterReverb.removeTap(onBus: 0); tapInstalled = false } }

    private func meter(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData, buf.frameLength >= 1024 else { return }
        let n = 1024, half = n / 2
        if fft == nil { fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self) }
        var mono = [Float](repeating: 0, count: n)
        let chans = Int(buf.format.channelCount), frames = Int(buf.frameLength)
        var lr = [Float](repeating: -90, count: 4)
        for c in 0..<min(chans, 2) {
            let p = UnsafeBufferPointer(start: ch[c], count: frames)
            lr[c] = max(-90, 20 * log10(vDSP.rootMeanSquare(p) + 1e-9)); lr[c + 2] = max(-90, 20 * log10(vDSP.maximumMagnitude(p) + 1e-9))
        }
        if chans == 1 { lr[1] = lr[0]; lr[3] = lr[2] }
        for c in 0..<chans { vDSP.add(mono, UnsafeBufferPointer(start: ch[c], count: n), result: &mono) }
        vDSP.multiply(1 / Float(chans), mono, result: &mono)
        let scope = stride(from: 0, to: n, by: n / 128).map { mono[$0] }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        vDSP.multiply(mono, window, result: &mono)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half), mags = [Float](repeating: 0, count: half)
        re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            mono.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half)) }
            fft?.forward(input: split, output: &split)
            vDSP.absolute(split, result: &mags)
        } }
        var bands = [Float](repeating: 0, count: 48)
        for i in 0..<48 {
            let lo = Int(2 * pow(Double(half) / 2, Double(i) / 48)), hi = max(lo + 1, Int(2 * pow(Double(half) / 2, Double(i + 1) / 48)))
            let m = mags[min(lo, half - 1)..<min(hi, half)].max() ?? 0
            bands[i] = max(0, min(1, (20 * log10(m / Float(n) + 1e-9) + 70) / 60))
        }
        onLevels?(bands, scope, lr)
    }
}
