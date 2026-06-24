#requires -RunAsAdministrator
<#
  install.ps1 — register the Laguna Escondida edge appliance as Windows services
  and lock down the firewall.

  Run from an ELEVATED PowerShell (Run as Administrator):
      .\scripts\install.ps1
      .\scripts\install.ps1 -AllowedTabletIPs '192.168.10.21','192.168.10.22'

  Re-runnable: it refreshes each service and the firewall rule.
  Pre-req: run scripts\fetch-artifacts.ps1 first so artifacts\ is populated.
#>
[CmdletBinding()]
param(
  # IPs / CIDRs allowed to reach the app on :443 and :80.
  # Tighten this to your DHCP-reserved tablet IPs once you know them.
  [string[]] $AllowedTabletIPs = @('192.168.10.0/24')
)

$ErrorActionPreference = 'Stop'
$Root     = Split-Path -Parent $PSScriptRoot
$Services = Join-Path $Root 'services'
$WinSW    = Join-Path $Services 'winsw.exe'
$Logs     = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $Logs | Out-Null

# --- 1. Ensure WinSW.exe is present ------------------------------------------------
if (-not (Test-Path $WinSW)) {
  $ver = (Get-Content (Join-Path $Root 'versions.json') | ConvertFrom-Json).winsw
  $url = "https://github.com/winsw/winsw/releases/download/v$ver/WinSW-x64.exe"
  Write-Host "Downloading WinSW v$ver ..."
  Invoke-WebRequest -Uri $url -OutFile $WinSW
}

# --- 2. Install services in dependency order --------------------------------------
# Postgres first; Caddy last. The <depend> entries in each XML also enforce ordering.
# WinSW finds "<name>.xml" automatically by matching the copied exe's basename.
$order = 'postgres','edge-node','pos-printing','next','caddy'

foreach ($name in $order) {
  $xml = Join-Path $Services "$name.xml"
  if (-not (Test-Path $xml)) { throw "Missing service definition: $xml" }
  $exe = Join-Path $Services "$name.exe"
  Copy-Item $WinSW $exe -Force
  Write-Host "Installing service: $name"
  & $exe install | Out-Host
}

# --- 3. Start services ------------------------------------------------------------
foreach ($name in $order) {
  Write-Host "Starting service: $name"
  & (Join-Path $Services "$name.exe") start | Out-Host
}

# --- 4. Windows Firewall: allow :443/:80 ONLY from known tablet IPs ----------------
$ruleName = 'Laguna POS - Caddy (LAN tablets)'
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $ruleName `
  -Direction Inbound -Action Allow -Protocol TCP `
  -LocalPort 443,80 -RemoteAddress $AllowedTabletIPs | Out-Null
Write-Host "Firewall rule set. Allowed: $($AllowedTabletIPs -join ', ')"

Write-Host ""
Write-Host "Done. Next steps:"
Write-Host "  - Provision tablets: install the Caddy root cert + point them at https://pos.laguna.lan"
Write-Host "  - See provisioning\README.md and certs\README.md"
