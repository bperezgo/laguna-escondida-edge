<#
  fetch-artifacts.ps1 -- download the pinned binaries/bundles into artifacts\.
  Reads versions.json.

  INFRASTRUCTURE (Caddy, Node, Postgres) are public downloads and are implemented
  below. APP artifacts (edge-node, next) are built locally from the sibling app repos
  by scripts\build-artifacts.ps1 (printing is built into edge-node — no separate service).

  Run:  .\scripts\fetch-artifacts.ps1
        .\scripts\fetch-artifacts.ps1 -Only node,postgres     # subset
#>
[CmdletBinding()]
param(
  # Which artifacts to fetch. Default: the infrastructure ones that are public.
  [ValidateSet('caddy','node','postgres','edge-node','next')]
  [string[]] $Only = @('caddy','node','postgres'),
  [switch]   $Force   # re-download even if the target already exists
)

$ErrorActionPreference = 'Stop'
$Root      = Split-Path -Parent $PSScriptRoot
$Artifacts = Join-Path $Root 'artifacts'
$v         = Get-Content (Join-Path $Root 'versions.json') | ConvertFrom-Json
$tmp       = Join-Path $env:TEMP 'laguna-fetch'

New-Item -ItemType Directory -Force -Path $Artifacts, $tmp | Out-Null
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

# --- App artifacts (edge-node, next) ----------------------------------------------
# These are built locally from the sibling app repos, not downloaded.
foreach ($a in 'edge-node','next') {
  if (Want $a) {
    Step "App artifact: $a"
    Write-Warning "Built locally, not fetched. Run scripts\build-artifacts.ps1 (Phase 2)."
  }
}

Write-Host "`nDone. Fetched: $(( $Only | Where-Object { $_ -in 'caddy','node','postgres' }) -join ', ')" -ForegroundColor Green
