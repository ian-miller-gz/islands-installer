# SPDX-License-Identifier: AGPL-3.0-or-later
"""install.sh against the fake forge: a channel resolved by git and by the
API, the prefix laid, checked, updated, rolled back, refused on a bad
sum, and left alone when the forge is unreached."""
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import time

import pytest

HERE = pathlib.Path(__file__).resolve().parent
INSTALL = HERE.parent / 'install.sh'
sys.path.insert(0, str(HERE))
import forge  # noqa: E402


def free_port():
  with socket.socket() as probe:
    probe.bind(('127.0.0.1', 0))
    return probe.getsockname()[1]


@pytest.fixture
def served(tmp_path):
  root = tmp_path / 'forge'
  forge.build(root, ['0.4.1', '0.4.2'], stable='0.4.1', latest='0.4.2',
              platform='linux-x64')
  port = free_port()
  server = subprocess.Popen([sys.executable, '-I', str(HERE / 'forge.py'), str(root),
                             '--serve', str(port)], stdout=subprocess.PIPE)
  server.stdout.readline()
  yield root, f'http://127.0.0.1:{port}'
  server.terminate()
  server.wait()


@pytest.fixture
def home(tmp_path, served):
  root, url = served
  env = dict(os.environ, ISLANDS_FORGE=url, ISLANDS_API=f'{url}/api',
             HOME=str(tmp_path / 'home'))
  env.pop('XDG_DATA_HOME', None)
  env.pop('ISLANDS_HOME', None)
  env.pop('ISLANDS_BIN', None)
  (tmp_path / 'home').mkdir()
  return tmp_path, env


def run(env, *words, **kwargs):
  return subprocess.run(['sh', str(INSTALL), *words], env=env, text=True,
                        capture_output=True, **kwargs)


def prefix(home):
  return home / 'home' / '.local' / 'share' / 'islands'


def record(home):
  return dict(row.split(': ', 1) for row in
              (prefix(home) / 'installed.yaml').read_text().splitlines())


def test_install_lays_the_stable_prefix(home):
  root, env = home
  done = run(env)
  assert done.returncode == 0, done.stderr
  assert done.stdout.strip() == 'installed 0.4.1'
  assert (prefix(root) / 'build' / 'Island').exists()
  assert (prefix(root) / 'cartridges' / '.core' / 'launcher' / 'manifest.yaml').exists()
  assert record(root)['version'] == '0.4.1'
  assert record(root)['channel'] == 'stable'
  island = root / 'home' / '.local' / 'bin' / 'islands'
  assert island.is_symlink()
  assert subprocess.run([str(island)], text=True, capture_output=True).stdout.endswith(' 0.4.1\n')
  assert (root / 'home' / '.local' / 'bin' / 'islands-installer').is_symlink()
  assert (prefix(root) / 'installer' / 'install.sh').exists()
  assert not (prefix(root).parent / 'islands.lock').exists()


def test_check_sees_the_line(home):
  root, env = home
  assert run(env, 'check').returncode == 11
  run(env, check=True)
  current = run(env, 'check')
  assert current.returncode == 0
  assert current.stdout == 'installed 0.4.1\nstable 0.4.1\n'
  ahead = run(env, 'check', '--channel', 'latest')
  assert ahead.returncode == 10
  assert ahead.stdout == 'installed 0.4.1\nlatest 0.4.2\n'


def test_update_carries_what_the_asset_does_not_ship(home, served):
  root, env = home
  forge_root, _ = served
  run(env, check=True)
  store = prefix(root) / 'cartridges' / '.store' / 'sound'
  store.mkdir(parents=True)
  (store / 'manifest.yaml').write_text('name: sound\n')
  (prefix(root) / 'configs' / 'links.yaml').write_text('links: [sound]\n')
  (prefix(root) / 'logs').mkdir()
  (prefix(root) / 'logs' / 'island.log').write_text('ran\n')
  assert run(env, 'update').stdout.strip() == 'up to date 0.4.1'
  forge.build(forge_root, ['0.4.1', '0.4.2'], stable='0.4.2', latest='0.4.2',
              platform='linux-x64')
  updated = run(env, 'update')
  assert updated.returncode == 0, updated.stderr
  assert updated.stdout.strip() == 'installed 0.4.2'
  assert record(root)['version'] == '0.4.2'
  assert (store / 'manifest.yaml').read_text() == 'name: sound\n'
  assert (prefix(root) / 'configs' / 'links.yaml').exists()
  assert (prefix(root) / 'configs' / 'make.yaml').read_text() == 'ENGINE_VERSION: 0.4.2\n'
  assert (prefix(root) / 'logs' / 'island.log').exists()
  previous = prefix(root).parent / 'islands.previous'
  assert (previous / 'configs' / 'make.yaml').read_text() == 'ENGINE_VERSION: 0.4.1\n'
  assert not (previous / 'cartridges' / '.store').exists()


