// Startup tab: Launch Agents (per user and for all users), Launch Daemons and Login Items.
// Switching off uses launchd's own "disabled" override (the plist file is never edited or deleted),
// so it is fully reversible. Every change is recorded in State/startup.json for "Undo all".
import Foundation
import Security

enum Startup {
    static let uid = getuid()
    static var stateFile: String { Paths.stateDir + "/startup.json" }
    static var lastItems: [String: JSON] = [:]

    struct Src { let dir: String; let kind: String; let domain: String; let location: String }
    static var sources: [Src] {
        [Src(dir: Paths.library + "/LaunchAgents", kind: "Agent", domain: "gui/\(uid)", location: "~/Library/LaunchAgents"),
         Src(dir: "/Library/LaunchAgents", kind: "Agent", domain: "gui/\(uid)", location: "/Library/LaunchAgents"),
         Src(dir: "/Library/LaunchDaemons", kind: "Daemon", domain: "system", location: "/Library/LaunchDaemons")]
    }

    // launchctl print-disabled: "label" => disabled | enabled (older macOS: true | false)
    static func disabledMap(_ domain: String) -> [String: Bool] {
        var m: [String: Bool] = [:]
        let out = sh("/bin/launchctl", ["print-disabled", domain], timeout: 15).out
        for line in out.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let v = parts[1].trimmingCharacters(in: .whitespaces)
            m[label] = (v == "disabled" || v == "true")
        }
        return m
    }
    static func runningLabels() -> Set<String> {
        var s = Set<String>()
        for line in sh("/bin/launchctl", ["list"], timeout: 15).out.split(separator: "\n").dropFirst() {
            let c = line.split(separator: "\t")
            if c.count == 3, c[0] != "-" { s.insert(String(c[2])) }
        }
        return s
    }

    static func signer(_ path: String, validate: Bool = true) -> String {
        var code: SecStaticCode?
        guard FS.exists(path), SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let c = code else {
            return FS.exists(path) ? "unsigned" : "file missing"
        }
        if validate && SecStaticCodeCheckValidity(c, SecCSFlags(rawValue: 0), nil) != errSecSuccess { return "signature NOT valid" }
        var info: CFDictionary?
        SecCodeCopySigningInformation(c, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let d = info as? [String: Any] ?? [:]
        if let certs = d[kSecCodeInfoCertificates as String] as? [SecCertificate], let first = certs.first {
            var cn: CFString?
            SecCertificateCopyCommonName(first, &cn)
            if let n = cn as String? {
                if n.hasPrefix("Developer ID Application: ") { return String(n.dropFirst(26)) }
                if n.hasPrefix("Apple Mac OS Application Signing") { return "Mac App Store" }
                if n.hasPrefix("Software Signing") { return "Apple" }
                return n
            }
        }
        return "unsigned"
    }

    static func appName(fromExe p: String) -> String? {
        guard let r = p.range(of: ".app/") else { return nil }
        return ((String(p[..<r.lowerBound]) as NSString).lastPathComponent)
    }

    static func list(includeApple: Bool, loginItems withLogin: Bool = true) -> [JSON] {
        var items: [JSON] = []
        let disabledGui = disabledMap("gui/\(uid)"), disabledSys = disabledMap("system")
        let running = runningLabels()
        for src in sources {
            for file in FS.children(src.dir) where file.hasSuffix(".plist") {
                guard let d = NSDictionary(contentsOfFile: file) as? [String: Any], let label = d["Label"] as? String else { continue }
                if !includeApple && label.hasPrefix("com.apple.") { continue }
                let args = (d["ProgramArguments"] as? [String]) ?? []
                let exe = (d["Program"] as? String) ?? args.first ?? ""
                let cmd = ([exe] + args.dropFirst()).joined(separator: " ")
                let off = (src.domain == "system" ? disabledSys : disabledGui)[label] ?? ((d["Disabled"] as? Bool) ?? false)
                let runAtLoad = (d["RunAtLoad"] as? Bool) == true || d["KeepAlive"] != nil
                let id = src.kind + "|" + file
                let item: JSON = [
                    "id": id, "Name": appName(fromExe: exe) ?? label, "Label": label, "Kind": src.kind, "Enabled": !off,
                    "Publisher": signer(exe), "Status": off ? "Off" : running.contains(label) ? "Running" : runAtLoad ? "On" : "On (on demand)",
                    "Location": src.location, "Command": cmd, "Exe": exe, "Domain": src.domain, "Plist": file
                ]
                items.append(item)
            }
        }
        if withLogin { for li in loginItems() { items.append(li) } }
        lastItems = Dictionary(uniqueKeysWithValues: items.map { ($0["id"] as! String, $0) })
        return items
    }

    // Login Items through System Events (macOS asks once for permission to control System Events).
    static func loginItems() -> [JSON] {
        let r = sh("/usr/bin/osascript", ["-e", "tell application \"System Events\" to get the path of every login item"], timeout: 20)
        guard r.code == 0 else { return [] }
        let paths = r.out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ", ").filter { !$0.isEmpty }
        return paths.map { p in
            let name = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
            return ["id": "LoginItem|" + p, "Name": name, "Label": name, "Kind": "LoginItem", "Enabled": true, "Publisher": signer(p),
                    "Status": "On", "Location": "Login Items", "Command": p, "Exe": p, "Domain": "", "Plist": ""]
        } + disabledLoginItems()
    }
    // Login items CleanIT removed are still listed (switched off) so they can be switched back on.
    static func disabledLoginItems() -> [JSON] {
        let st = (readJSON(stateFile) as? [JSON]) ?? []
        return st.filter { ($0["Kind"] as? String) == "LoginItem" && ($0["Enabled"] as? Bool) == false }.compactMap { c in
            guard let p = c["Path"] as? String else { return nil }
            let name = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
            return ["id": "LoginItem|" + p, "Name": name, "Label": name, "Kind": "LoginItem", "Enabled": false, "Publisher": signer(p),
                    "Status": "Off", "Location": "Login Items", "Command": p, "Exe": p, "Domain": "", "Plist": ""]
        }
    }

    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // changes: [{id, enable}]
    static func apply(_ changes: [JSON]) throws {
        var adminCmds: [String] = []
        var record = (readJSON(stateFile) as? [JSON]) ?? []
        for ch in changes {
            guard let id = ch["id"] as? String, let enable = ch["enable"] as? Bool else { continue }
            guard let it = lastItems[id] else { throw CleanITError("Unknown startup item - refresh the list and try again.") }
            let kind = it["Kind"] as! String, label = it["Label"] as! String, domain = it["Domain"] as! String, plist = it["Plist"] as! String
            let name = it["Name"] as! String
            switch kind {
            case "LoginItem":
                let path = it["Exe"] as! String
                let esc = path.replacingOccurrences(of: "\"", with: "\\\"")
                let script = enable
                    ? "tell application \"System Events\" to make login item at end with properties {path:\"\(esc)\", hidden:false}"
                    : "tell application \"System Events\" to delete (every login item whose path is \"\(esc)\")"
                let r = sh("/usr/bin/osascript", ["-e", script], timeout: 20)
                if r.code != 0 { throw CleanITError("Could not change login item \(name): \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))") }
                record.removeAll { ($0["Kind"] as? String) == "LoginItem" && ($0["Path"] as? String) == path }
                if !enable { record.append(["Kind": "LoginItem", "Path": path, "Enabled": false, "Date": isoNow()]) }
            case "Daemon":
                adminCmds.append(enable ? "launchctl enable system/\(q(label)); launchctl bootstrap system \(q(plist)) 2>/dev/null; true"
                                        : "launchctl disable system/\(q(label)); launchctl bootout system/\(q(label)) 2>/dev/null; true")
                record.removeAll { ($0["Label"] as? String) == label }
                if !enable { record.append(["Kind": kind, "Label": label, "Domain": domain, "Plist": plist, "Enabled": false, "Date": isoNow()]) }
            default:
                if enable {
                    sh("/bin/launchctl", ["enable", "\(domain)/\(label)"])
                    sh("/bin/launchctl", ["bootstrap", domain, plist])
                } else {
                    sh("/bin/launchctl", ["disable", "\(domain)/\(label)"])
                    sh("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
                }
                record.removeAll { ($0["Label"] as? String) == label }
                if !enable { record.append(["Kind": kind, "Label": label, "Domain": domain, "Plist": plist, "Enabled": false, "Date": isoNow()]) }
            }
            Log.write("Startup: \(name) switched \(enable ? "on" : "off").", "OK")
        }
        if !adminCmds.isEmpty {
            let r = shAdmin(adminCmds.joined(separator: "; "))
            if r.code != 0 { throw CleanITError("Background services need your Mac password - nothing was changed for them.") }
        }
        writeJSON(stateFile, record)
    }

    static func undoAll() throws {
        let record = (readJSON(stateFile) as? [JSON]) ?? []
        if record.isEmpty { Log.write("Startup: nothing to undo."); return }
        _ = list(includeApple: true)
        var changes: [JSON] = []
        for r in record {
            let id: String
            if (r["Kind"] as? String) == "LoginItem" { id = "LoginItem|" + (r["Path"] as? String ?? "") }
            else { id = (r["Kind"] as? String ?? "") + "|" + (r["Plist"] as? String ?? "") }
            if lastItems[id] != nil { changes.append(["id": id, "enable": true]) }
        }
        try apply(changes)
        writeJSON(stateFile, [JSON]())
    }
}
