#requires -RunAsAdministrator
<#
  update.ps1 — swap ONE service to its currently-pinned artifact with minimal downtime.
  Usage:  .\scripts\update.ps1 -Service next
#>
param(
  [Parameter(Mandatory)]
  [ValidateSet('edge-node','pos-printing','next','caddy','postgres')]
  [string] $Service
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$exe  = Join-Path (Join-Path $Root 'services') "$Service.exe"
if (-not (Test-Path $exe)) { throw "$Service is not installed. Run install.ps1 first." }

Write-Host "Stopping $Service ..."
& $exe stop | Out-Host

Write-Host "Re-fetching artifact ..."
& (Join-Path $PSScriptRoot 'fetch-artifacts.ps1')   # TODO: scope to a single artifact

Write-Host "Starting $Service ..."
& $exe start | Out-Host
Write-Host "Updated $Service."
