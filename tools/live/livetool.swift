// livetool: the small native pieces behind tools/live/live. Built on first use into .build/live/livetool.
//
//   livetool window <app name or bundle id>          id x y w h of its frontmost on-screen window (points, top-left origin)
//   livetool windows <app name or bundle id>         every on-screen window of the app, one per line
//   livetool warp <x> <y>                            move the pointer to a global point (points, top-left origin)
//   livetool crop <in.png> <out.png> <x> <y> <w> <h> crop in pixels, origin top-left
//   livetool size <png>                              pixel width and height
import AppKit
import CoreGraphics

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data("livetool: \(s)\n".utf8)); exit(1) }

struct Win { let id: Int; let x, y, w, h: Double; let name: String }

func windows(of app: String) -> [Win] {
    let running = NSWorkspace.shared.runningApplications
    let pids = Set(running.filter {
        $0.bundleIdentifier?.caseInsensitiveCompare(app) == .orderedSame
            || $0.localizedName?.caseInsensitiveCompare(app) == .orderedSame
    }.map { Int($0.processIdentifier) })
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w in
        guard let pid = w[kCGWindowOwnerPID as String] as? Int,
              pids.contains(pid) || (w[kCGWindowOwnerName as String] as? String)?.caseInsensitiveCompare(app) == .orderedSame,
              (w[kCGWindowLayer as String] as? Int) == 0,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let id = w[kCGWindowNumber as String] as? Int else { return nil }
        let n = { (k: String) in (b[k] as? NSNumber)?.doubleValue ?? 0 }
        guard n("Width") > 1, n("Height") > 1 else { return nil }
        return Win(id: id, x: n("X"), y: n("Y"), w: n("Width"), h: n("Height"), name: w[kCGWindowName as String] as? String ?? "")
    }
}

func line(_ w: Win) -> String { "\(w.id) \(Int(w.x)) \(Int(w.y)) \(Int(w.w)) \(Int(w.h))" + (w.name.isEmpty ? "" : " \(w.name)") }

let a = Array(CommandLine.arguments.dropFirst())
switch (a.first, a.count) {
case ("window", 2):
    guard let w = windows(of: a[1]).first else { fail("no on-screen window for \(a[1])") }
    print(line(w))
case ("windows", 2):
    let ws = windows(of: a[1])
    if ws.isEmpty { fail("no on-screen window for \(a[1])") }
    ws.forEach { print(line($0)) }
case ("warp", 3):
    guard let x = Double(a[1]), let y = Double(a[2]) else { fail("warp needs numbers") }
    CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
    CGAssociateMouseAndMouseCursorPosition(1)
case ("crop", 7):
    guard let img = NSImage(contentsOfFile: a[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fail("can't read \(a[1])") }
    let v = a[3...6].compactMap { Int($0) }
    guard v.count == 4, let c = img.cropping(to: CGRect(x: v[0], y: v[1], width: v[2], height: v[3])) else { fail("bad crop rect") }
    guard let data = NSBitmapImageRep(cgImage: c).representation(using: .png, properties: [:]) else { fail("can't encode png") }
    do { try data.write(to: URL(fileURLWithPath: a[2])) } catch { fail("\(error.localizedDescription)") }
    print("\(c.width) \(c.height)")
case ("size", 2):
    guard let img = NSImage(contentsOfFile: a[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fail("can't read \(a[1])") }
    print("\(img.width) \(img.height)")
default:
    print("usage: livetool window|windows <app> · warp <x> <y> · crop <in> <out> <x> <y> <w> <h> · size <png>")
    exit(2)
}
