#requires -RunAsAdministrator
<#
  uninstall.ps1 — stop & remove all edge services and the firewall rule.
  Run from an ELEVATED PowerShell:  .\scripts\uninstall.ps1
  Does NOT delete artifacts\ or caddy-data\ (so the CA root survives a reinstall).
#>
# Not SilentlyContinue: a skipped stop leaves a service holding handles on artifacts\.
$ErrorActionPreference = 'Stop'
$Root     = Split-Path -Parent $PSScriptRoot
$Services = Join-Path $Root 'services'
# Reverse of install. The optional services are always listed so a box that dropped one is cleaned too.
$order    = 'updater','caddy','next','edge-node','postgres','alloy'

foreach ($name in $order) {
  $svcId = "laguna-$name"
  $exe   = Join-Path $Services "$name.exe"

  # Stop via SCM, not the wrapper exe, so a registration whose exe is already gone is still removed.
  if (Get-CimInstance Win32_Service -Filter "Name='$svcId'" -ErrorAction SilentlyContinue) {
    Write-Host "Stopping & removing service: $svcId"
    & sc.exe stop   $svcId | Out-Host
    try { (Get-Service $svcId).WaitForStatus('Stopped', (New-TimeSpan -Seconds 20)) }
    catch { Write-Warning "$svcId did not reach 'Stopped' within 20s; continuing to delete." }
    & sc.exe delete $svcId | Out-Host
  }

  # The wrapper process can hold <name>.exe briefly after 'Stopped', so retry the delete.
  if (Test-Path $exe) {
    $removed = $false
    foreach ($attempt in 1..10) {
      try { Remove-Item $exe -Force -ErrorAction Stop; $removed = $true; break }
      catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $removed) { Remove-Item $exe -Force }
  }
}

Get-NetFirewallRule -DisplayName 'Laguna POS - Caddy (LAN tablets)' -ErrorAction SilentlyContinue |
  Remove-NetFirewallRule

Write-Host "Uninstalled. (artifacts\, caddy-data\ and alloy-data\ left intact.)"
