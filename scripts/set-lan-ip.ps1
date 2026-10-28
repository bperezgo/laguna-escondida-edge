#requires -RunAsAdministrator
<#
  set-lan-ip.ps1 — re-point the box at its CURRENT LAN IP after DHCP moved it.

  Run from an ELEVATED PowerShell:
      .\scripts\set-lan-ip.ps1                      # auto-detect this box's LAN IP
      .\scripts\set-lan-ip.ps1 -IP 192.168.0.100    # or state it explicitly
      .\scripts\set-lan-ip.ps1 -IP 192.168.1.50 -Cidr 192.168.1.0/24   # subnet changed too

  WHY THIS EXISTS
  The router hands the box a new address on every reboot unless you pin it. When that
  happens the whole stack keeps reporting "Running" while being completely unreachable,
  because Caddy binds the OLD address. Three things have to move together:

    1. env\box.env            — the repo's source of truth (install.ps1 preflights against it)
    2. machine env vars       — what the Caddy service ACTUALLY resolves {$EDGE_LAN_IP} from
    3. the laguna-caddy service — only re-reads the env vars on process start, not on reload

  Editing box.env alone does nothing. `caddy reload` alone does nothing (it re-reads the
  file, not the environment). This script does all three, then proves it worked by reading
  the cert Caddy actually serves.

  This is a NARROW tool: it changes the network identity only. It does not touch service
  registration, artifacts, or the CA. For a full (re)install use install.ps1.

  The real fix for repeat drift is a DHCP reservation on the router (box MAC -> fixed IP);
  this script is the recovery when that hasn't been done yet.
#>
[CmdletBinding()]
param(
  # This box's LAN IPv4. Omit to auto-detect from the adapter holding the default gateway.
  [string] $IP,
  # The POS subnet in CIDR form. Omit to keep the current one, or derive it when the whole
  # subnet moved (e.g. the router came back as 192.168.1.x instead of 192.168.0.x).
  [string] $Cidr
)

$ErrorActionPreference = 'Stop'
$Root     = Split-Path -Parent $PSScriptRoot
$BoxEnv   = Join-Path $Root 'env\box.env'
$CaddyExe = Join-Path $Root 'services\caddy.exe'

if (-not (Test-Path $BoxEnv))   { throw "Missing $BoxEnv. Copy env\box.env.example to env\box.env first." }
if (-not (Test-Path $CaddyExe)) { throw "laguna-caddy is not installed (no $CaddyExe). Run scripts\install.ps1 first." }

# --- helpers ------------------------------------------------------------------------
# Same big-endian -> UInt32 conversion install.ps1 uses, so both agree on subnet math.
function Convert-IpToUInt32([string]$ip) {
  $bytes = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()   # network (big-endian) order
  [Array]::Reverse($bytes)                                        # BitConverter wants little-endian
  return [System.BitConverter]::ToUInt32($bytes, 0)
}
function Get-MaskFromPrefix([int]$prefix) {
  # 0xFFFFFFFFL forces Int64 (bare 0xFFFFFFFF parses as Int32 -1); -band keeps the low 32 bits.
  return [uint32]((0xFFFFFFFFL -shl (32 - $prefix)) -band 0xFFFFFFFFL)
}
function Get-NetworkCidr([string]$ip, [int]$prefix) {
  $netU  = (Convert-IpToUInt32 $ip) -band (Get-MaskFromPrefix $prefix)
  $bytes = [System.BitConverter]::GetBytes([uint32]$netU)
  [Array]::Reverse($bytes)                                        # back to network order
  return ("{0}/{1}" -f ([System.Net.IPAddress]::new($bytes)).ToString(), $prefix)
}
# Rewrite one KEY=value line in place, preserving every comment in the file. Appends the
# key if it is somehow absent, so the file is always left valid for install.ps1 to read.
function Set-EnvFileValue([string]$path, [string]$key, [string]$value) {
  # -Encoding UTF8 on the READ matters as much as on the write: Windows PowerShell 5.1
  # defaults to ANSI, which decodes this file's UTF-8 em-dashes into three Latin-1 chars —
  # writing those back out as UTF-8 double-encodes them into mojibake on every run.
  $lines = @(Get-Content $path -Encoding UTF8)
  $found = $false
  $out = foreach ($line in $lines) {
    if ($line -match "^\s*$([regex]::Escape($key))\s*=") { $found = $true; "$key=$value" }
    else { $line }
  }
  if (-not $found) { $out = @($out) + "$key=$value" }
  # UTF-8 WITHOUT a BOM. Set-Content -Encoding utf8 emits a BOM on Windows PowerShell 5.1,
  # and the BOM would glue itself to the first line that install.ps1's parser reads; plain
  # Set-Content defaults to ANSI, which mangles the em-dashes in this file's comments.
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllLines($path, [string[]]$out, $utf8NoBom)
}

