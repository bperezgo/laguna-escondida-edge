#requires -RunAsAdministrator
<#
  uninstall.ps1 — stop & remove all edge services and the firewall rule.
  Run from an ELEVATED PowerShell:  .\scripts\uninstall.ps1
  Does NOT delete artifacts\ or caddy-data\ (so the CA root survives a reinstall).
#>
# NOT SilentlyContinue: a silently-skipped stop leaves a service RUNNING with a handle on
# artifacts\ (e.g. laguna-next's node.exe locking artifacts\next), which then breaks the next
# build's clean-rebuild Remove-Item. We tolerate specific expected failures inline instead.
$ErrorActionPreference = 'Stop'
$Root     = Split-Path -Parent $PSScriptRoot
$Services = Join-Path $Root 'services'
$order    = 'caddy','next','edge-node','postgres'   # reverse of install

foreach ($name in $order) {
  $svcId = "laguna-$name"
  $exe   = Join-Path $Services "$name.exe"

  # 1. Stop by SERVICE NAME first — independent of the WinSW wrapper exe. A prior partial
  #    uninstall may have deleted services\<name>.exe while the registration + process live on
  #    (a "ghost"); stopping via SCM catches that, the old `if (Test-Path $exe)` guard did not.
  #    sc.exe stop takes a single bare arg (no quoting pitfalls) and no-ops cleanly if already
  #    stopped or absent, so we let it run regardless of registration state.
  if (Get-CimInstance Win32_Service -Filter "Name='$svcId'" -ErrorAction SilentlyContinue) {
    Write-Host "Stopping & removing service: $svcId"
    & sc.exe stop   $svcId | Out-Host   # ignore exit code: may already be stopped
    # Wait for STOPPED so file handles (artifacts\) are released before install/build touch them.
    try { (Get-Service $svcId).WaitForStatus('Stopped', (New-TimeSpan -Seconds 20)) }
    catch { Write-Warning "$svcId did not reach 'Stopped' within 20s; continuing to delete." }
    & sc.exe delete $svcId | Out-Host   # remove registration even if the wrapper exe is gone
  }

  # 2. Remove the WinSW wrapper exe if it is still on disk. RACE: WinSW's wrapper process
  #    can linger briefly after the service reports 'Stopped' — it is still killing its child
  #    (e.g. laguna-next's node.exe) and flushing logs, so it keeps a handle on <name>.exe.
  #    A single Remove-Item then dies with "Access denied" and aborts the whole uninstall.
  #    Retry for a few seconds until the handle is released; only surface the error if it
  #    is still locked after that (a genuinely stuck process, worth failing on).
  if (Test-Path $exe) {
    $removed = $false
    foreach ($attempt in 1..10) {
      try { Remove-Item $exe -Force -ErrorAction Stop; $removed = $true; break }
      catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $removed) { Remove-Item $exe -Force }   # final attempt: surface the real error
  }
}

Get-NetFirewallRule -DisplayName 'Laguna POS - Caddy (LAN tablets)' -ErrorAction SilentlyContinue |
  Remove-NetFirewallRule

Write-Host "Uninstalled. (artifacts\ and caddy-data\ left intact.)"
