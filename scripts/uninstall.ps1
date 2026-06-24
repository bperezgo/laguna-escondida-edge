#requires -RunAsAdministrator
<#
  uninstall.ps1 — stop & remove all edge services and the firewall rule.
  Run from an ELEVATED PowerShell:  .\scripts\uninstall.ps1
  Does NOT delete artifacts\ or caddy-data\ (so the CA root survives a reinstall).
#>
$ErrorActionPreference = 'SilentlyContinue'
$Root     = Split-Path -Parent $PSScriptRoot
$Services = Join-Path $Root 'services'
$order    = 'caddy','next','pos-printing','edge-node','postgres'   # reverse of install

foreach ($name in $order) {
  $exe = Join-Path $Services "$name.exe"
  if (Test-Path $exe) {
    Write-Host "Stopping & removing: $name"
    & $exe stop      | Out-Host
    & $exe uninstall | Out-Host
    Remove-Item $exe -Force
  }
}

Get-NetFirewallRule -DisplayName 'Laguna POS - Caddy (LAN tablets)' -ErrorAction SilentlyContinue |
  Remove-NetFirewallRule

Write-Host "Uninstalled. (artifacts\ and caddy-data\ left intact.)"
