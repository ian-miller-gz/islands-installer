# SPDX-License-Identifier: AGPL-3.0-or-later
# install.ps1 against the fake forge (tests/forge.py, windows-x64 assets).
BeforeAll {
  $script:Here = $PSScriptRoot
  $script:Install = Join-Path (Split-Path $Here -Parent) 'install.ps1'
  $script:Python = if (Get-Command python -ErrorAction SilentlyContinue) { 'python' } else { 'python3' }
}

BeforeEach {
  $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ("islands-test-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $Root | Out-Null
  $script:ForgeRoot = Join-Path $Root 'forge'
  & $Python -I (Join-Path $Here 'forge.py') $ForgeRoot --version 0.4.1 --version 0.4.2 `
    --stable 0.4.1 --latest 0.4.2 --platform windows-x64 | Out-Null
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  $script:Port = $listener.LocalEndpoint.Port
  $listener.Stop()
  $script:Server = Start-Process -FilePath $Python -PassThru -NoNewWindow `
    -ArgumentList @('-I', (Join-Path $Here 'forge.py'), $ForgeRoot, '--serve', "$Port")
  Start-Sleep -Seconds 2
  $env:ISLANDS_FORGE = "http://127.0.0.1:$Port"
  $env:ISLANDS_API = "http://127.0.0.1:$Port/api"
  $env:ISLANDS_HOME = Join-Path $Root 'Islands'
  $env:ISLANDS_BIN = Join-Path $Root 'bin'
  $script:Prefix = $env:ISLANDS_HOME
}

AfterEach {
  if ($Server -and -not $Server.HasExited) { Stop-Process -Id $Server.Id -Force }
  Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue
}

function Run {
  param([string[]]$Words)
  $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $Install @Words 2>&1
  return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($output | Out-String) }
}

function Record {
  $rows = Get-Content (Join-Path $Prefix 'installed.yaml')
  $record = @{}
  foreach ($row in $rows) { $key, $value = $row -split ': ', 2; $record[$key] = $value }
  return $record
}

Describe 'install.ps1' {
  It 'lays the stable prefix' {
    $done = Run @()
    $done.Code | Should -Be 0
    $done.Text.Trim() | Should -Be 'installed 0.4.1'
    Test-Path (Join-Path $Prefix 'build\Island.exe') | Should -BeTrue
    (Record)['version'] | Should -Be '0.4.1'
    (Record)['channel'] | Should -Be 'stable'
    Test-Path (Join-Path $env:ISLANDS_BIN 'islands.cmd') | Should -BeTrue
    Test-Path (Join-Path $Prefix 'installer\install.ps1') | Should -BeTrue
    Test-Path "$Prefix.lock" | Should -BeFalse
  }

  It 'checks the line' {
    (Run @('check')).Code | Should -Be 11
    Run @() | Out-Null
    $current = Run @('check')
    $current.Code | Should -Be 0
    $current.Text.Trim() | Should -Be "installed 0.4.1`r`nstable 0.4.1"
    $ahead = Run @('check', '-Channel', 'latest')
    $ahead.Code | Should -Be 10
  }

  It 'updates and carries what the asset does not ship' {
    Run @() | Out-Null
    $store = Join-Path $Prefix 'cartridges\.store\sound'
    New-Item -ItemType Directory -Path $store | Out-Null
    Set-Content (Join-Path $store 'manifest.yaml') 'name: sound'
    Set-Content (Join-Path $Prefix 'configs\links.yaml') 'links: [sound]'
    (Run @('update')).Text.Trim() | Should -Be 'up to date 0.4.1'
    & $Python -I (Join-Path $Here 'forge.py') $ForgeRoot --version 0.4.1 --version 0.4.2 `
      --stable 0.4.2 --latest 0.4.2 --platform windows-x64 | Out-Null
    $updated = Run @('update')
    $updated.Code | Should -Be 0
    (Record)['version'] | Should -Be '0.4.2'
    Test-Path (Join-Path $store 'manifest.yaml') | Should -BeTrue
    Test-Path (Join-Path $Prefix 'configs\links.yaml') | Should -BeTrue
    Get-Content (Join-Path $Prefix 'configs\make.yaml') | Should -Be 'ENGINE_VERSION: 0.4.2'
    Get-Content (Join-Path "$Prefix.previous" 'configs\make.yaml') | Should -Be 'ENGINE_VERSION: 0.4.1'
  }

  It 'rolls back' {
    Run @() | Out-Null
    Run @('-Version', '0.4.2') | Out-Null
    (Record)['version'] | Should -Be '0.4.2'
    $back = Run @('rollback')
    $back.Code | Should -Be 0
    (Record)['version'] | Should -Be '0.4.1'
  }

  It 'refuses a wrong sum and leaves the prefix alone' {
    Run @() | Out-Null
    $sidecar = Join-Path $ForgeRoot 'ian-miller-gz\islands-packages\releases\download\0.4.2\islands-0.4.2-windows-x64.zip.sha256'
    Set-Content $sidecar (('0' * 64) + '  islands-0.4.2-windows-x64.zip')
    $refused = Run @('-Version', '0.4.2')
    $refused.Code | Should -Be 20
    (Record)['version'] | Should -Be '0.4.1'
    Test-Path "$Prefix.lock" | Should -BeFalse
  }

  It 'reports an unreached forge' {
    Run @() | Out-Null
    $env:ISLANDS_FORGE = 'http://127.0.0.1:9'
    $env:ISLANDS_API = 'http://127.0.0.1:9'
    (Run @('check')).Code | Should -Be 12
    (Run @('update')).Code | Should -Be 12
  }

  It 'refuses a channel with a version' {
    (Run @('-Channel', 'latest', '-Version', '0.4.1')).Code | Should -Be 2
    (Run @('version')).Text.Trim() | Should -Be '0.1.0'
  }
}
