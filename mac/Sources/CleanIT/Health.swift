// Security checks, Health report and the Dashboard score.
import Foundation
import IOKit.ps

enum Security {
    static func item(_ name: String, _ level: String, _ detail: String, _ fix: String? = nil) -> JSON {
        ["Name": name, "Level": level, "Detail": detail, "Fix": fix ?? NSNull()]
    }
    static func defaultsRead(_ domain: String, _ key: String) -> String? {
        let r = sh("/usr/bin/defaults", ["read", domain, key], timeout: 10)
        return r.code == 0 ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
    static func listening(_ port: Int) -> Bool {
        sh("/usr/sbin/netstat", ["-anp", "tcp"], timeout: 10).out.split(separator: "\n")
            .contains { $0.contains("LISTEN") && ($0.contains(".\(port) ") || $0.contains(":\(port) ")) }
    }

    static func checks() -> [JSON] {
        var out: [JSON] = []
        let os = ProcessInfo.processInfo.operatingSystemVersion
        // macOS support: Apple fixes security problems in the newest macOS and (mostly) the two before it.
        // Version numbers jumped from 15 to 26 in 2025, so compare positions in this list, not numbers.
        let releases = [11, 12, 13, 14, 15, 26, 27]      // newest last - add each autumn's release here
        let rank = releases.firstIndex(of: os.majorVersion) ?? (os.majorVersion > releases.last! ? releases.count - 1 : 0)
        let behind = releases.count - 1 - rank
        let ver = "macOS \(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
        if behind <= 1 { out.append(item("macOS support", "OK", ver + " gets security updates.")) }
        else if behind == 2 { out.append(item("macOS support", "INFO", ver + " still gets security updates, but it is the oldest version Apple supports. Plan to upgrade within a year if this Mac can.", "GoUpdates")) }
        else { out.append(item("macOS support", "BAD", ver + " no longer gets most security fixes. Upgrade macOS if this Mac supports it, or replace it.", "GoUpdates")) }

        let fv = sh("/usr/bin/fdesetup", ["status"], timeout: 10).out
        out.append(fv.contains("On") ? item("FileVault (disk encryption)", "OK", "On - your files are unreadable if the Mac is stolen.")
                   : item("FileVault (disk encryption)", "WARN", "Off - anyone with the Mac can read your files. Turn it on in Privacy & Security.", "OpenFileVault"))

        let fw = sh("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"], timeout: 10).out
        out.append(fw.contains("enabled") ? item("Firewall", "OK", "On")
                   : item("Firewall", "WARN", "Off - recommended on, especially on public Wi-Fi.", "EnableFirewall"))

        let sip = sh("/usr/bin/csrutil", ["status"], timeout: 10).out
        out.append(sip.contains("enabled") ? item("System Integrity Protection", "OK", "On")
                   : item("System Integrity Protection", "BAD", "Off - malware can change macOS itself. Turn it back on from Recovery (csrutil enable)."))

        let gk = sh("/usr/sbin/spctl", ["--status"], timeout: 10).out
        out.append(gk.contains("enabled") ? item("Gatekeeper", "OK", "On - only checked apps open without a warning.")
                   : item("Gatekeeper", "BAD", "Off - any downloaded app can run without a check.", "OpenPrivacy"))

        let su = "/Library/Preferences/com.apple.SoftwareUpdate"
        let autoCheck = defaultsRead(su, "AutomaticCheckEnabled") != "0"
        let critical = defaultsRead(su, "CriticalUpdateInstall") != "0"
        let config = defaultsRead(su, "ConfigDataInstall") != "0"
        if autoCheck && critical && config { out.append(item("Automatic security updates", "OK", "On")) }
        else { out.append(item("Automatic security updates", "WARN", "Security responses or XProtect updates are not installed automatically.", "OpenUpdates")) }

        let xp = "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist"
        if let d = NSDictionary(contentsOfFile: xp), let v = d["CFBundleShortVersionString"] as? String {
            let m = (try? FileManager.default.attributesOfItem(atPath: xp))?[.modificationDate] as? Date
            let age = m.map { Int(Date().timeIntervalSince($0) / 86400) } ?? 0
            out.append(item("XProtect (built-in malware protection)", age > 60 ? "WARN" : "OK",
                            "Version \(v), updated \(age) day\(age == 1 ? "" : "s") ago" + (age > 60 ? " - check that automatic updates are on." : "")))
        }

        if let u = defaultsRead("/Library/Preferences/com.apple.loginwindow", "autoLoginUser"), !u.isEmpty {
            out.append(item("Automatic login", "WARN", "On for \(u) - anyone who opens the Mac is signed in. Turn off in Users & Groups.", "OpenUsers"))
        } else { out.append(item("Automatic login", "OK", "Off")) }
        if defaultsRead("/Library/Preferences/com.apple.loginwindow", "GuestEnabled") == "1" {
            out.append(item("Guest user", "INFO", "On - fine for a shared Mac, otherwise turn it off in Users & Groups.", "OpenUsers"))
        }
        out.append(listening(22) ? item("Remote Login (SSH)", "WARN", "On - others on the network can try to sign in. Turn off in General > Sharing if you don't use it.", "OpenSharing")
                   : item("Remote Login (SSH)", "OK", "Off"))
        if listening(5900) { out.append(item("Screen Sharing", "INFO", "On - turn off in General > Sharing if you don't use it.", "OpenSharing")) }

        let unsigned = Startup.list(includeApple: false, loginItems: false).filter { ["unsigned", "signature NOT valid"].contains($0["Publisher"] as? String ?? "") }
        if !unsigned.isEmpty {
            out.append(item("Unsigned startup items", "WARN", "\(unsigned.count) item(s) start automatically without a valid signature: " +
                            unsigned.prefix(4).map { $0["Name"] as! String }.joined(separator: ", "), "GoStartup"))
        }
        return out
    }

