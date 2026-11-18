// Blend's music library: songs are copied into Application Support/Blend/library (originals untouched), with title,
// artist and artwork read from the file. Every song is analysed once in the background (beats, downbeats, BPM, key,
// sections, waveform) by analyze.py; the result is cached as analysis/<key>.json and served to the page.
import Cocoa
import AVFoundation

final class Library {
    struct Song: Codable {
        var key: String, file: String, title: String, artist: String, added: Double, duration: Double
        var art: Bool = false
        var analysed: Bool = false
        var analysing: Bool = false
        var failed: String? = nil
        var bpm: Double? = nil, camelot: String? = nil, keyName: String? = nil
        var cues: [Double] = []            // seconds; set in Edit
        var trimIn: Double? = nil, trimOut: Double? = nil
    }

    let bridge: AudioBridge            // shares its folders (library + stems)
    var songs: [Song] = []
    var onChange: (() -> Void)?
    let queue = DispatchQueue(label: "blend.analysis", qos: .utility)
    let splitQueue = DispatchQueue(label: "blend.presplit", qos: .utility)
    var splittingKeys = Set<String>()
    var highQuality = false
    var onSplit: ((String) -> Void)?   // a song finished splitting (the app reloads it on any deck that has it)

    /// Split a song ahead of time so its stems are ready the moment it's loaded. One at a time; skips songs already split.
    func presplit(_ key: String) {
        guard !stemsReady(key), !splittingKeys.contains(key), let src = bridge.songURL(key) else { return }
        splittingKeys.insert(key); save()
        let dir = bridge.stemDir(key), hq = highQuality
        splitQueue.async {
            var err: String? = nil
            do { _ = try Separation.djSplit(src, into: dir.appendingPathComponent("dj"), aiDir: dir.appendingPathComponent("ai"), quality: hq) }
            catch { err = "\(error)" }
            DispatchQueue.main.async {
                self.splittingKeys.remove(key); self.save()
                if let err { self.onError?(err) } else { self.onSplit?(key) }
            }
        }
    }
    var onError: ((String) -> Void)?

    var support: URL { bridge.support }
    var libDir: URL { bridge.libraryDir }
    lazy var artDir = support.appendingPathComponent("art", isDirectory: true)
    lazy var analysisDir = support.appendingPathComponent("analysis", isDirectory: true)
    lazy var dbURL = support.appendingPathComponent("songs.json")
    static var analyzer: URL { Separation.aiHome.appendingPathComponent("analyze.py") }

