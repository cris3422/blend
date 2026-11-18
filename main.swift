// Blend: a simple two-song mixer. Native window around a web page (web/), served on blend:// so it has a stable origin.
// Audio: PDMixer (one AVAudioEngine, one clock) with two PDEngine decks, each driven by an AudioBridge.
// Library: Library.swift (copies songs in, reads tags + artwork, runs the analysis in the background).
// The page gets library data and analysis files under blend://app/data/ (served from Application Support/Blend).
import Cocoa
import WebKit
import UniformTypeIdentifiers
import AVFoundation

final class SchemeHandler: NSObject, WKURLSchemeHandler {
    let root: URL, data: URL
    init(root: URL, data: URL) { self.root = root.standardizedFileURL; self.data = data.standardizedFileURL }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path.isEmpty || url.path == "/" ? "index.html" : String(url.path.dropFirst())
        path = path.removingPercentEncoding ?? path
        var base = root
        if path.hasPrefix("data/") { base = data; path = String(path.dropFirst(5)) }
        let file = base.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(base.path), let body = try? Data(contentsOf: file) else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)); return
        }
        let types = ["html": "text/html", "css": "text/css", "js": "text/javascript", "woff2": "font/woff2", "png": "image/png",
                     "jpg": "image/jpeg", "svg": "image/svg+xml", "json": "application/json"]
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": types[file.pathExtension.lowercased()] ?? "application/octet-stream",
                                                  "Content-Length": "\(body.count)", "Cache-Control": "no-cache"])!
        task.didReceive(resp); task.didReceive(body); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class DragStrip: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with e: NSEvent) { if e.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: e) } }
}

// Deck B's bridge talks to the page through this: its calls run with PD._d = 1, so the page knows which deck it is.
final class DeckWeb: WKWebViewLike {
    weak var base: WKWebViewLike?
    init(base: WKWebViewLike) { self.base = base }
    func run(_ js: String) { base?.run("if(window.PD){PD._d=1;try{\(js)}finally{PD._d=0}}") }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, WKWebViewLike {
    var window: NSWindow!
    var web: WKWebView!
    let mixer = PDMixer()
    lazy var deckA = AudioBridge(engine: mixer.decks[0], mixer: mixer)
    lazy var deckB = AudioBridge(engine: mixer.decks[1], mixer: mixer)
    lazy var webB = DeckWeb(base: self)
    lazy var library = Library(bridge: deckA)
    var mixTimer: Timer?
    var pendingJump: DispatchWorkItem?
    func run(_ code: String) { web?.evaluateJavaScript(code, completionHandler: nil) }
    func bridge(_ i: Int) -> AudioBridge { i == 1 ? deckB : deckA }

    func applicationDidFinishLaunching(_ n: Notification) {
        deckA.web = self; deckB.web = webB
        library.onChange = { [weak self] in self?.sendLibrary() }
        library.onSplit = { [weak self] key in self?.js("PD.stemsReady&&PD.stemsReady(\(self?.jsonString(key) ?? "null"))") }
        library.onError = { [weak self] m in self?.js("PD.toast&&PD.toast(\(self?.jsonString("Split failed: " + m) ?? "''"))") }
        buildMenu()
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(SchemeHandler(root: Bundle.main.resourceURL!.appendingPathComponent("web"), data: deckA.support), forURLScheme: "blend")
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default()
        cfg.userContentController.add(self, name: "pd")
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        if #available(macOS 12.3, *) { cfg.preferences.isElementFullscreenEnabled = true }   // the Handycam window can go full screen   // the page opens the Equalizer as its own window
        web = WKWebView(frame: .zero, configuration: cfg)
        web.uiDelegate = self; web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { web.isInspectable = true }

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(1400, screen.width * 0.9), height: min(880, screen.height * 0.9)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Blend"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.07, green: 0.067, blue: 0.063, alpha: 1)
        window.minSize = NSSize(width: 1040, height: 680)
        window.delegate = self; window.isReleasedWhenClosed = false
        let content = NSView(); window.contentView = content
        web.frame = content.bounds; web.autoresizingMask = [.width, .height]; content.addSubview(web)
        let strip = DragStrip(frame: NSRect(x: 0, y: content.bounds.height - 14, width: content.bounds.width, height: 14))
        strip.autoresizingMask = [.width, .minYMargin]; content.addSubview(strip)
        window.center(); window.setFrameAutosaveName("BlendMain")
        web.load(URLRequest(url: URL(string: "blend://app/index.html")!))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? mixer.start()
        mixTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.sendMix() }
    }

