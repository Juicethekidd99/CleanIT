// Entry point. With no switches CleanIT opens its window; switches run it from Terminal or the weekly LaunchAgent.
//
//   CleanIT --scan                      reclaimable space (default categories)
//   CleanIT --clean                     clean the default categories
//   CleanIT --clean --categories UserCaches,BrowserCache
//   CleanIT --list-categories
//   CleanIT --report                    health + security report
//   CleanIT --startup                   list startup items (add --all for Apple ones)
//   CleanIT --updates                   update Homebrew apps/tools (honours the "never update" list)
//   CleanIT --fleet                     write this Mac's report to the fleet folder now
//   CleanIT --performance               turn on the recommended performance settings (reversible)
//   CleanIT --undo-performance          put every performance setting CleanIT changed back
//   --silent: no questions, no output except errors; --scheduled: marks the run as the weekly clean and notifies.
import AppKit

Paths.ensure()
let args = Array(CommandLine.arguments.dropFirst())
func has(_ s: String) -> Bool { args.contains(s) }
func value(_ s: String) -> String? { args.firstIndex(of: s).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

if let dir = value("--make-icon") { Icon.write(to: dir); exit(0) }

let cli = ["--scan", "--clean", "--list-categories", "--report", "--updates", "--startup", "--fleet", "--performance", "--undo-performance"].contains { has($0) }
if cli {
    Log.echo = !has("--silent")
    let keys = value("--categories").map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
        ?? Clean.defs.filter { $0.isDefault }.map { $0.key }
    let unknown = keys.filter { k in !Clean.defs.contains { $0.key == k } }
    if !unknown.isEmpty { print("Unknown categories: \(unknown.joined(separator: ", ")) - see --list-categories"); exit(2) }

    if has("--list-categories") {
        for c in Clean.defs { print("\(c.key.padding(toLength: 20, withPad: " ", startingAt: 0)) \(c.isDefault ? "on " : "off") \(c.group.padding(toLength: 10, withPad: " ", startingAt: 0)) \(c.name)") }
    }
    if has("--scan") {
        var total: Int64 = 0
        for r in Clean.scan(keys) {
            let s = i64(r["Size"]); total += max(0, s)
            print("\((r["Key"] as! String).padding(toLength: 20, withPad: " ", startingAt: 0)) \(s < 0 ? "no access" : fmtSize(s))" + ((r["Running"] as? String).map { "  (open: \($0))" } ?? ""))
        }
        print("Total: \(fmtSize(total))")
    }
    if has("--clean") {
        let r = Clean.clean(keys, scheduled: has("--scheduled"))
        if has("--scheduled") { notify("CleanIT weekly clean", "Freed \(fmtSize(i64(r["Freed"]))).") }
    }
    if has("--updates") {
        let job = Job(id: "cli", name: "updates")
        if let items = try? Updates.brewList(job: job) {
            let excl = Set((Settings.load()["BrewExclude"] as? [String]) ?? [])
            try? Updates.brewUpgrade(items.map { $0["Id"] as! String }.filter { !excl.contains($0) }, job: job)
        }
    }
    if has("--startup") {
        for i in Startup.list(includeApple: has("--all")) {
            print("\((i["Enabled"] as! Bool) ? "on " : "off") \((i["Kind"] as! String).padding(toLength: 10, withPad: " ", startingAt: 0)) \((i["Name"] as! String).padding(toLength: 28, withPad: " ", startingAt: 0)) \(i["Publisher"]!)")
        }
    }
    if has("--performance") {
        let todo = Perf.items.filter { $0.recommended && $0.available() && !$0.isOn }.map { ["key": $0.key, "on": true] as JSON }
        do { try Perf.apply(todo); print("\(todo.count) setting(s) turned on.") } catch { print(error.localizedDescription); exit(1) }
    }
    if has("--undo-performance") {
        do { try Perf.restoreAll() } catch { print(error.localizedDescription); exit(1) }
    }
    if has("--clean") || has("--fleet") { Fleet.writeReport(wait: 120) }
    if has("--report") {
        print(Health.report()); print("")
        print("SECURITY")
        for s in Security.checks() { print("  [\(s["Level"]!)] \(s["Name"]!): \(s["Detail"]!)") }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
