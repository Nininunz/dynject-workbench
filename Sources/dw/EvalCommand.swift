// `dw eval <app> <path>`: reads a value in a running app through Inspector (Tweaks/Inspector/DYIEval.m). The path goes
// in the global preference "dynject.inspector.eval.<pid>", which a sandboxed app can read but not write; the command
// goes through Inspector's Darwin notification for the pid. Inspector answers at debug level, so values from the app
// are streamed to this command and never kept in the log store.
import DynjectCore
import Foundation

let evalUsage = """
usage: dw eval <app> <path>
       dw eval --pid <pid> <path>

  reads a value in a running app that Inspector is loaded in, background apps too. reads only: each step of the
  path is a declared property (read with its getter), never an arbitrary method.

    NSApp | app | <ClassName>      where the path starts
    .property                      a declared @property; on a class, a class property (NSScreen.mainScreen)
    [n]  .n                        an element of an array
    ["key"]  .key                  a value in a dictionary
    @count  @keys  @class          a count, a dictionary's keys, the class name
  a property of the elements, after an array, is read from each element.

  examples:
    dw eval TextEdit NSApp.windows.title
    dw eval TextEdit 'NSApp.windows[0].frame'
    dw eval MenuBarAgent NSScreen.mainScreen.frame
    dw eval Finder NSApp.mainMenu.itemArray.title
"""

func evalCommand(_ args: [String]) {
    var pid: pid_t?
    var positional: [String] = []
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--pid":
            guard i + 1 < args.count, let p = pid_t(args[i + 1]) else { fail("--pid needs a number\n\n\(evalUsage)", 2) }
            pid = p
            i += 1
        case "--help", "-h", "help": print(evalUsage); exit(0)
        case let a where a.hasPrefix("--"): fail("unknown option \(a)\n\n\(evalUsage)", 2)
        case let a: positional.append(a)
        }
        i += 1
    }
    let wanted = pid == nil ? 2 : 1
    guard positional.count == wanted else { fail(evalUsage, 2) }
    let path = positional.last!
    let app = runningApp(pid == nil ? positional[0] : nil, pid: pid, usage: evalUsage)
    requireInspector(in: app, marker: "dynject.eval:v1", feature: "dw eval")

    let ask = ProcessRequest(pid: app.pid, subsystem: "dynject.inspect", transient: true)
    let key = "dynject.inspector.eval.\(app.pid)" as CFString
    func clear() {
        CFPreferencesSetValue(key, nil, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    let request: [String: Any] = ["request": Int(ask.request), "path": path, "time": Date()]
    CFPreferencesSetValue(key, request as CFDictionary, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    let prefix = "A \(ask.request) "
    ask.post("local.dynject.inspector.command.\(app.pid)", state: 6 | (UInt64(ask.request) << 8))
    ask.wait(prefix: prefix, timeout: 5, quiet: 0.2) { lines in
        lines.contains { $0.hasPrefix(prefix + "end ") || $0.hasPrefix(prefix + "error ") || $0.hasPrefix(prefix + "refused") }
    }
    let answers = ask.finish(prefix: prefix).map { String($0.dropFirst(prefix.count)) }
    clear()
    guard let first = answers.first else {
        fail("no answer from Inspector in \(app.name) (pid \(app.pid)): Safe Mode or Shift at launch may have kept it out (dw why inspector \(app.bundleID))", 1)
    }
    if first.hasPrefix("refused") { fail("Inspector in \(app.name): \(first)", 1) }
    if first.hasPrefix("error ") { fail(String(first.dropFirst("error ".count)), 1) }
    let values = answers.filter { $0.hasPrefix("V ") }.map { String($0.dropFirst(2)) }
    let complete = answers.contains { $0.hasPrefix("end ") }
    print(values.joined(separator: "\n"))
    if !complete { print("(the answer was cut short)") }
}
