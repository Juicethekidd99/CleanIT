// Performance page: a speed check (things worth fixing) and a few reversible settings, like the Windows 2.8.0 page.
// Every setting CleanIT changes has its original value saved in State/performance.json ("Put everything back").
// No RAM purging, no killing apps, no switching off SIP/Spotlight/XProtect - see the page's honesty list.
import Foundation
import AppKit
import CoreGraphics

enum Perf {
    static var stateFile: String { Paths.stateDir + "/performance.json" }

    // ------------------------------------------------------------------ reversible settings
    struct Item {
        let key, name, description, group, impact: String
        var note: String? = nil
        var recommended = false
        var restart: String? = nil          // shown after applying, e.g. "log out"
        var admin = false
        let read: () -> String?             // current raw value (nil = not set = macOS default)
        let onValue: String
        let write: (String?) throws -> Void // value to write; nil = back to the macOS default
        var available: () -> Bool = { true }
        var isOn: Bool { read() == onValue }
    }

    static func defaultsRead(_ domain: String, _ key: String) -> String? {
        let r = sh("/usr/bin/defaults", ["read", domain, key], timeout: 10)
        return r.code == 0 ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
    // type: bool | float | int
    static func defaultsItem(_ domain: String, _ key: String, _ type: String, _ on: String, after: [String] = []) -> (() -> String?, (String?) throws -> Void) {
        let read = { defaultsRead(domain, key) }
        let write: (String?) throws -> Void = { v in
            let r = v == nil ? sh("/usr/bin/defaults", ["delete", domain, key], timeout: 10)
                             : sh("/usr/bin/defaults", ["write", domain, key, "-" + type, type == "bool" ? (v == "1" ? "true" : "false") : v!], timeout: 10)
            if r.code != 0 && v != nil { throw CleanITError("Could not change \(key): \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))") }
            if !after.isEmpty { sh("/usr/bin/killall", after, timeout: 10) }
        }
        return (read, write)
    }

    // pmset: Low Power Mode while on the charger ("AC Power" section of pmset -g custom)
    static func acLowPower() -> String? {
        var inAC = false
        for line in sh("/usr/bin/pmset", ["-g", "custom"], timeout: 10).out.split(separator: "\n") {
            if line.hasSuffix(":") { inAC = line.contains("AC Power"); continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if inAC, parts.count == 2, parts[0] == "lowpowermode" { return String(parts[1]) }
        }
        return nil
    }

    static let items: [Item] = {
        let dsStore = defaultsItem("com.apple.desktopservices", "DSDontWriteNetworkStores", "bool", "1")
        let winAnim = defaultsItem("NSGlobalDomain", "NSAutomaticWindowAnimationsEnabled", "bool", "0")
        let resize = defaultsItem("NSGlobalDomain", "NSWindowResizeTime", "float", "0.001")
        let dockDelay = defaultsItem("com.apple.dock", "autohide-delay", "float", "0", after: ["Dock"])
        let mission = defaultsItem("com.apple.dock", "expose-animation-duration", "float", "0.1", after: ["Dock"])
        return [
            Item(key: "LowPowerOnCharger", name: "Full speed while charging",
                 description: "Makes sure Low Power Mode is off when the Mac is plugged in. On battery it stays as you set it.",
                 group: "Speed", impact: "up to 20-30% faster when plugged in, if Low Power Mode was on", recommended: true, admin: true,
                 read: { acLowPower() }, onValue: "0",
                 write: { v in
                     let r = shAdmin("/usr/bin/pmset -c lowpowermode \(v ?? "0")")
                     if r.code != 0 { throw CleanITError("Power setting not changed (password needed).") }
                 },
                 available: { acLowPower() != nil }),
            Item(key: "NoNetworkDSStore", name: "No .DS_Store files on network drives",
                 description: "Finder stops writing its hidden .DS_Store files to shared folders and NAS drives.",
                 group: "Speed", impact: "faster browsing of network folders", recommended: true,
                 read: dsStore.0, onValue: "1", write: dsStore.1),
            Item(key: "NoWindowAnimations", name: "No window opening animation",
                 description: "New windows appear at once instead of zooming in.",
                 group: "Snappier", impact: "feels snappier; no real speed change", note: "Applies to apps opened afterwards",
                 read: winAnim.0, onValue: "0", write: winAnim.1),
            Item(key: "FastResize", name: "Instant sheet and window resizing",
                 description: "Save/print sheets and window resizes happen at once.",
                 group: "Snappier", impact: "feels snappier", note: "Applies to apps opened afterwards",
                 read: resize.0, onValue: "0.001", write: resize.1),
            Item(key: "DockNoDelay", name: "Dock appears without delay",
                 description: "If the Dock is set to hide, it shows up the moment the pointer reaches it.",
                 group: "Snappier", impact: "feels snappier when the Dock is hidden",
                 read: dockDelay.0, onValue: "0", write: dockDelay.1),
            Item(key: "FastMissionControl", name: "Faster Mission Control",
                 description: "Shortens the Mission Control animation.",
                 group: "Snappier", impact: "feels snappier",
                 read: mission.0, onValue: "0.1", write: mission.1),
        ]
    }()

    static func state() -> [String: JSON] { (readJSON(stateFile) as? [String: JSON]) ?? [:] }

    static func status() -> [JSON] {
        let st = state()
        return items.filter { $0.available() }.map { i in
            ["Key": i.key, "Name": i.name, "Description": i.description, "Group": i.group, "Impact": i.impact,
             "Note": i.note ?? NSNull(), "Recommended": i.recommended, "Restart": i.restart ?? NSNull(), "Admin": i.admin,
             "On": i.isOn, "ChangedByCleanIT": st[i.key] != nil]
        }
    }

    // changes: [{key, on}]. Turning on saves the original first; turning off puts the original back.
    static func apply(_ changes: [JSON]) throws {
        var st = state()
        for c in changes {
            guard let key = c["key"] as? String, let on = c["on"] as? Bool, let i = items.first(where: { $0.key == key }) else {
                throw CleanITError("Unknown setting.") }
            if on {
                if st[key] == nil { st[key] = ["Original": i.read() ?? NSNull(), "Date": isoNow()] }
                try i.write(i.onValue)
            } else {
                let orig = st[key]?["Original"] as? String
                try i.write(orig == i.onValue ? nil : orig)
                st[key] = nil
            }
            writeJSON(stateFile, st)
            Log.write("Performance: \(i.name) \(on ? "on" : "off").", "OK")
        }
    }

    static func restoreAll() throws {
        let st = state()
        if st.isEmpty { Log.write("Performance: nothing to put back."); return }
        try apply(st.keys.map { ["key": $0, "on": false] })
        Log.write("Performance settings put back.", "OK")
    }

    // ------------------------------------------------------------------ speed check
    static func check(_ level: String, _ title: String, _ text: String, _ action: JSON? = nil) -> JSON {
        ["Level": level, "Title": title, "Text": text, "Action": action ?? NSNull()]
    }
    static func page(_ label: String, _ target: String) -> JSON { ["Label": label, "Kind": "page", "Target": target] }
    static func pane(_ label: String, _ target: String) -> JSON { ["Label": label, "Kind": "pane", "Target": target] }
    static func app(_ label: String, _ target: String) -> JSON { ["Label": label, "Kind": "app", "Target": target] }

    // Refresh rate per display: current vs the highest the display offers at the same resolution.
    static func displays() -> [(name: String, current: Double, best: Double)] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        var names: [CGDirectDisplayID: String] = [:]
        for s in NSScreen.screens {
            if let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID { names[id] = s.localizedName }
        }
        var out: [(String, Double, Double)] = []
        for id in ids.prefix(Int(n)) {
            guard let cur = CGDisplayCopyDisplayMode(id) else { continue }
            let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            let modes = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
            let same = modes.filter { $0.pixelWidth == cur.pixelWidth && $0.pixelHeight == cur.pixelHeight }
            let best = same.map { $0.refreshRate }.max() ?? cur.refreshRate
            out.append((names[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in display" : "Display"), cur.refreshRate, best))
        }
        return out
    }

    static func checks() -> [JSON] {
        var out: [JSON] = []
        // screen
        for d in displays() {
            if d.current > 0 && d.best > d.current + 5 {
                out.append(check("WARN", "\(d.name) runs at \(Int(d.current.rounded())) Hz",
                                 "It can do \(Int(d.best.rounded())) Hz. Everything - scrolling, the mouse, games - looks smoother at the higher rate. Pick it under Displays > Refresh rate.",
                                 pane("Open Displays", "displays")))
            } else if d.current > 0 {
                out.append(check("OK", "\(d.name): \(Int(d.current.rounded())) Hz", "Running at its highest refresh rate."))
            }
        }
        // power
        let lp = sh("/usr/bin/pmset", ["-g"], timeout: 10).out
        if lp.split(separator: "\n").contains(where: { $0.contains("lowpowermode") && $0.trimmingCharacters(in: .whitespaces).hasSuffix("1") }) {
            out.append(check("WARN", "Low Power Mode is on", "The Mac runs slower to save energy. Fine on battery - turn it off when you need speed (or use \"Full speed while charging\" below).",
                             pane("Open Battery", "battery")))
        }
        // heat
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            out.append(check("WARN", "The Mac is too hot and slowing itself down",
                             "Make sure the vents are free (not on a bed or lap), close heavy apps, and if it keeps happening have the fans and dust cleaned."
                             + (sysctlStr("machdep.cpu.brand_string").contains("Intel") ? " Intel MacBooks are known for this; a clean often helps a lot." : "")))
        case .fair: out.append(check("INFO", "The Mac is warm", "Not slowing down yet. Keep the vents free."))
        default: out.append(check("OK", "Temperature", "Normal - no thermal slowdown."))
        }
        // memory
        let mp = sh("/usr/bin/memory_pressure", ["-Q"], timeout: 10).out
        let free = mp.split(separator: "\n").first { $0.contains("free percentage") }
            .flatMap { Int($0.components(separatedBy: ":").last!.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) } ?? -1
        let swapLine = sysctlStr("vm.swapusage")
        let swapMB = swapLine.components(separatedBy: "used = ").dropFirst().first.flatMap { Double($0.split(separator: "M").first ?? "") } ?? 0
        let ram = fmtSize(Int64(ProcessInfo.processInfo.physicalMemory))
        if free >= 0 && free < 15 {
            out.append(check("WARN", "Memory is tight (\(free)% free of \(ram))",
                             "Apps are competing for memory, which slows everything down. Quit apps and browser tabs you don't need. If this is normal for you, the Mac needs more memory - no app can \"clean\" that.",
                             app("Open Activity Monitor", "com.apple.ActivityMonitor")))
        } else if swapMB > 2048 {
            out.append(check("INFO", "macOS is using \(fmtSize(Int64(swapMB * 1048576))) of swap", "Some memory was moved to the disk. A restart clears it; if it keeps growing, quit heavy apps or browser tabs."))
        } else if free >= 0 {
            out.append(check("OK", "Memory (\(ram))", "\(free)% free - plenty."))
        }
        // background CPU
        let ps = sh("/bin/ps", ["-Aceo", "pcpu=,comm="], timeout: 10).out
        let busy = ps.split(separator: "\n").compactMap { l -> (Double, String)? in
            let t = l.trimmingCharacters(in: .whitespaces); guard let sp = t.firstIndex(of: " ") else { return nil }
            guard let c = Double(t[..<sp]) else { return nil }
            return (c, t[sp...].trimmingCharacters(in: .whitespaces))
        }.filter { $0.0 >= 60 && !["kernel_task", "WindowServer", "ps", "CleanIT"].contains($0.1) }.sorted { $0.0 > $1.0 }
        if let top = busy.first {
            out.append(check("INFO", "\(top.1) is using a lot of processor (\(Int(top.0))%)",
                             "If you're not using it right now, quitting it frees the Mac up. Spotlight (mds) and Photos are often busy for a while after updates - that settles by itself.",
                             app("Open Activity Monitor", "com.apple.ActivityMonitor")))
        }
        if sh("/bin/ps", ["-Aceo", "pcpu=,comm="], timeout: 10).out.split(separator: "\n").contains(where: { $0.hasSuffix("kernel_task") && (Double($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") ?? 0) > 150 }) {
            out.append(check("WARN", "kernel_task is very busy", "macOS does this on purpose to cool down an overheating Mac. Free the vents and let it cool."))
        }
        // startup + disk + uptime
        let startup = Startup.list(includeApple: false, loginItems: false).filter { ($0["Enabled"] as? Bool) == true }.count
        out.append(check(startup > 10 ? "WARN" : "OK", "\(startup) startup item\(startup == 1 ? "" : "s")",
                         startup > 10 ? "Many helpers start at login and run in the background. Switch off the ones you don't need." : "A light startup.", startup > 10 ? page("Startup", "startup") : nil))
        let v = FS.volume()
        let pct = v.total > 0 ? Int(100 * Double(v.free) / Double(v.total)) : 100
        out.append(check(pct < 10 ? "WARN" : "OK", "\(pct)% free disk space",
                         pct < 10 ? "macOS needs free space for memory swap and updates - below 10% everything slows down." : "Enough room for macOS to work.", pct < 15 ? page("Free up space", "clean") : nil))
        let days = Int(ProcessInfo.processInfo.systemUptime / 86400)
        if days >= 14 { out.append(check("INFO", "Not restarted for \(days) days", "A restart applies updates, clears swap and stops apps that got stuck in the background.")) }
        // mouse acceleration (System Settings switch on macOS 14+; old command-line tricks get reset)
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14 {
            out.append(check("INFO", "Gaming: mouse acceleration", "For precise aiming, switch off Pointer acceleration under Mouse > Advanced. macOS also turns on Game Mode by itself when a game is full screen (Apple silicon).",
                             pane("Open Mouse", "mouse")))
        } else {
            out.append(check("INFO", "Gaming: mouse acceleration", "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) has no switch for it; a gaming mouse app (Logitech G HUB, Razer Synapse) can turn it off."))
        }
        return out
    }

    static func sysctlStr(_ n: String) -> String { sh("/usr/sbin/sysctl", ["-n", n], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines) }
}
