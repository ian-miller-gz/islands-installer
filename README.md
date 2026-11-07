# Islands installer

*One install, then the line keeps you current*

[![check](https://github.com/ian-miller-gz/islands-installer/actions/workflows/check.yml/badge.svg?branch=main)](https://github.com/ian-miller-gz/islands-installer/actions/workflows/check.yml)
[![licence](https://img.shields.io/badge/licence-AGPL--3.0--or--later-blue.svg)](LICENSE)

<!-- ✎ two to four sentences, the developer's -->
The installer lays a prebuilt Islands prefix from the release asset of
the version on a line, `stable` or `latest`, and keeps it there. The
channels (Homebrew, Scoop, winget, apt, pacman) ship the installer
alone; the engine, the launcher and the bundled cartridges arrive
through it, so a promotion on the line reaches every user at their next
launcher start and nothing is republished.

## Get it

```sh
curl -fsSL https://github.com/ian-miller-gz/islands-installer/releases/latest/download/install.sh | sh
```

```powershell
irm https://github.com/ian-miller-gz/islands-installer/releases/latest/download/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Or clone and run `./install.sh` or `.\install.ps1`. A channel package
puts the same two scripts behind the `islands` and `islands-installer`
commands; see [`docs/channels.md`](docs/channels.md).

## First run

```sh
islands
```

The prefix lies at `~/.local/share/islands` (`%LOCALAPPDATA%\Islands`
on Windows) with `islands` and `islands-installer` linked from
`~/.local/bin` (`%LOCALAPPDATA%\Islands\bin`). The installer's own
words:

```sh
islands-installer check              # installed 0.4.17 / stable 0.4.19, exit 10
islands-installer update             # installed 0.4.19
islands-installer rollback           # installed 0.4.17
islands-installer --channel latest   # follow latest from here on
islands-installer --version 0.4.18   # pin one version, no channel
islands-installer run                # install when absent, then start
```

`--prefix DIR`, `--bin DIR` and `--no-bin` move or drop the seats;
`ISLANDS_HOME` and `ISLANDS_BIN` do the same from the environment.
`--wait PID --restart` is the launcher's handoff: wait for the running
launcher, swap, start the new one.

## Layout

| Path | Holds |
|---|---|
| `install.sh` | the installer for Linux (POSIX sh, curl or wget, tar, git or python3) |
| `install.ps1` | the installer for Windows (PowerShell 5.1 and later) |
| `islands.cmd`, `islands-installer.cmd` | the Windows shims a channel package puts on the path |
| `docs/assets.md` | the release asset the installer unpacks and what it carries over |
| `docs/handoff.md` | how the launcher checks, offers and runs an update |
| `docs/channels.md` | what a channel package ships once the installer carries the line |
| `tests/` | the fake forge and the tests of both installers against it |

## Releases

The installer's own releases are tags `X.Y.Z` on `main`; each carries
the scripts, the shims, a tarball of them and a `SHA256SUMS`. The engine's lines are
the engine repository's `stable` and `latest` branches, tagged `X.Y.Z`
at the tip; the asset of a version lies on the packages repository's
release of that name. The installer is at 1.0.1.

## Requirements

- Linux x64: sh, tar, curl or wget, and git or python3 to resolve a
  line. The prefix's hosts need the libraries the engine links against,
  listed in the engine's README.
- Windows 10 x64 and later: PowerShell 5.1 or later. Nothing else.
- The release assets: `islands-X.Y.Z-linux-x64.tar.gz` and
  `islands-X.Y.Z-windows-x64.zip` with their `.sha256` sidecars, per
  [`docs/assets.md`](docs/assets.md); the packages repository's
  `tools/release.sh --linux --windows` cuts both.

## Licence

AGPL-3.0-or-later; see [`LICENSE`](LICENSE).