def test_rollback_restores_the_previous_prefix(home):
  root, env = home
  run(env, check=True)
  run(env, '--version', '0.4.2', check=True)
  assert record(root)['version'] == '0.4.2'
  assert record(root)['channel'] == ''
  (prefix(root) / 'configs' / 'links.yaml').write_text('links: []\n')
  back = run(env, 'rollback')
  assert back.returncode == 0, back.stderr
  assert back.stdout.strip() == 'installed 0.4.1'
  assert record(root)['version'] == '0.4.1'
  assert (prefix(root) / 'configs' / 'links.yaml').exists()
  assert (prefix(root).parent / 'islands.previous' / 'configs' / 'make.yaml').read_text() == 'ENGINE_VERSION: 0.4.2\n'


def test_a_wrong_sum_leaves_the_prefix_alone(home, served):
  root, env = home
  forge_root, _ = served
  run(env, check=True)
  sidecar = forge_root / 'ian-miller-gz' / 'islands-packages' / 'releases' / 'download' / '0.4.2' / 'islands-0.4.2-linux-x64.tar.gz.sha256'
  sidecar.write_text('0' * 64 + '  islands-0.4.2-linux-x64.tar.gz\n')
  refused = run(env, '--version', '0.4.2')
  assert refused.returncode == 20
  assert 'sha256' in refused.stderr
  assert record(root)['version'] == '0.4.1'
  assert not (prefix(root).parent / 'islands.lock').exists()


def test_a_missing_asset_is_unreached(home):
  root, env = home
  missing = run(env, '--version', '0.9.9')
  assert missing.returncode == 12
  assert not prefix(root).exists()


def test_the_api_path_resolves_without_git(home, tmp_path):
  root, env = home
  shim = tmp_path / 'shim'
  shim.mkdir()
  for tool in ('sh', 'curl', 'tar', 'sha256sum', 'cut', 'sed', 'head', 'awk', 'sort',
               'mktemp', 'mkdir', 'mv', 'rm', 'cp', 'chmod', 'ln', 'date', 'dirname',
               'basename', 'cat', 'printf', 'kill', 'sleep', 'python3', 'setsid', 'nohup',
               'gzip'):
    found = shutil.which(tool)
    if found:
      os.symlink(found, shim / tool)
  env = dict(env, PATH=str(shim))
  done = run(env, '--channel', 'latest')
  assert done.returncode == 0, done.stderr
  assert record(root)['version'] == '0.4.2'
  assert record(root)['channel'] == 'latest'
  assert run(env, 'check').stdout == 'installed 0.4.2\nlatest 0.4.2\n'


def test_an_unreached_forge_is_reported(home):
  root, env = home
  run(env, check=True)
  env = dict(env, ISLANDS_FORGE='http://127.0.0.1:9', ISLANDS_API='http://127.0.0.1:9')
  unreached = run(env, 'check')
  assert unreached.returncode == 12
  assert unreached.stdout == 'installed 0.4.1\nstable unreached\n'
  assert run(env, 'update').returncode == 12


def test_wait_and_restart_hand_the_host_back(home):
  root, env = home
  run(env, check=True)
  sleeper = subprocess.run(['sh', '-c', 'sleep 2 >/dev/null 2>&1 & echo $!'],
                           text=True, capture_output=True, check=True).stdout.strip()
  mark = root / 'mark'
  env = dict(env, ISLANDS_MARK=str(mark))
  started = time.monotonic()
  done = run(env, '--version', '0.4.2', '--wait', sleeper, '--restart')
  assert done.returncode == 0, done.stderr
  assert 1.5 <= time.monotonic() - started < 30
  assert subprocess.run(['kill', '-0', sleeper], capture_output=True).returncode != 0
  for _ in range(50):
    if mark.exists():
      break
    time.sleep(0.1)
  assert mark.read_text().strip() == '0.4.2'


