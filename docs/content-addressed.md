# Content-addressed tweak builds (design, not built)

Status, 2026-11-25: proposal. Nothing here is built yet. It follows install approval (docs/install-approval.md) and
packages (docs/packages.md), and closes the first open problem listed in install-approval.md.

## The gap

An approval-aware dynjectd hashes a tweak's file and compares it with its `dylib-sha256` line. It then puts the
path in `DYLD_INSERT_LIBRARIES`, and dyld opens that path a moment later, inside the app. Nothing ties the bytes
dyld maps to the bytes dynjectd hashed. If the file is replaced in between, the app loads a build nobody approved.

### How much this matters

Less than it sounds. dynjectd already refuses a dylib whose path isn't root-owned all the way down, or that's
group- or other-writable (tweak_trust). So the only things that can swap the file in that window are root and the
install helper. Root is outside what approval defends against anyway (install-approval.md, "What this doesn't
do").

The real gains are elsewhere:

- **Exact build identity.** The path a running app loaded names the build it has. Respring and `dw why` can tell
  "this app has build X, the approved one is Y" from `lsof` alone. Today they guess from file change times
  ("updated … file changed 04:24").
- **Rollback.** Earlier approved builds stay on disk, so going back one is a config edit and a restart, with no
  rebuild.
- **No in-place replacement.** An update never overwrites a file a running app has mapped. Today the helper
  renames a new file over the old path, which is safe for mapped files, but nothing guarantees later steps keep
  it that way.
- **The window closes too,** for whatever it's worth against root.

Reading the trade-off honestly: this is worth doing for respring and why accuracy, and for rollback. It isn't worth
doing for security alone.

## The layout

    /opt/dynject/lib/approved/<sha256>/libX.dylib

The folder is named by the build's SHA-256, and the file keeps the tweak's own name. That matters:

- DynjectHook's hook maps (`dynject.hooks:map libX.dylib …`) and crash attribution match images by file name.
- `lsof`, crash reports (`/opt/dynject/*/libX.dylib` once anonymised) and Safe Mode's catalog do the same.

A file named `<sha256>.dylib` would break all of those. A folder named by its hash breaks none.

Rules for the store, enforced by the engine (tweak_trust) and written only by the install helper:

- `approved/` and each `<sha256>/` are root-owned, 0755, with no ACLs.
- Each file is root-owned 0444, written once, and never replaced. A different build goes in a different folder.
- Nothing in the store is a symbolic link.

## Engine (fork, a branch off `approval-audit`)

The config stays as it is:

    dylib:/opt/dynject/lib/tweaks/libX.dylib:deny
    dylib-sha256:/opt/dynject/lib/tweaks/libX.dylib:<hex>

The tweak's path remains its identity: overrides, Safe Mode, manifests and `dw enable` all keep using it. What
changes is the path dynjectd injects:

1. Evaluate the dylib as today: policy, then approval.
2. If it has an approval line and `/opt/dynject/lib/approved/<hex>/<basename>` exists and passes tweak_trust,
   inject that path instead.
   - Hash the store file once per (dev, inode, size, mtime, ctime), like today's cache. A mismatch means the store
     is damaged: in enforce mode, skip the dylib and log it; in audit mode, fall back to the tweak path and log it.
3. If there's no store copy, behave exactly as today: inject the tweak path after checking its hash. Configs and
   installs from before the store keep working, and so does a stock dynjectd, which ignores the store.

One new config key isn't needed: the store is used when it's there. The log line at startup says how many approved
dylibs have a store copy, like the approval summary line does today.

## Workbench

- **Install** writes the approved build into the store in the same privileged step as everything else. The new
  helper operation is `store <sha256> <basename> <staged>`. It creates the folder and writes the file 0444 once,
  and is a no-op if that exact build is already there. The install also keeps writing
  `/opt/dynject/lib/tweaks/libX.dylib` as today, so a stock dynjectd still works.
- **`dw tweak approve`** stores the builds it approves, in its one prompt.
- **Uninstall** removes the tweak's store folders, unless another tweak's approval names the same hash.
- **Pruning:** each tweak keeps its approved build and the one before it, for rollback. Older folders are removed
  in the next privileged step that touches the tweak.
- **`dw tweak rollback <tweak>`** points the approval line back at the previous stored build and copies it to the
  tweak path, in one prompt and one restart.
- **Respring, `dw why` and doctor** read the hash folder in a running app's loaded path, to say exactly which build
  it has. They match tweaks by file name, as today. Their candidate lists gain the store paths.
- **Doctor:**
  - a store folder whose file doesn't match its name is a problem;
  - an approved dylib with no store copy is a note ("approve again to store it").

## Rollout

1. Engine first, in the VM: with no store, nothing changes. With a store, apps load the stored path, and crash
   attribution, Safe Mode and respring still name the tweak.
2. Workbench writes the store on install and approve. `dw tweak approve --all` backfills it.
3. This Mac: swap the daemon, then `approve --all`, with your approval for each step as before.

## Milestones

1. Engine: the store lookup, its trust checks and hash cache, fallbacks, startup line, tests (store present,
   absent, damaged, symlinked, wrong owner), and the VM test.
2. Workbench: the `store` helper operation, install, approve and uninstall, pruning, and doctor's checks.
3. Respring, `dw why` and doctor reading build identity from loaded paths. `dw tweak rollback`.

## Open questions

- **Is it worth it now?** The security gain is small (see "How much this matters"). The respring and why accuracy
  and rollback are the reasons to do it, and they're conveniences. A fair answer is to wait until packages from
  other people are actually in use.
- **Keep the tweak path at all?** Writing both doubles the disk use per tweak, a few MB. Dropping the tweak path
  would break stock dynjectd and older Workbench versions. This proposal keeps both until the fork's engine is the
  only one in use.
- **Upstream.** The engine change only makes sense together with approvals, which exist only in the fork. Offering
  them upstream as a pair, later, is cleaner than either alone.
