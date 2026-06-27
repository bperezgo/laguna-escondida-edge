#requires -RunAsAdministrator
<#
  update.ps1 -- swap ONE service to a freshly-built/fetched artifact with minimal downtime.

  App services (edge-node, next) are rebuilt locally from the sibling repos via
  build-artifacts.ps1; infra services (caddy, postgres) are re-fetched via fetch-artifacts.ps1.

  Usage:  .\scripts\update.ps1 -Service next
          .\scripts\update.ps1 -Service edge-node
#>
param(
  [Parameter(Mandatory)]
  [ValidateSet('edge-node','next','caddy','postgres')]
  [string] $Service
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$exe  = Join-Path (Join-Path $Root 'services') "$Service.exe"
if (-not (Test-Path $exe)) { throw "$Service is not installed. Run install.ps1 first." }

Write-Host "Stopping $Service ..."
& $exe stop | Out-Host

if ($Service -in 'edge-node','next') {
  Write-Host "Rebuilding $Service from source ..."
  & (Join-Path $PSScriptRoot 'build-artifacts.ps1') -Only $Service
} else {
  Write-Host "Re-fetching $Service binary ..."
  & (Join-Path $PSScriptRoot 'fetch-artifacts.ps1') -Only $Service -Force
}

# edge-node reads its config from a .env next to the exe; refresh it in case it changed.
if ($Service -eq 'edge-node') {
  $envSrc = Join-Path $Root 'env\edge-node.env'
  if (Test-Path $envSrc) { Copy-Item $envSrc (Join-Path $Root 'artifacts\edge-node\.env') -Force }
}

Write-Host "Starting $Service ..."
& $exe start | Out-Host
Write-Host "Updated $Service."
