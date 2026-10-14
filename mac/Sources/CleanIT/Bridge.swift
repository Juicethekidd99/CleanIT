// The page's API. On Windows this is an HTTP server; here the page calls window.webkit.messageHandlers.api
// with the same paths and bodies, so app.js barely changes.
import Foundation
import AppKit

enum Bridge {
    typealias Action = (name: String, work: (JSON, Job) throws -> Any)

    static func strs(_ a: Any?) -> [String] { (a as? [Any])?.compactMap { $0 as? String } ?? [] }
    static func num(_ a: Any?, _ def: Double) -> Double { (a as? NSNumber)?.doubleValue ?? Double(a as? String ?? "") ?? def }

    static let actions: [String: Action] = [
        "dashboard": ("Checking your Mac", { _, _ in let d = Dashboard.data(); Fleet.writeReport(d); return d }),
        "smartScan": ("Smart Scan", { _, job in
            job.report(5, "Scanning junk")
            let scan = Clean.scan(Clean.defs.map { $0.key })
            job.report(60, "Checking security and startup")
            let defaults = Set(Clean.defs.filter { $0.isDefault }.map { $0.key })
            let junk = scan.filter { defaults.contains($0["Key"] as! String) }.reduce(Int64(0)) { $0 + max(0, i64($1["Size"])) }
            if Updates.brew != nil { job.report(80, "Checking Homebrew"); _ = try? Updates.brewList(job: job) }
            let dash = Dashboard.data()
            Log.write("Smart Scan done: \(fmtSize(junk)) of junk found, health score \(dash["Score"]!).", "OK")
            Fleet.writeReport(dash)
            return ["dash": dash, "junk": junk, "scan": scan]
        }),
        "junkScan": ("Scanning junk", { a, job in ["items": Clean.scan(strs(a["keys"]), job: job)] }),
        "clean": ("Cleaning", { a, job in let r = Clean.clean(strs(a["keys"]), job: job); Fleet.writeReport(); return r }),

        "diskScan": ("Analyzing disk space", { a, job in try Disk.scanTree(a["path"] as? String ?? "/", job: job) }),
        "largeFiles": ("Finding large files", { a, job in
            ["items": try Disk.largeFiles(path: a["path"] as? String ?? Paths.home, minMB: num(a["minMB"], 500), days: Int(num(a["days"], 0)),
                                          includeSystem: a["includeSystem"] as? Bool ?? false, job: job)] }),
        "duplicates": ("Finding duplicates", { a, job in
            ["items": try Disk.duplicates(path: a["path"] as? String ?? Paths.home, minMB: num(a["minMB"], 1),
                                          includeSystem: a["includeSystem"] as? Bool ?? false, job: job)] }),
        "recycle": ("Moving files to the Trash", { a, _ in ["removed": try Disk.trash(strs(a["paths"]))] }),

        "startupList": ("Loading startup items", { a, _ in ["items": Startup.list(includeApple: a["includeApple"] as? Bool ?? false)] }),
        "startupApply": ("Applying startup changes", { a, _ in try Startup.apply((a["changes"] as? [JSON]) ?? []); return [:] as JSON }),
        "startupUndo": ("Undoing startup changes", { _, _ in try Startup.undoAll(); return [:] as JSON }),

        "programsList": ("Listing apps", { _, job in ["items": Apps.list(job: job)] }),
        "uninstall": ("Uninstalling", { a, job in try Apps.uninstall(a["id"] as? String ?? "", job: job) }),
        "leftovers": ("Looking for leftovers", { a, _ in try Apps.findLeftovers(a["id"] as? String ?? "") }),
        "leftoversRemove": ("Removing leftovers", { a, _ in ["removed": try Apps.removeLeftovers(strs(a["paths"]))] }),

        "macList": ("Checking Software Update", { _, job in ["items": Updates.macList(job: job)] }),
        "macInstall": ("Installing updates", { a, job in try Updates.macInstall(strs(a["ids"]), job: job); return [:] as JSON }),
        "brewList": ("Checking Homebrew", { _, job in ["items": try Updates.brewList(job: job)] }),
        "brewUpgrade": ("Updating with Homebrew", { a, job in try Updates.brewUpgrade(strs(a["ids"]), job: job); return [:] as JSON }),

        "security": ("Security check", { _, _ in ["items": Security.checks()] }),
        "securityFix": ("Security fix", { a, _ in
            if a["fix"] as? String == "EnableFirewall" { try Security.enableFirewall() }
            return [:] as JSON }),
        "perfStatus": ("Checking performance", { _, _ in ["items": Perf.status(), "checks": Perf.checks()] }),
        "perfApply": ("Changing performance settings", { a, _ in try Perf.apply((a["changes"] as? [JSON]) ?? []); return ["items": Perf.status()] }),
        "perfRestore": ("Putting performance settings back", { _, _ in try Perf.restoreAll(); return ["items": Perf.status()] }),
        "health": ("Health report", { _, _ in ["text": Health.report()] }),
        "flushDns": ("Flushing DNS", { _, _ in try Health.flushDNS(); return [:] as JSON }),
        "fleetList": ("Reading fleet reports", { _, _ in ["items": try Fleet.reports()] }),
        "fleetOneDrive": ("Setting up the OneDrive fleet", { _, _ in try Fleet.useOneDrive(); return [:] as JSON }),
        "fleetSetPath": ("Setting fleet folder", { a, _ in try Fleet.setPath(a["path"] as? String ?? ""); return [:] as JSON }),
        "fleetChoose": ("Choosing fleet folder", { _, _ in
            guard let p = Fleet.chooseFolder() else { return ["chosen": false] as JSON }
            try Fleet.setPath(p); return ["chosen": true] as JSON }),
        "fleetWrite": ("Writing fleet report", { _, _ in Fleet.writeReport(wait: 30); return [:] as JSON }),
        "fleetRemove": ("Removing computer from fleet view", { a, _ in try Fleet.remove(a["computer"] as? String ?? ""); return [:] as JSON }),
        "scheduleSave": ("Saving schedule", { a, _ in
            try Schedule.save(enabled: a["enabled"] as? Bool ?? false, day: a["day"] as? String ?? "Sunday",
                              time: a["time"] as? String ?? "11:00", updates: a["updates"] as? Bool ?? false)
            return [:] as JSON }),
    ]

