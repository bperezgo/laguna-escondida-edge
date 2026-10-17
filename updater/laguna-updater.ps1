<#
  laguna-updater.ps1 -- the laguna-updater service: stage signed releases, apply on request.

  Every -CheckMinutes it fetches the edge release manifest + its minisign signature, verifies
  the signature against updater\minisign.pub, and if the release is newer than the installed
  one, downloads every artifact and checks its sha256. Only then does it write
  state\update-available.json. It applies nothing on its own: it waits for
  state\update-requested.json (written by edge-node when the manager presses "Actualizar
  ahora"), then copies the release's files in and runs scripts\apply-release.ps1.

  Contract with edge-node and the app: docs\UPDATE_PROTOCOL.md.

  Run:  (as the laguna-updater service, see services\updater.xml)
        .\updater\laguna-updater.ps1 -Once                  # one check + pending request, then exit
        .\updater\laguna-updater.ps1 -Once -ManifestUrl C:\tmp\manifest.json   # local manifest (tests)
#>
[CmdletBinding()]
param(
  [string] $ManifestUrl = 'https://github.com/bperezgo/laguna-escondida-edge/releases/latest/download/manifest.json',
  [int]    $CheckMinutes = 30,
  [string] $PublicKeyFile,
  [switch] $Once
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # PS 5.1's progress bar makes Invoke-WebRequest crawl
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root     = Split-Path -Parent $PSScriptRoot
$StateDir = Join-Path $Root 'state'
$Staging  = Join-Path $StateDir 'staging'
$Minisign = Join-Path $Root 'artifacts\minisign\minisign.exe'
if (-not $PublicKeyFile) { $PublicKeyFile = Join-Path $PSScriptRoot 'minisign.pub' }
# Artifacts are only ever downloaded from this owner's GitHub Releases.
$AllowedPrefix = 'https://github.com/bperezgo/'
# Never written by an update: per-box config, data, and the updater itself (§6.1 of the plan:
# it does not replace itself in place; a technician updates it with install.ps1).
$Protected = @('env/', 'certs/', 'artifacts/', 'logs/', 'state/', 'backups/', 'caddy-data/',
               'alloy-data/', '.git/', 'updater/', 'services/updater.xml')
New-Item -ItemType Directory -Force -Path $StateDir, $Staging | Out-Null

function Log($m) { Write-Host ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $m) }

function State($name) { Join-Path $StateDir $name }

function Read-Json($path) {
  if (-not (Test-Path $path)) { return $null }
  try { return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
  catch { Log "ignoring unreadable $path : $_"; return $null }
}

# Atomic and BOM-free: edge-node reads these files while we write them.
function Write-Json($path, $obj) {
  $tmp = "$path.tmp"
  [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
  Move-Item $tmp $path -Force
}

function Get-Sha256($path) { (Get-FileHash $path -Algorithm SHA256).Hash.ToLower() }

# A box cloned with git on Windows has CRLF; the release zip has LF. That is not a change.
function Test-SameFile($a, $b) {
  if (-not (Test-Path $b)) { return $false }
  if ((Get-Sha256 $a) -eq (Get-Sha256 $b)) { return $true }
  return ([IO.File]::ReadAllText($a).Replace("`r`n", "`n") -eq [IO.File]::ReadAllText($b).Replace("`r`n", "`n"))
}

function ConvertTo-SemVer($tag) {
  if ("$tag" -notmatch '^v(\d+)\.(\d+)\.(\d+)$') { return $null }
  return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
}

function Get-InstalledVersion {
  $i = Read-Json (State 'installed.json')
  if ($i -and $i.version) { return "$($i.version)" }
  $v = Read-Json (Join-Path $Root 'versions.json')
  if ($v -and $v.appliance_version) { return "$($v.appliance_version)" }
  return 'v0.0.0'
}

# A manifest given as a local file (technician / CI) may point at local files; it is still
# signature-checked. Anything else downloads only from $AllowedPrefix.
$LocalManifest = Test-Path $ManifestUrl

function Save-Url($url, $out) {
  if ($LocalManifest -and (Test-Path $url)) { Copy-Item $url $out -Force; return }
  if (-not $url.StartsWith($AllowedPrefix)) { throw "refusing to download from $url (not $AllowedPrefix*)." }
  Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 600
}

function Test-Signature($file) {
  if (-not (Test-Path $Minisign)) { throw "missing $Minisign (fetch-artifacts.ps1 -Only minisign)." }
  if (-not (Test-Path $PublicKeyFile)) { throw "missing $PublicKeyFile; cannot verify releases." }
  & $Minisign -V -q -p $PublicKeyFile -m $file -x "$file.minisig" | Out-Null
  return ($LASTEXITCODE -eq 0)
}

# Download manifest.json + .minisig into $dir and return the verified manifest object.
function Get-VerifiedManifest($dir) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $file = Join-Path $dir 'manifest.json'
  Save-Url $ManifestUrl $file
  Save-Url "$ManifestUrl.minisig" "$file.minisig"
  if (-not (Test-Signature $file)) { throw 'manifest signature is INVALID; ignoring this release.' }
  $m = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not (ConvertTo-SemVer $m.appliance_version)) { throw "manifest appliance_version '$($m.appliance_version)' is not vX.Y.Z." }
  foreach ($c in 'edge','edge-node','next') {
    $x = $m.components.$c
    if (-not $x -or -not $x.url -or "$($x.sha256)" -notmatch '^[0-9a-f]{64}$') { throw "manifest component $c is incomplete." }
  }
  return $m
}

function Get-StagedFile($dir, $component) { Join-Path $dir ([IO.Path]::GetFileName($component.url)) }

# Every artifact in $dir matches the signed manifest's sha256.
function Test-Staged($m, $dir) {
  foreach ($c in 'edge','edge-node','next') {
    $f = Get-StagedFile $dir $m.components.$c
    if (-not (Test-Path $f) -or (Get-Sha256 $f) -ne $m.components.$c.sha256) { return $false }
  }
  return $true
}

# Infra (Caddy, Postgres, Node, ...) upgrades need fetch-artifacts + install.ps1 by a technician.
function Get-InfraChanges($m) {
  $local = Read-Json (Join-Path $Root 'versions.json')
  $diff = @()
  foreach ($p in $m.infra.PSObject.Properties) {
    if ("$($local.($p.Name))" -ne "$($p.Value)") { $diff += "$($p.Name) $($local.($p.Name)) -> $($p.Value)" }
  }
  return $diff
}

function Invoke-Check {
  $installed = Get-InstalledVersion
  $m = Get-VerifiedManifest (Join-Path $Staging 'incoming')
  $ver = "$($m.appliance_version)"
  if ((ConvertTo-SemVer $ver) -le (ConvertTo-SemVer $installed)) {
    Log "up to date ($installed; latest $ver)"
    Remove-Item (State 'update-available.json') -ErrorAction SilentlyContinue
    return
  }
  $infra = @(Get-InfraChanges $m)
  if ($infra) {
    Log "release $ver changes infra ($($infra -join ', ')); needs a technician, not offered."
    return
  }

  $dir = Join-Path $Staging $ver
  if (-not (Test-Staged $m $dir)) {
    Log "staging $ver"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($c in 'edge','edge-node','next') {
      $x = $m.components.$c
      $f = Get-StagedFile $dir $x
      if ((Test-Path $f) -and (Get-Sha256 $f) -eq $x.sha256) { continue }
      Log "  downloading $($x.url)"
      Save-Url $x.url $f
      $got = Get-Sha256 $f
      if ($got -ne $x.sha256) { Remove-Item $f -Force; throw "CHECKSUM MISMATCH for $($x.url) (expected $($x.sha256), got $got)." }
    }
  }
  Copy-Item (Join-Path $Staging 'incoming\manifest.json*') $dir -Force
  # Older staged releases are dead weight once a newer one is ready.
  Get-ChildItem $Staging -Directory | Where-Object { $_.Name -ne $ver -and $_.Name -ne 'incoming' } |
    ForEach-Object { Remove-Item $_.FullName -Recurse -Force }

  Write-Json (State 'update-available.json') ([ordered]@{
    version      = $ver
    current      = $installed
    published_at = $m.published_at
    notes_url    = "https://github.com/bperezgo/laguna-escondida-edge/releases/tag/$ver"
    components   = [ordered]@{ 'edge-node' = $m.components.'edge-node'.tag; next = $m.components.next.tag }
    checked_at   = (Get-Date).ToString('o')
  })
  Log "release $ver staged and verified; waiting for the manager to start it"
}

# Paths in the release zip that the update copies into the install root (forward slashes).
function Get-ReleaseFiles($src) {
  $base = (Resolve-Path $src).Path.TrimEnd('\') + '\'
  foreach ($f in Get-ChildItem $src -Recurse -File) {
    $rel = $f.FullName.Substring($base.Length).Replace('\', '/')
    if ($rel.Contains('..')) { throw "refusing path $rel from the release zip." }
    $skip = $false
    foreach ($p in $Protected) { if ($rel -eq $p -or $rel.StartsWith($p)) { $skip = $true; break } }
    if (-not $skip) { $rel }
  }
}

function Write-Outcome($ver, $outcome, $message) {
  $r = Read-Json (State 'update-result.json')
  $o = [ordered]@{ version = $ver; outcome = $outcome; message = $message; finished_at = (Get-Date).ToString('o') }
  if ($r -and $outcome -eq $r.outcome) {
    foreach ($p in $r.PSObject.Properties) { if (-not $o.Contains($p.Name)) { $o[$p.Name] = $p.Value } }
  }
  Write-Json (State 'update-result.json') $o
}

function Invoke-Apply {
  $req = Read-Json (State 'update-requested.json')
  Remove-Item (State 'update-requested.json') -Force
  $avail = Read-Json (State 'update-available.json')
  if (-not $req -or -not $avail -or "$($req.version)" -ne "$($avail.version)") {
    Log "ignoring update request for '$($req.version)' (staged: '$($avail.version)')"
    return
  }
  $ver = "$($avail.version)"
  $dir = Join-Path $Staging $ver
  $started = Get-Date
  Write-Json (State 'update-progress.json') ([ordered]@{ version = $ver; phase = 'applying'; started_at = $started.ToString('o') })
  Log "applying $ver (requested by $($req.requested_by))"

  $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
  $saved   = Join-Path $Root "backups\edge-$stamp"
  $copied  = @()   # files that existed before: restore from $saved
  $created = @()   # files the release added: delete on rollback
  $ok = $false
  try {
    $mfile = Join-Path $dir 'manifest.json'
    if (-not (Test-Signature $mfile)) { throw 'staged manifest signature is invalid.' }
    $m = Get-Content $mfile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ("$($m.appliance_version)" -ne $ver -or -not (Test-Staged $m $dir)) { throw 'staged release no longer matches its manifest.' }

    $src = Join-Path $dir 'edge'
    if (Test-Path $src) { Remove-Item $src -Recurse -Force }
    Expand-Archive (Get-StagedFile $dir $m.components.edge) $src -Force
    $pins = Get-Content (Join-Path $src 'versions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ("$($pins.appliance_version)" -ne $ver -or
        "$($pins.artifacts.'edge-node'.version)" -ne "$($m.components.'edge-node'.tag)" -or
        "$($pins.artifacts.next.version)" -ne "$($m.components.next.tag)") {
      throw 'the release zip pins different versions than its manifest.'
    }

    # The app zips go where fetch-artifacts.ps1 looks first, so applying needs no network.
    $cache = Join-Path $Root 'artifacts\.cache'
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    foreach ($c in 'edge-node','next') { Copy-Item (Get-StagedFile $dir $m.components.$c) $cache -Force }

    $reinstall = $false
    $updaterChanged = $false
    foreach ($rel in (Get-ReleaseFiles $src)) {
      $from = Join-Path $src $rel
      $to   = Join-Path $Root $rel
      if (Test-SameFile $from $to) { continue }
      if ($rel -eq 'Caddyfile' -or $rel -like 'services/*.xml' -or $rel -eq 'alloy/config.alloy') { $reinstall = $true }
      if (Test-Path $to) {
        $keep = Join-Path $saved $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $keep) | Out-Null
        Copy-Item $to $keep -Force
        $copied += $rel
      } else {
        $created += $rel
      }
      New-Item -ItemType Directory -Force -Path (Split-Path $to) | Out-Null
      Copy-Item $from $to -Force
    }
    foreach ($rel in 'updater/laguna-updater.ps1','updater/minisign.pub','services/updater.xml') {
      $a = Join-Path $src $rel; $b = Join-Path $Root $rel
      if ((Test-Path $a) -and -not (Test-SameFile $a $b)) { $updaterChanged = $true }
    }
    Log "copied $($copied.Count + $created.Count) changed files (reinstall: $reinstall)"

    $applyArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                   '-File', (Join-Path $Root 'scripts\apply-release.ps1'))
    if ($reinstall) { $applyArgs += '-Reinstall' }
    & powershell.exe @applyArgs | ForEach-Object { Log "  $_" }
    $code = $LASTEXITCODE
    $r = Read-Json (State 'update-result.json')
    $outcome = if ($r -and $r.finished_at -and ([datetime]$r.finished_at) -ge $started) { "$($r.outcome)" } else { 'rolled_back' }
    if ($code -eq 0 -and $outcome -eq 'success') {
      $ok = $true
      Write-Json (State 'installed.json') ([ordered]@{ version = $ver; applied_at = (Get-Date).ToString('o') })
      Remove-Item (State 'update-available.json') -ErrorAction SilentlyContinue
      $msg = "Actualizado a $ver."
      if ($updaterChanged) { $msg += ' (El actualizador tiene una versión nueva: un técnico debe ejecutar install.ps1.)' }
      Write-Outcome $ver 'success' $msg
      Log "applied $ver"
    } else {
      $msg = if ($r) { "$($r.message)" } else { "apply-release.ps1 exited $code" }
      Write-Outcome $ver $outcome $msg
      Log "apply of $ver ended '$outcome' (exit $code): $msg"
    }
  } catch {
    Log "apply of $ver failed before the services were touched: $_"
    Write-Outcome $ver 'refused' "$_"
  } finally {
    if (-not $ok -and ($copied -or $created)) {
      Log 'restoring the previous release files'
      foreach ($rel in $copied)  { Copy-Item (Join-Path $saved $rel) (Join-Path $Root $rel) -Force }
      foreach ($rel in $created) { Remove-Item (Join-Path $Root $rel) -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item (State 'update-progress.json') -ErrorAction SilentlyContinue
  }
}

Log "laguna-updater started (installed: $(Get-InstalledVersion), manifest: $ManifestUrl)"
# Left behind by a crash mid-apply, it would show "actualizando" forever.
Remove-Item (State 'update-progress.json') -ErrorAction SilentlyContinue
$nextCheck = Get-Date
while ($true) {
  if ((Get-Date) -ge $nextCheck) {
    try { Invoke-Check } catch { Log "check failed: $_" }
    $nextCheck = (Get-Date).AddMinutes($CheckMinutes)
  }
  if (Test-Path (State 'update-requested.json')) {
    try { Invoke-Apply } catch { Log "apply failed: $_" }
  }
  if ($Once) { break }
  Start-Sleep -Seconds 10
}