    // songs dropped on the Dock icon or opened with Blend go into the library
    func application(_ application: NSApplication, open urls: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async {
            for u in urls { _ = self.library.importFile(u) }
            DispatchQueue.main.async { self.js("PD.toast&&PD.toast(\(self.jsonString("Added \(urls.count) song\(urls.count == 1 ? "" : "s") · analysing")))") }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }

    // MARK: pop-out windows (the Equalizer). The page calls window.open; we give it a real Mac window it can script,
    // so it can be dragged anywhere on any monitor. Its Win98 title bar is the drag handle; the page's ✕ calls window.close().
    var popups: [NSWindow] = []
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let w = CGFloat(windowFeatures.width?.doubleValue ?? 880), h = CGFloat(windowFeatures.height?.doubleValue ?? 600)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true; win.titleVisibility = .hidden; win.isReleasedWhenClosed = false
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { win.standardWindowButton(b)?.isHidden = true }
        win.backgroundColor = NSColor(white: 0.753, alpha: 1)   // Win98 grey under the page
        win.minSize = NSSize(width: 320, height: 240)
        let wv = WKWebView(frame: .zero, configuration: configuration)
        wv.uiDelegate = self; wv.navigationDelegate = self; wv.setValue(false, forKey: "drawsBackground")
        let content = NSView(); win.contentView = content
        wv.frame = content.bounds; wv.autoresizingMask = [.width, .height]; content.addSubview(wv)
        let strip = DragStrip(frame: NSRect(x: 0, y: content.bounds.height - 23, width: content.bounds.width - 30, height: 23))   // leaves the ✕ clickable
        strip.autoresizingMask = [.width, .minYMargin]; content.addSubview(strip)
        // it reopens where you left it (frame kept in the app's settings; only if that spot is still on a connected screen)
        let frameKey = "popupFrame-\(Int(w))x\(Int(h))"   // each pop-out (EQ, Handycam) remembers its own spot
        win.identifier = NSUserInterfaceItemIdentifier(frameKey)
        if let saved = UserDefaults.standard.string(forKey: frameKey), case let f = NSRectFromString(saved), f.width > 100,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }) { win.setFrame(f, display: false) }
        else { win.setFrameOrigin(NSPoint(x: window.frame.midX - w / 2, y: window.frame.midY - h / 2)) }
        win.makeKeyAndOrderFront(nil)
        popups.append(win)
        return wv
    }
    func webViewDidClose(_ webView: WKWebView) {
        guard let win = webView.window, win !== window else { return }
        UserDefaults.standard.set(NSStringFromRect(win.frame), forKey: win.identifier?.rawValue ?? "popupFrame")
        win.orderOut(nil); popups.removeAll { $0 === win }
        DispatchQueue.main.async { win.contentView = nil }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }

    // MARK: page -> native

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let t = body["t"] as? String else { return }
        let num = { (k: String) in (body[k] as? NSNumber)?.doubleValue ?? 0 }
        switch t {
        case "log": print("[page]", body["m"] as? String ?? "")
        case "eng":
            let b = bridge((body["deck"] as? NSNumber)?.intValue ?? 0)
            b.handle(body)
            if body["cmd"] as? String == "split" { watchSplit(b, key: b.currentKey) }
        case "lib":
            switch body["cmd"] as? String ?? "" {
            case "list": sendLibrary()
            case "import": addMusic()
            case "importData":
                guard let name = body["name"] as? String, let b64 = body["data"] as? String, let data = Data(base64Encoded: b64) else { return }
                let key = library.importData(name: name, data: data)
                if let key, let d = (body["deck"] as? NSNumber)?.intValue { js("PD.imported(\(jsonString(key)),\(d))") }
            case "analyse": if let k = body["key"] as? String { try? FileManager.default.removeItem(at: library.analysisURL(k)); library.analyse(k) }
            case "meta":
                guard let k = body["key"] as? String else { return }
                let cues = body["cues"] as? [Double]
                let tin: Double?? = body.keys.contains("trimIn") ? .some(body["trimIn"] as? Double) : .none
                let tout: Double?? = body.keys.contains("trimOut") ? .some(body["trimOut"] as? Double) : .none
                library.setMeta(k, cues: cues, trimIn: tin, trimOut: tout)
            case "remove": if let k = body["key"] as? String { library.remove(k) }
            case "split": if let k = body["key"] as? String { library.presplit(k) }
            case "splitQuality": let on = (body["on"] as? Bool) ?? false; library.highQuality = on; deckA.highQuality = on; deckB.highQuality = on
            default: break
            }
        case "mix":
            switch body["cmd"] as? String ?? "" {
            case "crossfade": mixer.crossfade = Float(num("v"))
            case "master": mixer.masterVolume = Float(num("v"))
            case "follow":
                mixer.follow = PDMixer.Follow(follower: Int(num("follower")), leader: Int(num("leader")), ratio: num("ratio"),
                                              anchorLeader: num("anchorLeader"), anchorFollower: num("anchorFollower"))
            case "unfollow": mixer.follow = nil
            case "playAt":
                // start `deck` at source position `from` exactly when the leader reaches `leaderPos` (its own source time)
                let d = Int(num("deck")), l = Int(num("leader")), L = mixer.decks[l]
                var delay = 0.06
                if L.isPlaying { delay = max(0.06, (num("leaderPos") - L.position) / Double(max(0.05, L.speed))) }
                do { try mixer.play(d, from: num("from"), at: mixer.soon(delay)) } catch { js("PD.toast('COULD NOT START THAT DECK')") }
            case "jumpAt":
                // Mashup beat jump: when `deck` reaches `leave` (a bar line, its own source time) it carries on from `to`,
                // landing on the same beat of the bar. If it is the follower, the lock's anchor moves by the same amount at
                // that moment, so the leader (the vocal) never notices. A newer jump replaces one that hasn't happened yet.
                pendingJump?.cancel()
                let d = Int(num("deck")), D = mixer.decks[d], leave = num("leave"), to = num("to")
                guard D.isPlaying else { try? D.seek(to: to); return }
                let delay = max(0.05, (leave - D.position) / Double(max(0.05, D.speed)))
                let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: delay))
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    if var f = self.mixer.follow, f.follower == d { f.anchorFollower += to - leave; self.mixer.follow = f }
                    do { try self.mixer.play(d, from: to, at: when) } catch { self.js("PD.toast('COULD NOT JUMP')") }
                }
                pendingJump = item
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay - 0.04), execute: item)
            case "rec":
                if mixer.isRecording { deckA.handle(["cmd": "recStop", "reveal": true]) } else { deckA.handle(["cmd": "recStart"]) }
            default: break
            }
        default: break
        }
    }

    /// after a split finishes, the library's stems flag changes
    func watchSplit(_ b: AudioBridge, key: String?) {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if !b.splitting { t.invalidate(); self.sendLibrary() }
        }
    }

    func sendLibrary() { js("PD.library&&PD.library(\(jsonString(library.listForPage())))") }
    func sendMix() {
        var m: [String: Any] = ["crossfade": mixer.crossfade, "rec": mixer.isRecording, "syncError": mixer.syncError]
        if let f = mixer.follow { m["follower"] = f.follower; m["leader"] = f.leader }
        js("PD.mixState&&PD.mixState(\(jsonString(m)))")
    }

    func js(_ code: String) { web.evaluateJavaScript(code, completionHandler: nil) }
    func jsonString(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]) else { return "null" }
        return String(data: d, encoding: .utf8) ?? "null"
    }

    @objc func addMusic() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.allowedContentTypes = [.audio]
        panel.message = "Choose songs to add to Blend"
        panel.beginSheetModal(for: window) { r in
            guard r == .OK else { return }
            let urls = panel.urls
            DispatchQueue.global(qos: .userInitiated).async {
                for u in urls { _ = self.library.importFile(u) }
                DispatchQueue.main.async { self.js("PD.toast(\(self.jsonString("ADDED \(urls.count) SONG\(urls.count == 1 ? "" : "S") · ANALYSING")))") }
            }
        }
    }
    @objc func showMixes() { let d = deckA.musicOut.appendingPathComponent("Mixes"); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); NSWorkspace.shared.open(d) }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil) }
    @objc func goMixer() { js("PD.go&&PD.go('mixer')") }
    @objc func goLibrary() { js("PD.go&&PD.go('library')") }
    @objc func goEdit() { js("PD.go&&PD.go('edit')") }
    @objc func goEq() { js("PD.go&&PD.go('eq')") }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.scheme ?? ""
        if ["blend", "blob", "data", "about"].contains(scheme) { decisionHandler(.allow); return }
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    func buildMenu() {
        let main = NSMenu()
        func item(_ m: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key); i.keyEquivalentModifierMask = mods; m.addItem(i)
        }
        let app = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = app; main.addItem(appItem)
        item(app, "About Blend", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        item(app, "Hide Blend", #selector(NSApplication.hide(_:)), "h")
        item(app, "Quit Blend", #selector(NSApplication.terminate(_:)), "q")
        let file = NSMenu(title: "File"); let fileItem = NSMenuItem(); fileItem.submenu = file; main.addItem(fileItem)
        item(file, "Import Songs…", #selector(addMusic), "o")
        item(file, "Show Recorded Mixes", #selector(showMixes), "r", [.command, .shift])
        let view = NSMenu(title: "View"); let viewItem = NSMenuItem(); viewItem.submenu = view; main.addItem(viewItem)
        item(view, "Mixer", #selector(goMixer), "1"); item(view, "Edit", #selector(goEdit), "2"); item(view, "Library", #selector(goLibrary), "3")
        item(view, "Equalizer", #selector(goEq), "e")
        let edit = NSMenu(title: "Edit"); let editItem = NSMenuItem(); editItem.submenu = edit; main.addItem(editItem)
        item(edit, "Copy", #selector(NSText.copy(_:)), "c"); item(edit, "Paste", #selector(NSText.paste(_:)), "v"); item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        let win = NSMenu(title: "Window"); let winItem = NSMenuItem(); winItem.submenu = win; main.addItem(winItem)
        item(win, "Blend", #selector(showWindow), "0", [.command, .shift])
        item(win, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(win, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        NSApp.mainMenu = main; NSApp.windowsMenu = win
    }
}

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