    static func state() -> JSON {
        let exe = Bundle.main.bundlePath
        return [
            "version": appVersion, "computer": Fleet.computer, "computerName": Fleet.displayName, "fleet": Fleet.status(), "settings": Settings.load(),
            "schedule": Schedule.isOn, "dataDir": Paths.dataDir, "logDir": Paths.logDir,
            "places": Disk.places(), "userProfile": Paths.home, "brew": Updates.brew != nil, "fda": hasFullDiskAccess(),
            "appPath": exe, "inApplications": exe.hasPrefix("/Applications/") || exe.hasPrefix(Paths.home + "/Applications/"),
            "categories": Clean.defs.map { $0.dto }, "jobs": Jobs.running()
        ]
    }

    static let settingsPanes: [String: String] = [
        "fda": "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        "privacy": "x-apple.systempreferences:com.apple.preference.security",
        "filevault": "x-apple.systempreferences:com.apple.preference.security?FileVault",
        "updates": "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
        "loginitems": "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
        "users": "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension",
        "sharing": "x-apple.systempreferences:com.apple.Sharing-Settings.extension",
        "storage": "x-apple.systempreferences:com.apple.settings.Storage",
        "appstore": "macappstore://showUpdatesPage",
        "displays": "x-apple.systempreferences:com.apple.Displays-Settings.extension",
        "battery": "x-apple.systempreferences:com.apple.Battery-Settings.extension",
        "mouse": "x-apple.systempreferences:com.apple.Mouse-Settings.extension",
        "onedrive": "macappstore://apps.apple.com/app/onedrive/id823766827",
    ]

    static func open(_ a: JSON) throws {
        let ws = NSWorkspace.shared
        switch a["what"] as? String ?? "" {
        case "path":
            let p = a["path"] as? String ?? ""
            guard FS.exists(p) else { throw CleanITError("Not found: \(p)") }
            DispatchQueue.main.async { ws.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
        case "logs": DispatchQueue.main.async { ws.open(URL(fileURLWithPath: Paths.logDir)) }
        case "data": DispatchQueue.main.async { ws.open(URL(fileURLWithPath: Paths.dataDir)) }
        case "fleet":
            let p = Fleet.path
            guard FS.isDir(p) else { throw CleanITError("The fleet folder is not reachable.") }
            DispatchQueue.main.async { ws.open(URL(fileURLWithPath: p)) }
        case "trash": DispatchQueue.main.async { ws.open(URL(fileURLWithPath: Paths.home + "/.Trash")) }
        case "app":
            let n = a["name"] as? String ?? ""
            DispatchQueue.main.async { if let u = ws.urlForApplication(withBundleIdentifier: n) { ws.open(u) } }
        case "pane":
            guard let s = settingsPanes[a["pane"] as? String ?? ""], let u = URL(string: s) else { throw CleanITError("Unknown settings page") }
            DispatchQueue.main.async { ws.open(u) }
        case "url":
            guard let s = a["url"] as? String, s.hasPrefix("https://"), let u = URL(string: s) else { throw CleanITError("Only https links can be opened.") }
            DispatchQueue.main.async { ws.open(u) }
        default: throw CleanITError("Unknown open request")
        }
    }

    // Returns the JSON reply for a page request, or throws (the page shows the message).
    static func handle(path full: String, body: Any?) throws -> Any {
        var path = full, query: [String: String] = [:]
        if let q = full.firstIndex(of: "?") {
            path = String(full[..<q])
            for kv in full[full.index(after: q)...].split(separator: "&") {
                let p = kv.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if p.count == 2 { query[p[0]] = p[1] }
            }
        }
        let b = body as? JSON ?? [:]
        switch path {
        case "/api/state": return state()
        case "/api/ping": return ["jobs": Jobs.running()]
        case "/api/log": return Log.since(Int(query["since"] ?? "0") ?? 0)
        case "/api/settings": return Settings.patch(b)
        case "/api/open": try open(b); return [:] as JSON
        case "/api/jserror": Log.write("Page error: " + (b["text"] as? String ?? ""), "ERROR"); return [:] as JSON
        case "/api/quit": DispatchQueue.main.async { NSApp.terminate(nil) }; return [:] as JSON
        case "/api/disk/node":
            guard let n = Disk.node(query["path"] ?? "") else { throw CleanITError("Analyze again - that folder is not in the last result.") }
            return n
        case "/api/run":
            let name = b["action"] as? String ?? ""
            guard let act = actions[name] else { throw CleanITError("Unknown action: \(name)") }
            let args = b["args"] as? JSON ?? [:]
            let job = Jobs.start(act.name) { job in try act.work(args, job) }
            return ["jobId": job.id]
        default:
            if path.hasPrefix("/api/jobs/") {
                let rest = path.dropFirst(10).split(separator: "/")
                guard let id = rest.first, let job = Jobs.get(String(id)) else { throw CleanITError("Unknown job") }
                if rest.count > 1 && rest[1] == "cancel" { job.cancel(); return [:] as JSON }
                return job.dto()
            }
            throw CleanITError("Not found: \(path)")
        }
    }
}
