// A tiny AppKit app for the respring end-to-end test (scripts/respring-e2e.sh). Built twice with different
// Info.plists:
//   RespringE2EQuitDelay = 0   quits at once
//   RespringE2EQuitDelay = N   answers "quit" with NSTerminateLater and only quits N seconds later (an app showing
//                              a save dialog), so the engine's timeout/skip path runs against a real process.
import AppKit

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    let delay = (Bundle.main.object(forInfoDictionaryKey: "RespringE2EQuitDelay") as? NSNumber)?.doubleValue ?? 0

    func applicationDidFinishLaunching(_ n: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 280, height: 60), styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.title = "\(ProcessInfo.processInfo.processName) \(getpid())"
        w.orderFront(nil)
        window = w
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard delay > 0 else { return .terminateNow }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
