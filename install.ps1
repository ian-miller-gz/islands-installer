# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('install', 'update', 'check', 'rollback', 'version')]
  [string]$Command = 'install',
  [ValidateSet('', 'stable', 'latest')]
  [string]$Channel = '',
  [string]$Version = '',
  [string]$Prefix = '',
  [string]$Bin = '',
  [switch]$NoBin,
  [int]$Wait = 0,
  [switch]$Restart,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$InstallerVersion = '0.1.0'
$Forge = if ($env:ISLANDS_FORGE) { $env:ISLANDS_FORGE } else { 'https://github.com' }
$Api = if ($env:ISLANDS_API) { $env:ISLANDS_API } else { 'https://api.github.com' }
$Owner = if ($env:ISLANDS_OWNER) { $env:ISLANDS_OWNER } else { 'ian-miller-gz' }
$Engine = if ($env:ISLANDS_ENGINE) { $env:ISLANDS_ENGINE } else { 'islands' }
$Packages = if ($env:ISLANDS_PACKAGES) { $env:ISLANDS_PACKAGES } else { 'islands-packages' }
$Installer = if ($env:ISLANDS_INSTALLER) { $env:ISLANDS_INSTALLER } else { 'islands-installer' }
$Platform = 'windows-x64'
$Extension = 'zip'
$Islands = @('build\Island.exe', 'build\islands.exe')
$Reefs = @('build\Reef.exe', 'build\reef.exe')
$Carried = @('cartridges', 'configs')
$WaitLimit = 60
$Record = 'installed.yaml'

if (-not $Prefix) {
  $Prefix = if ($env:ISLANDS_HOME) { $env:ISLANDS_HOME } else { Join-Path $env:LOCALAPPDATA 'Islands' }
}
if ($NoBin) { $Bin = '' }
elseif (-not $Bin) {
  $Bin = if ($env:ISLANDS_BIN) { $env:ISLANDS_BIN } else { Join-Path $env:LOCALAPPDATA 'Islands\bin' }
}
$Prefix = [System.IO.Path]::GetFullPath($Prefix)
$Previous = "$Prefix.previous"
$Lock = "$Prefix.lock"
$Work = $null

function Say([string]$text) { [Console]::Out.Write("$text`n") }
function Fail([string]$text, [int]$code = 1) {
  [Console]::Error.Write("install.ps1: $text`n")
  Finish
  exit $code
}
function Finish {
  if ($Work -and (Test-Path $Work)) { Remove-Item -Recurse -Force $Work }
  if (Test-Path $Lock) { Remove-Item -Recurse -Force $Lock }
}

if ($Command -eq 'version') { Say $InstallerVersion; exit 0 }
if ($Channel -and $Version) { Fail '-Channel and -Version together' 2 }

function Recorded([string]$key) {
  $path = Join-Path $Prefix $Record
  if (-not (Test-Path $path)) { return '' }
  foreach ($row in Get-Content $path) {
    if ($row -match "^$key\s*:\s*(.*)$") { return $Matches[1].Trim() }
  }
  return ''
}

function Write-Record([string]$version, [string]$channel, [string]$sum) {
  $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  $text = "version: $version`nchannel: $channel`nplatform: $Platform`nsha256: $sum`ninstalled: $stamp`ninstaller: $InstallerVersion`n"
  [System.IO.File]::WriteAllText((Join-Path $Prefix $Record), $text)
}

function Fetch([string]$url, [string]$path) {
  try {
    Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing
    return $true
  } catch {
    return $false
  }
}

function Digest([string]$path) {
  return (Get-FileHash -Algorithm SHA256 $path).Hash.ToLower()
}

function Sort-Versions([string[]]$tags) {
  return $tags | Sort-Object { [version]($_ -replace '[^0-9.].*$', '') }
}

