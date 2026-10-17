<#
  fetch-artifacts.ps1 -- download the pinned binaries/bundles into artifacts\.
  Reads versions.json.

  INFRASTRUCTURE (Caddy, Alloy, Node, Postgres, minisign) are public upstream downloads.
  APP artifacts (edge-node, next) are the Windows builds CI attaches to each app repo's
  GitHub Release (see .github/workflows/release.yml in -backend / -frontend). versions.json
  pins each to a release TAG; the download is checked against the release's .sha256 and
  REFUSED on mismatch. Nothing is compiled on the box (no Go / pnpm / source needed).
  scripts\build-artifacts.ps1 remains as a developer fallback for unreleased code.

  The installed tag is recorded in artifacts\<app>\RELEASE, so re-running is a no-op until
  versions.json changes (or -Force).

  Run:  .\scripts\fetch-artifacts.ps1                         # everything
        .\scripts\fetch-artifacts.ps1 -Only node,postgres     # subset
        .\scripts\fetch-artifacts.ps1 -Only next -DownloadOnly # download + verify into the cache only
#>
[CmdletBinding()]
param(
  # Which artifacts to fetch. Default: all of them.
  [ValidateSet('caddy','alloy','node','postgres','minisign','edge-node','next')]
  [string[]] $Only = @('caddy','alloy','node','postgres','minisign','edge-node','next'),
  [switch]   $Force,        # re-download/re-install even if the target already exists
  # App artifacts only: download + verify into the local cache, do not touch artifacts\.
  # update.ps1 uses this BEFORE stopping a service, so the download is not downtime.
  [switch]   $DownloadOnly
)

$ErrorActionPreference = 'Stop'
$Root      = Split-Path -Parent $PSScriptRoot
$Artifacts = Join-Path $Root 'artifacts'
$v         = Get-Content (Join-Path $Root 'versions.json') | ConvertFrom-Json
$tmp       = Join-Path $env:TEMP 'laguna-fetch'
# Verified app release zips, kept by tag so a staged download survives until install.
$cache     = Join-Path $Root 'artifacts\.cache'
# Releases are only ever downloaded from these repos (the updater will enforce the same).
$ReleaseOwner = 'bperezgo'
$ProgressPreference = 'SilentlyContinue'   # PS 5.1's progress bar makes Invoke-WebRequest crawl

New-Item -ItemType Directory -Force -Path $Artifacts, $tmp, $cache | Out-Null
function Want($name) { $Only -contains $name }
function Step($m) { Write-Host ("`n==> " + $m) -ForegroundColor Cyan }

function Get-Zip($url, $zipName) {
  $zip = Join-Path $tmp $zipName
  Write-Host "  downloading $url"
  Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
  $out = Join-Path $tmp ([IO.Path]::GetFileNameWithoutExtension($zipName))
  if (Test-Path $out) { Remove-Item $out -Recurse -Force }
  Expand-Archive -Path $zip -DestinationPath $out -Force
  return $out
}

# --- Caddy (official build) -------------------------------------------------------
if (Want 'caddy') {
  Step "Caddy $($v.caddy)"
  $dest = Join-Path $Artifacts 'caddy'
  if ((Test-Path (Join-Path $dest 'caddy.exe')) -and -not $Force) {
    Write-Host "  present -- skip (use -Force to refresh)."
  } else {
    $ex = Get-Zip "https://github.com/caddyserver/caddy/releases/download/v$($v.caddy)/caddy_$($v.caddy)_windows_amd64.zip" "caddy.zip"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item (Join-Path $ex 'caddy.exe') (Join-Path $dest 'caddy.exe') -Force
    Write-Host "  -> $dest\caddy.exe" -ForegroundColor Green
  }
}

