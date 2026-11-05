#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu

INSTALLER_VERSION=0.1.0
FORGE="${ISLANDS_FORGE:-https://github.com}"
API="${ISLANDS_API:-https://api.github.com}"
OWNER="${ISLANDS_OWNER:-ian-miller-gz}"
ENGINE="${ISLANDS_ENGINE:-islands}"
PACKAGES="${ISLANDS_PACKAGES:-islands-packages}"
INSTALLER="${ISLANDS_INSTALLER:-islands-installer}"
PLATFORM=linux-x64
EXTENSION=tar.gz
HOSTS="build/Island build/Reef"
CARRIED="cartridges configs"
WAIT_LIMIT=60
RECORD=installed.yaml

command=install
channel=
version=
prefix="${ISLANDS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/islands}"
bin="${ISLANDS_BIN:-$HOME/.local/bin}"
wait_pid=
restart=0
force=0

usage() {
  cat <<USAGE
install.sh [install] [--channel stable|latest] [--version X.Y.Z]
           [--prefix DIR] [--bin DIR | --no-bin] [--wait PID] [--restart]
install.sh update
install.sh check      exit 0 current, 10 update, 11 none, 12 unreached
install.sh rollback
install.sh version
USAGE
}

say() { printf '%s\n' "$*"; }
fail() { printf 'install.sh: %s\n' "$*" >&2; exit "${2:-1}"; }

case "${1:-}" in
  install|update|check|rollback|version) command="$1"; shift ;;
  -h|--help|help) usage; exit 0 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --channel) channel="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    --bin) bin="$2"; shift 2 ;;
    --no-bin) bin=; shift ;;
    --wait) wait_pid="$2"; shift 2 ;;
    --restart) restart=1; shift ;;
    --force) force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument $1" 2 ;;
  esac
done
[ "$command" = version ] && { say "$INSTALLER_VERSION"; exit 0; }
[ -n "$channel" ] && [ -n "$version" ] && fail "--channel and --version together" 2
case "$channel" in ''|stable|latest) ;; *) fail "channel $channel is not stable or latest" 2 ;; esac

recorded() {
  [ -f "$prefix/$RECORD" ] || return 0
  sed -n "s/^$1:[[:space:]]*//p" "$prefix/$RECORD" | head -1
}

record() {
  cat > "$prefix/$RECORD" <<RECORD
version: $1
channel: $2
platform: $PLATFORM
sha256: $3
installed: $(date -u +%Y-%m-%dT%H:%M:%SZ)
installer: $INSTALLER_VERSION
RECORD
}

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 2 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    fail "neither curl nor wget on PATH"
  fi
}

digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

by_git() {
  url="$FORGE/$OWNER/$ENGINE.git"
  head="$(git ls-remote "$url" "refs/heads/$1" 2>/dev/null | cut -f1)" || return 2
  [ -n "$head" ] || return 2
  git ls-remote --refs --tags "$url" 2>/dev/null |
    awk -v head="$head" '$1 == head { sub("refs/tags/", "", $2); print $2 }' |
    sort -V | tail -1
}

by_api() {
  json="$work/ref.json"
  fetch "$API/repos/$OWNER/$ENGINE/git/ref/heads/$1" "$json" || return 2
  fetch "$API/repos/$OWNER/$ENGINE/git/matching-refs/tags" "$work/tags.json" || return 2
  python3 -I - "$json" "$work/tags.json" <<'PY'
import json, sys
head = json.load(open(sys.argv[1]))["object"]["sha"]
tags = [t["ref"].split("/", 2)[2] for t in json.load(open(sys.argv[2]))
        if t["object"]["sha"] == head]
tags.sort(key=lambda v: [int(p) if p.isdigit() else p for p in v.split(".")])
print(tags[-1] if tags else "")
PY
}

resolve() {
  if command -v git >/dev/null 2>&1; then
    found="$(by_git "$1")" || return 2
  elif command -v python3 >/dev/null 2>&1; then
    found="$(by_api "$1")" || return 2
  else
    fail "resolving a channel needs git or python3 on PATH"
  fi
  [ -n "$found" ] || fail "no tag on the tip of $1"
  say "$found"
}

asset_name() { say "$ENGINE-$1-$PLATFORM.$EXTENSION"; }
asset_url() { say "$FORGE/$OWNER/$PACKAGES/releases/download/$1/$(asset_name "$1")"; }

download() {
  name="$(asset_name "$1")"
  fetch "$(asset_url "$1")" "$work/$name" || fail "no asset $name on the release $1" 12
  fetch "$(asset_url "$1").sha256" "$work/$name.sha256" || fail "no $name.sha256 beside the asset" 12
  expected="$(cut -d' ' -f1 "$work/$name.sha256")"
  actual="$(digest "$work/$name")"
  [ "$expected" = "$actual" ] || fail "$name does not match its sha256" 20
  say "$actual"
}

