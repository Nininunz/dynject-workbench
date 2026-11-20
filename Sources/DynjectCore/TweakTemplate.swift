import Foundation

// `dw new`: a ready-to-build tweak folder with the SDK vendored in, so it builds on its own.

/// The three SDK files a tweak compiles in.
public struct TweakSDKFiles: Equatable, Sendable {
    public var hookHeader: URL     // DynjectHook.h
    public var hookSource: URL     // DynjectHook.m
    public var tweakHeader: URL    // DynjectTweak.h

    /// `dir` laid out as in the app bundle (all three files flat) or as in the repository (headers in include/).
    public static func at(_ dir: URL) -> TweakSDKFiles? {
        let fm = FileManager.default
        for headers in [dir, dir.appendingPathComponent("include")] {
            let f = TweakSDKFiles(hookHeader: headers.appendingPathComponent("DynjectHook.h"),
                                  hookSource: dir.appendingPathComponent("DynjectHook.m"),
                                  tweakHeader: headers.appendingPathComponent("DynjectTweak.h"))
            if [f.hookHeader, f.hookSource, f.tweakHeader].allSatisfy({ fm.fileExists(atPath: $0.path) }) { return f }
        }
        return nil
    }

    /// Finds the SDK for the `dw` at `executable`: Contents/Resources/TweakSDK in the app bundle (scripts/build-app.sh
    /// copies it there), or the repository's TweakSDK/ above a SwiftPM build folder (.build/<triple>/<config>/dw).
    public static func locate(executable: URL) -> TweakSDKFiles? {
        let path = realpath(executable.path, nil).map { p -> String in defer { free(p) }; return String(cString: p) } ?? executable.path
        let exeDir = URL(fileURLWithPath: path).deletingLastPathComponent()
        if let f = at(exeDir.deletingLastPathComponent().appendingPathComponent("Resources/TweakSDK")) { return f }
        var dir = exeDir
        for _ in 0..<6 {
            if let f = at(dir.appendingPathComponent("TweakSDK")) { return f }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}

public struct TweakTemplate: Sendable {
    public var name: String
    public var identifier: String
    /// Restricts the tweak to one app (DH_CTOR's bundle filter); nil = every app the config injects it into.
    public var bundleID: String?

    public init(name: String, identifier: String? = nil, bundleID: String? = nil) throws {
        guard name.range(of: "^[A-Za-z][A-Za-z0-9]{0,63}$", options: .regularExpression) != nil else {
            throw TweakInstallError.refused("The name must start with a letter and contain only letters and digits (it names the dylib and an Objective-C class), e.g. WindowTitles.")
        }
        let id = identifier ?? "local.\(name.lowercased())"
        guard id.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,127}$", options: .regularExpression) != nil else {
            throw TweakInstallError.refused("The identifier must be reverse-DNS: letters, digits, dots and hyphens (e.g. com.you.\(name.lowercased())).")
        }
        if let bundleID, bundleID.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$", options: .regularExpression) == nil {
            throw TweakInstallError.refused("\(bundleID) is not a bundle ID.")
        }
        self.name = name
        self.identifier = id
        self.bundleID = bundleID
    }

    public var dylibName: String { "lib\(name).dylib" }
    public var installPath: String { TweakLocations.liveTweaksDirectory + "/" + dylibName }
    public static let sdkFolder = "sdk"

    /// Creates the folder (it must not exist or be empty). Returns the files written, relative to `dir`.
    @discardableResult
    public func write(to dir: URL, sdk: TweakSDKFiles) throws -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
            guard isDir.boolValue, ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["?"]).isEmpty else {
                throw TweakInstallError.refused("\(dir.path) already exists; choose another name or --dir.")
            }
        }
        try fm.createDirectory(at: dir.appendingPathComponent(Self.sdkFolder), withIntermediateDirectories: true)
        var written: [String] = []
        for (file, text) in files {
            try Data(text.utf8).write(to: dir.appendingPathComponent(file), options: .withoutOverwriting)
            written.append(file)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("build.sh").path)
        for src in [sdk.hookHeader, sdk.hookSource, sdk.tweakHeader] {
            let rel = Self.sdkFolder + "/" + src.lastPathComponent
            try fm.copyItem(at: src, to: dir.appendingPathComponent(rel))
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent(rel).path)
            written.append(rel)
        }
        return written
    }

    /// File name → contents (the SDK copies are added by `write`).
    public var files: [(String, String)] {
        [("\(name).m", source), ("\(name)\(TweakManifest.fileSuffix)", manifest), ("build.sh", buildScript),
         ("README.md", readme), (".gitignore", "build/\n")]
    }

    var appForDocs: String { bundleID ?? "com.apple.TextEdit" }

    public var source: String {
        let ctor = bundleID.map { "DH_CTOR(TWEAK_ID_C, \"\($0)\") {   // loads only in \($0), even if the config injects it elsewhere" }
            ?? "DH_CTOR(TWEAK_ID_C) {   // every app the config injects it into; add bundle IDs to narrow it down"
        return """
        // \(name): a Dynject tweak (made with `dw new`).
        //
        // Appends " [\(name)]" to window titles\(bundleID.map { " in \($0)" } ?? ""): an example DynjectHook hook class.
        // The "enabled" switch in Dynject Workbench turns the hook on and off while the app runs.
        //
        //   ./build.sh                                        build/\(dylibName)
        //   dw tweak install . --for \(appForDocs)    install, enable for that app, restart dynjectd
        //   dw respring                                       relaunch apps so they load it
        //   log stream --level default --predicate 'subsystem == "\(identifier)"'
        #import <AppKit/AppKit.h>
        #import <os/log.h>
        #import "DynjectHook.h"
        #import "DynjectTweak.h"

        #define TWEAK_ID_C "\(identifier)"
        #define TWEAK_ID @TWEAK_ID_C

        /// The hooks the "enabled" switch controls.
        static DHGroup *gMain;

        static os_log_t TweakLog(void) {
            static os_log_t log;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ log = os_log_create(TWEAK_ID_C, "tweak"); });
            return log;
        }

        // A hook class is never instantiated: DHHookClass installs its methods on NSWindow, so `self` is the window.
        // Class names are global in a process, so the name starts with the tweak's own.
        @interface \(name)_NSWindowHook : NSObject
        @end

        @implementation \(name)_NSWindowHook
        - (void)setTitle:(NSString *)title {
            NSString *suffix = @" [\(name)]";
            // A disabled group's hook can stay installed (when another tweak hooked on top), so check the group and
            // otherwise pass straight through.
            if (DHGroupIsEnabled(gMain) && title.length && ![title hasSuffix:suffix]) {
                title = [title stringByAppendingString:suffix];
            }
            DH_ORIG(void (*)(id, SEL, NSString *), title);   // the exact type of -[NSWindow setTitle:]
        }
        @end

        /// Reads the settings Workbench publishes (DynjectTweak.h) and applies them.
        static void ApplySettings(NSString *reason) {
            BOOL enabled = DTPrefBool(TWEAK_ID, @"enabled", YES);
            DHGroupSetEnabled(gMain, enabled);
            os_log(TweakLog(), "%{public}@: enabled=%d", reason, enabled);
        }

        // Runs when the dylib loads, before main(), unless Safe Mode or Shift-at-launch says to skip this tweak.
        \(ctor)
            gMain = DHGroupCreate("main");
            DHGroupSetEnabled(gMain, DTPrefBool(TWEAK_ID, @"enabled", YES));   // set the state before installing hooks
            NSUInteger hooked = DHHookClass([\(name)_NSWindowHook class], DHClass("NSWindow"), gMain);
            os_log(TweakLog(), "loaded into %{public}@ (%lu method(s) hooked)",
                   [[NSBundle mainBundle] bundleIdentifier] ?: @"(no bundle ID)", (unsigned long)hooked);
            // Workbench posts this after every change to the tweak's settings (the manifest says takesEffect: live).
            DTPrefObserve(TWEAK_ID, nil, ^{ ApplySettings(@"settings changed"); });
        }

        """
    }

    public var manifest: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>formatVersion</key><integer>1</integer>
        \t<key>identifier</key><string>\(identifier)</string>
        \t<key>name</key><string>\(name)</string>
        \t<key>summary</key><string>Appends [\(name)] to window titles.</string>
        \t<key>version</key><string>0.1</string>
        \t<key>dylib</key><string>\(installPath)</string>
        \t<key>takesEffect</key><string>live</string>
        \t<key>sections</key>
        \t<array>
        \t\t<dict>
        \t\t\t<key>title</key><string>General</string>
        \t\t\t<key>items</key>
        \t\t\t<array>
        \t\t\t\t<dict>
        \t\t\t\t\t<key>type</key><string>switch</string>
        \t\t\t\t\t<key>key</key><string>enabled</string>
        \t\t\t\t\t<key>title</key><string>Enabled</string>
        \t\t\t\t\t<key>default</key><true/>
        \t\t\t\t\t<key>perApp</key><true/>
        \t\t\t\t\t<key>footer</key><string>Takes effect for titles set from now on.</string>
        \t\t\t\t</dict>
        \t\t\t</array>
        \t\t</dict>
        \t</array>
        </dict>
        </plist>

        """
    }

    public var buildScript: String {
        """
        #!/bin/sh
        # Builds build/\(dylibName): x86_64 + arm64 + arm64e, no exported symbols, signed ad-hoc (or with
        # SIGN_IDENTITY="Apple Development: …"). The SDK is vendored in sdk/, so this folder builds on its own.
        set -eu
        DIR=$(cd "$(dirname "$0")" && pwd)
        OUT="$DIR/build"
        SDK=$(xcrun --show-sdk-path)
        CC=$(xcrun -find clang)
        mkdir -p "$OUT"

        # DynjectHook.m is compiled in (hooks, DH_CTOR's Safe Mode check); with -fvisibility=hidden nothing is exported,
        # so several tweaks in one app don't clash.
        "$CC" -Wall -Wextra -O2 -fobjc-arc -fvisibility=hidden -isysroot "$SDK" -I "$DIR/sdk" \\
          -mmacosx-version-min=14.0 -arch x86_64 -arch arm64 -arch arm64e -dynamiclib \\
          -install_name @rpath/\(dylibName) \\
          -framework AppKit -framework Foundation -framework CoreGraphics \\
          "$DIR/\(name).m" "$DIR/sdk/DynjectHook.m" -o "$OUT/\(dylibName)"
        if [ "${SIGN_IDENTITY:--}" = "-" ]; then codesign --force --sign - --timestamp=none "$OUT/\(dylibName)"
        else codesign --force --sign "$SIGN_IDENTITY" --timestamp "$OUT/\(dylibName)"; fi

        exported=$(nm -gU "$OUT/\(dylibName)" 2>/dev/null | grep -cv -e '^$' -e ':$' || true)
        echo "Built $OUT/\(dylibName) ($(lipo -archs "$OUT/\(dylibName)"); exported symbols: $exported)"
        [ "$exported" = 0 ] || { nm -gU "$OUT/\(dylibName)"; echo "error: exported symbols" >&2; exit 1; }

        """
    }

    public var readme: String {
        let scope = bundleID.map { "in \($0) (the bundle filter in `DH_CTOR`)" } ?? "in every app the config injects it into"
        return """
        # \(name)

        A Dynject tweak made with `dw new`. It appends " [\(name)]" to window titles \(scope), using a DynjectHook
        hook class on `-[NSWindow setTitle:]`, and has one setting, **Enabled**, which Dynject Workbench shows on its
        Tweaks page and which takes effect while the app runs.

        built with dynject-workbench's sdk: free and noncommercial; don't sell tweaks built with it.

        | File | |
        | --- | --- |
        | `\(name).m` | The tweak: `DH_CTOR` entry point, the hook class, settings through `DTPrefBool`/`DTPrefObserve`. |
        | `\(name).workbench.plist` | Manifest: identifier `\(identifier)`, install path `\(installPath)`, the settings page. |
        | `build.sh` | Builds `build/\(dylibName)` (x86_64, arm64, arm64e; ad-hoc signed unless `SIGN_IDENTITY` is set). |
        | `sdk/` | Copies of DynjectHook.h, DynjectHook.m and DynjectTweak.h, so the folder builds on its own. |

        ## Build

        ```sh
        ./build.sh
        SIGN_IDENTITY="Apple Development: Jane Doe (ABCDE12345)" ./build.sh   # with your own certificate
        ```

        ## Install

        ```sh
        dw tweak install . --for \(appForDocs)
        ```

        This copies the dylib to `\(installPath)`, declares it in `/opt/dynject/etc/dynjectd.conf` (deny by
        default), enables it for that app, restarts dynjectd (one password prompt for all of it) and copies the
        manifest into `~/Library/Application Support/Dynject Workbench/Tweaks/`. `--dry-run` shows the plan without
        changing anything. After a rebuild, run the same command again: it replaces the dylib (the old one is backed up).

        Dynject injects only at launch, so relaunch the app:

        ```sh
        dw respring                 # relaunches running apps whose tweaks are out of date
        ```

        (or Workbench → Respring…). To turn it on for more apps, use Workbench's Apps & Injection page or
        `dw enable \(installPath) <bundleID>`.

        ## Logs

        ```sh
        log stream --level default --predicate 'subsystem == "\(identifier)"'
        dw log \(identifier) 10      # the last 10 minutes
        ```

        DynjectHook logs to the same subsystem with the category `hook`.

        ## Uninstall

        ```sh
        dw tweak uninstall \(identifier)
        ```

        ## Next steps

        In the Dynject Workbench repository: `docs/hooking.md` (hook classes, `DH_ORIG`, groups, the ABI rule for
        calling originals) and `docs/tweak-format.md` (every kind of setting, per-app overrides, Apple-menu items).
        If you crash an app, Safe Mode switches the tweak off for it; hold Shift while launching an app to skip
        tweaks for that launch.

        """
    }
}