# --- Grafana Alloy (telemetry sidecar) --------------------------------------------
if (Want 'alloy') {
  Step "Grafana Alloy $($v.alloy)"
  $dest = Join-Path $Artifacts 'alloy'
  if ((Test-Path (Join-Path $dest 'alloy.exe')) -and -not $Force) {
    Write-Host "  present -- skip."
  } else {
    # The zip holds a single 'alloy-windows-amd64.exe'; rename it to alloy.exe so
    # services\alloy.xml can point at a stable path across version bumps.
    $ex  = Get-Zip "https://github.com/grafana/alloy/releases/download/v$($v.alloy)/alloy-windows-amd64.exe.zip" "alloy.zip"
    $src = Join-Path $ex 'alloy-windows-amd64.exe'
    if (-not (Test-Path $src)) { throw "Unexpected Alloy archive layout under $ex" }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item $src (Join-Path $dest 'alloy.exe') -Force
    Write-Host "  -> $dest\alloy.exe" -ForegroundColor Green
  }
}

# --- Node runtime -----------------------------------------------------------------
if (Want 'node') {
  Step "Node $($v.node)"
  $dest = Join-Path $Artifacts 'node'
  if ((Test-Path (Join-Path $dest 'node.exe')) -and -not $Force) {
    Write-Host "  present -- skip."
  } else {
    $folder = "node-v$($v.node)-win-x64"
    $ex = Get-Zip "https://nodejs.org/dist/v$($v.node)/$folder.zip" "node.zip"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    # The zip extracts to <folder>\node.exe (+ npm etc). Copy the whole runtime.
    Copy-Item (Join-Path $ex "$folder\*") $dest -Recurse -Force
    Write-Host "  -> $dest\node.exe" -ForegroundColor Green
  }
}

# --- Postgres (EnterpriseDB portable binaries) ------------------------------------
if (Want 'postgres') {
  Step "Postgres $($v.postgres)"
  $dest = Join-Path $Artifacts 'postgres'
  if ((Test-Path (Join-Path $dest 'bin\postgres.exe')) -and -not $Force) {
    Write-Host "  present -- skip."
  } else {
    # EDB 'binaries' zip extracts to a top-level 'pgsql\' (bin, lib, share). Flatten
    # it into artifacts\postgres\ so postgres.xml finds artifacts\postgres\bin\postgres.exe.
    $ex = Get-Zip "https://get.enterprisedb.com/postgresql/postgresql-$($v.postgres)-1-windows-x64-binaries.zip" "pg.zip"
    $pgsql = Join-Path $ex 'pgsql'
    if (-not (Test-Path $pgsql)) { throw "Unexpected Postgres archive layout under $ex" }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item (Join-Path $pgsql '*') $dest -Recurse -Force
    Write-Host "  -> $dest\bin\postgres.exe" -ForegroundColor Green
    Write-Host "  NOTE: the data dir is NOT created here. Initialize it with scripts\init-postgres.ps1." -ForegroundColor Yellow
  }
}

