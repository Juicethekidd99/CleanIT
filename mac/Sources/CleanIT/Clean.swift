// Junk categories for macOS. Like on Windows, categories are data: add one here and the UI and CLI pick it up.
// A target is a folder whose CONTENTS are removed (the folder itself stays) or a single file.
// A target with an owner (bundle id) is skipped while that app is open.
import Foundation
import AppKit

struct Target {
    let path: String
    var owner: String? = nil
}

struct Category {
    let key: String
    let name: String
    let description: String
    var group = "Mac"
    var isDefault = true
    var warning: String? = nil
    var minAgeHours: Double = 0
    var toTrash = false                        // files go to the Trash instead of being deleted (user files)
    var needsFullDiskAccess = false
    let targets: () -> [Target]

    var dto: JSON {
        ["key": key, "name": name, "description": description, "group": group, "default": isDefault, "deep": false,
         "warning": warning ?? NSNull(), "fda": needsFullDiskAccess]
    }
}

enum Clean {
    static let H = Paths.home, L = Paths.library
    static let AS = Paths.library + "/Application Support"

    // Cache folders that must never be cleared by the generic "App caches" category
    // (iCloud sync state, in-progress downloads, Find My, Home, account data).
    static let protectedCaches: Set<String> = [
        "com.apple.bird", "CloudKit", "com.apple.cloudd", "com.apple.CloudDocs", "com.apple.HomeKit", "com.apple.homed",
        "FamilyCircle", "com.apple.findmy.fmipcore", "com.apple.icloud.fmfd", "com.apple.akd", "com.apple.ap.adprivacyd",
        "com.apple.containermanagerd", "com.apple.nsurlsessiond", "com.apple.appstoreagent", "com.apple.softwareupdate",
        "com.apple.iCloudHelper", "com.apple.mediaanalysisd", "com.apple.photoanalysisd", "com.apple.Photos",
        "com.apple.passd", "com.apple.keychain", "com.apple.security", "com.apple.trustd"
    ]

