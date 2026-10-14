// Disk tab: space analyzer, large-file finder, duplicate finder. Never follows links; files only ever go to the Trash.
import Foundation
import CryptoKit

enum Disk {
    // Paths the page may send to the Trash must come from our own last results.
    static var trashable = Set<String>()
    static let lock = NSLock()

    // Folders skipped when scanning from "/" (other volumes, the firmlinked data volume seen twice, devices).
    static let rootSkips: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/cores"]
    static var systemDirs: [String] {
        [Paths.library, "/System", "/Library", "/Applications", "/private", "/usr", "/bin", "/sbin", "/opt", "/cores"]
    }
    static func isSystem(_ p: String) -> Bool { systemDirs.contains { p == $0 || p.hasPrefix($0 + "/") } }

    static func places() -> [String] {
        let h = Paths.home
        var p = ["/", h] + ["Downloads", "Documents", "Desktop", "Movies", "Music", "Pictures", "Library"].map { h + "/" + $0 }
        p += FS.children("/Volumes").filter { !FS.isLink($0) }
        return p.filter { FS.exists($0) }
    }

    static func norm(_ path: String) throws -> String {
        var p = (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard p.hasPrefix("/"), FS.isDir(p) else { throw CleanITError("Folder not found: \(path)") }
        return p
    }

    // ------------------------------------------------------------------ space analyzer
    final class Tree {
        let root: String
        var ownBytes: [String: Int64] = [:]
        var ownFiles: [String: Int] = [:]
        var kids: [String: [String]] = [:]
        var denied = Set<String>()
        var total: [String: (Int64, Int)] = [:]
        init(root: String) { self.root = root }
    }
    static var tree: Tree?

    static func scanTree(_ path: String, job: Job) throws -> JSON {
        let root = try norm(path)
        let t = Tree(root: root)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let url = URL(fileURLWithPath: root)
        var n = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { u, _ in
            t.denied.insert(u.path); return true })!
        for case let u as URL in e {
            n += 1
            if n % 5000 == 0 {
                if job.isCancelled { throw CleanITError("Cancelled") }
                job.report(-1, "\(n.formatted()) items - \(Paths.tilde(u.deletingLastPathComponent().path))")
            }
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            let p = u.path, parent = u.deletingLastPathComponent().path
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true {
                if root == "/" && rootSkips.contains(p) { e.skipDescendants(); continue }
                t.kids[parent, default: []].append(p)
            } else if v.isRegularFile == true {
                t.ownBytes[parent, default: 0] += FS.allocSize(v)
                t.ownFiles[parent, default: 0] += 1
            }
        }
        _ = roll(t, root)
        tree = t
        Log.write("Analyzed \(Paths.tilde(root)): \(fmtSize(t.total[root]!.0)) in \(t.total[root]!.1.formatted()) files.", "OK")
        return node(root)!
    }
    @discardableResult
    static func roll(_ t: Tree, _ p: String) -> (Int64, Int) {
        var b = t.ownBytes[p] ?? 0, f = t.ownFiles[p] ?? 0
        for k in t.kids[p] ?? [] { let r = roll(t, k); b += r.0; f += r.1 }
        t.total[p] = (b, f)
        return (b, f)
    }
    static func node(_ path: String) -> JSON? {
        guard let t = tree, let tot = t.total[path] else { return nil }
        let parent = path == t.root ? nil : (path as NSString).deletingLastPathComponent
        let children: [JSON] = (t.kids[path] ?? []).map { k in
            let s = t.total[k] ?? (0, 0)
            return ["name": (k as NSString).lastPathComponent, "path": k, "size": s.0, "files": s.1,
                    "hasChildren": !(t.kids[k] ?? []).isEmpty || (t.ownFiles[k] ?? 0) > 0, "denied": t.denied.contains(k)]
        }.sorted { i64($0["size"]) > i64($1["size"]) }
        return ["path": path, "root": t.root, "parent": parent ?? NSNull(), "size": tot.0, "files": tot.1,
                "ownFiles": t.ownFiles[path] ?? 0, "ownBytes": t.ownBytes[path] ?? 0, "children": children]
    }