    init(bridge: AudioBridge) {
        self.bridge = bridge
        for d in [libDir, artDir, analysisDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        if let d = try? Data(contentsOf: dbURL), let s = try? JSONDecoder().decode([Song].self, from: d) { songs = s }
        for i in songs.indices where songs[i].analysing { songs[i].analysing = false }   // an interrupted run starts again
        for i in songs.indices { if let u = bridge.songURL(songs[i].key) { var s = songs[i]; readTags(u, into: &s); songs[i].title = s.title; songs[i].artist = s.artist } }
        for s in songs where !s.analysed && s.failed == nil { analyse(s.key) }
    }

    func save() {
        if let d = try? JSONEncoder().encode(songs) { try? d.write(to: dbURL) }
        DispatchQueue.main.async { self.onChange?() }
    }
    func analysisURL(_ key: String) -> URL { analysisDir.appendingPathComponent(AudioBridge.safe(key) + ".json") }
    func artURL(_ key: String) -> URL { artDir.appendingPathComponent(AudioBridge.safe(key) + ".jpg") }

    // MARK: import

    @discardableResult
    func importFile(_ url: URL) -> String? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let key = url.lastPathComponent + ":" + String(size)
        if songs.contains(where: { $0.key == key }) { return key }
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension.lowercased()
        let dest = libDir.appendingPathComponent(AudioBridge.safe(key) + "." + ext)
        do { if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.copyItem(at: url, to: dest) } }
        catch { print("import failed:", error); return nil }
        var song = Song(key: key, file: url.lastPathComponent, title: url.deletingPathExtension().lastPathComponent, artist: "",
                        added: Date().timeIntervalSince1970, duration: 0)
        readTags(dest, into: &song)
        songs.append(song); save()
        analyse(key)
        return key
    }

    func importData(name: String, data: Data) -> String? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try data.write(to: tmp) } catch { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return importFile(tmp)
    }

    func readTags(_ url: URL, into s: inout Song) {
        let asset = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        var title: String?, artist: String?, art: Data?, dur = 0.0
        Task {
            if let md = try? await asset.load(.commonMetadata) {
                for item in md {
                    switch item.commonKey {
                    case .commonKeyTitle?: title = try? await item.load(.stringValue)
                    case .commonKeyArtist?: artist = try? await item.load(.stringValue)
                    case .commonKeyArtwork?: art = try? await item.load(.dataValue)
                    default: break
                    }
                }
            }
            if let d = try? await asset.load(.duration) { dur = d.seconds }
            sem.signal()
        }
        sem.wait()
        // no tags: tidy the file name ("Artist_-_Title__slowed_.mp3_3481737" -> "Artist" / "Title (slowed)")
        var name = (s.file as NSString).deletingPathExtension
        if let r = name.range(of: #"\.(mp3|m4a|wav|aiff?|flac|ogg)_\d+$"#, options: .regularExpression) { name.removeSubrange(r) }
        name = name.replacingOccurrences(of: "_-_", with: " - ")
        name = name.replacingOccurrences(of: #"__(.+?)_$"#, with: " ($1)", options: .regularExpression)
        name = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let parts = name.components(separatedBy: " - ")
        s.title = title?.isEmpty == false ? title! : (parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : name)
        s.artist = artist?.isEmpty == false ? artist! : (parts.count > 1 ? parts[0] : "")
        s.artist = s.artist.replacingOccurrences(of: " - Topic", with: "")
        s.duration = dur.isFinite ? dur : 0
        if let art, let img = NSImage(data: art), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            try? jpg.write(to: artURL(s.key)); s.art = true
        }
    }

    // MARK: analysis (background, one song at a time)

    func analyse(_ key: String) {
        guard let i = songs.firstIndex(where: { $0.key == key }) else { return }
        if FileManager.default.fileExists(atPath: analysisURL(key).path) { apply(key); return }
        songs[i].analysing = true; songs[i].failed = nil; save()
        queue.async {
            let result = self.runAnalysis(key)
            DispatchQueue.main.async {
                guard let j = self.songs.firstIndex(where: { $0.key == key }) else { return }
                self.songs[j].analysing = false
                if let err = result { self.songs[j].failed = err; self.save() } else { self.apply(key) }
            }
        }
    }

    /// nil on success, else what went wrong
    func runAnalysis(_ key: String) -> String? {
        guard let src = bridge.songURL(key) else { return "song file missing" }
        guard FileManager.default.isExecutableFile(atPath: Separation.python.path), FileManager.default.fileExists(atPath: Library.analyzer.path) else {
            return "analysis isn't installed (needs the separator venv + analyze.py)"
        }
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("blend-an-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        do { try Separation.decodeToWav(src, wav) } catch { return "couldn't read the song: \(error)" }
        let p = Process()
        p.executableURL = Separation.python
        p.arguments = [Library.analyzer.path, wav.path, analysisURL(key).path]
        var env = ProcessInfo.processInfo.environment; env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"; p.environment = env
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        do { try p.run() } catch { return "\(error)" }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            return String(data: errData, encoding: .utf8)?.split(separator: "\n").suffix(2).joined(separator: " ") ?? "analysis failed"
        }
        return nil
    }

    func apply(_ key: String) {
        guard let i = songs.firstIndex(where: { $0.key == key }),
              let d = try? Data(contentsOf: analysisURL(key)),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        songs[i].analysed = true
        songs[i].bpm = j["bpm"] as? Double
        songs[i].camelot = j["camelot"] as? String
        songs[i].keyName = j["key"] as? String
        if songs[i].duration == 0, let du = j["duration"] as? Double { songs[i].duration = du }
        save()
    }

    func stemsReady(_ key: String) -> Bool {
        let d = bridge.stemDir(key).appendingPathComponent("dj")
        return ["m4a", "wav"].contains { FileManager.default.fileExists(atPath: d.appendingPathComponent("vocals.\($0)").path) }
    }

    /// what the page shows in the library
    func listForPage() -> [[String: Any]] {
        songs.map { s in
            var o: [String: Any] = ["key": s.key, "title": s.title, "artist": s.artist, "duration": s.duration, "added": s.added,
                                    "art": s.art ? "data/art/" + AudioBridge.safe(s.key) + ".jpg" : "",
                                    "analysed": s.analysed, "analysing": s.analysing, "stems": stemsReady(s.key), "splitting": splittingKeys.contains(s.key),
                                    "cues": s.cues, "safe": AudioBridge.safe(s.key)]
            if let f = s.failed { o["failed"] = f }
            if let b = s.bpm { o["bpm"] = b }
            if let c = s.camelot { o["camelot"] = c }
            if let k = s.keyName { o["keyName"] = k }
            if let t = s.trimIn { o["trimIn"] = t }
            if let t = s.trimOut { o["trimOut"] = t }
            return o
        }
    }

    func setMeta(_ key: String, cues: [Double]?, trimIn: Double??, trimOut: Double??) {
        guard let i = songs.firstIndex(where: { $0.key == key }) else { return }
        if let c = cues { songs[i].cues = c }
        if let t = trimIn { songs[i].trimIn = t }
        if let t = trimOut { songs[i].trimOut = t }
        save()
    }

    func remove(_ key: String) {
        songs.removeAll { $0.key == key }
        if let u = bridge.songURL(key) { try? FileManager.default.removeItem(at: u) }
        try? FileManager.default.removeItem(at: analysisURL(key)); try? FileManager.default.removeItem(at: artURL(key))
        save()
    }
}
