# What a channel ships

A channel package (Homebrew tap, Scoop bucket, winget, apt, pacman)
ships the installer alone. The engine, the launcher and the bundled
cartridges arrive through the installer from the release asset of the
version on the channel's line, so a promotion on the engine's `stable`
or `latest` branch reaches every user at their next launcher start, and
the channel package is republished only when the installer changes.

## The package

| Path | Holds |
|---|---|
| `install.sh` or `install.ps1` | the installer, from the release of its own version |
| `islands` | a shim: lays the prefix when it is absent, then runs `build/Island` |
| `islands-installer` | a shim to the installer |

The shim for posix channels:

```sh
#!/bin/sh
exec /usr/libexec/islands/install.sh run -- "$@"
```

`run` lays the prefix when it is absent, then starts `build/Island`
with the arguments given. The Windows shims `islands.cmd` and
`islands-installer.cmd` ship in the installer's release tarball and
call `install.ps1` beside them.

The channel package's version is the installer's version, not the
engine's. The installer's own release carries `install.sh`,
`install.ps1` and a `SHA256SUMS`; a channel manifest pins the sum of
the script it ships.

## What a user sees

- `brew install islands`, `scoop install islands`, `winget install
  IanMiller.Islands`, `apt install islands`: the installer and the
  shims, a few kilobytes.
- `islands`: the first run lays the prefix from the `stable` asset;
  every later start asks the installer whether the line moved.
- `brew upgrade` and its kin report the installer's version. The
  launcher shows the engine's.

## Policy

Debian, Arch and Homebrew core refuse a package whose payload arrives
at run time. The Islands channels are the project's own tap, bucket
and repositories, where that rule is the project's to set. A Flatpak
would sandbox the download and the swap; none is planned.
