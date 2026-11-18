// Stem separation. Two engines, and the app always says which one made the stems:
//  - "centre" (built in, works now): stereo centre extraction with a short-time FFT. Keeps what is identical in
//    left and right between ~110 Hz and ~9 kHz as Vocals; Instrumental = original minus Vocals, so the two always
//    sum back to the original. Rough: centred snare/synth leaks into Vocals; mono files can't be split.
//  - "ai" (needs install): an AI model (Demucs / RoFormer via a local Python environment) for vocals, drums,
//    bass, other. Not installed on this Mac yet; `aiStatus()` says exactly what's missing.
import AVFoundation
import Accelerate

public enum SeparationError: Error, CustomStringConvertible {
    case mono, read(String), aiUnavailable(String), aiFailed(String)
    public var description: String {
        switch self {
        case .mono: return "this file is mono, so there is no stereo centre to separate"
        case .read(let s): return "could not read audio: \(s)"
        case .aiUnavailable(let s): return s
        case .aiFailed(let s): return "AI separation failed: \(s)"
        }
    }
}

public struct StemSet { public let engine: String; public let stems: [(name: String, url: URL)] }

public enum Separation {
    static func readStereo(_ url: URL) throws -> (l: [Float], r: [Float], rate: Double) {
        let f: AVAudioFile
        do { f = try AVAudioFile(forReading: url) } catch { throw SeparationError.read(error.localizedDescription) }
        let fmt = f.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)) else { throw SeparationError.read("buffer") }
        try f.read(into: buf)
        guard fmt.channelCount >= 2, let ch = buf.floatChannelData else { throw SeparationError.mono }
        let n = Int(buf.frameLength)
        return (Array(UnsafeBufferPointer(start: ch[0], count: n)), Array(UnsafeBufferPointer(start: ch[1], count: n)), fmt.sampleRate)
    }

    static func writeStereo(_ url: URL, _ l: [Float], _ r: [Float], rate: Double) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false]
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(l.count))!
        buf.frameLength = AVAudioFrameCount(l.count)
        l.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: l.count) }
        r.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: r.count) }
        try f.write(from: buf)
    }

    /// Centre extraction. Returns the vocal estimate (mono) for a stereo pair.
    public static func centreVocals(l L: [Float], r R: [Float], rate sr: Double, progress: ((Double) -> Void)? = nil) -> [Float] {
        let n = L.count, N = 2048, H = 512
        let win = (0..<N).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(N)) }
        let fwd = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(N), .FORWARD)!, inv = vDSP_DFT_zop_CreateSetupD(fwd, vDSP_Length(N), .INVERSE)!
        defer { vDSP_DFT_DestroySetupD(fwd); vDSP_DFT_DestroySetupD(inv) }
        func smooth(_ x: Double, _ a: Double, _ b: Double) -> Double { let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
        let band = (0...N / 2).map { k -> Double in let f = Double(k) * sr / Double(N); return smooth(f, 110, 230) * (1 - smooth(f, 9000, 14000)) }
        var inR = [Double](repeating: 0, count: N), inI = inR, re = inR, im = inR, vr = inR, vi = inR, outR = inR, outI = inR
        var out = [Double](repeating: 0, count: n)
        let norm = 1 / (1.5 * Double(N))
        let frames = (n + N) / H + 1
        for fi in 0..<frames {
            let start = fi * H - N
            for i in 0..<N { let x = start + i; let ok = x >= 0 && x < n; inR[i] = ok ? Double(L[x]) * win[i] : 0; inI[i] = ok ? Double(R[x]) * win[i] : 0 }
            vDSP_DFT_ExecuteD(fwd, inR, inI, &re, &im)
            for k in 0...N / 2 {
                let j = (N - k) % N
                let Lr = (re[k] + re[j]) / 2, Li = (im[k] - im[j]) / 2, Rr = (im[k] + im[j]) / 2, Ri = (re[j] - re[k]) / 2
                let p = Lr * Lr + Li * Li + Rr * Rr + Ri * Ri
                var w = p > 1e-14 ? 2 * (Lr * Rr + Li * Ri) / p : 0
                if w < 0 { w = 0 }
                let m = w * w * w * w * band[k]
                vr[k] = (Lr + Rr) / 2 * m; vi[k] = (Li + Ri) / 2 * m
                if k > 0 && k < N / 2 { vr[N - k] = vr[k]; vi[N - k] = -vi[k] }
            }
            vDSP_DFT_ExecuteD(inv, vr, vi, &outR, &outI)
            for i in 0..<N { let x = start + i; if x >= 0 && x < n { out[x] += outR[i] * win[i] * norm } }
            if fi % 500 == 0 { progress?(Double(fi) / Double(frames)) }
        }
        return out.map { Float($0) }
    }

    /// Splits a song into Vocals + Instrumental files in `dir` with the built-in centre engine.
    public static func centreSplit(_ url: URL, into dir: URL, progress: ((Double) -> Void)? = nil) throws -> StemSet {
        let (l, r, rate) = try readStereo(url)
        let v = centreVocals(l: l, r: r, rate: rate, progress: progress)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vu = dir.appendingPathComponent("vocals.wav"), iu = dir.appendingPathComponent("instrumental.wav")
        try writeStereo(vu, v, v, rate: rate)
        var il = l, ir = r
        vDSP.subtract(l, v, result: &il); vDSP.subtract(r, v, result: &ir)
        try writeStereo(iu, il, ir, rate: rate)
        return StemSet(engine: "centre", stems: [("vocals", vu), ("instrumental", iu)])
    }

    // MARK: AI separation (local Python environment, Demucs htdemucs_ft on the Apple GPU)

    public static var aiHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Blend/separator", isDirectory: true)
    }
    static var python: URL { aiHome.appendingPathComponent("venv/bin/python") }
    static var runner: URL { aiHome.appendingPathComponent("separate.py") }

    /// nil when the AI engine is ready; otherwise exactly what's missing.
    public static func aiStatus() -> String? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: python.path) && fm.fileExists(atPath: runner.path) { return nil }
        return "AI separation is not installed. It needs Python 3.11, PyTorch and the Demucs htdemucs_ft model "
            + "(about 1 GB in ~/Library/Application Support/Blend/separator). Run separator/setup.sh once to install it."
    }

    /// Decodes any file macOS can read (MP3, M4A, WAV…) to a stereo float WAV for the model; mono is doubled.
    static func decodeToWav(_ url: URL, _ out: URL) throws {
        let f: AVAudioFile
        do { f = try AVAudioFile(forReading: url) } catch { throw SeparationError.read(error.localizedDescription) }
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { throw SeparationError.read("buffer") }
        try f.read(into: buf)
        let n = Int(buf.frameLength), ch = buf.floatChannelData!
        let l = Array(UnsafeBufferPointer(start: ch[0], count: n))
        let r = f.processingFormat.channelCount > 1 ? Array(UnsafeBufferPointer(start: ch[1], count: n)) : l
        try writeStereo(out, l, r, rate: f.processingFormat.sampleRate)
    }

    /// Four stems (vocals, drums, bass, other). `shifts` = averaged time-shifted passes: 2 high quality, 4 max.
    public static func aiSplit(_ url: URL, into dir: URL, shifts: Int = 2, model: String = "htdemucs_ft", progress: ((String) -> Void)? = nil) throws -> StemSet {
        if let missing = aiStatus() { throw SeparationError.aiUnavailable(missing) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = dir.appendingPathComponent("source.wav")
        try decodeToWav(url, input)
        defer { try? FileManager.default.removeItem(at: input) }
        let p = Process()
        p.executableURL = python
        p.arguments = [runner.path, input.path, dir.path, "--shifts", "\(shifts)", "--overlap", "0.5", "--model", model]
        var env = ProcessInfo.processInfo.environment; env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"; p.environment = env
        let outPipe = Pipe(), errPipe = Pipe(); p.standardOutput = outPipe; p.standardError = errPipe
        var errData = Data()
        errPipe.fileHandleForReading.readabilityHandler = { h in errData.append(h.availableData) }
        outPipe.fileHandleForReading.readabilityHandler = { h in
            if let line = String(data: h.availableData, encoding: .utf8), !line.isEmpty { progress?(line.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        try p.run(); p.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil; errPipe.fileHandleForReading.readabilityHandler = nil
        guard p.terminationStatus == 0 else {
            let tail = String(data: errData, encoding: .utf8)?.split(separator: "\n").suffix(3).joined(separator: " ") ?? "exit \(p.terminationStatus)"
            throw SeparationError.aiFailed(tail)
        }
        let stems = ["vocals", "drums", "bass", "other"].map { (name: $0, url: dir.appendingPathComponent("\($0).wav")) }
        guard stems.allSatisfy({ FileManager.default.fileExists(atPath: $0.url.path) }) else { throw SeparationError.aiFailed("stems missing in \(dir.path)") }
        return StemSet(engine: "ai", stems: stems)
    }

    // MARK: DJ stems for Blend (vocals / drums / bass / melody / fx)

    /// Demucs gives vocals, drums, bass and "other". Blend calls "other" Melody. When the effects model is installed it
    /// pulls an FX layer out of the melody (melody keeps what's left), so all five still add up to the song.
    /// Only one AI split runs at a time (two decks splitting together would fight over the GPU).
    static let splitLock = NSLock()

    /// Stems are kept as 16-bit Apple Lossless (.m4a): about a tenth of the 32-bit WAVs the models write, with no
    /// encoder delay, so every stem stays sample-locked to the others. 16-bit noise sits ~96 dB down: inaudible.
    public static func writeALAC(_ url: URL, _ l: [Float], _ r: [Float], rate: Double) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16]
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!, chunk = 65536
        var at = 0
        while at < l.count {
            let n = min(chunk, l.count - at)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!; buf.frameLength = AVAudioFrameCount(n)
            for k in 0..<n { buf.floatChannelData![0][k] = max(-1, min(1, l[at + k])); buf.floatChannelData![1][k] = max(-1, min(1, r[at + k])) }
            try f.write(from: buf); at += n
        }
    }

    /// Free space on the startup disk, in bytes.
    public static func freeBytes() -> Int64 {
        let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Demucs (vocals, drums, bass, "other" = Melody), then the FX layer pulled out of the melody. All five still add up
    /// to the song. `quality`: false = htdemucs, 1 pass (about 7x faster, slightly lower separation score),
    /// true = htdemucs_ft, 2 passes (the old setting). Working files go in a temp folder and are removed; the stem folder
    /// ends up holding only the five .m4a files.
    public static func djSplit(_ url: URL, into dir: URL, aiDir: URL, shifts: Int = 2, quality: Bool = false) throws -> StemSet {
        splitLock.lock(); defer { splitLock.unlock() }
        let fm = FileManager.default
        if freeBytes() < 1_500_000_000 { throw SeparationError.aiFailed("not enough disk space to split (needs about 1.5 GB free while working)") }
        let work = fm.temporaryDirectory.appendingPathComponent("blend-split-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work); try? fm.removeItem(at: aiDir) }
        // reuse an older full-size split of this song if one is lying around, else run Demucs
        let old = ["vocals", "drums", "bass", "other"].map { aiDir.appendingPathComponent("\($0).wav") }
        let four: [URL]
        if old.allSatisfy({ fm.fileExists(atPath: $0.path) }) { four = old }
        else {
            _ = try aiSplit(url, into: work, shifts: quality ? 2 : 1, model: quality ? "htdemucs_ft" : "htdemucs")
            four = ["vocals", "drums", "bass", "other"].map { work.appendingPathComponent("\($0).wav") }
        }
        var melody = try readStereo(four[3]); let rate = melody.rate
        var parts: [(String, [Float], [Float])] = []
        for (src, name) in zip(four.prefix(3), ["vocals", "drums", "bass"]) { let x = try readStereo(src); parts.append((name, x.l, x.r)) }
        var fxPart: ([Float], [Float])? = nil
        if fxReady {
            let fx = work.appendingPathComponent("fx.wav")
            let p = Process(); p.executableURL = python; p.arguments = [fxRunner.path, four[3].path, fx.path]
            var env = ProcessInfo.processInfo.environment; env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"; p.environment = env
            let errPipe = Pipe(); p.standardError = errPipe; p.standardOutput = Pipe()
            try p.run(); let errData = errPipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            if p.terminationStatus == 0, fm.fileExists(atPath: fx.path) {
                let e = try readStereo(fx)
                for k in 0..<min(melody.l.count, e.l.count) { melody.l[k] -= e.l[k]; melody.r[k] -= e.r[k] }
                fxPart = (e.l, e.r)
            } else { print("fx stage failed:", String(data: errData, encoding: .utf8)?.suffix(300) ?? "") }
        }
        parts.append(("melody", melody.l, melody.r))
        if let fx = fxPart { parts.append(("fx", fx.0, fx.1)) }
        // write into a fresh folder, then swap it in, so a half-written split is never loaded
        let tmpOut = work.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: tmpOut, withIntermediateDirectories: true)
        for (name, l, r) in parts { try writeALAC(tmpOut.appendingPathComponent("\(name).m4a"), l, r, rate: rate) }
        try? fm.removeItem(at: dir); try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: tmpOut, to: dir)
        let order = ["vocals", "drums", "bass", "melody", "fx"].filter { n in parts.contains { $0.0 == n } }
        return StemSet(engine: "dj", stems: order.map { (name: $0, url: dir.appendingPathComponent("\($0).m4a")) })
    }

    // MARK: three stems (vocals / instrumentals / fx)

    static var fxRunner: URL { aiHome.appendingPathComponent("fx.py") }
    /// The effects model is a separate, optional stage (see fx.py); without it the split gives vocals + instrumentals only.
    public static var fxReady: Bool { FileManager.default.isExecutableFile(atPath: python.path) && FileManager.default.fileExists(atPath: fxRunner.path) }

    /// Vocals and instrumentals come from Demucs (instrumentals = drums + bass + other, so nothing is thrown away).
    /// When the effects model is installed it pulls an effects layer out of the instrumentals, and the instrumentals keep
    /// what's left, so vocals + instrumentals + fx still add back up to the song.
    public static func threeSplit(_ url: URL, into dir: URL, aiDir: URL, shifts: Int = 2, progress: ((String) -> Void)? = nil) throws -> StemSet {
        let fm = FileManager.default
        let four = ["vocals", "drums", "bass", "other"].map { aiDir.appendingPathComponent("\($0).wav") }
        if !four.allSatisfy({ fm.fileExists(atPath: $0.path) }) { _ = try aiSplit(url, into: aiDir, shifts: shifts, progress: progress) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let voc = try readStereo(four[0])
        var l = [Float](repeating: 0, count: voc.l.count), r = l
        for u in four.dropFirst() {
            let s = try readStereo(u)
            for k in 0..<min(l.count, s.l.count) { l[k] += s.l[k]; r[k] += s.r[k] }
        }
        let vocals = dir.appendingPathComponent("vocals.wav"), inst = dir.appendingPathComponent("instrumentals.wav"), fx = dir.appendingPathComponent("fx.wav")
        try writeStereo(vocals, voc.l, voc.r, rate: voc.rate)
        try writeStereo(inst, l, r, rate: voc.rate)
        var stems = [(name: "vocals", url: vocals), (name: "instrumentals", url: inst)]
        if fxReady {
            progress?("FX")
            let p = Process()
            p.executableURL = python
            p.arguments = [fxRunner.path, inst.path, fx.path]
            var env = ProcessInfo.processInfo.environment; env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"; p.environment = env
            let errPipe = Pipe(); p.standardError = errPipe; p.standardOutput = Pipe()
            try p.run()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0, fm.fileExists(atPath: fx.path) else {
                let tail = String(data: errData, encoding: .utf8)?.split(separator: "\n").suffix(3).joined(separator: " ") ?? "exit \(p.terminationStatus)"
                throw SeparationError.aiFailed("fx stage: " + tail)
            }
            let e = try readStereo(fx)
            for k in 0..<min(l.count, e.l.count) { l[k] -= e.l[k]; r[k] -= e.r[k] }
            try writeStereo(inst, l, r, rate: voc.rate)
            stems.append((name: "fx", url: fx))
        } else { try? fm.removeItem(at: fx) }
        return StemSet(engine: "ai3", stems: stems)
    }
}