# --- 1. Read the current identity from box.env ---------------------------------------
$box = @{}
foreach ($line in (Get-Content $BoxEnv -Encoding UTF8)) {
  $t = $line.Trim()
  if (-not $t -or $t.StartsWith('#')) { continue }
  $kv = $t -split '=', 2
  if ($kv.Count -eq 2) { $box[$kv[0].Trim()] = $kv[1].Trim() }
}
$oldIp   = $box['EDGE_LAN_IP']
$oldCidr = $box['EDGE_LAN_CIDR']
if (-not $oldCidr) { throw "env\box.env has no EDGE_LAN_CIDR. Set it (see env\box.env.example)." }

# --- 2. Work out the new identity ----------------------------------------------------
# Auto-detect = the adapter that holds the IPv4 default gateway. That is the one actually on
# the restaurant LAN; picking "first IPv4" would happily grab a Hyper-V/WSL/VPN virtual NIC
# and bind Caddy to an address no tablet can reach.
$detectedPrefix = $null
if (-not $IP) {
  $cfg = @(Get-NetIPConfiguration | Where-Object {
    $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address
  })
  if ($cfg.Count -eq 0) {
    throw "Could not auto-detect a LAN adapter with a default gateway. Pass -IP explicitly."
  }
  if ($cfg.Count -gt 1) {
    $names = ($cfg | ForEach-Object { "$($_.InterfaceAlias)=$($_.IPv4Address.IPAddress)" }) -join ', '
    throw "Multiple gateway adapters found ($names). Pass -IP explicitly to choose one."
  }
  $IP             = $cfg[0].IPv4Address.IPAddress
  $detectedPrefix = $cfg[0].IPv4Address.PrefixLength
  Write-Host "Detected LAN adapter '$($cfg[0].InterfaceAlias)' -> $IP/$detectedPrefix"
}

