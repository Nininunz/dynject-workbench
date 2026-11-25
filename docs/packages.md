# Tweak packages (design, not built)

Status, 2026-11-25: proposal. Nothing here is built yet. It builds on install approval (docs/install-approval.md),
which is done.

## Why

Today a tweak is installed from a folder on this Mac, built from source with its `build.sh`. To install someone
else's tweak, you'd need its source and a working toolchain, and you'd still be trusting whatever the source does.
A package is one file you can pass around: the built dylib, its manifest, and what else it needs. Installing it
goes through the same reviewed, one-prompt install as a folder.

Before that's safe, these need to be true:

- opening a package can't write outside a private staging folder, however the archive is built.
- the review says what's claimed (name, author, version) and what's checked (signer, hash, architectures).
- it also says what the tweak can do on this Mac, beyond loading into the apps you pick: settings commands,
  Apple-menu actions, app extensions, bridge capabilities.
- installing a package records where it came from, so `dw tweak list` and doctor can say so later.

What this doesn't do: it doesn't make a tweak safe to run. A tweak's dylib runs inside every app you enable it for,
with everything that app can reach: its files, its keychain items, and its privacy permissions (Messages' messages,
Mail's mail). The review and approval only make sure you install the build you looked at.

Packages also skip Gatekeeper. The install helper writes each file's bytes without its extended attributes, so the
installed dylib carries no quarantine attribute, and Gatekeeper never assesses it. Workbench's review is the only
check a package gets. (The VM test confirms that a dylib from a quarantined package loads.)

## The format

A `.dwtweak` file is a zip of one folder, laid out like a built tweak folder:

    MyTweak/
      MyTweak.workbench.plist
      build/libMyTweak.dylib
      build/MyTweak.app          (only with extensionsApp)
      README.md, LICENSE         (optional, shown in the review)

So a package unpacks into something `dw tweak install <folder>` already understands. Nothing else is read from it.

`dw tweak pack <folder>` makes one from a built tweak folder. It checks the manifest, a `version`, and a dylib with
an arm64e slice that's signed. It writes `<id>-<version>.dwtweak` without resource forks, extended attributes or
quarantine, and prints its SHA-256.

## Opening a package

1. **List before extracting.** Read the zip's entries (`zipinfo`), and refuse the package on any of these:
   - an absolute path, `..`, or a name that isn't valid UTF-8;
   - more than one top-level folder;
   - a symbolic link or a device file;
   - more than 500 entries, or more than 200 MB uncompressed.
2. **Extract** with `ditto -x -k --norsrc --noqtn` into a new 0700 folder under
   `~/Library/Caches/Dynject Workbench/Packages/<package sha256>/`.
3. **Walk what came out** with `lstat`: regular files and folders only, all inside the staging folder. Anything else
   refuses the package.
4. **Locate and plan** it as a folder: the dylib checks, version, `depends`, signer, the approval line. The plan
   gets a package section on top.

The staging folder is deleted after the install, or when the review is cancelled.

## The review

The plan for a package adds:

- **The file:** name, SHA-256, and where it came from. That's the download URL in its `kMDItemWhereFroms`, and the
  app that downloaded it, from its quarantine attribute, when the file has them.
- **Claims, marked unverified:** name, identifier, author, version, summary. Any package can claim any of them.
- **Checked:**
  - the signer: Team ID, ad-hoc or unsigned;
  - architectures;
  - the dylib's SHA-256, which becomes its approval;
  - the apps the dylib's `DH_CTOR` names, next to the apps you enable it for.
- **What else it can do:**
  - `applyCommand`: the program and arguments it would run each time you change a setting.
  - Apple-menu actions that leave the menu (`url:`, `shortcut:`, `app:`), with their targets.
  - `extensionsApp`: the app extensions it registers, and where they run (System Settings, for SettingsLoader).
  - `bridge` capabilities.
  - `depends`.

Policy for packages, which installs from your own folders don't need:

- **`applyCommand` is refused** unless you pass `--allow-apply-command`. It runs a program as you, from
  Workbench, outside the apps you picked.
- **A signer change on update is refused** unless you pass `--allow-signer-change`. Today it's only a warning. An
  ad-hoc package can't be matched to an earlier build at all, so the review says so ("can't tell who built it")
  every time.
- A `url:` action that opens `dynject-workbench://` or another app's URL scheme is listed as a warning.

## Where it came from

The install writes `<id>.origin.plist` next to the installed manifest in Workbench's Tweaks folder. It holds the
package's file name and SHA-256, its download URL if known, the signer, and the install date.

- `dw tweak list` shows "from package <file> (sha256 …), <signer>", or "from <folder>" for local builds.
- `dw doctor` notes a packaged tweak whose installed dylib no longer matches its approval. That's the same check as
  today, with the package named.
- Uninstall removes the origin file.

## Workbench

- **Install Tweak…** accepts a `.dwtweak` as well as a folder.
- Later: a document type, so double-clicking a package opens the review, and dropping one on the Tweaks page.

## Milestones

1. `dw tweak pack`, and `dw tweak install <file.dwtweak>` with every check above, the review section and the origin
   file. Tests with crafted bad zips: `..` paths, an absolute path, a symlink, two top-level folders, too many
   entries, an oversized member.
2. Workbench: the sheet accepts packages and shows the package section.
3. VM test:
   - pack a tweak, then mark the file as downloaded (`xattr -w com.apple.quarantine`, `kMDItemWhereFroms`);
   - install it, and confirm it loads, its approval matches, and the origin shows in `dw tweak list`;
   - try an update signed by someone else, and confirm it's refused.
4. Later: double-click and drag-and-drop, a repository format, and update checks.

## Open questions

- **The extension name.** `.dwtweak` is short and unclaimed, but a name that says Dynject may read better to
  someone receiving one.
- **Requiring signed packages.** Most hobby tweaks will be ad-hoc, so requiring a Team ID would rule nearly all of
  them out. This proposal shows the signer plainly instead, and refuses only a signer change.
- **Hashing the package.** A package could carry a checksum file for its contents. The zip's own SHA-256, shown in
  the review and recorded, already does that job, so this proposal leaves it out.
