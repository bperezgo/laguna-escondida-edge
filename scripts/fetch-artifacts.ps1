<#
  fetch-artifacts.ps1 — download the pinned binaries/bundles into artifacts\.
  Reads versions.json. The app-artifact steps are TODO until each repo publishes
  release artifacts; the Caddy/Node/Postgres steps are standard public downloads.

  Run:  .\scripts\fetch-artifacts.ps1
#>
$ErrorActionPreference = 'Stop'
$Root      = Split-Path -Parent $PSScriptRoot
$Artifacts = Join-Path $Root 'artifacts'
$v         = Get-Content (Join-Path $Root 'versions.json') | ConvertFrom-Json

function Ensure-Dir($p) { New-Item -ItemType Directory -Force -Path $p | Out-Null }

# --- Caddy (official build) -------------------------------------------------------
Ensure-Dir (Join-Path $Artifacts 'caddy')
# TODO: download + extract caddy.exe ->
#   https://github.com/caddyserver/caddy/releases/download/v$($v.caddy)/caddy_$($v.caddy)_windows_amd64.zip

# --- Node runtime -----------------------------------------------------------------
Ensure-Dir (Join-Path $Artifacts 'node')
# TODO: download node-v$($v.node)-win-x64.zip; place node.exe in artifacts\node\
#   https://nodejs.org/dist/v$($v.node)/node-v$($v.node)-win-x64.zip

# --- Postgres (portable) ----------------------------------------------------------
Ensure-Dir (Join-Path $Artifacts 'postgres')
# TODO: download portable Postgres $($v.postgres); initdb -> artifacts\postgres\data
#   (or skip and use the official installer; see services\postgres.xml note)

# --- App artifacts (from the three repos) -----------------------------------------
Ensure-Dir (Join-Path $Artifacts 'edge-node')
Ensure-Dir (Join-Path $Artifacts 'pos-printing')
Ensure-Dir (Join-Path $Artifacts 'next')
# TODO edge-node:    $($v.artifacts.'edge-node'.repo)    @ $($v.artifacts.'edge-node'.version)
#        -> artifacts\edge-node\edge-node.exe
# TODO pos-printing: $($v.artifacts.'pos-printing'.repo) @ $($v.artifacts.'pos-printing'.version)
#        -> artifacts\pos-printing\pos-printing.exe
# TODO next:         $($v.artifacts.next.repo)           @ $($v.artifacts.next.version)
#        -> artifacts\next\  (server.js + .next\static + public  from .next\standalone)

Write-Host "Artifact folders prepared under $Artifacts."
Write-Host "Fill in the TODO download steps, then run scripts\install.ps1."
