contributing
============

issues and patches welcome.

- by contributing you license your contribution under PolyForm Noncommercial 1.0.0 to the
  maintainer, and agree that the maintainer may relicense it.
- no tooling for paid tweaks: no license checks, paywalls, drm or early-access gates.
- run `./scripts/test-all.sh` before you send anything (unit tests, the app, every tweak and
  its test host, a fresh `dw new` tweak). if you touched the app, respring or the bridge, run
  `./scripts/test-all.sh --all` too, when you can spare the screen for a minute.
- follow HACKING.md: the isolation rule (tests never touch the live config, /opt/dynject, real
  keys or real apps), one helper call per user-visible change, DynjectHook stays hidden and
  class-free.
- bug reports: macOS version, what you ran, `dw safemode status`, the crash report if there is
  one, and `dw log <subsystem>` output.
- someone selling this or tweaks built with it: open an issue with a link (https://github.com/Nininunz/dynject-workbench/issues).
