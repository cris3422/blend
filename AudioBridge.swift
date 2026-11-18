// Connects the page to the native audio engine. The page sends {t: "eng", cmd, ...} messages; the bridge
// keeps the song files, runs the engine, and pushes state (15 Hz) and meter levels (30 Hz) back to the page.
// Songs: the page hands each song over once (importSong); it is kept in Application Support so the
// engine reads the real file. Stems from a split live next to it and load automatically.
import Cocoa
import AVFoundation
import CryptoKit
import Accelerate

final class AudioBridge {
    let engine: PDEngine
    weak var mixer: PDMixer?          // set when this deck shares the app's mixer: recording, crossfade and master go through it
    weak var web: WKWebViewLike?
    let home: URL
    var revealInFinder = true
    lazy var support = home.appendingPathComponent("Library/Application Support/Blend", isDirectory: true)
    lazy var libraryDir = support.appendingPathComponent("library", isDirectory: true)
    lazy var stemsRoot = support.appendingPathComponent("stems", isDirectory: true)
    lazy var musicOut = home.appendingPathComponent("Music/Blend", isDirectory: true)
    var currentKey: String?
    var stemEngine = "none"
    var mutes: [String: Bool] = [:], solos: [String: Bool] = [:]
    var lastLevels = Date.distantPast
    var timer: Timer?
    var splitting = false
    var highQuality = false   // false: fast split (htdemucs, 1 pass); true: the slower fine-tuned model
    var lastExport: URL?, lastRecording: URL?, recordingNow: URL?
    /// Mashup: this deck plays its song's stems re-rendered at `mashRate` x the tempo (key kept, + mashSemis). 1 = the song itself.
    var mashRate: Double = 1, mashSemis: Double = 0, mashing = false

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, engine: PDEngine = PDEngine(), mixer: PDMixer? = nil) {
        self.home = home; self.engine = engine; self.mixer = mixer
        for d in [libraryDir, stemsRoot] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        engine.onLevels = { [weak self] bands, scope, lr in
            guard let self else { return }
            let now = Date(); guard now.timeIntervalSince(self.lastLevels) > 1.0 / 30 else { return }
            self.lastLevels = now
            let b = bands.map { String(format: "%.3f", $0) }.joined(separator: ","), s = scope.map { String(format: "%.3f", $0) }.joined(separator: ","), m = lr.map { String(format: "%.1f", $0) }.joined(separator: ",")
            DispatchQueue.main.async { self.web?.run("PD.levels&&PD.levels([\(b)],[\(s)],[\(m)])") }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.pushState() }
    }

    static func safe(_ key: String) -> String { String(key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }) }
    func songURL(_ key: String) -> URL? {
        let base = AudioBridge.safe(key)
        return (try? FileManager.default.contentsOfDirectory(at: libraryDir, includingPropertiesForKeys: nil))?.first { $0.deletingPathExtension().lastPathComponent == base }
    }
    /// Stems are filed under a fingerprint of the song's audio file, not its name, so a second copy of the same song
    /// (different file name) reuses the split instead of splitting again. Older splits filed by name move over once.
    static var hashCache: [String: String] = [:]
    static let hashLock = NSLock()
    func fingerprint(_ key: String) -> String? {
        AudioBridge.hashLock.lock(); defer { AudioBridge.hashLock.unlock() }
        if let h = AudioBridge.hashCache[key] { return h }
        guard let u = songURL(key), let data = try? Data(contentsOf: u, options: .mappedIfSafe) else { return nil }
        let h = "song-" + SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        AudioBridge.hashCache[key] = h; return h
    }
    func stemDir(_ key: String) -> URL {
        let legacy = stemsRoot.appendingPathComponent(AudioBridge.safe(key), isDirectory: true)
        guard let h = fingerprint(key) else { return legacy }
        let dir = stemsRoot.appendingPathComponent(h, isDirectory: true), fm = FileManager.default
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) { try? fm.moveItem(at: legacy, to: dir) }
        return dir
    }

    func available(_ key: String) -> [(name: String, url: URL)] {
        let fm = FileManager.default, d = stemDir(key)
        let dj = ["vocals", "drums", "bass", "melody", "fx"].compactMap { n in ["m4a", "wav"].lazy.map { d.appendingPathComponent("dj/\(n).\($0)") }.first { fm.fileExists(atPath: $0.path) }.map { (n, $0) } }
        if dj.count >= 4 { stemEngine = "dj"; return dj.map { (name: $0.0, url: $0.1) } }
        let three = ["vocals", "instrumentals", "fx"].map { ($0, d.appendingPathComponent("ai3/\($0).wav")) }.filter { fm.fileExists(atPath: $0.1.path) }
        if three.count >= 2, three[0].0 == "vocals", three[1].0 == "instrumentals" { stemEngine = "ai3"; return three.map { (name: $0.0, url: $0.1) } }
        let ai = ["vocals", "drums", "bass", "other"].map { ($0, d.appendingPathComponent("ai/\($0).wav")) }
        if ai.allSatisfy({ fm.fileExists(atPath: $0.1.path) }) { stemEngine = "ai"; return ai.map { (name: $0.0, url: $0.1) } }
        let c = ["vocals", "instrumental"].map { ($0, d.appendingPathComponent("centre/\($0).wav")) }
        if c.allSatisfy({ fm.fileExists(atPath: $0.1.path) }) { stemEngine = "centre"; return c.map { (name: $0.0, url: $0.1) } }
        stemEngine = "none"
        return songURL(key).map { [(name: "mix", url: $0)] } ?? []
    }

    // MARK: messages from the page

    func handle(_ body: [String: Any]) {
        guard let cmd = body["cmd"] as? String else { return }
        let num = { (k: String) in (body[k] as? NSNumber)?.floatValue ?? 0 }
        do {
            switch cmd {
            case "importSong":
                guard let key = body["key"] as? String, let name = body["name"] as? String, let b64 = body["data"] as? String, let data = Data(base64Encoded: b64) else { return }
                let ext = (name as NSString).pathExtension.isEmpty ? "mp3" : (name as NSString).pathExtension
                if songURL(key) == nil { try data.write(to: libraryDir.appendingPathComponent("\(AudioBridge.safe(key)).\(ext)")) }
                web?.run("PD.songImported(\(json(key)))")
            case "songKeys":
                let keys = body["keys"] as? [String] ?? []
                web?.run("PD.needSongs(\(json(keys.filter { songURL($0) == nil })))")
            case "load":
                guard let key = body["key"] as? String else { return }
                let stems = available(key)
                guard !stems.isEmpty else { throw EngineError.notLoaded }
                currentKey = key; mutes = [:]; solos = [:]; mashRate = 1; mashSemis = 0
                try engine.load(stems: stems)
                if (body["play"] as? Bool) == true { try engine.play(from: 0) }
            case "reloadStems":   // stems for this song were split in the background: swap them in where we are
                if let key = currentKey, let k = body["key"] as? String, k == key, mashRate == 1 {
                    let wasPlaying = engine.isPlaying, at = engine.position
                    try engine.load(stems: available(key))
                    if wasPlaying { try engine.play(from: at) } else { try engine.seek(to: at) }
                }
            case "mash":
                guard let key = body["key"] as? String else { return }
                mash(key, rate: (body["rate"] as? NSNumber)?.doubleValue ?? 1, semis: (body["semis"] as? NSNumber)?.doubleValue ?? 0,
                     at: (body["at"] as? NSNumber)?.doubleValue ?? 0, play: (body["play"] as? Bool) ?? false)
            case "mashScan":
                guard let key = body["key"] as? String else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let ph = self.vocalPhrases(key)
                    DispatchQueue.main.async { self.web?.run("PD.mashScan&&PD.mashScan(\(self.json(key)),\(self.json(ph ?? [])))") }
                }
            case "splitQuality": highQuality = (body["on"] as? Bool) ?? false
            case "play": try engine.play()
            case "pause": engine.pause()
            case "unload": engine.stop(); currentKey = nil
            case "seek": try engine.seek(to: Double((body["pos"] as? NSNumber)?.floatValue ?? num("t")))   // "pos": a "t" field would clash with the message type
            case "volume": engine.masterVolume = num("v")
            case "filter": engine.filter = num("v")
            case "echo": engine.setEcho(time: num("time"), feedback: num("feedback"), mix: num("mix"))
            case "crossfade": mixer?.crossfade = num("v")
            case "master": mixer?.masterVolume = num("v")
            case "speed": engine.speed = num("v")
            case "pitch": engine.pitchSemitones = num("v")
            case "stemVolume": try engine.setVolume(body["stem"] as? String ?? "", num("v"))
            case "mute": let s = body["stem"] as? String ?? ""; let on = body["on"] as? Bool ?? false; mutes[s] = on; try engine.setMute(s, on)
            case "solo": let s = body["stem"] as? String ?? ""; let on = body["on"] as? Bool ?? false; solos[s] = on; try engine.setSolo(s, on)
            case "reverb":
                if let s = body["stem"] as? String { try engine.setStemReverb(s, wet: num("wet")) } else { engine.setMasterReverb(wet: num("wet")) }
            case "eq":
                let b = EQBandSetting(type: EQType(rawValue: body["type"] as? String ?? "parametric") ?? .parametric, frequency: num("freq"),
                                      gain: num("gain"), bandwidth: (body["bw"] as? NSNumber)?.floatValue ?? 1, bypass: (body["bypass"] as? Bool) ?? false)
                let band = (body["band"] as? NSNumber)?.intValue ?? 0
                if let s = body["stem"] as? String { try engine.setStemEQ(s, band: band, b) } else { engine.setMasterEQ(band: band, b) }
            case "split": split(engineName: body["engine"] as? String ?? "centre", shifts: (body["shifts"] as? NSNumber)?.intValue ?? 2)
            case "export": try exportMix(reveal: (body["reveal"] as? Bool) ?? revealInFinder)
            case "recStart": try startRecording()
            case "recStop": stopRecording(reveal: (body["reveal"] as? Bool) ?? revealInFinder)
            default: break
            }
        } catch { web?.run("PD.engineError&&PD.engineError(\(json("\(error)")))") }
        pushState()
    }

    // MARK: actions

    func split(engineName: String, shifts: Int = 2) {
        guard let key = currentKey, let src = songURL(key), !splitting else { return }
        if engineName.hasPrefix("ai") || engineName == "dj", let missing = Separation.aiStatus() { web?.run("PD.engineError(\(json(missing)))"); return }
        splitting = true
        let dir = stemDir(key).appendingPathComponent(engineName == "dj" ? "dj" : engineName == "ai3" ? "ai3" : engineName == "ai" ? "ai" : "centre")
        let wasPlaying = engine.isPlaying, at = engine.position
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if engineName == "dj" {
                    let t0 = Date()
                    let tick = DispatchSource.makeTimerSource(queue: .main)
                    tick.schedule(deadline: .now(), repeating: 2)
                    tick.setEventHandler { self.web?.run("PD.splitProgress&&PD.splitProgress(-\(Int(Date().timeIntervalSince(t0))))") }
                    tick.resume()
                    defer { tick.cancel() }
                    _ = try Separation.djSplit(src, into: dir, aiDir: self.stemDir(key).appendingPathComponent("ai"), quality: shifts >= 2 && self.highQuality)
                } else if engineName == "ai3" {
                    let t0 = Date()
                    let tick = DispatchSource.makeTimerSource(queue: .main)
                    tick.schedule(deadline: .now(), repeating: 2)
                    tick.setEventHandler { self.web?.run("PD.toast&&PD.toast('AI SPLIT · \(Int(Date().timeIntervalSince(t0)))S')") }
                    tick.resume()
                    defer { tick.cancel() }
                    _ = try Separation.threeSplit(src, into: dir, aiDir: self.stemDir(key).appendingPathComponent("ai"), shifts: shifts)
                } else if engineName == "ai" {
                    let t0 = Date()
                    let tick = DispatchSource.makeTimerSource(queue: .main)
                    tick.schedule(deadline: .now(), repeating: 2)
                    tick.setEventHandler { self.web?.run("PD.toast&&PD.toast('AI SPLIT · \(shifts == 4 ? "MAX" : "HIGH") QUALITY · \(Int(Date().timeIntervalSince(t0)))S')") }
                    tick.resume()
                    defer { tick.cancel() }
                    _ = try Separation.aiSplit(src, into: dir, shifts: shifts)
                } else {
                    _ = try Separation.centreSplit(src, into: dir) { p in DispatchQueue.main.async { self.web?.run("PD.splitProgress&&PD.splitProgress(\(p))") } }
                }
                DispatchQueue.main.async {
                    self.splitting = false
                    guard self.currentKey == key, self.mashRate == 1 else { return }
                    do { try self.engine.load(stems: self.available(key)); if wasPlaying { try self.engine.play(from: at) } else { try self.engine.seek(to: at) } } catch {}
                    self.web?.run("PD.toast&&PD.toast('SPLIT INTO \(self.engine.stemNames.count) STEMS')"); self.pushState()
                }
            } catch {
                DispatchQueue.main.async { self.splitting = false; self.web?.run("PD.engineError(\(self.json("\(error)")))") }
            }
        }
    }

    // MARK: mashup (one song's vocal over the other song's beat)

    static func ffmpegURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Re-render this song's five DJ stems at `rate` x its tempo with the key kept (Rubber Band, offline, so it is
    /// beat-exact: Apple's live stretcher drifts when it speeds a song up), optionally shifted `semis` semitones, and play
    /// those instead. Cached per song + setting; older mash renders of the song are removed (disk is tight).
    /// rate 1 + semis 0 goes back to the song itself. `at` = where to be in the file that gets loaded.
    func mash(_ key: String, rate: Double, semis: Double, at: Double, play: Bool) {
        guard currentKey == key, !mashing else { return }
        let finish: ([(name: String, url: URL)]) -> Void = { stems in
            do {
                self.mutes = [:]; self.solos = [:]
                try self.engine.load(stems: stems)
                try self.engine.seek(to: at); if play { try self.engine.play() }
            } catch { self.web?.run("PD.engineError(\(self.json("\(error)")))") }
            self.web?.run("PD.mashReady&&PD.mashReady(\(self.json(key)),\(self.mashRate),\(self.mashSemis))"); self.pushState()
        }
        if abs(rate - 1) < 1e-6, abs(semis) < 0.01 { mashRate = 1; mashSemis = 0; finish(available(key)); return }
        let fm = FileManager.default, src = stemDir(key).appendingPathComponent("dj")
        let names = ["vocals", "drums", "bass", "melody", "fx"].filter { fm.fileExists(atPath: src.appendingPathComponent("\($0).m4a").path) }
        guard names.contains("vocals"), names.count >= 4 else { web?.run("PD.engineError('Split this song into stems first')"); return }
        guard let ff = AudioBridge.ffmpegURL() else { web?.run("PD.engineError('ffmpeg is missing, so the vocal song cannot be re-timed')"); return }
        let root = stemDir(key).appendingPathComponent("mash", isDirectory: true)
        let dir = root.appendingPathComponent(String(format: "r%.6f_p%+.1f", rate, semis), isDirectory: true)
        mashing = true; pushState()
        DispatchQueue.global(qos: .userInitiated).async {
            var failed: String? = nil
            if !names.allSatisfy({ fm.fileExists(atPath: dir.appendingPathComponent("\($0).m4a").path) }) {
                let tmp = root.appendingPathComponent("rendering", isDirectory: true)
                try? fm.removeItem(at: tmp); try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                let lock = NSLock()
                DispatchQueue.concurrentPerform(iterations: names.count) { i in
                    let n = names[i]
                    var af = String(format: "rubberband=tempo=%.6f:pitch=%.6f:transients=crisp:detector=compound:phase=laminar:window=standard:pitchq=quality:channels=together", rate, pow(2, semis / 12))
                    if n == "vocals" { af += ":formant=preserved" }
                    let p = Process(); p.executableURL = ff
                    p.arguments = ["-v", "error", "-y", "-i", src.appendingPathComponent("\(n).m4a").path, "-af", af, "-c:a", "alac", tmp.appendingPathComponent("\(n).m4a").path]
                    let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
                    do { try p.run(); let e = err.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                        if p.terminationStatus != 0 { lock.lock(); failed = "\(n): " + (String(data: e, encoding: .utf8) ?? "ffmpeg failed").prefix(160); lock.unlock() }
                    } catch { lock.lock(); failed = "\(n): \(error)"; lock.unlock() }
                }
                if failed == nil {
                    for old in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where old != tmp { try? fm.removeItem(at: old) }
                    do { try fm.moveItem(at: tmp, to: dir) } catch { failed = "\(error)" }
                } else { try? fm.removeItem(at: tmp) }
            }
            DispatchQueue.main.async {
                self.mashing = false
                if let failed { self.web?.run("PD.engineError(\(self.json("Mashup render failed: " + failed)))"); self.pushState(); return }
                guard self.currentKey == key else { return }
                self.mashRate = rate; self.mashSemis = semis
                finish(names.map { (name: $0, url: dir.appendingPathComponent("\($0).m4a")) })
            }
        }
    }

    /// Where the vocal sings: the split's vocal stem, 50 ms loudness, gaps under 1 s bridged, blips under 0.3 s dropped.
    /// Returns [start, end] pairs in song seconds.
    func vocalPhrases(_ key: String) -> [[Double]]? {
        let fm = FileManager.default, d = stemDir(key).appendingPathComponent("dj")
        guard let u = ["m4a", "wav"].map({ d.appendingPathComponent("vocals.\($0)") }).first(where: { fm.fileExists(atPath: $0.path) }),
              let f = try? AVAudioFile(forReading: u) else { return nil }
        let hop = AVAudioFrameCount(f.processingFormat.sampleRate * 0.05), ch = Int(f.processingFormat.channelCount)
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: hop * 200) else { return nil }
        var db: [Float] = []
        while f.framePosition < f.length {
            do { try f.read(into: buf) } catch { break }
            let n = Int(buf.frameLength); if n == 0 { break }
            var k = 0
            while k + Int(hop) <= n {
                var s: Float = 0
                for c in 0..<ch { var m: Float = 0; vDSP_measqv(buf.floatChannelData![c] + k, 1, &m, vDSP_Length(hop)); s += m }
                db.append(10 * log10(s / Float(ch) + 1e-12)); k += Int(hop)
            }
        }
        guard !db.isEmpty else { return [] }
        let ref = db.sorted()[Int(Double(db.count - 1) * 0.95)]
        var runs: [[Int]] = [], start: Int? = nil
        for (k, v) in db.enumerated() {
            let on = v > ref - 25
            if on, start == nil { start = k }
            if !on, let a = start { runs.append([a, k]); start = nil }
        }
        if let a = start { runs.append([a, db.count]) }
        var merged: [[Int]] = []
        for r in runs { if let last = merged.last, r[0] - last[1] < 20 { merged[merged.count - 1][1] = r[1] } else { merged.append(r) } }
        return merged.filter { $0[1] - $0[0] >= 6 }.map { [Double($0[0]) * 0.05, Double($0[1]) * 0.05] }
    }

    func stamp() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return f.string(from: Date()) }

    func exportMix(reveal: Bool = true) throws {
        guard let key = currentKey else { throw EngineError.notLoaded }
        let dir = musicOut.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let title = (key.split(separator: ":").first.map(String.init) ?? "Mix").replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent("\((title as NSString).deletingPathExtension) · \(String(format: "%.2fx %+.0f st", engine.speed, engine.pitchSemitones)) · \(stamp()).wav")
        try engine.export(to: url, format: .wav)
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        lastExport = url
        web?.run("PD.toast&&PD.toast('MIX SAVED · OK ON IT TO DOWNLOAD');PD.mixesChanged&&PD.mixesChanged()")
    }

    func startRecording() throws {
        let dir = musicOut.appendingPathComponent("Mixes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Mix \(stamp()).wav")
        if let mixer { try mixer.startRecording(to: url) } else { try engine.startRealtime(); try engine.startRecording(to: url) }
        recordingNow = url
        web?.run("PD.toast&&PD.toast('RECORDING THE MIX')")
    }
    func stopRecording(reveal: Bool = true) {
        recordingNow = nil
        if let url = mixer?.stopRecording() ?? engine.stopRecording() { lastRecording = url; if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }; web?.run("PD.toast&&PD.toast('MIX SAVED TO MUSIC › POCKET DECK');PD.mixesChanged&&PD.mixesChanged()") }
    }

    // every mix made so far (live recordings and processed songs), newest first
    func mixList() -> [[String: String]] {
        let fm = FileManager.default, f = DateFormatter(); f.dateFormat = "MM/dd HH:mm"
        var out: [(Date, [String: String])] = []
        for dir in ["Mixes", "Exports"] {
            let d = musicOut.appendingPathComponent(dir, isDirectory: true)
            for url in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where ["wav", "m4a"].contains(url.pathExtension.lowercased()) {
                if url == recordingNow { continue }   // still being written
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                out.append((date, ["name": url.lastPathComponent, "dir": dir, "date": f.string(from: date)]))
            }
        }
        return out.sorted { $0.0 > $1.0 }.map { $0.1 }
    }
    func mixURL(_ dir: String, _ name: String) -> URL? {
        guard ["Mixes", "Exports"].contains(dir), !name.contains("/") else { return nil }
        let url = musicOut.appendingPathComponent(dir, isDirectory: true).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: state to the page

    var wasPlaying = false
    func pushState() {
        let ended = engine.isPlaying && engine.currentFrame >= engine.lengthFrames - 256
        if ended { engine.stop() }
        let stems = engine.stemNames.map { ["name": $0, "mute": mutes[$0] ?? false, "solo": solos[$0] ?? false] as [String: Any] }
        let st: [String: Any] = ["pos": engine.position, "dur": engine.duration, "playing": engine.isPlaying, "ended": ended,
                                 "speed": engine.speed, "mash": mashRate, "mashSemis": mashSemis, "mashing": mashing, "pitch": engine.pitchSemitones, "rec": mixer?.isRecording ?? engine.isRecording,
                                 "stems": stems, "stemEngine": stemEngine, "splitting": splitting, "ai": Separation.aiStatus() == nil, "fx": Separation.fxReady]
        web?.run("PD.engineState&&PD.engineState(\(json(st)))")
    }

    func json(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]) else { return "null" }
        return String(data: d, encoding: .utf8) ?? "null"
    }
}

protocol WKWebViewLike: AnyObject { func run(_ js: String) }
