// Fleet: every computer writes <name>.json into one shared folder (normally "OneDrive/CleanIT Fleet"),
// in the same format as the Windows version, so Macs and PCs show up together on both.
import Foundation
import AppKit
import SystemConfiguration

enum Fleet {
    static let folderName = "CleanIT Fleet"

    // Report file name / "Computer" field. Windows only accepts [A-Za-z0-9._-] (its "Remove from list"
    // checks that), so this is the Bonjour name ("users-MacBook-Pro"), not "user's MacBook Pro".
    static var computer: String {
        let n = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? Host.current().localizedName ?? "Mac"
        let clean = String(n.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) ? Character($0) : "-" })
        return String(clean.prefix(63))
    }
    static var displayName: String {
        ((SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? computer).replacingOccurrences(of: "\u{2019}", with: "'")
    }

    // OneDrive for Mac keeps its files in ~/Library/CloudStorage/OneDrive-Personal (or OneDrive-<Company>).
    static func oneDrive() -> String? {
        let cs = Paths.library + "/CloudStorage"
        let all = FS.children(cs).filter { ($0 as NSString).lastPathComponent.hasPrefix("OneDrive") && FS.isDir($0) }
        return all.first { $0.hasSuffix("OneDrive-Personal") } ?? all.first
    }

    static var path: String { (Settings.load()["FleetPath"] as? String) ?? "" }

    static func status() -> JSON {
        let p = path, od = oneDrive()
        var mode = "off"
        if !p.isEmpty { mode = (od != nil && p.hasPrefix(od!)) ? "onedrive" : "custom" }
        let existing = od.map { $0 + "/" + folderName }.flatMap { FS.isDir($0) ? $0 : nil }
        return ["Mode": mode, "Path": p, "OneDrive": od ?? NSNull(), "Reachable": !p.isEmpty && reachable(p),
                "Existing": existing ?? NSNull(), "Computer": computer, "DisplayName": displayName]
    }

    // A folder check that gives up after 3 s (a stalled cloud folder counts as not reachable).
    static func reachable(_ p: String) -> Bool {
        var ok = false
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { ok = FS.isDir(p); done.signal() }
        return done.wait(timeout: .now() + 3) == .success && ok
    }

    static func setPath(_ p: String) throws {
        let p = (p.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if !p.isEmpty {
            guard p.hasPrefix("/") else { throw CleanITError("Pick a folder.") }
            do { try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true) }
            catch { throw CleanITError("Can't use that folder: \(error.localizedDescription)") }
        }
        Settings.patch(["FleetPath": p])
        if p.isEmpty { Log.write("Fleet reporting turned off.", "OK") }
        else { Log.write("Fleet folder: \(Paths.tilde(p))", "OK"); writeReport() }
    }

    static func useOneDrive() throws {
        guard let od = oneDrive() else { throw CleanITError("OneDrive is not set up on this Mac. Install OneDrive and sign in with the same account as your PCs, or choose a folder yourself.") }
        try setPath(od + "/" + folderName)
    }

    // Folder picker (runs on the main thread; the page waits for the answer).
    static func chooseFolder() -> String? {
        var picked: String?
        DispatchQueue.main.sync {
            let p = NSOpenPanel()
            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
            p.prompt = "Use this folder"
            p.message = "Pick a folder that all your computers can reach (OneDrive, Dropbox, Google Drive, a NAS...)."
            NSApp.activate(ignoringOtherApps: true)
            if p.runModal() == .OK { picked = p.url?.path }
        }
        return picked
    }

    // Same fields as Write-FleetReport on Windows (+ Platform/DisplayName/MacUpdates, which Windows ignores).
    static func report(_ d: JSON) -> JSON {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let build = sh("/usr/bin/sw_vers", ["-buildVersion"], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let issues = (d["Issues"] as? [JSON] ?? []).sorted { i64($0["Penalty"]) > i64($1["Penalty"]) }
            .map { "[\($0["Level"] as? String ?? "INFO")] \($0["Text"] as? String ?? "")" }
        return [
            "Computer": computer, "DisplayName": displayName, "Platform": "Mac", "Version": appVersion, "Time": f.string(from: Date()),
            "Score": d["Score"] ?? 0, "Issues": issues,
            "FreePct": d["FreePct"] ?? 0, "FreeBytes": d["FreeBytes"] ?? 0, "SizeBytes": d["SizeBytes"] ?? 0,
            "FreedTotal": d["FreedTotal"] ?? 0, "LastClean": d["LastClean"] ?? NSNull(), "LastFreed": d["LastFreed"] ?? 0,
            "LastScheduled": Clean.history().lastScheduled ?? NSNull(),
            "StartupCount": d["StartupCount"] ?? 0, "PendingReboot": false,
            "Uptime": (ProcessInfo.processInfo.systemUptime / 86400 * 10).rounded() / 10,
            "AppUpdates": d["AppUpdates"] ?? -1, "WinUpdates": max(0, Int(i64(d["MacUpdates"]))), "MacUpdates": d["MacUpdates"] ?? -1,
            "OS": "macOS \(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : ""), "Build": build
        ]
    }

    // Writes this Mac's report if a fleet folder is set. Never throws and never blocks the caller for long:
    // cloud folders (OneDrive, iCloud) can stall for minutes while they sync or wait for a permission prompt.
    // wait = how long to wait for the write (CLI runs wait so the process doesn't exit first; the app doesn't).
    static let queue = DispatchQueue(label: "cleanit.fleet")
    private static var pending = false
    private static let lock = NSLock()

    static func writeReport(_ dash: JSON? = nil, wait: TimeInterval = 0) {
        let p = path
        guard !p.isEmpty else { return }
        lock.lock(); if pending { lock.unlock(); Log.write("Fleet report skipped - the previous one is still being written.", "WARN"); return }
        pending = true; lock.unlock()
        let data = try? JSONSerialization.data(withJSONObject: report(dash ?? Dashboard.data()), options: [.prettyPrinted, .sortedKeys])
        let done = DispatchSemaphore(value: 0)
        queue.async {
            defer { lock.lock(); pending = false; lock.unlock(); done.signal() }
            do {
                guard let data = data else { return }
                try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: p + "/\(computer).json"), options: .atomic)
                Log.write("Fleet report written to \(Paths.tilde(p))", "OK")
            } catch {
                Log.write("Fleet report could not be written to \(Paths.tilde(p)): \(error.localizedDescription)", "WARN")
            }
        }
        if wait > 0 && done.wait(timeout: .now() + wait) == .timedOut {
            Log.write("Fleet folder is not answering (is OneDrive syncing or asking for permission?) - report not written yet.", "WARN")
        }
    }

    static func reports() throws -> [JSON] {
        let p = path
        guard !p.isEmpty else { return [] }
        var out: [JSON]?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            out = FS.children(p).filter { $0.hasSuffix(".json") }.compactMap { f in
                guard let j = readJSON(f) as? JSON, j["Computer"] is String else { return nil }
                return j
            }
            done.signal()
        }
        if done.wait(timeout: .now() + 30) == .timedOut {
            throw CleanITError("The fleet folder is not answering. If it is in OneDrive, check that OneDrive is running and signed in, and allow CleanIT to access it if macOS asks.")
        }
        return out ?? []
    }

    static func remove(_ name: String) throws {
        guard name.range(of: #"^[A-Za-z0-9._-]{1,63}$"#, options: .regularExpression) != nil else { throw CleanITError("Invalid computer name.") }
        let f = path + "/\(name).json"
        if FS.exists(f) { try FileManager.default.removeItem(atPath: f); Log.write("Removed \(name) from the fleet view.", "OK") }
    }
}
