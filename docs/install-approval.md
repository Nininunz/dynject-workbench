# Install approval (design, not built)

Status, 2026-11-25: the first milestone is built and passed in the VM. Engine: the fork's `approval-audit` branch
(dylib-sha256, `dylib-approval:audit|enforce`, order-independent, cached digests). Workbench: installs write
approvals, uninstalls remove them, `dw tweak approve`, and the `dw doctor` check. In the VM, audit mode changed
nothing, `dw tweak approve --all` wrote matching lines, and enforce skipped a replaced file and an unapproved one
while approved ones loaded. On this Mac since 2026-11-25, in audit mode, with all six tweaks approved; `dw why` has the
approval step. Not built yet: the richer approval prompt (signer), an approve button in Workbench, packages, and
switching this Mac to enforce.

## Why

Today a tweak loads if the config has an allow line for its path and the file exists. That's fine while every tweak
is built on this Mac. Before other people's tweaks are installed, these need to be true:

- you approve one build of a tweak, not a path. A different file at that path doesn't load until you approve it.
- installing, updating and removing all go through one privileged step that records the approval with the file.
- `dw why`, `dw doctor` and the Tweaks page say when a tweak won't load because it isn't approved.

What this doesn't do: it doesn't sandbox a tweak once it runs inside an app, and it doesn't defend against someone who
already has root. The fork's README says the same.

## What the engine checks (fork, `safety-audit`)

- `dylib-sha256:<path>:<64 hex>` approves those exact bytes. It must come after that dylib's `dylib:` line.
- With approval on, an allow line alone no longer loads a dylib. A missing or mismatched hash skips it, and the
  log says so.
- `dylib-unsafe-executable:<path>:<executable>` skips the hash for one exact app (testing only).
- The config and every dylib path component must be root-owned, contain no symlinks, and not be writable by group
  or other. Otherwise the daemon refuses the config or skips the dylib.
- dynjectd checks each dylib's hash at every intercepted launch.

## What Workbench would do

### Install and update

The privileged helper already gets the staged file's SHA-256 (`install <target> <staged> <new-sha256> <old|->`). In
the same helper run, the install would:

1. Write `dylib-sha256:<path>:<hash>` right after the dylib's `dylib:` line, replacing any old one for that path.
2. Do this in the same config write as the allow and override lines, before the dynjectd restart that's already
   folded in.

An update writes the new hash in the same step that replaces the file, so there's no window where the file and the
approval disagree.

### Uninstall

Remove the `dylib-sha256` and `dylib-unsafe-executable` lines for the path, along with its other lines. Today the
editor keeps unknown lines verbatim, so without this they would be left behind.

### Approval prompt

The password prompt stays the one approval. Before it, Workbench's plan (`dw tweak install` prints it) gains:

- name, tweak ID and version from the manifest, marked as unverified claims;
- the signer from `codesign` (Team ID, or "ad-hoc" or "unsigned"), which is verified;
- SHA-256 (short) and architectures;
- the apps it will be enabled for, and its `requires`;
- warnings: ad-hoc or unsigned, and a different signer than the installed build.

### Packages, later

A third-party tweak arrives as a folder or zip: a manifest, a dylib, and optionally an `extensionsApp`. It goes
through the same install. A repo format and update checks come after this works for local folders.

### `dw why`, `dw doctor` and the Tweaks page

- `PolicyEvaluator` learns `dylib-sha256`, and only when the running daemon enforces it. That needs a way to tell,
  either from a version line in dynjectd's log or from whether the config has an approval key.
- New `dw why` step: "approved: hash matches / no approval / file changed since approval".
- New `dw doctor` check: installed tweaks without an approval, and approvals for files that are gone.

## Rollout without breaking current installs

1. **Audit mode first.** Add `dylib-approval:audit|enforce` to the engine: in audit mode a missing or mismatched hash
   is logged and the dylib still loads. Today the fork goes straight to enforce, which would stop every tweak on this
   Mac, because none has a hash line.
2. **Backfill.** A `dw tweak approve --all` hashes each installed dylib and writes the lines in one privileged step.
   It shows the list first.
3. **Watch.** Run audit mode for a while. `dw doctor` reports what enforce would block.
4. **Enforce.** Switch the key once doctor is clean. Keep `audit` as the documented way back.

## Open problems (from the 2026-11-24 review)

- **The check and the load aren't bound together.** dynjectd hashes the file, then dyld opens the path later. Root
  ownership and the mode checks keep non-root users out of that window. Closing it fully would mean injecting a
  content-addressed copy, for example `/opt/dynject/lib/approved/<sha256>.dylib`, written only by the install step,
  so that the path names the bytes.
- **Hashing at every launch costs time.** A large dylib is hashed while xpcproxy waits. A cache keyed on
  (dev, inode, size, mtime, ctime) would avoid it, or the content-addressed copy would make it moot.
- **Line order matters.** The engine needs the `dylib:` line before its approval. Workbench writes them adjacent, and
  the engine should accept either order.
- **The fork's loader supervisor and amfid guard** are separate milestones and aren't needed for this.

## Smallest first milestone

Engine: audit mode and order-independent approval lines, on a branch off `fix-spawn-buffers` (the daemon that's
installed now) rather than `safety-audit`, with tests. Workbench: write and remove `dylib-sha256` lines at install and
uninstall, plus `dw doctor` reporting missing approvals. Install that daemon in the VM in audit mode, backfill, and
check that nothing changes for running tweaks.
