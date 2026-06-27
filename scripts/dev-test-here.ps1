#requires -RunAsAdministrator
<#
.SYNOPSIS
  One-shot DEV setup to test the HTTPS + LAN-DNS flow on THIS development box.

  Does the box-side admin steps so a phone on this Wi-Fi can open
  https://pos.laguna.lan:
    1. Frees port 53 by stopping Windows ICS (SharedAccess) -- needed only because
       this dev box runs WSL/Hyper-V. Reversible with  -Restore.
    2. Marks the network Private (it's currently Public).
    3. Opens the LAN firewall: 443 + 80 (Caddy) and 53 UDP/TCP (DNS), subnet-scoped.
    4. Installs + configures Technitium DNS (via setup-technitium-dns.ps1).

  After this runs, you still: start Caddy, point the router DHCP DNS at this box,
  and install the root cert on the phone. The script prints those final steps.

.PARAMETER Restore
  Undo the dev-only changes: re-enable ICS and remove the firewall rules this added.
  (Leaves Technitium installed; uninstall from Apps if you want it gone.)

.EXAMPLE
  # Run from an ELEVATED PowerShell, from the repo root:
  .\scripts\dev-test-here.ps1

.EXAMPLE
  .\scripts\dev-test-here.ps1 -Restore
#>
[CmdletBinding()]
param(
  [string] $InterfaceAlias = 'Ethernet',
  [string] $BoxIP          = '192.168.0.123',
  [switch] $Restore
)

$ErrorActionPreference = 'Stop'
function Step($m) { Write-Host ("`n==> " + $m) -ForegroundColor Cyan }

$rules = @(
  @{ Name = 'Caddy LAN HTTPS 443'; Proto = 'TCP'; Port = 443 },
  @{ Name = 'Caddy LAN HTTP 80';   Proto = 'TCP'; Port = 80  },
  @{ Name = 'LAN DNS 53 UDP';      Proto = 'UDP'; Port = 53  },
  @{ Name = 'LAN DNS 53 TCP';      Proto = 'TCP'; Port = 53  }
)

# ===================== RESTORE =====================
if ($Restore) {
  # Disable Technitium first so it doesn't grab port 53 after reboot and block ICS.
  Step "Disabling Technitium DNS (so it won't fight ICS for port 53)"
  if (Get-Service DnsService -ErrorAction SilentlyContinue) {
    Stop-Service DnsService -Force -ErrorAction SilentlyContinue
    Set-Service  DnsService -StartupType Disabled
    Write-Host "Technitium DnsService stopped and disabled (still installed; remove via Apps if you want it gone)." -ForegroundColor Yellow
  } else {
    Write-Host "Technitium not installed -- nothing to disable." -ForegroundColor Green
  }
  Step "Re-enabling ICS (SharedAccess)"
  Set-Service SharedAccess -StartupType Automatic
  Start-Service SharedAccess -ErrorAction SilentlyContinue
  Step "Removing firewall rules this script added"
  foreach ($r in $rules) {
    Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  }
  Write-Host "`nRestored. REBOOT now to fully rebuild WSL/Hyper-V networking:" -ForegroundColor Green
  Write-Host "    Restart-Computer" -ForegroundColor Green
  return
}

# ===================== SETUP =====================

# 1. Free port 53 (stop ICS) ---------------------------------------------------------
# On a WSL/Hyper-V box, ICS is pinned by the "Default Switch" and CANNOT be stopped
# live -- so we disable it and reboot, after which port 53 comes up free.
Step "Freeing port 53 (Windows ICS / SharedAccess)"
$ics = Get-Service SharedAccess -ErrorAction SilentlyContinue
if ($ics -and $ics.Status -eq 'Running') {
  try {
    Stop-Service SharedAccess -Force -ErrorAction Stop
    Set-Service SharedAccess -StartupType Disabled
    Write-Host "ICS stopped and disabled." -ForegroundColor Yellow
  } catch {
    Set-Service SharedAccess -StartupType Disabled
    Write-Warning "ICS couldn't be stopped live (held by Hyper-V/WSL). It is now DISABLED."
    Write-Host "`n  >>> REBOOT, then re-run this script. Port 53 will be free after restart. <<<`n" -ForegroundColor Yellow
    return
  }
} else {
  Write-Host "ICS not running -- nothing to free." -ForegroundColor Green
}

# 2. Mark the network Private --------------------------------------------------------
Step "Marking '$InterfaceAlias' network as Private"
Set-NetConnectionProfile -InterfaceAlias $InterfaceAlias -NetworkCategory Private
Write-Host "Done." -ForegroundColor Green

# 3. Firewall rules (subnet-scoped) --------------------------------------------------
Step "Opening LAN firewall rules (443, 80, 53) for LocalSubnet only"
foreach ($r in $rules) {
  if (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue) {
    Write-Host ("  exists: {0}" -f $r.Name)
  } else {
    New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Allow `
      -Protocol $r.Proto -LocalPort $r.Port -Profile Private -RemoteAddress LocalSubnet | Out-Null
    Write-Host ("  added:  {0} ({1}/{2})" -f $r.Name, $r.Proto, $r.Port) -ForegroundColor Green
  }
}

# 4. Install + configure Technitium DNS ----------------------------------------------
Step "Installing + configuring Technitium DNS"
& (Join-Path $PSScriptRoot 'setup-technitium-dns.ps1') -BoxIP $BoxIP

# ===================== FINAL STEPS =====================
Step "Box-side setup complete. Remaining manual steps:"
Write-Host @"
1. START CADDY (separate window, no admin needed):
     cd C:\Users\USER\dev\laguna-escondida-edge
     .\artifacts\caddy\caddy.exe run --config .\Caddyfile --adapter caddyfile

2. ROUTER (TP-Link TL-WR850N):
     DHCP -> DHCP Settings:    Primary DNS = $BoxIP   (Secondary blank)
     DHCP -> Address Reservation: reserve $BoxIP for this box's MAC
     Then toggle Wi-Fi on the phone to pick up the new DNS.

3. PHONE:
     - Install certs\laguna-root.crt (Android: Settings > Security > Install a
       certificate > CA certificate.  iPhone: install profile, then
       Settings > General > About > Certificate Trust Settings > enable full trust).
     - Turn OFF Private DNS (Android: Settings > Network > Private DNS > Off).

4. TEST from the phone:  https://pos.laguna.lan   ->  no warning, app loads.

To undo the dev-only changes later:  .\scripts\dev-test-here.ps1 -Restore
"@ -ForegroundColor Green