function By-Git([string]$channel) {
  $url = "$Forge/$Owner/$Engine.git"
  $head = (& git ls-remote $url "refs/heads/$channel" 2>$null)
  if ($LASTEXITCODE -ne 0 -or -not $head) { return $null }
  $sha = ($head -split "`t")[0]
  $tags = @()
  foreach ($row in (& git ls-remote --refs --tags $url 2>$null)) {
    $cells = $row -split "`t"
    if ($cells[0] -eq $sha) { $tags += $cells[1] -replace '^refs/tags/', '' }
  }
  if (-not $tags) { return '' }
  return @(Sort-Versions $tags)[-1]
}

function By-Api([string]$channel) {
  try {
    $ref = Invoke-RestMethod -Uri "$Api/repos/$Owner/$Engine/git/ref/heads/$channel" -UseBasicParsing
    $all = Invoke-RestMethod -Uri "$Api/repos/$Owner/$Engine/git/matching-refs/tags" -UseBasicParsing
  } catch {
    return $null
  }
  $tags = @($all | Where-Object { $_.object.sha -eq $ref.object.sha } |
    ForEach-Object { $_.ref -replace '^refs/tags/', '' })
  if (-not $tags) { return '' }
  return @(Sort-Versions $tags)[-1]
}

function Resolve-Channel([string]$channel) {
  $found = if (Get-Command git -ErrorAction SilentlyContinue) { By-Git $channel } else { By-Api $channel }
  if ($null -eq $found) { return $null }
  if ($found -eq '') { Fail "no tag on the tip of $channel" }
  return $found
}

function Asset-Name([string]$version) { return "$Engine-$version-$Platform.$Extension" }
function Asset-Url([string]$version) { return "$Forge/$Owner/$Packages/releases/download/$version/$(Asset-Name $version)" }

function Download([string]$version) {
  $name = Asset-Name $version
  $path = Join-Path $Work $name
  if (-not (Fetch (Asset-Url $version) $path)) { Fail "no asset $name on the release $version" 12 }
  if (-not (Fetch "$(Asset-Url $version).sha256" "$path.sha256")) { Fail "no $name.sha256 beside the asset" 12 }
  $expected = ((Get-Content "$path.sha256" -First 1) -split '\s+')[0].ToLower()
  $actual = Digest $path
  if ($expected -ne $actual) { Fail "$name does not match its sha256" 20 }
  return $actual
}

function Unpack([string]$version) {
  $tree = Join-Path $Work 'tree'
  Expand-Archive -Path (Join-Path $Work (Asset-Name $version)) -DestinationPath $tree
  $root = Join-Path $tree $Engine
  if (-not (Test-Path $root)) { Fail "the asset has no $Engine/ folder" }
  if (-not (Host-Of $root $Islands)) { Fail "the asset has no build\Island.exe" }
  if (-not (Host-Of $root $Reefs)) { Fail "the asset has no build\Reef.exe" }
  return $root
}

function Host-Of([string]$root, [string[]]$names) {
  foreach ($name in $names) {
    $path = Join-Path $root $name
    if (Test-Path $path) { return $path }
  }
  return $null
}

function Carry-Entry([string]$from, [string]$to) {
  if (-not (Test-Path $from)) { return }
  if (Test-Path $to) { return }
  $parent = Split-Path $to -Parent
  if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
  Move-Item -Path $from -Destination $to
}

function Carry([string]$from, [string]$to) {
  if (-not (Test-Path $from)) { return }
  foreach ($entry in Get-ChildItem -Force $from) {
    if ($entry.Name -eq $Record) { continue }
    if ($Carried -contains $entry.Name) {
      foreach ($inner in Get-ChildItem -Force $entry.FullName) {
        Carry-Entry $inner.FullName (Join-Path $to (Join-Path $entry.Name $inner.Name))
      }
    } else {
      Carry-Entry $entry.FullName (Join-Path $to $entry.Name)
    }
  }
}

function Take-Lock {
  $parent = Split-Path $Prefix -Parent
  if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
  try {
    New-Item -ItemType Directory -Path $Lock -ErrorAction Stop | Out-Null
  } catch {
    [Console]::Error.Write("install.ps1: another installer holds $Lock`n")
    exit 1
  }
}