    static func enableFirewall() throws {
        let r = shAdmin("/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on")
        if r.code != 0 { throw CleanITError("The firewall was not changed.") }
        Log.write("Firewall turned on (turn it off again in System Settings > Network > Firewall).", "OK")
    }
}

enum Health {
    static func sysctl(_ name: String) -> String { sh("/usr/sbin/sysctl", ["-n", name], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func battery() -> JSON? {
        let out = sh("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"], timeout: 10).out
        if out.isEmpty { return nil }
        func val(_ k: String) -> Int? {
            for line in out.split(separator: "\n") where line.contains("\"\(k)\" = ") {
                return Int(line.components(separatedBy: " = ").last!.trimmingCharacters(in: .whitespaces))
            }
            return nil
        }
        let design = val("DesignCapacity") ?? 0
        let maxCap = val("AppleRawMaxCapacity") ?? val("NominalChargeCapacity") ?? val("MaxCapacity") ?? 0
        let health = design > 0 && maxCap > 100 ? Int(100 * Double(maxCap) / Double(design)) : -1
        return ["cycles": val("CycleCount") ?? -1, "health": health, "design": design, "max": maxCap]
    }

    static func crashes(days: Int = 30) -> [(String, Int)] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        var counts: [String: Int] = [:]
        for dir in [Paths.library + "/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports"] {
            for p in FS.children(dir) {
                let n = (p as NSString).lastPathComponent
                guard n.hasSuffix(".ips") || n.hasSuffix(".crash") || n.hasSuffix(".panic"),
                      let m = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date, m > cutoff else { continue }
                if n.contains("panic") { counts["Kernel panic (whole Mac restarted)", default: 0] += 1; continue }
                if n.hasPrefix("JetsamEvent") || n.contains(".diag") || n.contains(".spin") || n.contains(".hang") || n.contains(".cpu_resource") { continue }
                let app = n.components(separatedBy: "-20").first ?? n
                counts[app, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }
    }

    static func report() -> String {
        var t: [String] = []
        let os = ProcessInfo.processInfo
        t.append("MAC")
        t.append("  Model         \(sysctl("hw.model"))")
        t.append("  Processor     \(sysctl("machdep.cpu.brand_string").isEmpty ? "Apple silicon" : sysctl("machdep.cpu.brand_string"))")
        t.append("  Memory        \(fmtSize(Int64(os.physicalMemory)))")
        t.append("  macOS         \(os.operatingSystemVersionString)")
        let up = Int(os.systemUptime)
        t.append("  Uptime        \(up / 86400) days \(up % 86400 / 3600) h" + (up > 14 * 86400 ? "   (restart now and then - it applies updates and frees memory)" : ""))
        let mp = sh("/usr/bin/memory_pressure", ["-Q"], timeout: 10).out
        if let line = mp.split(separator: "\n").first(where: { $0.contains("free percentage") }) {
            t.append("  Memory free   " + (line.components(separatedBy: ":").last ?? "").trimmingCharacters(in: .whitespaces))
        }
        t.append("")
        t.append("STORAGE")
        let v = FS.volume()
        t.append("  Startup disk  \(fmtSize(v.free)) free of \(fmtSize(v.total)) (\(v.total > 0 ? Int(100 * Double(v.free) / Double(v.total)) : 0)%)")
        let di = sh("/usr/sbin/diskutil", ["info", "disk0"], timeout: 15).out
        for key in ["Device / Media Name", "Solid State", "SMART Status"] {
            if let line = di.split(separator: "\n").first(where: { $0.contains(key + ":") }) {
                t.append("  " + key.padding(toLength: 13, withPad: " ", startingAt: 0) + " " + (line.components(separatedBy: ":").last ?? "").trimmingCharacters(in: .whitespaces))
            }
        }
        let tm = sh("/usr/bin/tmutil", ["latestbackup"], timeout: 15)
        let tmPath = tm.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if tm.code == 0, tmPath.hasPrefix("/") {
            t.append("  Time Machine  last backup: " + (tmPath as NSString).lastPathComponent)
        } else if tm.out.contains("mount") {
            t.append("  Time Machine  set up, but the backup disk is not connected right now.")
        } else {
            t.append("  Time Machine  no backup found (or CleanIT has no Full Disk Access) - a backup is the best protection there is.")
        }
        t.append("")
        if let b = battery() {
            t.append("BATTERY")
            t.append("  Cycle count   \(b["cycles"]!)")
            if let h = b["health"] as? Int, h > 0 {
                t.append("  Capacity      \(h)% of new" + (h < 80 ? "   (worn - Apple suggests service below 80%)" : ""))
            }
            t.append("")
        }
        t.append("CRASHES (last 30 days)")
        let c = crashes()
        if c.isEmpty { t.append("  none") }
        for (app, n) in c.prefix(15) { t.append("  \(String(n).padding(toLength: 4, withPad: " ", startingAt: 0)) \(app)") }
        return t.joined(separator: "\n")
    }

    static func flushDNS() throws {
        let r = shAdmin("dscacheutil -flushcache; killall -HUP mDNSResponder")
        if r.code != 0 { throw CleanITError("DNS cache was not flushed.") }
        Log.write("DNS cache flushed. If websites still fail, restart the router.", "OK")
    }
}

enum Dashboard {
    static func data() -> JSON {
        var issues: [JSON] = []
        func issue(_ level: String, _ text: String, _ tab: String?, _ penalty: Int) {
            issues.append(["Level": level, "Text": text, "Tab": tab ?? NSNull(), "Penalty": penalty])
        }
        let v = FS.volume()
        let pct = v.total > 0 ? Int(100 * Double(v.free) / Double(v.total)) : 0
        if pct < 10 { issue("BAD", "Only \(pct)% free on the startup disk (\(fmtSize(v.free))). macOS slows down and updates can fail.", "Disk", 25) }
        else if pct < 20 { issue("WARN", "\(pct)% free on the startup disk (\(fmtSize(v.free))).", "Disk", 10) }

        for s in Security.checks() {
            let lvl = s["Level"] as! String
            if lvl == "BAD" { issue("BAD", "\(s["Name"]!): \(s["Detail"]!)", "Security", 15) }
            else if lvl == "WARN" { issue("WARN", "\(s["Name"]!): \(s["Detail"]!)", "Security", 5) }
        }
        let up = Updates.cached()
        let mac = up["mac"] as? Int ?? -1, brew = up["brew"] as? Int ?? -1
        if mac > 0 { issue("WARN", "\(mac) macOS update\(mac > 1 ? "s" : "") waiting.", "Updates", 10) }
        if brew > 5 { issue("INFO", "\(brew) Homebrew updates available.", "Updates", 2) }
        let startup = Startup.list(includeApple: false, loginItems: false).filter { ($0["Enabled"] as? Bool) == true }.count
        if startup > 15 { issue("INFO", "\(startup) apps and helpers start automatically. Switching off what you don't need speeds up login.", "Startup", 3) }
        let c = Health.crashes(days: 30)
        if let panic = c.first(where: { $0.0.hasPrefix("Kernel panic") }) { issue("WARN", "\(panic.1) kernel panic(s) in 30 days - see Health.", "Health", 8) }
        if let b = Health.battery(), let h = b["health"] as? Int, h > 0, h < 80 { issue("INFO", "Battery holds \(h)% of its original charge.", "Health", 2) }
        if Int(ProcessInfo.processInfo.systemUptime) > 21 * 86400 { issue("INFO", "Not restarted for over 3 weeks - a restart applies updates and frees memory.", nil, 2) }
        if !hasFullDiskAccess() { issue("INFO", "CleanIT has no Full Disk Access, so Safari, Mail and the Trash can't be scanned. Optional - see Settings.", "Settings", 0) }

        let hist = Clean.history()
        let score = max(0, 100 - issues.reduce(0) { $0 + ($1["Penalty"] as! Int) })
        return ["Score": score, "Issues": issues, "FreeBytes": v.free, "SizeBytes": v.total, "FreePct": pct,
                "StartupCount": startup, "AppUpdates": brew, "MacUpdates": mac,
                "FreedTotal": hist.total, "LastClean": hist.last ?? NSNull(), "LastFreed": hist.lastFreed]
    }
}
