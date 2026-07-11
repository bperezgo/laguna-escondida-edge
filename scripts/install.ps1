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
  # IPs / CIDRs allowed to reach the app on :443 and :80. If omitted, this defaults to
  # LAGUNA_LAN_CIDR from env\box.env (the single source of truth, also used by the
  # Caddyfile @notlan guard). Pass this only to tighten to specific tablet IPs.
  [string[]] $AllowedTabletIPs
)

$ErrorActionPreference = 'Stop'
$Root     = Split-Path -Parent $PSScriptRoot
$Services = Join-Path $Root 'services'
$WinSW    = Join-Path $Services 'winsw.exe'
$Logs     = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $Logs | Out-Null

# --- 0. Network identity: read env\box.env, preflight, export for the Caddy service ----
# env\box.env is the SINGLE SOURCE OF TRUTH for this box's LAN IP/subnet. The Caddyfile
# uses {$LAGUNA_LAN_IP} / {$LAGUNA_LAN_CIDR} placeholders, the firewall rule below uses the
# same CIDR, and Caddy's cert SAN derives from the IP — so all three can never drift.
$BoxEnv = Join-Path $Root 'env\box.env'
if (-not (Test-Path $BoxEnv)) {
  throw "Missing $BoxEnv. Copy env\box.env.example to env\box.env and set LAGUNA_LAN_IP / LAGUNA_LAN_CIDR for this box."
}
$box = @{}
foreach ($line in Get-Content $BoxEnv) {
  $t = $line.Trim()
  if (-not $t -or $t.StartsWith('#')) { continue }
  $kv = $t -split '=', 2
  if ($kv.Count -eq 2) { $box[$kv[0].Trim()] = $kv[1].Trim() }
}
$LanIp   = $box['LAGUNA_LAN_IP']
$LanCidr = $box['LAGUNA_LAN_CIDR']
if (-not $LanIp -or -not $LanCidr) {
  throw "env\box.env must define both LAGUNA_LAN_IP and LAGUNA_LAN_CIDR."
}

# Preflight: the config must match reality, or Caddy serves a cert/site for an IP this box
# doesn't have and every request silently times out (services 'Running' but unreachable).
$boxIps = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
if ($boxIps -notcontains $LanIp) {
  throw ("box.env says LAGUNA_LAN_IP=$LanIp but this box does NOT hold that address. " +
         "This box has: $($boxIps -join ', '). Fix env\box.env (or set a DHCP reservation / static IP).")
}
# Preflight: LAGUNA_LAN_IP must fall inside LAGUNA_LAN_CIDR (else firewall blocks the box's own subnet).
$cidrParts = $LanCidr -split '/'
if ($cidrParts.Count -ne 2) { throw "LAGUNA_LAN_CIDR ('$LanCidr') is not valid CIDR (expected e.g. 192.168.0.0/24)." }
$prefix = [int]$cidrParts[1]
if ($prefix -lt 0 -or $prefix -gt 32) { throw "LAGUNA_LAN_CIDR prefix '/$prefix' is out of range (0-32)." }
function Convert-IpToUInt32([string]$ip) {
  $bytes = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()   # network (big-endian) order
  [Array]::Reverse($bytes)                                        # BitConverter wants little-endian
  return [System.BitConverter]::ToUInt32($bytes, 0)
}
# 0xFFFFFFFFL forces an Int64 literal (bare 0xFFFFFFFF parses as Int32 -1); -band keeps low 32 bits.
$mask  = [uint32]((0xFFFFFFFFL -shl (32 - $prefix)) -band 0xFFFFFFFFL)
$ipU   = Convert-IpToUInt32 $LanIp
$netU  = Convert-IpToUInt32 $cidrParts[0]
if (($ipU -band $mask) -ne ($netU -band $mask)) {
  throw "LAGUNA_LAN_IP=$LanIp is not inside LAGUNA_LAN_CIDR=$LanCidr. Fix env\box.env."
}

# Export as MACHINE env vars so the Caddy service (started below) resolves the {$...}
# placeholders. Set them in this process too for any immediate use.
[Environment]::SetEnvironmentVariable('LAGUNA_LAN_IP',   $LanIp,   'Machine')
[Environment]::SetEnvironmentVariable('LAGUNA_LAN_CIDR', $LanCidr, 'Machine')
$env:LAGUNA_LAN_IP   = $LanIp
$env:LAGUNA_LAN_CIDR = $LanCidr
Write-Host "Network identity OK: LAGUNA_LAN_IP=$LanIp  LAGUNA_LAN_CIDR=$LanCidr (from env\box.env)"

