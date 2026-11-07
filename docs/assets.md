# The release asset

The installer lays what a release asset holds. This page is the
contract between the asset's maker (the packaging repository's
`tools/release.sh`) and the installer that unpacks it.

## Where

| Part | Value |
|---|---|
| Channel | a branch of `ian-miller-gz/islands`: `stable` or `latest` |
| Version | the lightweight tag `X.Y.Z` on the channel's tip commit |
| Release | `ian-miller-gz/islands-packages`, the release named `X.Y.Z` |
| Asset | `islands-X.Y.Z-linux-x64.tar.gz`, `islands-X.Y.Z-windows-x64.zip` |
| Sidecar | the asset's name plus `.sha256`, holding `<hex>  <name>` |

The installer resolves a channel with `git ls-remote` when git is on
the path, and through the forge's API (`git/ref/heads/<channel>`,
`git/matching-refs/tags`) when it is not. Both read the tip's commit
and look for a tag at that commit, so the line tags must be lightweight
(an annotated tag's object is the tag, not the commit). When several
tags sit on the tip the highest version wins.

## Inside

One top folder, `islands/`, in the shape `tools/prefix.sh` lays:

| Path | Holds |
|---|---|
| `build/Island`, `build/Reef` | the hosts (`Island.exe`, `Reef.exe`, `islands.dll` on Windows) |
| `assets/` | fonts, shaders, the gui sheets |
| `configs/` | `make.yaml`, `header.yaml`, `verify.yaml`, `web.html` |
| `cartridges/.core/launcher/` | the launcher, built for the platform |
| `LICENSE` | AGPL-3.0-or-later |

The installer refuses an asset without the folder or without both
hosts, before anything on disk changes.

## What the installer keeps

The asset owns what it ships. Every path in the replaced prefix that
the asset does not ship is carried into the new one: a child of
`cartridges/` or `configs/` the asset lacks (`cartridges/.store/*`,
`configs/links.yaml`, `configs/release.yaml`), and any other top-level
entry (`logs/`). `installed.yaml` is the installer's own and is written
fresh. The replaced prefix stays as `<prefix>.previous`; `rollback`
swaps it back and carries the same way.

## Making the assets

The packaging repository's release tool lays both from a built engine
checkout (the posix build and the windows-ship cell) and puts them on
the packages release of the version, beside the source tarball:

```sh
tools/release.sh X.Y.Z --no-build --linux --windows --engine <checkout> --packages <packages checkout>
``` A prefix built for one distribution's
libraries runs where those libraries are; the tarball should be built
on the oldest supported base (the deb's) so the hosts link against the
lowest glibc.

## Trust

The sidecar proves the download is the asset that was published; the
transport to the forge is TLS. It does not prove who published it. A
signed sidecar (minisign, the public key carried by the installer and
by the channel packages) is the next step and is not in 0.1.0.