    // ------------------------------------------------------------------ large files
    static func largeFiles(path: String, minMB: Double, days: Int, includeSystem: Bool, job: Job) throws -> [JSON] {
        let root = try norm(path)
        let min = Int64(max(1, minMB) * 1048576)
        let cutoff = days > 0 ? Date().addingTimeInterval(-Double(days) * 86400) : nil
        var hits: [(String, Int64, Date?)] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey,
                                      .contentAccessDateKey, .contentModificationDateKey, .isPackageKey]
        let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })!
        var n = 0
        for case let u as URL in e {
            n += 1
            if n % 5000 == 0 { if job.isCancelled { throw CleanITError("Cancelled") }; job.report(-1, "\(n.formatted()) files checked, \(hits.count) found") }
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true {
                if (root == "/" && rootSkips.contains(u.path)) || (!includeSystem && isSystem(u.path) && !isSystem(root)) { e.skipDescendants() }
                continue
            }
            let size = Int64(v.fileSize ?? 0)
            guard v.isRegularFile == true, size >= min else { continue }
            let used = lastUsed(u.path) ?? v.contentModificationDate
            if let c = cutoff, let d = used, d > c { continue }
            hits.append((u.path, size, used))
        }
        hits.sort { $0.1 > $1.1 }
        let top = hits.prefix(2000)
        lock.lock(); trashable.formUnion(top.map { $0.0 }); lock.unlock()
        return top.map { ["path": $0.0, "size": $0.1, "lastUsed": $0.2.map { shortDate($0) } ?? ""] }
    }
    static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // ------------------------------------------------------------------ duplicates
    static func duplicates(path: String, minMB: Double, includeSystem: Bool, job: Job) throws -> [JSON] {
        let root = try norm(path)
        let min = Swift.max(Int64(minMB * 1048576), 1024)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .fileResourceIdentifierKey,
                                      .contentModificationDateKey, .totalFileAllocatedSizeKey]
        var bySize: [Int64: [(String, Date?)]] = [:]
        var seen = Set<String>()            // hard links: same file id counted once
        let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })!
        var n = 0
        for case let u as URL in e {
            n += 1
            if n % 5000 == 0 { if job.isCancelled { throw CleanITError("Cancelled") }; job.report(-1, "Listing files: \(n.formatted())") }
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true {
                if (root == "/" && rootSkips.contains(u.path)) || (!includeSystem && isSystem(u.path) && !isSystem(root)) { e.skipDescendants() }
                continue
            }
            let size = Int64(v.fileSize ?? 0)
            guard v.isRegularFile == true, size >= min else { continue }
            // online-only iCloud files have no local data - skip them
            if FS.allocSize(v) == 0 { continue }
            if let id = v.fileResourceIdentifier { let k = "\(id)"; if seen.contains(k) { continue }; seen.insert(k) }
            bySize[size, default: []].append((u.path, v.contentModificationDate))
        }
        let cands = bySize.filter { $0.value.count > 1 }
        let totalFiles = cands.values.reduce(0) { $0 + $1.count }
        var done = 0
        var out: [JSON] = []
        var g = 0
        for (size, files) in cands.sorted(by: { $0.key > $1.key }) {
            if job.isCancelled { throw CleanITError("Cancelled") }
            // quick pass on the first 64 KB, then a full SHA-256 of the files that still match
            var byHead: [String: [(String, Date?)]] = [:]
            for f in files { if let hsh = hash(f.0, limit: 65536) { byHead[hsh, default: []].append(f) } }
            for (_, same) in byHead where same.count > 1 {
                var byFull: [String: [(String, Date?)]] = [:]
                for f in same { if let hsh = size <= 65536 ? "s" : hash(f.0, limit: nil) { byFull[hsh, default: []].append(f) } }
                for (_, dup) in byFull where dup.count > 1 {
                    g += 1
                    for f in dup { out.append(["path": f.0, "size": size, "modified": f.1.map { shortDate($0) } ?? "", "group": g]) }
                }
            }
            done += files.count
            job.report(Int(100 * Double(done) / Double(max(1, totalFiles))), "Comparing \(done) of \(totalFiles) files")
        }
        lock.lock(); trashable.formUnion(out.map { $0["path"] as! String }); lock.unlock()
        return out
    }
    static func hash(_ path: String, limit: Int?) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        var left = limit ?? Int.max
        while left > 0 {
            let chunk = h.readData(ofLength: Swift.min(1 << 20, left))
            if chunk.isEmpty { break }
            sha.update(data: chunk); left -= chunk.count
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func trash(_ paths: [String]) throws -> [String] {
        lock.lock(); let ok = paths.allSatisfy { trashable.contains($0) }; lock.unlock()
        guard ok else { throw CleanITError("Only files from the last search can be moved to the Trash.") }
        let done = FS.trash(paths)
        lock.lock(); trashable.subtract(done); lock.unlock()
        return done
    }
}
