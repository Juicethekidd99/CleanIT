// Development helper: sends JavaScript to a running debug CleanIT and asks for a snapshot.
// Usage: swift tools/debug.swift '<js>' /path/out.png [waitSeconds]
import Foundation
let a = CommandLine.arguments
var o: [String: Any] = ["png": a.count > 2 ? a[2] : "/tmp/cleanit.png"]
if a.count > 1 && !a[1].isEmpty { o["js"] = a[1] }
if a.count > 3, let w = Double(a[3]) { o["wait"] = w }
let s = String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
DistributedNotificationCenter.default().postNotificationName(Notification.Name("io.github.juicethekidd99.cleanit.debug"), object: s, userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