unpack() {
  mkdir -p "$work/tree"
  tar -xzf "$work/$(asset_name "$1")" -C "$work/tree"
  [ -d "$work/tree/$ENGINE" ] || fail "the asset has no $ENGINE/ folder"
  for host in $HOSTS; do
    [ -f "$work/tree/$ENGINE/$host" ] || fail "the asset has no $host"
  done
}

carry_entry() {
  [ -e "$1" ] || return 0
  [ -e "$2" ] && return 0
  mkdir -p "$(dirname "$2")"
  mv "$1" "$2"
}

shared() {
  case " $CARRIED " in *" $1 "*) return 0 ;; esac
  return 1
}

carry() {
  [ -d "$1" ] || return 0
  for entry in "$1"/* "$1"/.[!.]*; do
    [ -e "$entry" ] || continue
    name="${entry##*/}"
    [ "$name" = "$RECORD" ] && continue
    if shared "$name"; then
      for inner in "$entry"/* "$entry"/.[!.]*; do
        [ -e "$inner" ] || continue
        carry_entry "$inner" "$2/$name/${inner##*/}"
      done
    else
      carry_entry "$entry" "$2/$name"
    fi
  done
}

lock() {
  mkdir -p "$(dirname "$prefix")"
  mkdir "$prefix.lock" 2>/dev/null || fail "another installer holds $prefix.lock"
  trap 'rm -rf "$prefix.lock" "$work"' EXIT INT TERM
}

alive() {
  kill -0 "$1" 2>/dev/null || return 1
  [ -r "/proc/$1/status" ] || return 0
  ! grep -q '^State:[[:space:]]*Z' "/proc/$1/status"
}

await() {
  [ -n "$wait_pid" ] || return 0
  waited=0
  while alive "$wait_pid"; do
    [ "$waited" -lt "$WAIT_LIMIT" ] || { say "pid $wait_pid still runs"; break; }
    sleep 1
    waited=$((waited + 1))
  done
}

swap() {
  rm -rf "$prefix.previous"
  if [ -d "$prefix" ]; then
    mv "$prefix" "$prefix.previous"
    carry "$prefix.previous" "$work/tree/$ENGINE"
  fi
  mv "$work/tree/$ENGINE" "$prefix"
}

self_url() { say "$FORGE/$OWNER/$INSTALLER/releases/latest/download/install.sh"; }

place() {
  seat="$prefix/installer/install.sh"
  mkdir -p "$prefix/installer"
  case "$0" in
    *install.sh) [ -f "$0" ] && cp "$0" "$seat" ;;
    *) fetch "$(self_url)" "$seat" || { rm -f "$seat"; say "installer not placed"; } ;;
  esac
  [ -f "$seat" ] && chmod 755 "$seat"
  [ -n "$bin" ] || return 0
  mkdir -p "$bin"
  ln -sfn "$prefix/${HOSTS%% *}" "$bin/islands"
  [ -f "$seat" ] && ln -sfn "$seat" "$bin/islands-installer"
  return 0
}

launch() {
  [ "$restart" = 1 ] || return 0
  (cd "$prefix" && setsid nohup "$prefix/${HOSTS%% *}" >/dev/null 2>&1 &)
}

do_check() {
  current="$(recorded version)"
  [ -n "$current" ] || { say "installed none"; exit 11; }
  line="${channel:-$(recorded channel)}"
  [ -n "$line" ] || line=stable
  wanted="$(resolve "$line")" || { say "installed $current"; say "$line unreached"; exit 12; }
  say "installed $current"
  say "$line $wanted"
  [ "$wanted" = "$current" ] && exit 0
  exit 10
}

do_install() {
  current="$(recorded version)"
  if [ -z "$version" ]; then
    line="${channel:-$(recorded channel)}"
    [ -n "$line" ] || line=stable
    version="$(resolve "$line")" || fail "$line unreached" 12
  else
    line=
  fi
  if [ "$version" = "$current" ] && [ "$force" = 0 ]; then
    say "up to date $current"
    launch
    exit 0
  fi
  sum="$(download "$version")"
  unpack "$version"
  await
  swap
  record "$version" "$line" "$sum"
  place
  say "installed $version"
  launch
}

do_rollback() {
  [ -d "$prefix.previous" ] || fail "nothing at $prefix.previous"
  [ -d "$prefix" ] || fail "nothing at $prefix"
  await
  carry "$prefix" "$prefix.previous"
  mv "$prefix" "$work/undone"
  mv "$prefix.previous" "$prefix"
  mv "$work/undone" "$prefix.previous"
  place
  say "installed $(recorded version)"
  launch
}

work="$(mktemp -d)"
case "$command" in
  check) trap 'rm -rf "$work"' EXIT INT TERM; do_check ;;
  install|update) lock; do_install ;;
  rollback) lock; do_rollback ;;
esac
