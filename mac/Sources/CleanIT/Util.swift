// Shared helpers: paths, settings, logging, shell commands, safe file walking.
import Foundation
import AppKit

let appVersion = "0.1.0"
typealias JSON = [String: Any]

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let library = home + "/Library"
    static var dataDir: String {
        if let d = ProcessInfo.processInfo.environment["CLEANIT_DATADIR"], !d.isEmpty { return d }
        return library + "/Application Support/CleanIT"
    }
    static var stateDir: String { dataDir + "/State" }
    static var logDir: String { library + "/Logs/CleanIT" }
    static var settingsFile: String { dataDir + "/settings.json" }
    static var historyFile: String { dataDir + "/history.json" }

    static func ensure() {
        for d in [dataDir, stateDir, logDir] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
    }
    static func tilde(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
}

// ---------------------------------------------------------------------------
// JSON files
// ---------------------------------------------------------------------------
func readJSON(_ path: String) -> Any? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONSerialization.jsonObject(with: d)
}
func writeJSON(_ path: String, _ obj: Any) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
}
func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }
func isoDate(_ d: Date?) -> String? { d.map { ISO8601DateFormatter().string(from: $0) } }
func shortDate(_ d: Date?) -> String {
    guard let d = d else { return "" }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------
enum Settings {
    static let defaults: JSON = [
        "ScheduleDay": "Sunday", "ScheduleTime": "11:00", "ScheduleUpdates": false,
        "BrewExclude": [String](), "UpdateCheck": true
    ]
    private static let lock = NSLock()
    static func load() -> JSON {
        lock.lock(); defer { lock.unlock() }
        var s = defaults
        if let f = readJSON(Paths.settingsFile) as? JSON { for (k, v) in f { s[k] = v } }
        return s
    }
    // Only known keys can be changed from the page.
    @discardableResult
    static func patch(_ p: JSON) -> JSON {
        var s = load()
        lock.lock(); defer { lock.unlock() }
        for (k, v) in p where defaults[k] != nil || k == "ShowApple" { s[k] = v }
        writeJSON(Paths.settingsFile, s)
        return s
    }
}

// ---------------------------------------------------------------------------
// Log: in-memory buffer for the page's Activity drawer + one file per day
// ---------------------------------------------------------------------------
enum Log {
    private static let lock = NSLock()
    private static var lines: [JSON] = []
    private static var base = 0
    static var echo = false     // CLI prints to stdout

    static func write(_ text: String, _ level: String = "INFO") {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let line = "[\(f.string(from: Date()))] \(text)"
        lock.lock()
        lines.append(["level": level, "text": line])
        if lines.count > 3000 { lines.removeFirst(1000); base += 1000 }
        lock.unlock()
        if echo { print((level == "INFO" ? "" : "[\(level)] ") + text) }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let file = Paths.logDir + "/CleanIT-\(df.string(from: Date())).log"
        let data = ("\(isoNow()) [\(level)] \(text)\n").data(using: .utf8)!
        if let h = FileHandle(forWritingAtPath: file) { h.seekToEndOfFile(); h.write(data); h.closeFile() }
        else { FileManager.default.createFile(atPath: file, contents: data) }
    }
    static func since(_ n: Int) -> JSON {
        lock.lock(); defer { lock.unlock() }
        let start = max(0, n - base)
        let out = start < lines.count ? Array(lines[start...]) : []
        return ["lines": out, "next": base + lines.count]
    }
}

// ---------------------------------------------------------------------------
// Shell commands (with a timeout - some system tools can hang)
// ---------------------------------------------------------------------------
@discardableResult
func sh(_ exe: String, _ args: [String], timeout: TimeInterval = 60, cancel: (() -> Bool)? = nil) -> (out: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["HOMEBREW_NO_AUTO_UPDATE"] = "1"; env["HOMEBREW_NO_ENV_HINTS"] = "1"
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    var data = Data()
    let dlock = NSLock()
    pipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        dlock.lock(); data.append(d); dlock.unlock()
    }
    do { try p.run() } catch { return ("", -1) }
    let end = Date().addingTimeInterval(timeout)
    while p.isRunning {
        if Date() > end || (cancel?() ?? false) { p.terminate(); break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    p.waitUntilExit()
    pipe.fileHandleForReading.readabilityHandler = nil
    let rest = pipe.fileHandleForReading.readDataToEndOfFile()
    dlock.lock(); data.append(rest); dlock.unlock()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus)
}

func which(_ tool: String) -> String? {
    for d in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
        let p = d + "/" + tool
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

// Runs a shell command as administrator (macOS shows its own password prompt).
func shAdmin(_ command: String) -> (out: String, code: Int32) {
    let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return sh("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"], timeout: 600)
}

func notify(_ title: String, _ text: String) {
    func q(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    sh("/usr/bin/osascript", ["-e", "display notification \"\(q(text))\" with title \"\(q(title))\""], timeout: 10)
}

// ---------------------------------------------------------------------------
// File system. Nothing here ever follows a symlink, and sizes are allocated
// sizes (what you actually get back), not logical sizes.
// ---------------------------------------------------------------------------
enum FS {
    static let fm = FileManager.default
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                         .contentModificationDateKey, .isRegularFileKey]

    static func exists(_ p: String) -> Bool { fm.fileExists(atPath: p) }
    static func isDir(_ p: String) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue && !isLink(p)
    }
    static func isLink(_ p: String) -> Bool {
        (try? fm.attributesOfItem(atPath: p)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
    static func children(_ p: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: p)) ?? []).map { p + "/" + $0 }
    }
    static func allocSize(_ v: URLResourceValues) -> Int64 {
        Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
    }

    // Expands a pattern where any path component may be "*".
    static func glob(_ pattern: String) -> [String] {
        let parts = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var cur = [""]
        for part in parts {
            var next: [String] = []
            for base in cur {
                if part == "*" {
                    for c in children(base.isEmpty ? "/" : base) where isDir(c) { next.append(c) }
                } else {
                    let p = base + "/" + part
                    if exists(p) || isLink(p) { next.append(p) }
                }
            }
            cur = next
            if cur.isEmpty { break }
        }
        return cur
    }

    // Walks a tree without following links. The visitor gets (path, values) for every regular file.
    // Returns false if the folder could not be read (no permission).
    @discardableResult
    static func walk(_ root: String, cancel: (() -> Bool)? = nil, _ visit: (String, URLResourceValues) -> Void) -> Bool {
        let url = URL(fileURLWithPath: root)
        var denied = false
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                    errorHandler: { _, _ in denied = true; return true }) else { return false }
        var n = 0
        for case let u as URL in e {
            n += 1
            if n % 2000 == 0, cancel?() == true { break }
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { if v.isDirectory == true { e.skipDescendants() }; continue }
            if v.isRegularFile == true { visit(u.path, v) }
        }
        if !fm.isReadableFile(atPath: root) { return false }
        return !denied || n > 0
    }

    static func size(_ path: String, minAge: TimeInterval = 0, cancel: (() -> Bool)? = nil) -> (bytes: Int64, files: Int, readable: Bool) {
        if isLink(path) { return (0, 0, true) }
        let cutoff = Date().addingTimeInterval(-minAge)
        var b: Int64 = 0, n = 0
        if !isDir(path) {
            guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: Set(keys)) else { return (0, 0, false) }
            if minAge > 0, let m = v.contentModificationDate, m > cutoff { return (0, 0, true) }
            return (allocSize(v), 1, true)
        }
        let ok = walk(path, cancel: cancel) { _, v in
            if minAge > 0, let m = v.contentModificationDate, m > cutoff { return }
            b += allocSize(v); n += 1
        }
        return (b, n, ok)
    }

    // Deletes the CONTENTS of a cache folder (the folder itself stays - apps expect it).
    // Never follows links: a link inside is removed as a link, its target is untouched.
    // With minAge, only files older than that go; folders are removed only when left empty.
    static func clearContents(_ dir: String, minAge: TimeInterval = 0) -> (freed: Int64, failed: Int) {
        var freed: Int64 = 0, failed = 0
        if isLink(dir) { return (0, 0) }
        if !isDir(dir) {
            let s = size(dir, minAge: minAge)
            if s.files == 0 { return (0, 0) }
            do { try fm.removeItem(atPath: dir); return (s.bytes, 0) } catch { return (0, 1) }
        }
        for c in children(dir) {
            if isLink(c) { try? fm.removeItem(atPath: c); continue }
            if minAge > 0 {
                if isDir(c) {
                    let r = clearContents(c, minAge: minAge); freed += r.freed; failed += r.failed
                    if children(c).isEmpty { try? fm.removeItem(atPath: c) }
                } else {
                    let s = size(c, minAge: minAge)
                    if s.files > 0 { do { try fm.removeItem(atPath: c); freed += s.bytes } catch { failed += 1 } }
                }
            } else {
                let s = size(c)
                do { try fm.removeItem(atPath: c); freed += s.bytes }
                catch {
                    // something inside is locked or protected - clear what we can
                    if isDir(c) { let r = clearContents(c); freed += r.freed; failed += r.failed + 1 } else { failed += 1 }
                }
            }
        }
        return (freed, failed)
    }

    // Moves to the Trash (always restorable). Returns the paths that were moved.
    static func trash(_ paths: [String]) -> [String] {
        var done: [String] = []
        for p in paths {
            do { try fm.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil); done.append(p); Log.write("Moved to Trash: \(Paths.tilde(p))", "OK") }
            catch { Log.write("Could not move to Trash: \(Paths.tilde(p)) - \(error.localizedDescription)", "WARN") }
        }
        return done
    }

    static func volume(_ path: String = "/") -> (free: Int64, total: Int64) {
        let u = URL(fileURLWithPath: path)
        let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let free = v?.volumeAvailableCapacityForImportantUsage ?? Int64(v?.volumeAvailableCapacity ?? 0)
        return (free, Int64(v?.volumeTotalCapacity ?? 0))
    }
}

func fmtSize(_ b: Int64) -> String {
    let u: [(String, Double, Int)] = [("TB", 1099511627776, 2), ("GB", 1073741824, 2), ("MB", 1048576, 1), ("KB", 1024, 0)]
    for (n, s, d) in u where Double(b) >= s { return String(format: "%.\(d)f \(n)", Double(b) / s) }
    return "\(b) B"
}

// Apps that are open right now, by bundle id.
func runningBundleIds() -> Set<String> {
    Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
}

// Full Disk Access: needed to read Safari, Mail and the Trash. We can only test by trying.
func hasFullDiskAccess() -> Bool {
    let probe = Paths.library + "/Containers/com.apple.stocks"
    let probe2 = Paths.library + "/Safari"
    for p in [probe2, probe] where FS.exists(p) {
        return (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil
    }
    return true
}

// Numbers inside JSON dictionaries can be Int, Int64 or NSNumber - read them all the same way.
func i64(_ a: Any?) -> Int64 { (a as? NSNumber)?.int64Value ?? (a as? Int64) ?? Int64(a as? Int ?? 0) }