    static func chromium(_ appSupport: String, _ owner: String) -> [Target] {
        var t: [Target] = []
        for prof in FS.glob(appSupport + "/*") {
            for sub in ["Code Cache", "GPUCache", "Service Worker/CacheStorage", "Service Worker/ScriptCache"] {
                let p = prof + "/" + sub
                if FS.isDir(p) { t.append(Target(path: p, owner: owner)) }
            }
        }
        return t
    }
    static func electron(_ dir: String, _ owner: String) -> [Target] {
        ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "Service Worker/CacheStorage"]
            .map { Target(path: dir + "/" + $0, owner: owner) }.filter { FS.isDir($0.path) }
    }

    static let browserTargets: () -> [Target] = {
        var t: [Target] = [
            Target(path: L + "/Caches/com.apple.Safari", owner: "com.apple.Safari"),
            Target(path: L + "/Containers/com.apple.Safari/Data/Library/Caches", owner: "com.apple.Safari"),
            Target(path: L + "/Caches/Google/Chrome", owner: "com.google.Chrome"),
            Target(path: L + "/Caches/Microsoft Edge", owner: "com.microsoft.edgemac"),
            Target(path: L + "/Caches/BraveSoftware", owner: "com.brave.Browser"),
            Target(path: L + "/Caches/Vivaldi", owner: "com.vivaldi.Vivaldi"),
            Target(path: L + "/Caches/Chromium", owner: "org.chromium.Chromium"),
            Target(path: L + "/Caches/com.operasoftware.Opera", owner: "com.operasoftware.Opera"),
            Target(path: L + "/Caches/company.thebrowser.Browser", owner: "company.thebrowser.Browser"),
            Target(path: L + "/Caches/Arc", owner: "company.thebrowser.Browser"),
            Target(path: L + "/Caches/Firefox", owner: "org.mozilla.firefox"),
        ]
        t += chromium(AS + "/Google/Chrome", "com.google.Chrome")
        t += chromium(AS + "/Microsoft Edge", "com.microsoft.edgemac")
        t += chromium(AS + "/BraveSoftware/Brave-Browser", "com.brave.Browser")
        t += chromium(AS + "/Vivaldi", "com.vivaldi.Vivaldi")
        t += chromium(AS + "/Arc/User Data", "company.thebrowser.Browser")
        return t.filter { FS.exists($0.path) }
    }

    static let devTargets: () -> [Target] = {
        [H + "/.npm/_cacache", L + "/Caches/Yarn", L + "/Caches/pip", L + "/Caches/Homebrew", L + "/Caches/CocoaPods",
         L + "/Caches/go-build", L + "/Caches/org.swift.swiftpm", H + "/.gradle/caches", H + "/.cargo/registry/cache",
         L + "/Caches/pnpm", L + "/Caches/ms-playwright", L + "/Caches/node-gyp"]
            .filter { FS.exists($0) }.map { Target(path: $0) }
    }

    static let defs: [Category] = [
        // ---------------- Mac ----------------
        Category(key: "UserCaches", name: "App caches",
                 description: "Cache folders in ~/Library/Caches. Apps rebuild them as needed. Caches of open apps, iCloud, Find My and Home are skipped.",
                 targets: {
                     let claimed = Set(Clean.defs.filter { $0.key != "UserCaches" }.flatMap { $0.targets().map { $0.path } })
                     return FS.children(L + "/Caches").filter { p in
                         let n = (p as NSString).lastPathComponent
                         if n.hasPrefix(".") || Clean.protectedCaches.contains(n) || claimed.contains(p) { return false }
                         // folders that contain a claimed path (e.g. Caches/Google holds Chrome) are left alone
                         return !claimed.contains { $0.hasPrefix(p + "/") }
                     }.map { Target(path: $0, owner: ($0 as NSString).lastPathComponent) }
                 }),
        Category(key: "UserLogs", name: "Old logs & crash reports",
                 description: "App logs and crash reports in ~/Library/Logs older than 7 days.", minAgeHours: 168,
                 targets: { FS.children(L + "/Logs").filter { !$0.hasSuffix("/CleanIT") }.map { Target(path: $0) } }),
        Category(key: "TempFiles", name: "Temporary files",
                 description: "Your temporary folder (TMPDIR), files older than 3 days.", minAgeHours: 72,
                 targets: { [Target(path: (NSTemporaryDirectory() as NSString).standardizingPath)] }),
        Category(key: "DeviceUpdates", name: "iPhone/iPad update files",
                 description: "Downloaded iOS/iPadOS firmware (.ipsw). Finder downloads them again if ever needed.",
                 targets: { ["iPhone", "iPad", "iPod"].map { Target(path: L + "/iTunes/\($0) Software Updates") }.filter { FS.exists($0.path) } }),
        Category(key: "MailDownloads", name: "Mail attachment copies",
                 description: "Copies Mail makes when you open an attachment. The attachments stay in your mail.",
                 needsFullDiskAccess: true,
                 targets: { [Target(path: L + "/Containers/com.apple.mail/Data/Library/Mail Downloads", owner: "com.apple.mail")] }),
        Category(key: "OldInstallers", name: "Old installers in Downloads",
                 description: "Disk images and installer packages (.dmg, .pkg, .mpkg) in Downloads older than 30 days. They go to the Trash.",
                 isDefault: false, toTrash: true,
                 targets: {
                     let cutoff = Date().addingTimeInterval(-30 * 86400)
                     return FS.children(H + "/Downloads").filter { p in
                         let ext = (p as NSString).pathExtension.lowercased()
                         guard ["dmg", "pkg", "mpkg"].contains(ext),
                               let m = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date else { return false }
                         return m < cutoff
                     }.map { Target(path: $0) }
                 }),
        Category(key: "Trash", name: "Trash",
                 description: "Everything in your Trash.", isDefault: false,
                 warning: "Permanently deletes what is in the Trash - it cannot be restored afterwards.", needsFullDiskAccess: true,
                 targets: { [Target(path: H + "/.Trash")] }),

        // ---------------- Browsers ----------------
        Category(key: "BrowserCache", name: "Browser caches",
                 description: "Cached web data for Safari, Chrome, Edge, Brave, Arc, Vivaldi, Opera and Firefox. Logins, history, cookies and bookmarks are untouched.",
                 group: "Browsers", targets: browserTargets),

        // ---------------- Apps ----------------
        Category(key: "Discord", name: "Discord cache", description: "Discord image/code/GPU cache. Messages and login are not affected.", group: "Apps",
                 targets: { ["discord", "discordptb", "discordcanary"].flatMap { Clean.electron(AS + "/" + $0, "com.hnc.Discord") } }),
        Category(key: "Spotify", name: "Spotify streaming cache", description: "Spotify streaming cache. Downloaded (offline) songs are NOT touched.", group: "Apps",
                 targets: { [Target(path: L + "/Caches/com.spotify.client", owner: "com.spotify.client")].filter { FS.exists($0.path) } }),
        Category(key: "Slack", name: "Slack cache", description: "Slack web cache. Messages and login are not affected.", group: "Apps",
                 targets: { Clean.electron(AS + "/Slack", "com.tinyspeck.slackmacgap")
                     + Clean.electron(L + "/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack", "com.tinyspeck.slackmacgap") }),
        Category(key: "Teams", name: "Microsoft Teams cache", description: "Teams web cache. Chats and login are not affected.", group: "Apps",
                 targets: { [Target(path: L + "/Containers/com.microsoft.teams2/Data/Library/Caches", owner: "com.microsoft.teams2")].filter { FS.exists($0.path) }
                     + Clean.electron(AS + "/Microsoft/Teams", "com.microsoft.teams") }),
        Category(key: "VSCode", name: "VS Code caches", description: "VS Code web/code caches and cached extension downloads. Settings and extensions stay.", group: "Apps",
                 targets: { Clean.electron(AS + "/Code", "com.microsoft.VSCode")
                     + ["CachedData", "CachedExtensionVSIXs"].map { Target(path: AS + "/Code/" + $0, owner: "com.microsoft.VSCode") }.filter { FS.exists($0.path) } }),
        Category(key: "Steam", name: "Steam web cache", description: "Steam's built-in browser cache and logs. Games are not touched.", group: "Apps",
                 targets: { ["appcache/httpcache", "logs"].map { Target(path: AS + "/Steam/" + $0, owner: "com.valvesoftware.steam") }.filter { FS.exists($0.path) } }),
        Category(key: "AdobeCache", name: "Adobe media cache", description: "Premiere Pro / After Effects media cache. Rebuilt when you open a project (slower first time).",
                 group: "Apps", isDefault: false,
                 targets: { ["Media Cache Files", "Media Cache"].map { Target(path: AS + "/Adobe/Common/" + $0) }.filter { FS.exists($0.path) } }),

        // ---------------- Developer ----------------
        Category(key: "XcodeDerivedData", name: "Xcode DerivedData", description: "Xcode build products and indexes. Safe; the next build of each project takes longer.",
                 group: "Developer", isDefault: false,
                 targets: { [Target(path: L + "/Developer/Xcode/DerivedData", owner: "com.apple.dt.Xcode")].filter { FS.exists($0.path) } }),
        Category(key: "XcodeDeviceSupport", name: "Xcode device support files",
                 description: "Debug symbols copied from your iPhone/iPad/Watch for each iOS version. Copied again (a few minutes) the next time you debug on that device.",
                 group: "Developer", isDefault: false,
                 targets: { ["iOS", "watchOS", "tvOS", "visionOS"].map { Target(path: L + "/Developer/Xcode/\($0) DeviceSupport", owner: "com.apple.dt.Xcode") }.filter { FS.exists($0.path) } }),
        Category(key: "SimulatorCaches", name: "Simulator caches", description: "CoreSimulator caches. Your simulators and their apps stay.",
                 group: "Developer", isDefault: false,
                 targets: { [Target(path: L + "/Developer/CoreSimulator/Caches", owner: "com.apple.iphonesimulator")].filter { FS.exists($0.path) } }),
        Category(key: "DevCaches", name: "Developer package caches",
                 description: "npm, Yarn, pnpm, pip, Homebrew, CocoaPods, SwiftPM, Go, Gradle and Cargo download caches. Downloaded again when needed.",
                 group: "Developer", isDefault: false, targets: devTargets),
    ]

    static func find(_ keys: [String]) -> [Category] { defs.filter { keys.contains($0.key) } }

    static func appName(_ bundleId: String) -> String {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) { return (u.lastPathComponent as NSString).deletingPathExtension }
        return bundleId
    }

    // ------------------------------------------------------------------
    static func scan(_ keys: [String], job: Job? = nil) -> [JSON] {
        let running = runningBundleIds()
        let cats = find(keys)
        var out: [JSON] = []
        for (i, c) in cats.enumerated() {
            if job?.isCancelled == true { break }
            job?.report(Int(100 * Double(i) / Double(max(1, cats.count))), "Scanning " + c.name)
            var total: Int64 = 0
            var busy = Set<String>()
            var denied = false
            for t in c.targets() {
                if let o = t.owner, running.contains(o) { busy.insert(appName(o)) }
                let s = FS.size(t.path, minAge: c.minAgeHours * 3600, cancel: { job?.isCancelled == true })
                if !s.readable && FS.exists(t.path) { denied = true }
                total += s.bytes
            }
            // generic app caches: only name the open apps that hold a lot
            let running = c.key == "UserCaches" ? (busy.count > 4 ? "\(busy.count) open apps" : busy.sorted().joined(separator: ", ")) : busy.sorted().joined(separator: ", ")
            out.append(["Key": c.key, "Size": (denied && total == 0) ? Int64(-1) : total, "Running": running.isEmpty ? NSNull() : running,
                        "Denied": denied])
        }
        return out
    }

    static func clean(_ keys: [String], job: Job? = nil, scheduled: Bool = false) -> JSON {
        let running = runningBundleIds()
        let cats = find(keys)
        var details: [JSON] = []
        var freedAll: Int64 = 0
        for (i, c) in cats.enumerated() {
            if job?.isCancelled == true { break }
            job?.report(Int(100 * Double(i) / Double(max(1, cats.count))), "Cleaning " + c.name)
            var freed: Int64 = 0, failed = 0, skipped: [String] = []
            for t in c.targets() {
                if let o = t.owner, running.contains(o) { skipped.append(appName(o)); continue }
                if c.toTrash {
                    let s = FS.size(t.path)
                    if !FS.trash([t.path]).isEmpty { freed += s.bytes }
                } else {
                    let r = FS.clearContents(t.path, minAge: c.minAgeHours * 3600)
                    freed += r.freed; failed += r.failed
                }
            }
            freedAll += freed
            var msg = "\(c.name): freed \(fmtSize(freed))"
            if failed > 0 { msg += ", \(failed) item(s) in use or protected were skipped" }
            if !skipped.isEmpty { msg += ", skipped (open): " + Set(skipped).sorted().joined(separator: ", ") }
            Log.write(msg, "OK")
            details.append(["Key": c.key, "Freed": freed, "Failed": failed])
        }
        Log.write("Clean finished - freed \(fmtSize(freedAll)) in total.", "OK")
        var hist = (readJSON(Paths.historyFile) as? [JSON]) ?? []
        hist.append(["Date": isoNow(), "Freed": freedAll, "Categories": keys, "Scheduled": scheduled])
        if hist.count > 500 { hist.removeFirst(hist.count - 500) }
        writeJSON(Paths.historyFile, hist)
        return ["Freed": freedAll, "Details": details]
    }

    static func history() -> (total: Int64, last: String?, lastFreed: Int64, lastScheduled: String?) {
        let hist = (readJSON(Paths.historyFile) as? [JSON]) ?? []
        let total = hist.reduce(Int64(0)) { $0 + (($1["Freed"] as? NSNumber)?.int64Value ?? 0) }
        let last = hist.last
        let sched = hist.last { ($0["Scheduled"] as? Bool) == true }
        return (total, last?["Date"] as? String, (last?["Freed"] as? NSNumber)?.int64Value ?? 0, sched?["Date"] as? String)
    }
}
