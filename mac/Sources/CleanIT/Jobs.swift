// Background jobs. The page starts an action (/api/run) and polls /api/jobs/<id>, like on Windows.
import Foundation

final class Job {
    let id: String
    let name: String
    var status = "running"       // running | done | error | cancelled
    var progress = -1
    var statusText = ""
    var result: Any = NSNull()
    var error = ""
    private var cancelled = false
    private let lock = NSLock()

    init(id: String, name: String) { self.id = id; self.name = name }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); Log.write("Stopping: \(name)", "WARN") }
    func report(_ pct: Int, _ text: String = "") { lock.lock(); progress = pct; statusText = text; lock.unlock() }

    func dto(light: Bool = false) -> JSON {
        lock.lock(); defer { lock.unlock() }
        var d: JSON = ["id": id, "name": name, "status": status, "progress": progress, "statusText": statusText]
        if !light { d["result"] = result; d["error"] = error }
        return d
    }
    func finish(_ r: Any) { lock.lock(); result = r; status = cancelled ? "cancelled" : "done"; lock.unlock() }
    func fail(_ e: String) { lock.lock(); error = e; status = "error"; lock.unlock() }
}

struct CleanITError: Error, LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

enum Jobs {
    private static var jobs: [String: Job] = [:]
    private static let lock = NSLock()
    private static var counter = 0

    static func start(_ name: String, _ work: @escaping (Job) throws -> Any) -> Job {
        lock.lock()
        counter += 1
        let job = Job(id: String(counter), name: name)
        jobs[job.id] = job
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            Log.write("\(name)...")
            do { job.finish(try work(job)) }
            catch { job.fail(error.localizedDescription); Log.write("\(name) failed: \(error.localizedDescription)", "ERROR") }
        }
        return job
    }
    static func get(_ id: String) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs[id] }
    static func running() -> [JSON] {
        lock.lock(); defer { lock.unlock() }
        return jobs.values.filter { $0.status == "running" }.sorted { Int($0.id)! < Int($1.id)! }.map { $0.dto(light: true) }
    }
    static var anyRunning: Bool { !running().isEmpty }
}