# Sanity: the box must actually HOLD the address we are about to serve on, or Caddy binds
# an address that does not exist and every tablet request times out against a "healthy" stack.
$boxIps = @((Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress)
if ($boxIps -notcontains $IP) {
  throw "This box does not hold $IP. It has: $($boxIps -join ', ')."
}

# CIDR: explicit wins; else keep the old one if the new IP still falls inside it; else derive
# it from the adapter's own prefix (the router handed us a different subnet entirely).
if (-not $Cidr) {
  $oldParts = $oldCidr -split '/'
  $inOld = $false
  if ($oldParts.Count -eq 2) {
    $mask  = Get-MaskFromPrefix ([int]$oldParts[1])
    $inOld = (((Convert-IpToUInt32 $IP) -band $mask) -eq ((Convert-IpToUInt32 $oldParts[0]) -band $mask))
  }
  if ($inOld) {
    $Cidr = $oldCidr
  } else {
    if (-not $detectedPrefix) {
      $detectedPrefix = (Get-NetIPAddress -IPAddress $IP -AddressFamily IPv4).PrefixLength
    }
    $Cidr = Get-NetworkCidr $IP $detectedPrefix
    Write-Warning "$IP is outside the old subnet $oldCidr. Deriving new EDGE_LAN_CIDR=$Cidr."
  }
}

$cidrChanged = ($Cidr -ne $oldCidr)
Write-Host ""
Write-Host "  IP   : $oldIp  ->  $IP"
Write-Host "  CIDR : $oldCidr  ->  $Cidr"
Write-Host ""

# --- 3. Apply: box.env, then the machine env vars Caddy actually reads ----------------
Set-EnvFileValue $BoxEnv 'EDGE_LAN_IP'   $IP
Set-EnvFileValue $BoxEnv 'EDGE_LAN_CIDR' $Cidr
Write-Host "Updated $BoxEnv"

[Environment]::SetEnvironmentVariable('EDGE_LAN_IP',   $IP,   'Machine')
[Environment]::SetEnvironmentVariable('EDGE_LAN_CIDR', $Cidr, 'Machine')
$env:EDGE_LAN_IP   = $IP
$env:EDGE_LAN_CIDR = $Cidr
Write-Host "Updated machine env vars"

# --- 4. Firewall — only when the SUBNET moved ----------------------------------------
# A new host address inside the same /24 is already covered by the existing rule. A new
# subnet is not, and would lock every tablet out at the packet level.
if ($cidrChanged) {
  $ruleName = 'Laguna POS - Caddy (LAN tablets)'
  $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
  if (-not $rule) {
    Write-Warning "Firewall rule '$ruleName' not found. Run install.ps1 to create it."
  } else {
    $remote = @(($rule | Get-NetFirewallAddressFilter).RemoteAddress)
    # Only auto-widen a rule that is still the plain old-CIDR default. If someone tightened it
    # to specific tablet IPs, silently replacing that with a whole subnet would undo a
    # deliberate hardening decision — say so and let them re-run install.ps1 with their list.
    if ($remote.Count -eq 1 -and $remote[0] -eq $oldCidr) {
      Set-NetFirewallRule -DisplayName $ruleName -RemoteAddress $Cidr
      Write-Host "Firewall rule remote range: $oldCidr -> $Cidr"
    } else {
      Write-Warning ("Firewall rule is tightened to: $($remote -join ', '). Left as-is. " +
                     "Re-run: install.ps1 -AllowedTabletIPs '<the new tablet IPs>'")
    }
  }
}

# --- 5. Restart Caddy (the ONLY service that carries the network identity) -------------
# Nothing depends on laguna-caddy, so this leaves Postgres / edge-node / Next untouched —
# no order lost, no session dropped beyond the few seconds of proxy downtime.
Write-Host "Restarting laguna-caddy ..."
Restart-Service laguna-caddy -Force
Start-Sleep -Seconds 4
$state = (Get-Service laguna-caddy).Status
if ($state -ne 'Running') {
  $errLog = Join-Path $Root 'logs\caddy.err.log'
  $tail = ''
  if (Test-Path $errLog) { $tail = (Get-Content $errLog -Tail 15) -join "`n" }
  throw "laguna-caddy is '$state', not Running.`n--- caddy.err.log ---`n$tail"
}
Write-Host "laguna-caddy is Running."

# --- 6. Prove it — read the cert Caddy is actually serving -----------------------------
# The service being "Running" proves nothing; it ran fine on the stale IP too. The cert SAN is
# the honest signal: `tls internal` re-issues on the new site address, so a SAN that still
# shows the OLD ip means the service inherited a stale environment block from the SCM.
$sanOk = $false
try {
  $tcp = New-Object Net.Sockets.TcpClient($IP, 443)
  $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, { $true })
  $ssl.AuthenticateAsClient($IP)
  $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
  foreach ($ext in $cert.Extensions) {
    # 2.5.29.17 = subjectAltName. Match by OID, not FriendlyName — the friendly name is
    # localized (this box reports "Dirección IP"), so a name match fails on es-ES Windows.
    if ($ext.Oid.Value -eq '2.5.29.17' -and $ext.Format($false) -match [regex]::Escape($IP)) {
      $sanOk = $true
    }
  }
  $ssl.Dispose(); $tcp.Dispose()
} catch {
  Write-Warning "Could not read the served certificate: $($_.Exception.Message)"
}

if ($sanOk) {
  Write-Host "Certificate SAN confirms $IP."
} else {
  Write-Warning ("The served cert does NOT carry $IP. The Service Control Manager likely " +
                 "cached the old environment block. REBOOT the box, then re-run this script.")
}

Write-Host ""
Write-Host "Done. Tablets now use:  https://$IP"
Write-Host "The internal CA root is unchanged, so already-provisioned tablets need no re-trust."
Write-Host "To stop this recurring: add a DHCP reservation on the router (this box's MAC -> $IP)."
