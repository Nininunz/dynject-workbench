// Sweep: steps NotchDemo through status item and menu counts at several paddings and checks, from MenuBarAgent's own
// frames (`dw inspect MenuBarAgent --tree`), that nothing visible enters the padded notch: no menu, no status item,
// no ». It also says whether anything overlaps Clerestory's notch window, when that's on screen. Live: it changes the
// tweak's setting and the demo's items, and puts the setting back at the end.
//
//   ../build.sh sweep [paddings…]      default 0 20 40
import AppKit
import notify

setvbuf(stdout, nil, _IOLBF, 0)

let demoID = "local.dynject.notchpadding.demo"
let settingsKey = "dynject.tweak.local.dynject.notchpadding" as CFString
let dw = ProcessInfo.processInfo.environment["DW"] ?? "dw"
let demoApp = CommandLine.arguments[1]
let paddings = CommandLine.arguments.dropFirst(2).compactMap { Int($0) }.isEmpty ? [0, 20, 40]
                                                                                    : CommandLine.arguments.dropFirst(2).compactMap { Int($0) }

func run(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func which(_ name: String) -> String {
    if name.contains("/") { return name }
    return run("/usr/bin/which", [name]).trimmingCharacters(in: .whitespacesAndNewlines)
}

// The real notch, from this process (no tweak here).
guard let screen = NSScreen.screens.first, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
    print("no notch on the main display: nothing to sweep"); exit(0)
}
let notchL = Double(left.maxX), notchR = Double(right.minX)

// Clerestory's notch window, if it's there: the black wings beside the notch.
func clerestoryWing() -> (Double, Double)? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w[kCGWindowOwnerName as String] as? String) == "Clerestory" {
        guard let b = w[kCGWindowBounds as String] as? [String: Double], let x = b["X"], let y = b["Y"], let wd = b["Width"],
              y < 1, x < notchL, x + wd > notchR else { continue }
        return (x, x + wd)
    }
    return nil
}

// MARK: the menu bar, as MenuBarAgent lays it out

enum Kind { case item, overflow, menu }
struct Box { var x: Double; var w: Double; var id: String; var kind: Kind; var maxX: Double { x + w } }
struct Bar { var window: String; var boxes: [Box] }

let frameRE = try! NSRegularExpression(pattern: #"frame=(-?[0-9.]+),(-?[0-9.]+) ([0-9.]+)x([0-9.]+)"#)
func frame(_ line: String) -> (Double, Double)? {
    guard let m = frameRE.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let x = Range(m.range(at: 1), in: line), let w = Range(m.range(at: 3), in: line) else { return nil }
    return (Double(line[x]) ?? 0, Double(line[w]) ?? 0)
}

func readBars() -> [Bar] {
    var bars: [Bar] = []
    var originX = 0.0
    for line in run(which(dw), ["inspect", "MenuBarAgent", "--tree"]).components(separatedBy: "\n") {
        if line.hasPrefix("window ") {
            guard line.contains("DisplayItemAppKitWindow") else { originX = .nan; continue }
            originX = frame(line)?.0 ?? 0
            bars.append(Bar(window: String(line.split(separator: " ")[1]), boxes: []))
            continue
        }
        guard !originX.isNaN, !bars.isEmpty else { continue }
        if line.contains("SceneHostDisplayItemContainerView frame="), let f = frame(line) {
            bars[bars.count - 1].boxes.append(Box(x: originX + f.0, w: f.1, id: "", kind: .item))
        } else if line.contains("ax=menu-bar-overflow-indicator "), let f = frame(line) {
            bars[bars.count - 1].boxes.append(Box(x: originX + f.0, w: f.1, id: "»", kind: .overflow))
        } else if line.contains("AppMenuItemView frame="), let f = frame(line) {
            bars[bars.count - 1].boxes.append(Box(x: originX + f.0, w: f.1, id: "menu", kind: .menu))
        } else if let r = line.range(of: " ax="), let last = bars.last?.boxes.last, last.kind == .item, last.id.isEmpty {
            let id = line[r.upperBound...].prefix { $0 != " " }
            bars[bars.count - 1].boxes[bars[bars.count - 1].boxes.count - 1].id = String(id)
        }
    }
    return bars
}

/// What's drawn: menus, the », and the status items that aren't stacked behind the » (hidden ones end where it ends).
func visible(_ bar: Bar) -> [Box] {
    let overflow = bar.boxes.first { $0.kind == .overflow }
    return bar.boxes.filter { b in
        guard b.kind == .item, let o = overflow else { return true }
        return abs(b.maxX - o.maxX) > 0.6
    }.map { b in var b = b; if b.kind == .item && b.id.isEmpty { b.id = "demo icon" }; return b }
}

// MARK: driving the demo and the setting

func post(_ name: String, state: UInt64) {
    var token: Int32 = 0
    guard notify_register_check(name, &token) == UInt32(NOTIFY_STATUS_OK) else { return }
    notify_set_state(token, state)
    notify_post(name)
    notify_cancel(token)
}

func setDemo(items: Int, menus: Int, padding: Int? = nil) {
    let code = padding.map { UInt64($0 < 0 ? 255 : min($0, 200) + 1) } ?? 0
    post("local.dynject.notchpadding.demo.set", state: UInt64(items) | UInt64(menus) << 8 | code << 16)
}

func demoRunning() -> NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: demoID).first }