# Firewall default derives from the same CIDR unless the caller tightened it explicitly.
if (-not $PSBoundParameters.ContainsKey('AllowedTabletIPs')) { $AllowedTabletIPs = @($LanCidr) }

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
    & sc.exe stop $svcId | Out-Null        # ignore exit code: may already be stopped
    # WAIT for STOPPED before deleting. sc.exe stop only REQUESTS a stop and returns immediately;
    # a slow shutdown (e.g. postgres draining + checkpointing) keeps the WinSW wrapper alive, and
    # it holds a handle on services\<name>.exe until its child exits. Deleting/copying over that
    # locked exe is what fails the reinstall ("used by another process"). WaitForStatus blocks
    # until SCM reports Stopped (or times out); tolerate the timeout and press on to delete anyway.
    try { (Get-Service $svcId).WaitForStatus('Stopped', (New-TimeSpan -Seconds 30)) }
    catch { Write-Warning "$svcId did not reach 'Stopped' within 30s; continuing to delete." }
    & sc.exe delete $svcId | Out-Null
    Start-Sleep -Seconds 2                  # let SCM finish deregistration before reinstalling
  }
  # Copy the WinSW wrapper into place. RACE: even after SCM reports Stopped + deleted, the wrapper
  # process can linger briefly (killing its child, flushing logs), still holding <name>.exe. A
  # single Copy-Item then dies with "used by another process" and aborts the whole install. Retry
  # until the handle releases; only surface the error if it is still locked after that (mirrors
  # the Remove-Item retry in uninstall.ps1, which guards the same lingering-wrapper window).
  $copied = $false
  foreach ($attempt in 1..10) {
    try { Copy-Item $WinSW $exe -Force -ErrorAction Stop; $copied = $true; break }
    catch { Start-Sleep -Milliseconds 500 }
  }
  if (-not $copied) { Copy-Item $WinSW $exe -Force }   # final attempt: surface the real error
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

# --- 3b. Verify Caddy actually came up (catches an unresolved {$LAGUNA_LAN_*} placeholder) ---
# If the Caddy service didn't inherit the machine env vars, the caddyfile adapter errors on the
# {$...} placeholder and the service crash-loops. Surface that here instead of letting it look
# like a network problem. Give WinSW a moment to settle, then check the service state.
Start-Sleep -Seconds 3
$caddyState = (Get-Service laguna-caddy -ErrorAction SilentlyContinue).Status
if ($caddyState -ne 'Running') {
  $logTail = ''
  $errLog = Join-Path $Logs 'caddy.err.log'
  if (Test-Path $errLog) { $logTail = (Get-Content $errLog -Tail 15) -join "`n" }
  throw ("laguna-caddy is '$caddyState', not Running. The Caddyfile {`$LAGUNA_LAN_IP}/{`$LAGUNA_LAN_CIDR} " +
         "placeholders likely didn't resolve. Confirm the machine env vars, then re-run.`n--- caddy.err.log ---`n$logTail")
}
Write-Host "laguna-caddy is Running."

# --- 4. Windows Firewall: allow :443/:80 ONLY from known tablet IPs ----------------
$ruleName = 'Laguna POS - Caddy (LAN tablets)'
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $ruleName `
  -Direction Inbound -Action Allow -Protocol TCP `
  -LocalPort 443,80 -RemoteAddress $AllowedTabletIPs | Out-Null
Write-Host "Firewall rule set. Allowed: $($AllowedTabletIPs -join ', ')"

# --- 5. Export Caddy's internal-CA root cert + trust it on THIS box -----------------
# `tls internal` (Caddyfile) signs the LAN cert with Caddy's OWN private CA. Any client that
# hasn't installed that CA gets ERR_CERT_AUTHORITY_INVALID — the cert is valid, just untrusted.
# Caddy writes the root only when it issues its first cert, so poll briefly (services started
# just above). $CaddyData must match the Caddyfile `storage file_system { root ... }`.
$CaddyData  = 'C:\laguna-edge\caddy-data'
$RootCrt    = Join-Path $CaddyData 'pki\authorities\local\root.crt'
$RootExport = 'C:\laguna-edge\laguna-root-ca.crt'
$deadline   = (Get-Date).AddSeconds(30)
while (-not (Test-Path $RootCrt) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
if (Test-Path $RootCrt) {
  # Copy to a fixed, easy-to-grab path for distributing to dev PCs / tablets.
  Copy-Item $RootCrt $RootExport -Force
  Write-Host "Exported Caddy root CA -> $RootExport"
  # Trust it on THIS box too, so a browser opened on the box gets a clean padlock.
  # Idempotent: re-importing the same cert into LocalMachine\Root is a no-op.
  Import-Certificate -FilePath $RootCrt -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
  Write-Host "Trusted Caddy root CA in LocalMachine\Root on this box."
} else {
  Write-Warning "Caddy root CA not found at $RootCrt yet (Caddy writes it on its first request)."
  Write-Warning "Once it exists, export it with: Copy-Item '$RootCrt' '$RootExport'"
}

Write-Host ""
Write-Host "Done. Next steps:"
Write-Host "  - Dev PCs / tablets: install $RootExport as a Trusted Root CA, then open https://$LanIp"
Write-Host "      Windows client:  Import-Certificate -FilePath laguna-root-ca.crt -CertStoreLocation Cert:\LocalMachine\Root"
Write-Host "  - See provisioning\README.md and certs\README.md"
