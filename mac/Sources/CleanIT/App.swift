// The app window: a WKWebView showing the CleanIT web UI (bundled in Resources/web).
import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandlerWithReply, WKNavigationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var web: WKWebView!

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.applicationIconImage = Icon.image(512, appIcon: true)
        buildMenu()
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "api")
        web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { web.isInspectable = true }   // Safari > Develop menu can inspect the UI

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "CleanIT"
        window.minSize = NSSize(width: 960, height: 620)
        window.contentView = web
        window.delegate = self
        window.setFrameAutosaveName("CleanITMain")
        if !window.setFrameUsingName("CleanITMain") { window.center() }
        window.makeKeyAndOrderFront(nil)

        let webDir = AppDelegate.webDir()
        web.loadFileURL(URL(fileURLWithPath: webDir + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: webDir))
        NSApp.activate(ignoringOtherApps: true)
        Log.write("CleanIT \(appVersion) started.")
        if ProcessInfo.processInfo.environment["CLEANIT_DEBUG"] != nil { listenForDebug() }
    }

    // Development only (CLEANIT_DEBUG=1): another process can run JavaScript in the page and save a snapshot,
    // so the UI can be checked without Screen Recording permission. Object = {"js": "...", "png": "/path"}.
    func listenForDebug() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("io.github.juicethekidd99.cleanit.debug"), object: nil, queue: .main) { [weak self] n in
            guard let self = self, let s = n.object as? String, let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            let snap = {
                guard let png = o["png"] as? String else { return }
                self.web.takeSnapshot(with: nil) { img, _ in
                    guard let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                          let data = rep.representation(using: .png, properties: [:]) else { return }
                    try? data.write(to: URL(fileURLWithPath: png))
                }
            }
            if let js = o["js"] as? String {
                self.web.evaluateJavaScript(js) { r, e in
                    if let e = e { Log.write("debug js error: \(e)", "ERROR") } else if let r = r { Log.write("debug js: \(r)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + ((o["wait"] as? Double) ?? 1.0)) { snap() }
                }
            } else { snap() }
        }
    }

    static func webDir() -> String {
        if let d = ProcessInfo.processInfo.environment["CLEANIT_WEB"] { return d }
        return (Bundle.main.resourcePath ?? ".") + "/web"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        if !Jobs.anyRunning { return .terminateNow }
        let a = NSAlert()
        a.messageText = "CleanIT is still working"
        a.informativeText = "Quitting now stops: " + Jobs.running().map { $0["name"] as! String }.joined(separator: ", ")
        a.addButton(withTitle: "Keep working"); a.addButton(withTitle: "Quit anyway")
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    // Page -> engine. Replies with a JSON string, or an error message the page turns into a toast.
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let m = message.body as? [String: Any], let path = m["path"] as? String else { replyHandler(nil, "Bad request"); return }
        var body: Any? = nil
        if let s = m["body"] as? String, let d = s.data(using: .utf8) { body = try? JSONSerialization.jsonObject(with: d) }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try Bridge.handle(path: path, body: body)
                let d = try JSONSerialization.data(withJSONObject: r, options: [.fragmentsAllowed])
                let s = String(decoding: d, as: UTF8.self)
                DispatchQueue.main.async { replyHandler(s, nil) }
            } catch {
                let msg = error.localizedDescription
                DispatchQueue.main.async { replyHandler(nil, msg) }
            }
        }
    }

    // Links never navigate the app window; https links open in the default browser.
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = a.request.url, u.isFileURL { decisionHandler(.allow); return }
        if let u = a.request.url, u.scheme == "https" { NSWorkspace.shared.open(u) }
        decisionHandler(.cancel)
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "About CleanIT", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide CleanIT", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit CleanIT", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
        viewItem.submenu = view
        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }
    @objc func reload() { web.reload() }
}

// The CleanIT mark: teal disc, white open ring, yellow sparkle (same as the Windows icon).
enum Icon {
    static func image(_ size: CGFloat, appIcon: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
            let s = r.width
            let teal = NSColor(red: 13 / 255, green: 148 / 255, blue: 136 / 255, alpha: 1)
            var inner = r
            if appIcon {
                // macOS icon grid: rounded square with margin
                let m = s * 0.1, rr = NSRect(x: m, y: m, width: s - 2 * m, height: s - 2 * m)
                teal.setFill(); NSBezierPath(roundedRect: rr, xRadius: rr.width * 0.225, yRadius: rr.width * 0.225).fill()
                inner = rr
            } else {
                teal.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            }
            let w = inner.width, ox = inner.minX, oy = inner.minY
            let m = w * 0.24
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: ox + w / 2, y: oy + w / 2), radius: (w - 2 * m) / 2, startAngle: 45, endAngle: 315)
            arc.lineWidth = w * 0.12; arc.lineCapStyle = .round
            NSColor.white.setStroke(); arc.stroke()
            let c = ox + w * 0.74, cy = oy + w * 0.74, rad = w * 0.1
            let p = NSBezierPath()
            let pts: [(CGFloat, CGFloat)] = [(0, -1), (0.3, -0.3), (1, 0), (0.3, 0.3), (0, 1), (-0.3, 0.3), (-1, 0), (-0.3, -0.3)]
            for (i, (dx, dy)) in pts.enumerated() {
                let pt = NSPoint(x: c + dx * rad, y: cy + dy * rad)
                if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
            }
            p.close()
            NSColor(red: 253 / 255, green: 224 / 255, blue: 71 / 255, alpha: 1).setFill(); p.fill()
            return true
        }
    }

    static func png(_ size: Int, appIcon: Bool) -> Data? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image(CGFloat(size), appIcon: appIcon).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // Writes CleanIT.iconset (for iconutil) and favicon.png into dir. Used by build.sh.
    static func write(to dir: String) {
        let set = dir + "/CleanIT.iconset"
        try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
                try? png(base * scale, appIcon: true)?.write(to: URL(fileURLWithPath: set + "/" + name))
            }
        }
        try? png(128, appIcon: false)?.write(to: URL(fileURLWithPath: dir + "/favicon.png"))
    }
}
