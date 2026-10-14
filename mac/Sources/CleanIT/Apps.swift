// Apps tab: list installed apps, uninstall (app goes to the Trash), find leftovers.
// The leftover finder is strict on purpose, like the Windows one: exact bundle id or exact app name only.
import Foundation
import AppKit

enum Apps {
    static var lastList: [String: JSON] = [:]
    static var leftoverPaths = Set<String>()
    static let builtIn: Set<String> = ["com.apple.Safari"]

    static func appDirs() -> [String] {
        ["/Applications", "/Applications/Utilities", Paths.home + "/Applications"]
    }

    static func physicalSize(_ path: String) -> Int64 {
        if let item = MDItemCreate(nil, path as CFString), let n = MDItemCopyAttribute(item, "kMDItemPhysicalSize" as CFString) as? NSNumber {
            return n.int64Value
        }
        return FS.size(path).bytes
    }

    static func list(job: Job) -> [JSON] {
        var apps: [String] = []
        for d in appDirs() {
            for c in FS.children(d) {
                if c.hasSuffix(".app") && !FS.isLink(c) { apps.append(c) }
                else if FS.isDir(c) && !c.hasSuffix("/Utilities") {   // apps inside a vendor folder, e.g. /Applications/Adobe Photoshop 2025/
                    apps += FS.children(c).filter { $0.hasSuffix(".app") && !FS.isLink($0) }
                }
            }
        }
        var out: [JSON] = []
        for (i, p) in apps.enumerated() {
            job.report(Int(100 * Double(i) / Double(max(1, apps.count))), (p as NSString).lastPathComponent)
            let b = Bundle(path: p)
            let info = b?.infoDictionary ?? [:]
            let id = b?.bundleIdentifier ?? ""
            let name = (info["CFBundleDisplayName"] as? String) ?? ((p as NSString).lastPathComponent as NSString).deletingPathExtension
            let appStore = FS.exists(p + "/Contents/_MASReceipt/receipt")
            let attrs = try? FileManager.default.attributesOfItem(atPath: p)
            let item: JSON = [
                "id": p, "name": name, "bundleId": id,
                // full signature checks hash the whole app (slow for big apps) - the signer name is enough here
                "publisher": appStore ? "App Store" : Startup.signer(p, validate: false).replacingOccurrences(of: #" \([A-Z0-9]{10}\)$"#, with: "", options: .regularExpression),
                "version": (info["CFBundleShortVersionString"] as? String) ?? "",
                "size": physicalSize(p),
                "date": shortDate(attrs?[.modificationDate] as? Date),
                "lastUsed": shortDate(Disk.lastUsed(p)),
                "scope": p.hasPrefix(Paths.home) ? "You" : "All users",
                "location": p, "builtIn": builtIn.contains(id)
            ]
            out.append(item)
        }
        lastList = Dictionary(uniqueKeysWithValues: out.map { ($0["id"] as! String, $0) })
        return out
    }

    static func recycle(_ urls: [URL]) -> [URL] {
        let sem = DispatchSemaphore(value: 0)
        var moved: [URL] = []
        DispatchQueue.main.async {
            NSWorkspace.shared.recycle(urls) { done, _ in moved = Array(done.keys); sem.signal() }
        }
        sem.wait()
        return moved
    }

    static func uninstall(_ id: String, job: Job) throws -> JSON {
        guard let a = lastList[id] else { throw CleanITError("Unknown app - refresh the list and try again.") }
        let name = a["name"] as! String, bid = a["bundleId"] as! String
        if (a["builtIn"] as? Bool) == true { throw CleanITError("\(name) is part of macOS and can't be removed.") }
        if !bid.isEmpty && runningBundleIds().contains(bid) { throw CleanITError("\(name) is open. Quit it first, then try again.") }
        job.report(-1, "Moving \(name) to the Trash")
        let moved = recycle([URL(fileURLWithPath: id)])
        let gone = !moved.isEmpty || !FS.exists(id)
        if !gone { throw CleanITError("\(name) could not be moved to the Trash. Try dragging it to the Trash in Finder.") }
        Log.write("\(name) moved to the Trash.", "OK")
        job.report(-1, "Looking for leftovers")
        return ["gone": true, "name": name, "hits": leftovers(name: name, bundleId: bid)]
    }

    static func findLeftovers(_ id: String) throws -> JSON {
        guard let a = lastList[id] else { throw CleanITError("Unknown app - refresh the list and try again.") }
        let name = a["name"] as! String
        return ["name": name, "hits": leftovers(name: name, bundleId: a["bundleId"] as! String)]
    }

    static func leftovers(name: String, bundleId: String) -> [JSON] {
        let L = Paths.library
        let user = ["Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers", "Group Containers", "Saved Application State",
                    "HTTPStorages", "WebKit", "Logs", "Cookies", "LaunchAgents", "Application Scripts"].map { L + "/" + $0 }
        let system = ["Application Support", "Caches", "Preferences", "LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools"].map { "/Library/" + $0 }
        let bid = bundleId.lowercased(), nm = name.lowercased()
        var hits: [JSON] = []
        for dir in user + system {
            for p in FS.children(dir) {
                var base = (p as NSString).lastPathComponent.lowercased()
                for ext in [".plist", ".savedstate", ".binarycookies", ".log"] where base.hasSuffix(ext) { base = String(base.dropLast(ext.count)) }
                var reason: String?
                if !bid.isEmpty && (base == bid || base.hasPrefix(bid + ".")) { reason = "Named after the app's id (\(bundleId))" }
                else if !bid.isEmpty && dir.hasSuffix("Group Containers") && base.hasSuffix("." + bid) { reason = "Shared container of \(bundleId)" }
                else if !bid.isEmpty && (dir.hasSuffix("LaunchAgents") || dir.hasSuffix("LaunchDaemons") || dir.hasSuffix("PrivilegedHelperTools")) && base.hasPrefix(bid) {
                    reason = "Background helper of \(bundleId)" }
                else if nm.count >= 3 && base == nm && !dir.hasSuffix("Containers") { reason = "Same name as the app" }
                guard let r = reason else { continue }
                let isDir = FS.isDir(p)
                hits.append(["Type": isDir ? "Folder" : "File", "Path": p, "Size": FS.size(p).bytes, "Reason": r])
            }
        }
        leftoverPaths.formUnion(hits.map { $0["Path"] as! String })
        return hits
    }

    static func removeLeftovers(_ paths: [String]) throws -> [String] {
        guard paths.allSatisfy({ leftoverPaths.contains($0) }) else { throw CleanITError("Only leftovers from the last search can be removed.") }
        let moved = recycle(paths.map { URL(fileURLWithPath: $0) }).map { $0.path }
        for p in moved { Log.write("Leftover moved to the Trash: \(Paths.tilde(p))", "OK") }
        for p in paths where !moved.contains(p) && FS.exists(p) { Log.write("Could not remove: \(Paths.tilde(p))", "WARN") }
        leftoverPaths.subtract(moved)
        return moved
    }
}
