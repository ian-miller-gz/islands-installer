# SPDX-License-Identifier: AGPL-3.0-or-later
"""A fake forge for the installer's tests: a bare engine repository served
over dumb HTTP (git ls-remote reads info/refs), the two API answers the
no-git path reads, and a packages release per version holding a prefix
tarball and its sha256 sidecar.

    python3 forge.py <root> [--version X.Y.Z ...] [--stable X.Y.Z]
                     [--latest X.Y.Z] [--platform linux-x64|windows-x64]
                     [--installer <script> ...]
    python3 forge.py <root> --serve <port>

The engine tree inside each asset is the smallest a prefix needs: the
two hosts (scripts that print their version), assets/, configs/ and a
LICENSE. Rebuilding on an existing root moves the lines and adds
versions; the assets of versions already laid are kept.
"""
import argparse
import hashlib
import http.server
import io
import json
import os
import pathlib
import stat
import subprocess
import sys
import tarfile
import zipfile

OWNER = 'ian-miller-gz'
ENGINE = 'islands'
PACKAGES = 'islands-packages'
INSTALLER = 'islands-installer'


def git(repo, *words, **kwargs):
  return subprocess.run(['git', *words], cwd=repo, check=True, text=True,
                        capture_output=True, **kwargs).stdout.strip()


def repository(root, versions):
  bare = root / OWNER / f'{ENGINE}.git'
  seed = root / '.seed'
  if not bare.exists():
    bare.mkdir(parents=True)
    git(bare, 'init', '-q', '--bare')
    seed.mkdir()
    git(seed, 'init', '-q')
    git(seed, 'config', 'user.email', 'forge@test')
    git(seed, 'config', 'user.name', 'forge')
    git(seed, 'config', 'commit.gpgsign', 'false')
    git(seed, 'config', 'tag.gpgsign', 'false')
  for version in versions:
    if version in git(seed, 'tag').split():
      continue
    (seed / 'VERSION').write_text(version + '\n')
    git(seed, 'add', 'VERSION')
    git(seed, 'commit', '-q', '-m', version)
    git(seed, 'tag', version)
  git(seed, 'push', '-q', '--force', str(bare), 'HEAD:refs/heads/main', '--tags')
  return bare, seed


def line(bare, seed, name, version):
  if version is None:
    return
  sha = git(seed, 'rev-parse', version)
  git(bare, 'update-ref', f'refs/heads/{name}', sha)


def api(root, bare):
  base = root / 'api' / 'repos' / OWNER / ENGINE / 'git'
  (base / 'ref' / 'heads').mkdir(parents=True, exist_ok=True)
  (base / 'matching-refs').mkdir(parents=True, exist_ok=True)
  refs = git(bare, 'for-each-ref', '--format=%(refname) %(objectname)')
  tags = []
  for row in refs.splitlines():
    name, sha = row.split()
    body = {'ref': name, 'object': {'sha': sha, 'type': 'commit'}}
    if name.startswith('refs/heads/'):
      (base / 'ref' / 'heads' / name.rsplit('/', 1)[1]).write_text(json.dumps(body))
    elif name.startswith('refs/tags/'):
      tags.append(body)
  (base / 'matching-refs' / 'tags').write_text(json.dumps(tags))
  git(bare, 'update-server-info')


HOST = '''#!/bin/sh
printf '%s %s\\n' "$(basename "$0")" {version}
[ -n "${{ISLANDS_MARK:-}}" ] && printf '%s\\n' {version} > "$ISLANDS_MARK"
exit 0
'''
HOST_WINDOWS = '@echo off\r\necho %~n0 {version}\r\nif defined ISLANDS_MARK echo {version}> "%ISLANDS_MARK%"\r\n'


def tree(version, platform):
  files = {
    'LICENSE': 'AGPL-3.0-or-later\n',
    'assets/islands.gui': 'gui\n',
    'configs/make.yaml': f'ENGINE_VERSION: {version}\n',
    'cartridges/.core/launcher/manifest.yaml': 'name: launcher\n',
  }
  if platform == 'windows-x64':
    for host in ('Island.exe', 'Reef.exe'):
      files[f'build/{host}'] = HOST_WINDOWS.format(version=version)
  else:
    for host in ('Island', 'Reef'):
      files[f'build/{host}'] = HOST.format(version=version)
  return files


def asset(root, version, platform):
  release = root / OWNER / PACKAGES / 'releases' / 'download' / version
  release.mkdir(parents=True, exist_ok=True)
  if platform == 'windows-x64':
    name = f'{ENGINE}-{version}-{platform}.zip'
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as archive:
      for path, text in tree(version, platform).items():
        archive.writestr(f'{ENGINE}/{path}', text)
    data = buffer.getvalue()
  else:
    name = f'{ENGINE}-{version}-{platform}.tar.gz'
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
      for path, text in tree(version, platform).items():
        info = tarfile.TarInfo(f'{ENGINE}/{path}')
        body = text.encode()
        info.size = len(body)
        info.mode = 0o755 if path.startswith('build/') else 0o644
        archive.addfile(info, io.BytesIO(body))
    data = buffer.getvalue()
  (release / name).write_bytes(data)
  digest = hashlib.sha256(data).hexdigest()
  (release / f'{name}.sha256').write_text(f'{digest}  {name}\n')
  return digest


def installer(root, script):
  seat = root / OWNER / INSTALLER / 'releases' / 'latest' / 'download'
  seat.mkdir(parents=True, exist_ok=True)
  (seat / script.name).write_bytes(script.read_bytes())


def build(root, versions, stable, latest, platform, scripts=()):
  root = pathlib.Path(root)
  bare, seed = repository(root, versions)
  line(bare, seed, 'stable', stable)
  line(bare, seed, 'latest', latest)
  api(root, bare)
  for script in scripts:
    installer(root, pathlib.Path(script))
  return {version: asset(root, version, platform) for version in versions}


def serve(root, port):
  class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
      pass
  os.chdir(root)
  with http.server.ThreadingHTTPServer(('127.0.0.1', port), Quiet) as server:
    print(server.server_address[1], flush=True)
    server.serve_forever()


def main():
  parser = argparse.ArgumentParser()
  parser.add_argument('root')
  parser.add_argument('--version', action='append', default=[])
  parser.add_argument('--stable')
  parser.add_argument('--latest')
  parser.add_argument('--platform', default='linux-x64')
  parser.add_argument('--serve', type=int)
  parser.add_argument('--installer', action='append', default=[])
  options = parser.parse_args()
  if options.serve is not None:
    serve(options.root, options.serve)
    return
  digests = build(options.root, options.version, options.stable, options.latest,
                  options.platform, options.installer)
  for version, digest in digests.items():
    print(version, digest)


if __name__ == '__main__':
  main()
