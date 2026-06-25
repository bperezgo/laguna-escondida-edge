#requires -RunAsAdministrator
<#
.SYNOPSIS
  Fallback LAN DNS for the edge box when the router can't host local names
  (e.g. TP-Link TL-WR850N, which has no local-DNS / host-records feature).

  Installs Technitium DNS Server (if needed) and configures it to answer
  pos.laguna.lan -> <box IP> for the whole LAN, while forwarding everything
  else to upstream resolvers. After running this, set the router's DHCP
  Primary DNS to the box IP so every tablet/phone uses it.

.NOTES
  Run as Administrator. Installer is staged at artifacts\technitium\DnsServerSetup.exe
  (re-fetch from https://download.technitium.com/dns/ if missing).

  Web console after install:  http://localhost:5380   default login admin / admin
  (CHANGE THIS PASSWORD in the console after first run).

.EXAMPLE
  .\scripts\setup-technitium-dns.ps1 -BoxIP 192.168.101.49
#>
[CmdletBinding()]
param(
  [string]   $Hostname   = 'pos.laguna.lan',
  [string]   $Zone       = 'laguna.lan',
  [string]   $BoxIP      = '192.168.101.49',
  [string[]] $Forwarders = @('1.1.1.1', '8.8.8.8'),
  [string]   $AdminUser  = 'admin',
  [string]   $AdminPass  = 'admin',
  [int]      $TTL        = 3600
)

$ErrorActionPreference = 'Stop'
$api = 'http://localhost:5380/api'

function Step($m) { Write-Host ("`n==> " + $m) -ForegroundColor Cyan }

# Helper: call the Technitium API with query params passed as a hashtable so the
# request builder handles the & joining (no ampersands in the script source).
function Invoke-Dns($path, $query) {
  $pairs = foreach ($k in $query.Keys) {
    "{0}={1}" -f $k, [uri]::EscapeDataString([string]$query[$k])
  }
  $uri = "$api/$path`?" + ($pairs -join '&')
  Invoke-RestMethod -Uri $uri -TimeoutSec 10
}

# 1. Port 53 precheck ----------------------------------------------------------------
# On a dev box, Windows ICS (SharedAccess service) often squats on 0.0.0.0:53 for the
# WSL/Hyper-V virtual switches. A dedicated edge box normally has 53 free.
Step "Checking port 53"
$u53 = Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue
if ($u53) {
  $pid53 = ($u53 | Select-Object -First 1).OwningProcess
  $svc = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -eq $pid53 }
  Write-Warning ("Port 53 is already in use by PID {0} ({1})." -f $pid53, $svc.DisplayName)
  if ($svc.Name -eq 'SharedAccess') {
    Write-Warning "That's Internet Connection Sharing (ICS). Technitium can't bind 53 until it's freed."
    Write-Host   "To free it (also disables ICS NAT for WSL/Hyper-V internal switches):" -ForegroundColor Yellow
    Write-Host   "    Stop-Service SharedAccess; Set-Service SharedAccess -StartupType Disabled" -ForegroundColor Yellow
    throw "Resolve the port 53 conflict, then re-run."
  }
  throw "Free port 53 (stop the conflicting service), then re-run."
}
Write-Host "Port 53 is free." -ForegroundColor Green

# 2. Install Technitium if the service isn't present ---------------------------------
Step "Ensuring Technitium DNS Server is installed"
$dns = Get-Service -Name 'DnsService' -ErrorAction SilentlyContinue
if (-not $dns) {
  $installer = Join-Path $PSScriptRoot '..\artifacts\technitium\DnsServerSetup.exe'
  if (-not (Test-Path $installer)) {
    throw "Installer not found at $installer - fetch DnsServerSetup.zip from https://download.technitium.com/dns/ into artifacts\technitium\ first."
  }
  Write-Host "Launching the Technitium installer -- click through it (accept defaults)." -ForegroundColor Yellow
  Write-Host "This script will continue automatically once the installer closes."
  Start-Process -FilePath (Resolve-Path $installer) -Wait
  Start-Sleep -Seconds 5
  if (-not (Get-Service -Name 'DnsService' -ErrorAction SilentlyContinue)) {
    throw "DnsService not found after install. Re-run the installer, then re-run this script."
  }
} else {
  Write-Host ("Service 'DnsService' already present ({0})." -f $dns.Status)
}