function Await {
  if ($Wait -le 0) { return }
  $waited = 0
  while (Get-Process -Id $Wait -ErrorAction SilentlyContinue) {
    if ($waited -ge $WaitLimit) { Say "pid $Wait still runs"; break }
    Start-Sleep -Seconds 1
    $waited += 1
  }
}

function Swap([string]$root) {
  if (Test-Path $Previous) { Remove-Item -Recurse -Force $Previous }
  if (Test-Path $Prefix) {
    Move-Item -Path $Prefix -Destination $Previous
    Carry $Previous $root
  }
  Move-Item -Path $root -Destination $Prefix
}

function Place {
  $seat = Join-Path $Prefix 'installer'
  if (-not (Test-Path $seat)) { New-Item -ItemType Directory -Path $seat | Out-Null }
  $self = Join-Path $seat 'install.ps1'
  if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
    Copy-Item -Path $PSCommandPath -Destination $self -Force
  } elseif (-not (Fetch "$Forge/$Owner/$Installer/releases/latest/download/install.ps1" $self)) {
    Remove-Item -Force $self -ErrorAction SilentlyContinue
    Say 'installer not placed'
  }
  if (-not $Bin) { return }
  if (-not (Test-Path $Bin)) { New-Item -ItemType Directory -Path $Bin | Out-Null }
  $island = Host-Of $Prefix $Islands
  [System.IO.File]::WriteAllText((Join-Path $Bin 'islands.cmd'),
    "@echo off`r`n`"$island`" %*`r`n")
  if (Test-Path $self) {
    [System.IO.File]::WriteAllText((Join-Path $Bin 'islands-installer.cmd'),
      "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$self`" %*`r`n")
  }
}

function Launch {
  if (-not $Restart) { return }
  $island = Host-Of $Prefix $Islands
  Start-Process -FilePath $island -WorkingDirectory $Prefix | Out-Null
}

function Do-Check {
  $current = Recorded 'version'
  if (-not $current) { Say 'installed none'; exit 11 }
  $line = if ($Channel) { $Channel } else { Recorded 'channel' }
  if (-not $line) { $line = 'stable' }
  $wanted = Resolve-Channel $line
  Say "installed $current"
  if ($null -eq $wanted) { Say "$line unreached"; exit 12 }
  Say "$line $wanted"
  if ($wanted -eq $current) { exit 0 }
  exit 10
}

function Do-Install {
  $current = Recorded 'version'
  $line = ''
  if (-not $Version) {
    $line = if ($Channel) { $Channel } else { Recorded 'channel' }
    if (-not $line) { $line = 'stable' }
    $script:Version = Resolve-Channel $line
    if ($null -eq $Version) { Fail "$line unreached" 12 }
  }
  if ($Version -eq $current -and -not $Force) {
    Say "up to date $current"
    Launch
    Finish
    exit 0
  }
  $sum = Download $Version
  $root = Unpack $Version
  Await
  Swap $root
  Write-Record $Version $line $sum
  Place
  Say "installed $Version"
  Launch
}

function Do-Rollback {
  if (-not (Test-Path $Previous)) { Fail "nothing at $Previous" }
  if (-not (Test-Path $Prefix)) { Fail "nothing at $Prefix" }
  Await
  Carry $Prefix $Previous
  $undone = Join-Path $Work 'undone'
  Move-Item -Path $Prefix -Destination $undone
  Move-Item -Path $Previous -Destination $Prefix
  Move-Item -Path $undone -Destination $Previous
  Place
  Say "installed $(Recorded 'version')"
  Launch
}

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("islands-installer-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work | Out-Null
try {
  switch ($Command) {
    'check' { Do-Check }
    'rollback' { Take-Lock; Do-Rollback }
    default { Take-Lock; Do-Install }
  }
} finally {
  Finish
}