def test_two_installers_do_not_overlap(home):
  root, env = home
  prefix(root).parent.mkdir(parents=True)
  (prefix(root).parent / 'islands.lock').mkdir()
  held = run(env)
  assert held.returncode == 1
  assert 'lock' in held.stderr


def test_a_piped_installer_places_itself_from_its_release(home, served):
  root, env = home
  forge_root, _ = served
  with open(INSTALL) as script:
    piped = subprocess.run(['sh', '-s', '--', '--channel', 'stable'], stdin=script, env=env,
                           text=True, capture_output=True)
  assert piped.returncode == 0, piped.stderr
  assert piped.stdout == 'installer not placed\ninstalled 0.4.1\n'
  assert not (prefix(root) / 'installer' / 'install.sh').exists()
  assert not (root / 'home' / '.local' / 'bin' / 'islands-installer').exists()
  forge.build(forge_root, ['0.4.1', '0.4.2'], stable='0.4.1', latest='0.4.2',
              platform='linux-x64', scripts=[INSTALL])
  with open(INSTALL) as script:
    piped = subprocess.run(['sh', '-s', '--', '--version', '0.4.2'], stdin=script, env=env,
                           text=True, capture_output=True)
  assert piped.returncode == 0, piped.stderr
  assert piped.stdout == 'installed 0.4.2\n'
  assert (prefix(root) / 'installer' / 'install.sh').read_text() == INSTALL.read_text()
  assert (root / 'home' / '.local' / 'bin' / 'islands-installer').is_symlink()


def test_run_installs_when_absent_then_starts_the_host(home):
  root, env = home
  mark = root / 'mark'
  env = dict(env, ISLANDS_MARK=str(mark))
  first = run(env, 'run', '--', '--cartridge', 'x')
  assert first.returncode == 0, first.stderr
  assert first.stdout.splitlines()[0] == 'installed 0.4.1'
  assert first.stdout.splitlines()[1].endswith(' 0.4.1')
  assert mark.read_text().strip() == '0.4.1'
  assert not (prefix(root).parent / 'islands.lock').exists()
  again = run(env, 'run')
  assert again.returncode == 0, again.stderr
  assert again.stdout.strip().endswith(' 0.4.1')
  assert 'installed' not in again.stdout


def test_the_seated_copy_addresses_its_own_prefix(home, tmp_path):
  root, env = home
  elsewhere = tmp_path / 'elsewhere' / 'islands'
  run(dict(env, ISLANDS_HOME=str(elsewhere)), check=True)
  seated = elsewhere / 'installer' / 'install.sh'
  bare = {k: v for k, v in env.items() if k != 'ISLANDS_HOME'}
  found = subprocess.run(['sh', str(seated), 'check'], env=bare, text=True, capture_output=True)
  assert found.returncode == 0, found.stderr
  assert found.stdout == 'installed 0.4.1\nstable 0.4.1\n'
  assert not prefix(root).exists()
  moved = subprocess.run(['sh', str(seated), '--version', '0.4.2'], env=bare, text=True, capture_output=True)
  assert moved.returncode == 0, moved.stderr
  assert (elsewhere / 'installed.yaml').read_text().splitlines()[0] == 'version: 0.4.2'


def test_run_refreshes_an_older_seated_installer(home):
  root, env = home
  run(env, check=True)
  seat = prefix(root) / 'installer' / 'install.sh'
  seat.write_text('#!/bin/sh\necho old\n')
  record = prefix(root) / 'installed.yaml'
  record.write_text(record.read_text().replace('installer: 1.0.1', 'installer: 0.9.0'))
  again = run(env, 'run')
  assert again.returncode == 0, again.stderr
  assert seat.read_text() == INSTALL.read_text()
  assert 'installer: 1.0.1' in record.read_text()


def test_usage_refuses_a_channel_with_a_version(home):
  root, env = home
  assert run(env, '--channel', 'latest', '--version', '0.4.1').returncode == 2
  assert run(env, '--channel', 'nightly').returncode == 2
  assert run(env, '--bogus').returncode == 2
  assert run(env, 'version').stdout.strip() == '1.0.1'
