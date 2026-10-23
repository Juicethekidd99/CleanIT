// Memory saver (Mac). Apps get killed - or macOS shows "Your system has run out of application memory" - when
// memory pressure goes critical and swap cannot grow (the disk is too full). So this page:
//  - shows memory pressure (the real warning), RAM, swap and compressed memory, and the apps using the most,
//  - quits ONLY apps the user ticks, gracefully (NSRunningApplication.terminate = Cmd-Q, so unsaved work asks first).
//    Never force-quit, never automatic. macOS itself, security/VPN/management tools, the Claude app, CleanIT and the
//    user's Keep list can never be ticked,
//  - optionally warns (LaunchAgent every 15 min) when pressure is high. No "purge", no RAM cleaner.
import Foundation
import AppKit
import Darwin

enum Memory {
    static let watchLabel = "io.github.juicethekidd99.cleanit.memwatch"
    static var watchPlist: String { Paths.library + "/LaunchAgents/\(watchLabel).plist" }
    static var closable = Set<String>()        // keys from the last list - the only ones the page may ask to close

    static let defaultKeep = ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser",
                              "company.thebrowser.Browser", "com.apple.mail", "com.microsoft.Outlook", "com.microsoft.teams2", "us.zoom.xos",
                              "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.dt.Xcode",
                              "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint"]
    // Never closable, whatever the Keep list says.
    static let alwaysProtected: [String: String] = [
        "com.anthropic.claudefordesktop": "The Claude app - quitting it would end your Claude conversations and sessions.",
        "io.github.juicethekidd99.cleanit": "CleanIT itself.",
        "com.apple.finder": "Part of macOS.", "com.apple.dock": "Part of macOS.", "com.apple.systemuiserver": "Part of macOS."
    ]
    // Plain-English names for macOS processes that otherwise show up as ids.
    static let friendlyNames: [String: String] = [
        "com.apple.WebKit.WebContent": "Web pages (Safari, Mail and apps that show web content)",
        "com.apple.WebKit.GPU": "Web page graphics (Safari and apps)",
        "com.apple.WebKit.Networking": "Web page downloads (Safari and apps)",
        "com.apple.Virtualization.VirtualMachine": "Virtual machine (Simulator, Docker or a VM app)",
        "SimMetalHost": "iOS Simulator graphics", "SpringBoard": "iOS Simulator home screen",
        "AMPLibraryAgent": "Music library helper", "mds_stores": "Spotlight search index", "photoanalysisd": "Photos analysis",
        "claude": "Claude Code"
    ]
    // Command-line tools that must never be touched (matched on the program name).
    static let protectedTools: [String: String] = [
        "claude": "Claude Code - quitting it would stop the work it is doing.", "node": "Developer tool (Node.js) - may be running your work.",
        "CleanIT": "CleanIT itself."
    ]
    // Security, VPN, remote support and device-management tools (matched against bundle id or name, lowercased).
    static let securityWords = ["crowdstrike", "falcon", "sentinel", "sophos", "jamf", "kandji", "mosyle", "addigy", "intune", "companyportal",
                                "wdav", "microsoft.defender", "forticlient", "globalprotect", "paloalto", "zscaler", "anyconnect", "secureclient",
                                "cisco", "datto", "ninjarmm", "ninjaone", "kaseya", "connectwise", "screenconnect", "teamviewer", "anydesk",
                                "tailscale", "wireguard", "nordlayer", "openvpn", "netskope", "okta", "duo", "malwarebytes", "bitdefender",
                                "eset", "avast", "norton", "huntress", "littlesnitch", "lulu", "1password", "bitwarden"]

    // ------------------------------------------------------------------ counters
    static func sysctlInt(_ name: String) -> Int {
        var v: Int32 = 0; var size = MemoryLayout<Int32>.size
        if sysctlbyname(name, &v, &size, nil, 0) == 0 { return Int(v) }
        var v64: Int64 = 0; size = MemoryLayout<Int64>.size
        return sysctlbyname(name, &v64, &size, nil, 0) == 0 ? Int(v64) : -1
    }

    static func counters() -> JSON {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        let mp = sh("/usr/bin/memory_pressure", ["-Q"], timeout: 10).out
        let free = mp.split(separator: "\n").first { $0.contains("free percentage") }
            .flatMap { Int($0.components(separatedBy: ":").last!.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) } ?? -1
        let level = sysctlInt("kern.memorystatus_vm_pressure_level")      // 1 normal, 2 warning, 4 critical
        let swapLine = sh("/usr/sbin/sysctl", ["-n", "vm.swapusage"], timeout: 5).out
        func mb(_ key: String) -> Double {
            guard let r = swapLine.range(of: key + " = ") else { return 0 }
            return Double(swapLine[r.upperBound...].split(separator: "M").first ?? "") ?? 0
        }
        // compressed memory from vm_stat (pages occupied by compressor)
        let vm = sh("/usr/bin/vm_stat", [], timeout: 5).out
        let page = Int64(vm.components(separatedBy: "page size of ").dropFirst().first?.split(separator: " ").first ?? "") ?? 4096
        let comp = vm.split(separator: "\n").first { $0.contains("occupied by compressor") }
            .flatMap { Int64($0.components(separatedBy: ":").last!.trimmingCharacters(in: CharacterSet(charactersIn: " ."))) } ?? 0
        let used = free >= 0 ? 100 - free : -1
        return ["RamTotal": total, "UsedPct": used, "FreePct": free, "Pressure": level == 4 ? "critical" : level == 2 ? "warning" : "normal",
                "SwapUsed": Int64(mb("used") * 1048576), "SwapTotal": Int64(mb("total") * 1048576), "Compressed": comp * page]
    }

    // ------------------------------------------------------------------ apps
    struct Proc { let pid: Int32; let path: String; let footprint: Int64 }

    static func processes() -> [Proc] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        var out: [Proc] = []
        var buf = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(max(0, got))) where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }                // not ours (system/root processes) - not listed
            let len = proc_pidpath(pid, &buf, UInt32(buf.count))
            let path = len > 0 ? String(cString: buf) : ""
            out.append(Proc(pid: pid, path: path, footprint: Int64(info.ri_phys_footprint)))
        }
        return out
    }

    // The outermost .app in a path, so helpers ("Google Chrome Helper (Renderer)") count as their app.
    static func appBundle(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    static func apps() -> [JSON] {
        let keep = Set((Settings.load()["MemoryKeep"] as? [String]) ?? defaultKeep)
        let running = NSWorkspace.shared.runningApplications
        var byBundlePath: [String: NSRunningApplication] = [:]
        for a in running { if let u = a.bundleURL { byBundlePath[u.path] = a } }
        let me = ProcessInfo.processInfo.processIdentifier

        struct G { var key = "", label = "", bundleId = "", path = "", bytes: Int64 = 0, count = 0, app: NSRunningApplication? = nil }
        var groups: [String: G] = [:]
        for p in processes() {
            let bundle = appBundle(p.path)
            let key = bundle ?? ((p.path as NSString).lastPathComponent.isEmpty ? "pid \(p.pid)" : (p.path as NSString).lastPathComponent)
            var g = groups[key] ?? G()
            g.key = key; g.path = bundle ?? p.path; g.bytes += p.footprint; g.count += 1
            if let b = bundle, g.app == nil { g.app = byBundlePath[b] }
            if p.pid == me { g.bundleId = "io.github.juicethekidd99.cleanit" }
            groups[key] = g
        }
        var out: [JSON] = []
        // apps under 40 MB are not worth listing; CLEANIT_MEM_MIN_MB = test hook (lets small test apps show up)
        let minMB = Int64(ProcessInfo.processInfo.environment["CLEANIT_MEM_MIN_MB"] ?? "") ?? 40
        for (_, var g) in groups where g.bytes >= minMB * 1048576 {
            if g.bundleId.isEmpty { g.bundleId = g.app?.bundleIdentifier ?? Bundle(path: g.path)?.bundleIdentifier ?? "" }
            g.label = g.app?.localizedName ?? (g.path.hasSuffix(".app") ? FileManager.default.displayName(atPath: g.path).replacingOccurrences(of: ".app", with: "") : g.key)
            if let nice = friendlyNames[g.label] { g.label = nice }
            let id = g.bundleId.isEmpty ? g.key : g.bundleId
            let low = (id + " " + g.label).lowercased()
            var kind = "App", why = "", hint = ""
            let dockApp = g.app?.activationPolicy == .regular
            if let w = alwaysProtected[g.bundleId] { kind = "Protected"; why = w }
            else if g.bundleId.hasPrefix("com.anthropic.") || g.path.contains("/Application Support/Claude/") {
                kind = "Protected"; why = "Part of Claude / Claude Code - quitting it would stop your Claude sessions."
            }
            else if protectedTools[g.key] != nil { kind = "Protected"; why = protectedTools[g.key]! }
            else if securityWords.contains(where: { low.contains($0) }) { kind = "Security"; why = "Security, VPN, password or device-management software - never closed." }
            else if dockApp && keep.contains(id) { kind = "Keep"; why = "On your Keep list - never closed from here." }
            else if dockApp { kind = "App" }        // any app in the Dock - Apple's own (Music, Preview...) included
            else if g.path.hasPrefix("/System/") || g.path.hasPrefix("/usr/") || g.path.hasPrefix("/Library/Apple/") || g.bundleId.hasPrefix("com.apple.") {
                kind = "System"; why = "Part of macOS."
            }
            else {
                kind = "Background"; why = "Runs in the background or the menu bar, so it is not closed from here. If you never need it, switch it off on the Startup page."
            }
            if ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser"].contains(g.bundleId) {
                hint = "Turn on Memory Saver in the browser's settings (Performance) - tabs you are not looking at then use almost nothing."
            } else if g.bundleId == "com.apple.Safari" {
                hint = "Close tabs you are not using - Safari keeps them all in memory."
            } else if g.bytes > 1610612736 && (kind == "App" || kind == "Keep") {
                hint = "Uses a lot of memory. If it has been open for days, quitting and reopening it usually frees most of that."
            }
            out.append(["Key": id, "Label": g.label, "Kind": kind, "Why": why, "Hint": hint, "Count": g.count,
                        "WorkingSet": g.bytes, "Closable": kind == "App", "Keepable": ["App", "Keep", "Background"].contains(kind)])
        }
        out.sort { i64($0["WorkingSet"]) > i64($1["WorkingSet"]) }
        let top = Array(out.prefix(ProcessInfo.processInfo.environment["CLEANIT_MEM_MIN_MB"] == nil ? 30 : 1000))
        closable = Set(top.filter { ($0["Closable"] as? Bool) == true }.map { $0["Key"] as! String })
        return top
    }

    static func report() -> JSON {
        let c = counters()
        let pressure = c["Pressure"] as! String
        let used = c["UsedPct"] as? Int ?? -1
        let v = FS.volume()
        let freePct = v.total > 0 ? Int(100 * Double(v.free) / Double(v.total)) : 100
        var level = "OK", verdict = "Memory is fine right now."
        if pressure == "critical" { level = "BAD"; verdict = "Memory is critically full - macOS may start closing apps. Quit something you do not need below." }
        else if pressure == "warning" || (used >= 0 && used >= 90) { level = "WARN"; verdict = "Memory is getting tight. Quitting an app or two you are not using will keep things smooth." }
        else if i64(c["SwapUsed"]) > 2 * 1073741824 { level = "INFO"; verdict = "Memory is OK now, but macOS has moved a lot to swap. A restart clears it." }
        let swapRoom: JSON = freePct < 10
            ? ["Level": "WARN", "Text": "Only \(fmtSize(v.free)) (\(freePct)%) is free on the disk. macOS needs free space for swap - when it runs out, apps get closed. Free up space on the Clean and Disk pages."]
            : ["Level": "OK", "Text": "\(fmtSize(v.free)) free on the disk - enough room for swap."]
        return ["Counters": c, "Level": level, "Verdict": verdict, "SwapRoom": swapRoom, "Apps": apps(),
                "Keep": (Settings.load()["MemoryKeep"] as? [String]) ?? defaultKeep, "Watch": FS.exists(watchPlist)]
    }

    // ------------------------------------------------------------------ quitting (gently)
    // Asks the ticked apps to quit - exactly like Cmd-Q, so unsaved work asks first. Never force-quits.
    // Protection is checked again right now.
    static func quit(_ keys: [String], job: Job) throws -> JSON {
        guard keys.allSatisfy({ closable.contains($0) }) else { throw CleanITError("Only apps from the last list can be closed - refresh and try again.") }
        let before = counters()
        let fresh = apps()
        var asked: [String] = []
        for k in keys {
            guard let a = fresh.first(where: { $0["Key"] as? String == k }), (a["Closable"] as? Bool) == true else {
                Log.write("Memory saver: \(k) is protected now - not closed.", "WARN"); continue
            }
            let targets = NSWorkspace.shared.runningApplications.filter { ($0.bundleIdentifier ?? "") == k && $0.activationPolicy == .regular }
            DispatchQueue.main.sync { for t in targets { _ = t.terminate() } }
            asked.append(k)
            Log.write("Memory saver: asked \(a["Label"] as? String ?? k) to quit.", "OK")
        }
        job.report(-1, "Waiting for the apps to quit (they may ask you to save)...")
        let deadline = Date().addingTimeInterval(15)
        var open: [String] = asked
        while !open.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.8)
            let alive = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
            open = asked.filter { alive.contains($0) }
        }
        Thread.sleep(forTimeInterval: 2)
        let after = counters()
        let freedPct = max(0, (before["UsedPct"] as? Int ?? 0) - (after["UsedPct"] as? Int ?? 0))
        let freed = Int64(Double(freedPct) / 100 * Double(i64(after["RamTotal"])))
        for o in open { Log.write("Memory saver: \(o) is still open - it may be asking you to save something. Check its window.", "WARN") }
        Log.write("Memory saver: freed about \(fmtSize(freed)).", "OK")
        return ["Closed": asked.filter { !open.contains($0) }, "StillOpen": open, "Freed": freed]
    }

    // ------------------------------------------------------------------ optional warning
    static func setWatch(_ on: Bool) throws {
        sh("/bin/launchctl", ["bootout", "gui/\(getuid())/\(watchLabel)"])
        try? FileManager.default.removeItem(atPath: watchPlist)
        if !on { Log.write("Memory saver: low-memory warning turned off.", "OK"); return }
        guard let exe = Bundle.main.executablePath, !exe.contains("/AppTranslocation/") else {
            throw CleanITError("Move CleanIT into your Applications folder first.") }
        let d: NSDictionary = ["Label": watchLabel, "ProgramArguments": [exe, "--memory-check"], "StartInterval": 900,
                               "ProcessType": "Background", "LowPriorityIO": true, "Nice": 10]
        try? FileManager.default.createDirectory(atPath: (watchPlist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard d.write(toFile: watchPlist, atomically: true) else { throw CleanITError("Could not write \(watchPlist)") }
        sh("/bin/launchctl", ["bootstrap", "gui/\(getuid())", watchPlist])
        Log.write("Memory saver: low-memory warning turned on (checks every 15 minutes).", "OK")
    }

    // Run by the LaunchAgent. Changes nothing - only a notification, at most every 30 minutes.
    static func check() {
        let c = counters()
        let pressure = c["Pressure"] as! String
        let used = c["UsedPct"] as? Int ?? 0
        guard pressure != "normal" || used >= 92 else { return }
        let stamp = Paths.stateDir + "/memory-warning.txt"
        if let m = (try? FileManager.default.attributesOfItem(atPath: stamp))?[.modificationDate] as? Date, Date().timeIntervalSince(m) < 1800 { return }
        let top = apps().first { !["System", "Security"].contains($0["Kind"] as? String ?? "") }
        var msg = "Memory is \(pressure == "critical" ? "critically full" : "almost full") (\(used)%)."
        if let t = top { msg += " Biggest: \(t["Label"] as? String ?? "") (\(fmtSize(i64(t["WorkingSet"]))))." }
        msg += " Open CleanIT > Memory to free some."
        FileManager.default.createFile(atPath: stamp, contents: Data(isoNow().utf8))
        notify("CleanIT - memory almost full", msg)
    }
}