# 3. Wait for the web API and authenticate -------------------------------------------
Step "Waiting for the DNS web console (localhost:5380)"
$token = $null
for ($i = 0; $i -lt 30; $i++) {
  try {
    $login = Invoke-Dns 'user/login' @{ user = $AdminUser; pass = $AdminPass; includeInfo = 'true' }
    if ($login.status -eq 'ok') { $token = $login.token; break }
    if ($login.status -eq 'error') { throw ("Login failed: {0}. If you changed the admin password, pass -AdminPass." -f $login.errorMessage) }
  } catch { Start-Sleep -Seconds 2 }
}
if (-not $token) { throw "Could not reach/authenticate the Technitium API after 60s." }
Write-Host "Authenticated." -ForegroundColor Green

# 4. Create the primary zone (idempotent) --------------------------------------------
Step ("Creating primary zone '{0}'" -f $Zone)
$z = Invoke-Dns 'zones/create' @{ token = $token; zone = $Zone; type = 'Primary' }
if ($z.status -eq 'ok') { Write-Host "Zone created." -ForegroundColor Green }
elseif ($z.errorMessage -match 'already exists') { Write-Host "Zone already exists - ok." }
else { throw ("Zone create failed: {0}" -f $z.errorMessage) }

# 5. Add/overwrite the A record  pos.laguna.lan -> BoxIP -----------------------------
Step ("Adding A record  {0} -> {1}" -f $Hostname, $BoxIP)
$r = Invoke-Dns 'zones/records/add' @{ token = $token; domain = $Hostname; zone = $Zone; type = 'A'; ipAddress = $BoxIP; ttl = $TTL; overwrite = 'true' }
if ($r.status -ne 'ok') { throw ("Record add failed: {0}" -f $r.errorMessage) }
Write-Host "A record set." -ForegroundColor Green

# 6. Set upstream forwarders (so internet names still resolve) -----------------------
Step ("Setting forwarders: {0}" -f ($Forwarders -join ', '))
$s = Invoke-Dns 'settings/set' @{ token = $token; forwarders = ($Forwarders -join ','); forwarderProtocol = 'Udp' }
if ($s.status -ne 'ok') { Write-Warning ("Forwarder set returned: {0}" -f $s.errorMessage) } else { Write-Host "Forwarders set." -ForegroundColor Green }

# Done -------------------------------------------------------------------------------
Step "Done"
Write-Host @"
The box is now a DNS server answering '$Hostname -> $BoxIP'.

NEXT (one-time, on the TP-Link TL-WR850N):
  - DHCP -> DHCP Settings: set Primary DNS = $BoxIP  (leave Secondary DNS blank, or
    also $BoxIP -- do NOT set a public DNS there, or '$Hostname' will fail randomly).
  - DHCP -> Address Reservation: bind the box MAC to $BoxIP so it never changes.
  - Renew the lease on a test device (toggle Wi-Fi) so it picks up the new DNS.

SECURITY:
  - Open http://localhost:5380 and change the admin password.
  - Allow inbound UDP+TCP 53 from the LAN only:
      New-NetFirewallRule -DisplayName 'LAN DNS 53 UDP' -Direction Inbound -Action Allow -Protocol UDP -LocalPort 53 -Profile Private -RemoteAddress LocalSubnet
      New-NetFirewallRule -DisplayName 'LAN DNS 53 TCP' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 53 -Profile Private -RemoteAddress LocalSubnet

TEST (from another device once the router DNS points here):
  nslookup $Hostname $BoxIP      # should return $BoxIP
"@ -ForegroundColor Green
