// Weekly automatic clean through a per-user LaunchAgent. launchd runs a missed run when the Mac wakes up.
import Foundation

enum Schedule {
    static let label = "io.github.juicethekidd99.cleanit.weekly"
    static var plist: String { Paths.library + "/LaunchAgents/\(label).plist" }
    static let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static var isOn: Bool { FS.exists(plist) }

    static func save(enabled: Bool, day: String, time: String, updates: Bool) throws {
        Settings.patch(["ScheduleDay": day, "ScheduleTime": time, "ScheduleUpdates": updates])
        sh("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        if !enabled {
            try? FileManager.default.removeItem(atPath: plist)
            Log.write("Weekly clean turned off.", "OK")
            return
        }
        guard let exe = Bundle.main.executablePath else { throw CleanITError("Can't find CleanIT's own program file.") }
        if exe.contains("/AppTranslocation/") || exe.hasPrefix("/Volumes/") {
            throw CleanITError("Move CleanIT into your Applications folder first, then turn on the weekly clean.")
        }
        let hm = time.split(separator: ":").compactMap { Int($0) }
        var args = [exe, "--clean", "--silent", "--scheduled"]
        if updates { args.append("--updates") }
        let d: NSDictionary = [
            "Label": label, "ProgramArguments": args,
            "StartCalendarInterval": ["Weekday": days.firstIndex(of: day) ?? 0, "Hour": hm.first ?? 11, "Minute": hm.count > 1 ? hm[1] : 0],
            "ProcessType": "Background", "LowPriorityIO": true, "Nice": 10,
            "StandardOutPath": Paths.logDir + "/weekly.log", "StandardErrorPath": Paths.logDir + "/weekly.log"
        ]
        try? FileManager.default.createDirectory(atPath: (plist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard d.write(toFile: plist, atomically: true) else { throw CleanITError("Could not write \(plist)") }
        sh("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist])
        Log.write("Weekly clean scheduled: \(day) at \(time).", "OK")
    }
}
