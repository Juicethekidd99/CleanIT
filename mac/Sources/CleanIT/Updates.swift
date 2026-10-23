// Updates tab: macOS Software Update (softwareupdate) and Homebrew. Each update gets an
// Important / Recommended / Optional label with a one-line reason, like on Windows.
import Foundation

enum Updates {
    static var cacheFile: String { Paths.stateDir + "/updates.json" }
    static var lastMac: [String: JSON] = [:]

    static func cached() -> JSON { (readJSON(cacheFile) as? JSON) ?? [:] }
    static func remember(_ key: String, _ n: Int) {
        var c = cached(); c[key] = n; c[key + "Checked"] = isoNow(); writeJSON(cacheFile, c)
    }

    // ------------------------------------------------------------------ macOS
    static func macList(job: Job) -> [JSON] {
        job.report(-1, "Asking Apple's update server (can take a minute)...")
        let out = sh("/usr/sbin/softwareupdate", ["-l"], timeout: 300, cancel: { job.isCancelled }).out
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        var items: [JSON] = []
        var label: String?
        for raw in out.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("* Label:") { label = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces); continue }
            guard let l = label, line.hasPrefix("Title:") else { continue }
            var f: [String: String] = [:]
            for part in line.components(separatedBy: ", ") {
                let kv = part.components(separatedBy: ": ")
                if kv.count >= 2 { f[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1...].joined(separator: ": ").trimmingCharacters(in: CharacterSet(charactersIn: " ,")) }
            }
            let title = f["Title"] ?? l
            let sizeKiB = Int64((f["Size"] ?? "").replacingOccurrences(of: "KiB", with: "").replacingOccurrences(of: "K", with: "")) ?? 0
            let reboot = (f["Action"] ?? "").contains("restart")
            let isMacOS = title.hasPrefix("macOS")
            let verMajor = Int((f["Version"] ?? "").split(separator: ".").first ?? "") ?? major
            var imp = "Recommended", why = "Fixes and improvements from Apple."
            if title.contains("Security Response") || title.contains("Background Security") {
                imp = "Important"; why = "An urgent security fix from Apple. Install today."
            } else if isMacOS && verMajor > major {
                imp = "Optional"; why = "A new major version of macOS. Free, but it changes a lot - install when you have time, after a backup."
            } else if isMacOS {
                imp = "Important"; why = "Security and bug fixes for your current macOS. Install today."
            } else if title.contains("Command Line Tools") {
                imp = "Optional"; why = "Developer tools. Only needed if you build software."
            } else if title.contains("Safari") {
                imp = "Important"; why = "Safari security fixes."
            }
            items.append(["Id": l, "Title": title, "Size": sizeKiB * 1024, "Reboot": reboot, "Importance": imp, "Why": why,
                          "NeedsInput": isMacOS])
            label = nil
        }
        lastMac = Dictionary(uniqueKeysWithValues: items.map { ($0["Id"] as! String, $0) })
        remember("mac", items.filter { ($0["Importance"] as? String) != "Optional" }.count)
        Log.write("macOS updates: \(items.count) available.", "OK")
        return items
    }

    static func macInstall(_ ids: [String], job: Job) throws {
        let ok = ids.filter { lastMac[$0] != nil && (lastMac[$0]?["NeedsInput"] as? Bool) != true }
        guard !ok.isEmpty else { throw CleanITError("Install macOS itself from System Settings > General > Software Update.") }
        job.report(-1, "Installing \(ok.count) update(s) - macOS will ask for your password")
        let cmd = "/usr/sbin/softwareupdate -i " + ok.map { Startup.q($0) }.joined(separator: " ")
        let r = shAdmin(cmd)
        if r.code != 0 { throw CleanITError("Software Update did not finish: " + r.out.suffix(300)) }
        Log.write("Installed: " + ok.joined(separator: ", "), "OK")
    }

    // ------------------------------------------------------------------ Homebrew
    static var brew: String? { which("brew") }
    static let securityTools: Set<String> = ["openssl@3", "openssl@1.1", "curl", "git", "gnupg", "openssh", "libssh2", "sqlite", "python@3.12",
        "python@3.13", "node", "google-chrome", "firefox", "brave-browser", "microsoft-edge", "zoom", "signal", "1password", "bitwarden",
        "tor-browser", "vlc", "wireshark", "gh", "libxml2", "expat", "zlib", "ca-certificates", "gnutls", "libgcrypt", "sudo"]

    static func brewList(job: Job) throws -> [JSON] {
        guard let b = brew else { return [] }
        job.report(-1, "Checking Homebrew")
        let r = sh(b, ["outdated", "--json=v2", "--greedy-auto-updates"], timeout: 180, cancel: { job.isCancelled })
        guard let start = r.out.firstIndex(of: "{"), let d = String(r.out[start...]).data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? JSON else { throw CleanITError("Homebrew did not answer: " + r.out.prefix(200)) }
        var items: [JSON] = []
        for (kind, arr) in [("formula", j["formulae"]), ("cask", j["casks"])] {
            for o in (arr as? [JSON]) ?? [] {
                let name = o["name"] as? String ?? ""
                let have = ((o["installed_versions"] as? [String]) ?? []).last ?? (o["installed_versions"] as? String) ?? ""
                let sec = securityTools.contains(name)
                items.append(["Id": kind + ":" + name, "Name": name, "Kind": kind == "cask" ? "App" : "Tool", "Version": have,
                              "Available": o["current_version"] as? String ?? "", "Pinned": (o["pinned"] as? Bool) ?? false,
                              "Importance": sec ? "Recommended" : "Optional",
                              "Why": sec ? "Handles internet data or passwords - updates usually include security fixes." : "New features and bug fixes."])
            }
        }
        remember("brew", items.count)
        Log.write("Homebrew: \(items.count) update(s) available.", "OK")
        return items
    }

    static func brewUpgrade(_ ids: [String], job: Job) throws {
        guard let b = brew else { throw CleanITError("Homebrew is not installed.") }
        let excl = Set((Settings.load()["BrewExclude"] as? [String]) ?? [])
        let ids = ids.filter { !excl.contains($0) }
        let formulae = ids.filter { $0.hasPrefix("formula:") }.map { String($0.dropFirst(8)) }
        let casks = ids.filter { $0.hasPrefix("cask:") }.map { String($0.dropFirst(5)) }
        for (args, list) in [(["upgrade"], formulae), (["upgrade", "--cask"], casks)] where !list.isEmpty {
            for (i, n) in list.enumerated() {
                if job.isCancelled { return }
                job.report(Int(100 * Double(i) / Double(list.count)), "Updating \(n)")
                let r = sh(b, args + [n], timeout: 1800, cancel: { job.isCancelled })
                Log.write(r.code == 0 ? "Updated \(n)." : "\(n): update failed - \(r.out.suffix(200))", r.code == 0 ? "OK" : "WARN")
            }
        }
    }
}