func bringDemoForward() {
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == demoID { return }
    _ = run("/usr/bin/open", [demoApp])
    usleep(600_000)
}

let savedSettings = CFPreferencesCopyValue(settingsKey, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
func restore() {
    CFPreferencesSetValue(settingsKey, savedSettings, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    post("dynject.tweak.local.dynject.notchpadding.changed", state: 0)
    setDemo(items: 14, menus: 14)
}
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
sigint.setEventHandler { restore(); print("\ninterrupted: setting put back"); exit(130) }
sigint.resume()

// MARK: the sweep

if demoRunning() == nil {
    _ = run("/usr/bin/open", [demoApp])
    for _ in 0..<50 where demoRunning() == nil { usleep(100_000) }
    sleep(2)
}
guard demoRunning() != nil else { print("NotchDemo didn't start (\(demoApp))"); exit(1) }

print(String(format: "real notch %.1f–%.1f; Clerestory's notch window %@", notchL, notchR,
             clerestoryWing().map { String(format: "%.1f–%.1f", $0.0, $0.1) } ?? "not on screen"))

/// Sets the step and waits until MenuBarAgent shows it: as many demo icons (no accessibility id) as asked, and the demo's
/// menus (plus the apple and app menus) in one of the bars.
func step(items: Int, menus: Int, padding: Int?) -> [Bar] {
    setDemo(items: items, menus: menus, padding: padding)
    usleep(700_000)
    var bars: [Bar] = []
    for _ in 0..<6 {
        bars = readBars()
        let icons = bars.first.map { $0.boxes.filter { $0.kind == .item && $0.id.isEmpty }.count } ?? -1
        let menusShown = bars.contains { $0.boxes.filter { $0.kind == .menu }.count == menus + 2 }
        if icons == items && menusShown { return bars }
        if !menusShown { bringDemoForward() }
        usleep(500_000)
    }
    print("    (MenuBarAgent didn't settle on \(items) icons / \(menus) menus; checked what it showed)")
    return bars
}

struct Worst { var right = Double.infinity, left = Double.infinity, wingHits = 0, steps = 0, failures = 0 }
var totals: [(Int, Worst)] = []

bringDemoForward()
for padding in paddings {
    let zoneL = notchL - Double(padding), zoneR = notchR + Double(padding)
    print(String(format: "\npadding %d: nothing may be drawn between %.1f and %.1f", padding, zoneL, zoneR))
    var worst = Worst()
    let steps = (0...20).map { (items: $0, menus: 3) } + (0...24).map { (items: 14, menus: $0) }
    for (n, s) in steps.enumerated() {
        let bars = step(items: s.items, menus: s.menus, padding: n == 0 ? padding : nil)
        let wing = clerestoryWing()
        var problems: [String] = [], wingHits: [String] = []
        var right = Double.infinity, left = Double.infinity
        for bar in bars {
            for b in visible(bar) {
                if b.x < zoneR - 0.5 && b.maxX > zoneL + 0.5 {
                    problems.append(String(format: "%@ at %.1f–%.1f (window %@)", b.id, b.x, b.maxX, bar.window))
                }
                if let w = wing, b.x < w.1 - 0.5 && b.maxX > w.0 + 0.5 {
                    wingHits.append(String(format: "%@ at %.1f–%.1f", b.id, b.x, b.maxX))
                }
                if b.x >= zoneR - 0.5 { right = min(right, b.x - zoneR) }
                if b.maxX <= zoneL + 0.5 { left = min(left, zoneL - b.maxX) }
            }
        }
        worst.steps += 1
        worst.right = min(worst.right, right)
        worst.left = min(worst.left, left)
        if !wingHits.isEmpty { worst.wingHits += 1 }
        let gaps = String(format: "gap left %@ right %@", left.isFinite ? String(format: "%.1f", left) : "-",
                          right.isFinite ? String(format: "%.1f", right) : "-")
        if problems.isEmpty {
            print(String(format: "  %2d icons %2d menus  ok    %@%@", s.items, s.menus, gaps,
                         wingHits.isEmpty ? "" : "   under Clerestory: " + Set(wingHits).sorted().joined(separator: ", ")))
        } else {
            worst.failures += 1
            print(String(format: "  %2d icons %2d menus  FAIL  %@", s.items, s.menus, Set(problems).sorted().joined(separator: "; ")))
        }
    }
    totals.append((padding, worst))
}

restore()
print("\nsummary (gaps are from the padded notch; setting put back, demo at 14 icons / 14 menus)")
var failed = false
for (padding, w) in totals {
    failed = failed || w.failures > 0
    print(String(format: "  padding %3d: %d steps, %d failed, closest left %.1f, closest right %.1f, under Clerestory in %d",
                 padding, w.steps, w.failures, w.left, w.right, w.wingHits))
}
exit(failed ? 1 : 0)