# --- minisign (laguna-updater verifies release signatures with it) -----------------
if (Want 'minisign') {
  $ms = $v.minisign
  Step "minisign $($ms.version)"
  $dest = Join-Path $Artifacts 'minisign'
  if ((Test-Path (Join-Path $dest 'minisign.exe')) -and -not $Force) {
    Write-Host "  present -- skip."
  } else {
    # The updater trusts this binary to check signatures, so pin the zip itself by sha256.
    $zip = Join-Path $tmp 'minisign.zip'
    $url = "https://github.com/jedisct1/minisign/releases/download/$($ms.version)/minisign-$($ms.version)-win64.zip"
    Write-Host "  downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    $got = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $ms.sha256) { throw "CHECKSUM MISMATCH for minisign (expected $($ms.sha256), got $got)." }
    $ex = Join-Path $tmp 'minisign'
    if (Test-Path $ex) { Remove-Item $ex -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $ex -Force
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item (Join-Path $ex 'minisign-win64\x86_64\minisign.exe') (Join-Path $dest 'minisign.exe') -Force
    Write-Host "  -> $dest\minisign.exe" -ForegroundColor Green
  }
}

# --- App artifacts (edge-node, next) from GitHub Releases --------------------------
# Asset names match the app repos' release workflows.
$AppAssets = @{
  'edge-node' = { param($tag) "edge-node-windows-amd64-$tag.zip" }
  'next'      = { param($tag) "next-standalone-windows-$tag.zip" }
}

# Download <asset> and <asset>.sha256 for $tag into the cache and verify. Returns the zip
# path. A cached zip is re-verified, never trusted blindly; a bad one is deleted.
function Get-VerifiedRelease($app) {
  $pin = $v.artifacts.$app
  $tag = "$($pin.version)"
  if ($tag -notmatch '^v\d+\.\d+\.\d+') {
    throw ("versions.json pins $app to '$tag', which is not a release tag. Set " +
           "artifacts.$app.version to a tag of $($pin.repo) that has a Windows release asset (e.g. v1.2.0), " +
           "or build from source with scripts\build-artifacts.ps1 -Only $app.")
  }
  $asset = & $AppAssets[$app] $tag
  $base  = "https://github.com/$ReleaseOwner/$($pin.repo)/releases/download/$tag"
  $zip   = Join-Path $cache $asset
  $sumF  = "$zip.sha256"

  Write-Host "  $($pin.repo) $tag"
  # release.sh pins the sha256 too, so a zip the updater already staged installs offline.
  if ($pin.sha256) {
    $expected = "$($pin.sha256)".ToLower()
  } else {
    Invoke-WebRequest -Uri "$base/$asset.sha256" -OutFile $sumF -UseBasicParsing
    $expected = ((Get-Content $sumF -Raw).Trim() -split '\s+')[0].ToLower()
  }
  if ($expected -notmatch '^[0-9a-f]{64}$') { throw "$asset.sha256 is not a sha256 checksum." }

  if (-not (Test-Path $zip) -or ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() -ne $expected)) {
    Write-Host "  downloading $base/$asset"
    Invoke-WebRequest -Uri "$base/$asset" -OutFile $zip -UseBasicParsing
  } else {
    Write-Host "  cached (checksum ok)"
  }
  $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
  if ($actual -ne $expected) {
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    throw "CHECKSUM MISMATCH for $asset (expected $expected, got $actual). Refusing to install."
  }
  Write-Host "  sha256 ok  $actual" -ForegroundColor DarkGray
  return $zip
}

function Get-InstalledRelease($dest) {
  $f = Join-Path $dest 'RELEASE'
  if (Test-Path $f) { return (Get-Content $f -Raw).Trim() }
  return $null
}

foreach ($a in 'edge-node','next') {
  if (-not (Want $a)) { continue }
  $tag  = "$($v.artifacts.$a.version)"
  $dest = Join-Path $Artifacts $a
  Step "App artifact: $a $tag"
  if (-not $DownloadOnly -and -not $Force -and (Get-InstalledRelease $dest) -eq $tag) {
    Write-Host "  $tag already installed -- skip (use -Force to reinstall)."
    continue
  }
  $zip = Get-VerifiedRelease $a
  if ($DownloadOnly) { Write-Host "  staged: $zip" -ForegroundColor Green; continue }

  # Unpack to a scratch dir first, check the layout, THEN replace the live folder.
  $ex = Join-Path $cache "extract-$a-$tag"   # same volume as artifacts\, so Move-Item works
  if (Test-Path $ex) { Remove-Item $ex -Recurse -Force }
  Expand-Archive -Path $zip -DestinationPath $ex -Force

  if ($a -eq 'edge-node') {
    $src = Join-Path $ex 'edge-node.exe'
    if (-not (Test-Path $src)) { throw "Unexpected edge-node archive layout under $ex" }
    # Replace only the exe: artifacts\edge-node\.env (per-box config) stays as it is.
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item $src (Join-Path $dest 'edge-node.exe') -Force
  } else {
    foreach ($p in 'server.js', '.next\static', 'node_modules\next\package.json') {
      if (-not (Test-Path (Join-Path $ex $p))) { throw "Unexpected next archive layout: $p missing under $ex" }
    }
    # Whole-folder swap: never mix chunks from two builds. Nothing per-box lives in here.
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Move-Item $ex $dest
  }
  Set-Content (Join-Path $dest 'RELEASE') $tag -Encoding ascii
  Write-Host "  -> $dest  ($tag)" -ForegroundColor Green
}

$verb = 'Fetched'; if ($DownloadOnly) { $verb = 'Staged' }
Write-Host "`nDone. ${verb}: $($Only -join ', ')" -ForegroundColor Green
