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
  # Must match the LAN/subnet in Caddyfile's @notlan guard (192.168.101.0/24).
  # Tighten this to your DHCP-reserved tablet IPs once you know them.
  [string[]] $AllowedTabletIPs = @('192.168.101.0/24')
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

# --- 1b. Stage the edge-node config (.env) next to its exe ------------------------
# The backend loads its config from a .env file in its working directory
# (cmd/main.go: godotenv.Load()). Copy the per-box env into the artifact folder.
$EnvSrc = Join-Path $Root 'env\edge-node.env'
$EnvDst = Join-Path $Root 'artifacts\edge-node\.env'
if (-not (Test-Path $EnvSrc)) {
  throw "Missing $EnvSrc. Copy env\edge-node.env.example to env\edge-node.env and fill it in."
}
New-Item -ItemType Directory -Force -Path (Split-Path $EnvDst) | Out-Null
Copy-Item $EnvSrc $EnvDst -Force
Write-Host "Staged edge-node config -> $EnvDst"

# --- 1c. Grant the Postgres service account access to the Postgres tree -----------
# postgres.exe refuses to run under a privileged account, so laguna-postgres runs as
# NT AUTHORITY\NetworkService (see services\postgres.xml). That account needs Modify on
# artifacts\postgres (write the data dir + read/execute the binaries). Use the well-known
# SID S-1-5-20 (locale-independent; the display name is localized on non-English Windows).
# Idempotent: re-granting the same ACE is a no-op.
$PgDir = Join-Path $Root 'artifacts\postgres'
if (Test-Path $PgDir) {
  Write-Host "Granting NetworkService (S-1-5-20) Modify on $PgDir"
  & icacls $PgDir /grant '*S-1-5-20:(OI)(CI)M' /T /C /Q | Out-Null
}
# WinSW runs AS the service account and writes postgres.*.log into logs\, so the
# Postgres service account needs Modify there too (the other services run as LocalSystem).
& icacls $Logs /grant '*S-1-5-20:(OI)(CI)M' /C /Q | Out-Null
# The Postgres service launches the WinSW wrapper services\postgres.exe (and reads postgres.xml)
# AS NetworkService. These live under the user profile, which grants NetworkService nothing by
# default -> SCM fails the start with "Access denied" BEFORE postgres.exe even runs. Grant
# Read/Execute on services\ (inheritable, so the wrapper exe copied in step 2 inherits it).
& icacls $Services /grant '*S-1-5-20:(OI)(CI)RX' /T /C /Q | Out-Null

# --- 2. Install services in dependency order --------------------------------------
# Postgres first; Caddy last. The <depend> entries in each XML also enforce ordering.
# WinSW finds "<name>.xml" automatically by matching the copied exe's basename.
$order = 'postgres','edge-node','next','caddy'

foreach ($name in $order) {
  $xml = Join-Path $Services "$name.xml"
  if (-not (Test-Path $xml)) { throw "Missing service definition: $xml" }
  $exe   = Join-Path $Services "$name.exe"
  $svcId = "laguna-$name"
  # Idempotent / self-healing: if this service is already registered (re-run, or a previous
  # partially-failed install/uninstall that left a "ghost" registration), remove it first via
  # sc.exe so `install` starts clean. sc.exe stop/delete take a single bare arg -> no quoting
  # pitfalls, and work even when the WinSW wrapper exe is missing or its XML was unparseable.
  if (Get-CimInstance Win32_Service -Filter "Name='$svcId'" -ErrorAction SilentlyContinue) {
    Write-Host "Service $svcId already exists; removing before reinstall"
    & sc.exe stop   $svcId | Out-Null      # ignore errors (may already be stopped)
    & sc.exe delete $svcId | Out-Null
    Start-Sleep -Seconds 2                  # let SCM finish deregistration before reinstalling
  }
  Copy-Item $WinSW $exe -Force
  Write-Host "Installing service: $name"
  & $exe install | Out-Host
}

# --- 2b. Force laguna-postgres to run as NetworkService ---------------------------
# postgres.exe refuses to run under a privileged account (LocalSystem default), so this ONE
# service must run as the low-privilege built-in NetworkService account. WinSW 2.x does NOT
# apply <serviceaccount> for built-in virtual accounts, and `sc.exe config` is fragile to
# call from PowerShell (token/quoting parsing -> error 1639). Use the Win32_Service CIM
# Change() method: robust, no quoting pitfalls, identical on every box. NetworkService needs
# no password and already holds "Log on as a service"; the data/log ACLs were granted above.
Write-Host "Setting laguna-postgres logon account -> NT AUTHORITY\NetworkService"
$pgSvc = Get-CimInstance Win32_Service -Filter "Name='laguna-postgres'"
if (-not $pgSvc) { throw "laguna-postgres service not found after install." }
$chg = Invoke-CimMethod -InputObject $pgSvc -MethodName Change -Arguments @{
  StartName     = 'NT AUTHORITY\NetworkService'
  StartPassword = ''
}
if ($chg.ReturnValue -ne 0) {
  throw "Failed to set laguna-postgres logon account (Win32_Service.Change returned $($chg.ReturnValue))."
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
