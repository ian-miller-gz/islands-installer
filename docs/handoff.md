# The launcher's handoff

How the launcher keeps an installed prefix on its line through the
installer, and what that asks of the launcher. This is the shape of a
launcher order; it is drafted here and not queued.

## Today

`LAUNCHER::LINE::follow` (`line/line.follow.cpp`) keeps the launcher
cartridge alone on its line: with a `.git` under
`cartridges/.core/launcher` it fetches the line, rebuilds the cartridge
with `cartridges/build.sh`, and restarts (`RELATIONS::start`, then
`SIGTERM`). On Windows, and wherever there is no clone, it stands
`pinned`. The engine under the cartridge is never updated.

## With the installer

An installed prefix carries `installed.yaml` at its root. When the
launcher finds it, the installer owns the line and the git follow
stands down on every platform.

| Step | Command | Outcome |
|---|---|---|
| checking | `<prefix>/installer/install.sh check --channel <followed>` | exit 0 current, 10 an update stands, 11 or 12 nothing to offer |
| offering | the launcher's prompt | update, later, skip this version |
| updating | `<prefix>/installer/install.sh update --channel <followed> --wait <pid> --restart` spawned detached, then `SIGTERM` | the installer waits for the launcher to exit, swaps the prefix, starts `build/Island` |

On Windows the same two commands run `install.ps1` through
`powershell -NoProfile -ExecutionPolicy Bypass -File`.

`check` prints two rows, `installed X.Y.Z` and `<channel> X.Y.Z`, so
the prompt can name both versions. A skipped version goes in
`configs/release.yaml` beside `release:` and silences the prompt for
that version alone. Exit 12 (unreached) is silence, not an error: an
offline start runs what is installed.

`check` makes one or two requests to the forge and no change on disk,
so it can run at every start without a lock. `update` takes
`<prefix>.lock`; a second launcher starting during an update sees the
lock and runs what is installed.

## Developers

A checkout (no `installed.yaml`, a `.git` under the cartridge) is not
installed and the installer never touches it. A developer who runs on
the launcher is on `stable` like everyone, through the installer; a
developer who needs their own engine builds it and runs
`build/Island` from the checkout, where the follow stands down.

## The record

```yaml
version: 0.4.19
channel: stable
platform: linux-x64
sha256: <the asset's>
installed: 2026-11-05T20:00:00Z
installer: 0.1.0
```

`channel` is empty after `--version X.Y.Z`; `check` and `update` then
fall back to `stable` unless `--channel` is given.
