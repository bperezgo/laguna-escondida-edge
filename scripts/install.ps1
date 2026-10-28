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
  # IPs / CIDRs allowed on :443 and :80. Defaults to EDGE_LAN_CIDR from env\box.env.
  [string[]] $AllowedTabletIPs
)

$ErrorActionPreference = 'Stop'
$Root     = Split-Path -Parent $PSScriptRoot
$Services = Join-Path $Root 'services'
$WinSW    = Join-Path $Services 'winsw.exe'
$Logs     = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $Logs | Out-Null

# --- 0. Network identity from env\box.env (feeds the Caddyfile, cert SAN and firewall) ----
$BoxEnv = Join-Path $Root 'env\box.env'
if (-not (Test-Path $BoxEnv)) {
  throw "Missing $BoxEnv. Copy env\box.env.example to env\box.env and set EDGE_LAN_IP / EDGE_LAN_CIDR for this box."
}
$box = @{}
foreach ($line in Get-Content $BoxEnv) {
  $t = $line.Trim()
  if (-not $t -or $t.StartsWith('#')) { continue }
  $kv = $t -split '=', 2
  if ($kv.Count -eq 2) { $box[$kv[0].Trim()] = $kv[1].Trim() }
}
function Assert-NoLegacyKeys([hashtable]$cfg, [string]$file) {
  $legacy = @($cfg.Keys | Where-Object { $_ -like 'LAGUNA_*' })
  if ($legacy) {
    throw ("$file uses the old LAGUNA_ prefix ($($legacy -join ', ')). " +
           "Rename each to EDGE_ (e.g. LAGUNA_LAN_IP -> EDGE_LAN_IP); see $file.example.")
  }
}
Assert-NoLegacyKeys $box 'env\box.env'
$LanIp   = $box['EDGE_LAN_IP']
$LanCidr = $box['EDGE_LAN_CIDR']
if (-not $LanIp -or -not $LanCidr) {
  throw "env\box.env must define both EDGE_LAN_IP and EDGE_LAN_CIDR."
}
# Optional, comma-separated. Blank keeps the box IP-only.
$LanHost = $box['EDGE_LAN_HOST']

# A wrong IP leaves every service Running but unreachable, so fail loudly here.
$boxIps = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
if ($boxIps -notcontains $LanIp) {
  throw ("box.env says EDGE_LAN_IP=$LanIp but this box does NOT hold that address. " +
         "This box has: $($boxIps -join ', '). Fix env\box.env (or set a DHCP reservation / static IP).")
}
$cidrParts = $LanCidr -split '/'
if ($cidrParts.Count -ne 2) { throw "EDGE_LAN_CIDR ('$LanCidr') is not valid CIDR (expected e.g. 192.168.0.0/24)." }
$prefix = [int]$cidrParts[1]
if ($prefix -lt 0 -or $prefix -gt 32) { throw "EDGE_LAN_CIDR prefix '/$prefix' is out of range (0-32)." }
function Convert-IpToUInt32([string]$ip) {
  $bytes = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
  [Array]::Reverse($bytes)
  return [System.BitConverter]::ToUInt32($bytes, 0)
}
# 0xFFFFFFFFL: a bare 0xFFFFFFFF parses as Int32 -1.
$mask  = [uint32]((0xFFFFFFFFL -shl (32 - $prefix)) -band 0xFFFFFFFFL)
$ipU   = Convert-IpToUInt32 $LanIp
$netU  = Convert-IpToUInt32 $cidrParts[0]
if (($ipU -band $mask) -ne ($netU -band $mask)) {
  throw "EDGE_LAN_IP=$LanIp is not inside EDGE_LAN_CIDR=$LanCidr. Fix env\box.env."
}

# Composed here, not in the Caddyfile, so a blank host doesn't leave an empty ", <ip>" label.
if ($LanHost) { $SiteAddr = "$LanHost, $LanIp" } else { $SiteAddr = $LanIp }

# Machine scope so the Caddy service resolves the {$...} placeholders.
[Environment]::SetEnvironmentVariable('EDGE_LAN_IP',    $LanIp,    'Machine')
[Environment]::SetEnvironmentVariable('EDGE_LAN_CIDR',  $LanCidr,  'Machine')
[Environment]::SetEnvironmentVariable('EDGE_SITE_ADDR', $SiteAddr, 'Machine')
$env:EDGE_LAN_IP    = $LanIp
$env:EDGE_LAN_CIDR  = $LanCidr
$env:EDGE_SITE_ADDR = $SiteAddr
Write-Host "Network identity OK: EDGE_SITE_ADDR='$SiteAddr'  EDGE_LAN_CIDR=$LanCidr (from env\box.env)"

# Every var this repo sets is EDGE_* now; drop the pre-rename copies so nothing reads stale values.
$machineEnv = [Environment]::GetEnvironmentVariables('Machine')
foreach ($name in @($machineEnv.Keys | Where-Object { $_ -like 'LAGUNA_*' })) {
  [Environment]::SetEnvironmentVariable($name, $null, 'Machine')
}

if (-not $PSBoundParameters.ContainsKey('AllowedTabletIPs')) { $AllowedTabletIPs = @($LanCidr) }

# --- 1. Ensure WinSW.exe is present ------------------------------------------------
if (-not (Test-Path $WinSW)) {
  $ver = (Get-Content (Join-Path $Root 'versions.json') | ConvertFrom-Json).winsw
  $url = "https://github.com/winsw/winsw/releases/download/v$ver/WinSW-x64.exe"
  Write-Host "Downloading WinSW v$ver ..."
  Invoke-WebRequest -Uri $url -OutFile $WinSW
}

# --- 1b. Stage the edge-node .env (loaded from its working directory) --------------
$EnvSrc = Join-Path $Root 'env\edge-node.env'
$EnvDst = Join-Path $Root 'artifacts\edge-node\.env'
if (-not (Test-Path $EnvSrc)) {
  throw "Missing $EnvSrc. Copy env\edge-node.env.example to env\edge-node.env and fill it in."
}
New-Item -ItemType Directory -Force -Path (Split-Path $EnvDst) | Out-Null
Copy-Item $EnvSrc $EnvDst -Force
Write-Host "Staged edge-node config -> $EnvDst"

# --- 1c. Grant NetworkService (S-1-5-20) what laguna-postgres needs ---------------
# postgres.exe refuses privileged accounts. SIDs, not names, so non-English Windows works.
$PgDir = Join-Path $Root 'artifacts\postgres'
if (Test-Path $PgDir) {
  Write-Host "Granting NetworkService (S-1-5-20) Modify on $PgDir"
  & icacls $PgDir /grant '*S-1-5-20:(OI)(CI)M' /T /C /Q | Out-Null
}
& icacls $Logs /grant '*S-1-5-20:(OI)(CI)M' /C /Q | Out-Null
# Without RX on services\, SCM fails the start with "Access denied" before postgres.exe runs.
& icacls $Services /grant '*S-1-5-20:(OI)(CI)RX' /T /C /Q | Out-Null

# --- 1d. Telemetry sidecar (opt-in: only when env\alloy.env exists) ---------------
$AlloyEnv    = Join-Path $Root 'env\alloy.env'
$InstallAlloy = Test-Path $AlloyEnv
if (-not $InstallAlloy) {
  Write-Host "No env\alloy.env -- skipping the telemetry sidecar (copy env\alloy.env.example to enable it)."
} else {
  $alloyCfg = @{}
  foreach ($line in Get-Content $AlloyEnv) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    $kv = $t -split '=', 2
    if ($kv.Count -eq 2) { $alloyCfg[$kv[0].Trim()] = $kv[1].Trim() }
  }

  Assert-NoLegacyKeys $alloyCfg 'env\alloy.env'

  $NodeKey = $alloyCfg['EDGE_NODE_KEY']
  if (-not $NodeKey -or $NodeKey -eq 'CHANGE_ME') {
    throw "env\alloy.env must set EDGE_NODE_KEY (same value as NODE_SYNC_KEY in env\edge-node.env)."
  }
  if (-not $alloyCfg['EDGE_TELEMETRY_INGEST_URL']) {
    throw "env\alloy.env must set EDGE_TELEMETRY_INGEST_URL (the cloud backend's /api/telemetry base URL)."
  }

  # Alloy stamps metrics and the app stamps logs/traces; a mismatch shows one box as two.
  $nodeCfg = @{}
  foreach ($line in Get-Content $EnvSrc) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    $kv = $t -split '=', 2
    if ($kv.Count -eq 2) { $nodeCfg[$kv[0].Trim()] = $kv[1].Trim() }
  }
  # A blank NODE_ID is derived inside the app, and Alloy can't reproduce it.
  if (-not $nodeCfg['NODE_ID']) {
    throw ("env\edge-node.env must set NODE_ID explicitly when the telemetry sidecar is enabled " +
           "(it is otherwise derived inside the app and Alloy cannot know the value). " +
           "Pick a stable id for this box and set the SAME value as EDGE_NODE_ID in env\alloy.env.")
  }
  if ($alloyCfg['EDGE_NODE_ID'] -ne $nodeCfg['NODE_ID']) {
    throw "EDGE_NODE_ID ('$($alloyCfg['EDGE_NODE_ID'])') must equal NODE_ID ('$($nodeCfg['NODE_ID'])') in env\edge-node.env."
  }
  if ($alloyCfg['EDGE_ORGANIZATION_ID'] -ne $nodeCfg['ORGANIZATION_ID']) {
    throw "EDGE_ORGANIZATION_ID ('$($alloyCfg['EDGE_ORGANIZATION_ID'])') must equal ORGANIZATION_ID ('$($nodeCfg['ORGANIZATION_ID'])') in env\edge-node.env."
  }
  if ($nodeCfg['NODE_SYNC_KEY'] -and $NodeKey -ne $nodeCfg['NODE_SYNC_KEY']) {
    throw "EDGE_NODE_KEY must equal NODE_SYNC_KEY in env\edge-node.env -- the cloud matches both against one key."
  }

  # WriteAllText: a BOM or trailing newline would end up in X-Node-Key and cause 401s.
  $KeyFile = Join-Path $Root 'env\alloy-node-key'
  [IO.File]::WriteAllText($KeyFile, $NodeKey)
  # LocalSystem (S-1-5-18) and Administrators (S-1-5-32-544) only.
  & icacls $KeyFile /inheritance:r /grant '*S-1-5-18:(R)' '*S-1-5-32-544:(F)' /C /Q | Out-Null

  $BufferDir = $alloyCfg['EDGE_TELEMETRY_BUFFER_DIR']
  if (-not $BufferDir) { $BufferDir = Join-Path $Root 'alloy-data\buffer' }
  New-Item -ItemType Directory -Force -Path $BufferDir, (Join-Path $Root 'alloy-data\wal') | Out-Null

  # EDGE_* only, so a typo can't set PATH machine-wide. The key stays out of the environment.
  foreach ($k in $alloyCfg.Keys) {
    if ($k -eq 'EDGE_NODE_KEY' -or $k -notlike 'EDGE_*') { continue }
    [Environment]::SetEnvironmentVariable($k, $alloyCfg[$k], 'Machine')
    Set-Item -Path "env:$k" -Value $alloyCfg[$k]
  }
  [Environment]::SetEnvironmentVariable('EDGE_NODE_KEY_FILE',        $KeyFile,   'Machine')
  [Environment]::SetEnvironmentVariable('EDGE_TELEMETRY_BUFFER_DIR', $BufferDir, 'Machine')
  $env:EDGE_NODE_KEY_FILE        = $KeyFile
  $env:EDGE_TELEMETRY_BUFFER_DIR = $BufferDir


  # Fail here rather than as a crash-looping service.
  $AlloyExe = Join-Path $Root 'artifacts\alloy\alloy.exe'
  if (-not (Test-Path $AlloyExe)) {
    throw "Missing $AlloyExe. Run scripts\fetch-artifacts.ps1 -Only alloy first."
  }
  & $AlloyExe validate --stability.level=public-preview (Join-Path $Root 'alloy\config.alloy') | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "alloy\config.alloy failed validation; fix it before installing." }
  Write-Host "Telemetry sidecar config OK -> $($alloyCfg['EDGE_TELEMETRY_INGEST_URL']) (node $($alloyCfg['EDGE_NODE_ID']))"
}

# --- 1e. Owner-triggered updates: the updater's state and DB backup dirs -------------
# SYSTEM and Administrators only: a request file starts an install, and backups hold the whole DB.
$StateDir = Join-Path $Root 'state'
foreach ($d in $StateDir, (Join-Path $Root 'backups')) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  & icacls $d /inheritance:r /grant '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /C /Q | Out-Null
}
if (-not (Select-String -Path $EnvSrc -Pattern '^\s*EDGE_STATE_DIR\s*=\s*[^\s#]' -Quiet)) {
  Write-Warning "env\edge-node.env has no EDGE_STATE_DIR, so the POS will not offer updates. Add: EDGE_STATE_DIR=$StateDir"
}

# --- 2. Install services in dependency order --------------------------------------
# WinSW finds <name>.xml by matching the copied exe's basename.
$order = 'postgres','edge-node','next','caddy'
# Alloy first so OTLP is listening when edge-node starts exporting.
if ($InstallAlloy) { $order = @('alloy') + $order }

# On a re-run, stop everything first, dependents before what they depend on: SCM refuses to
# stop laguna-postgres while laguna-edge-node is running, which left postgres.exe locked.
foreach ($name in 'caddy','next','edge-node','postgres','alloy') {
  $svcId = "laguna-$name"
  if (-not (Get-CimInstance Win32_Service -Filter "Name='$svcId'" -ErrorAction SilentlyContinue)) { continue }
  Write-Host "Stopping $svcId before reinstall"
  & sc.exe stop $svcId | Out-Null
  try { (Get-Service $svcId).WaitForStatus('Stopped', (New-TimeSpan -Seconds 30)) }
  catch { Write-Warning "$svcId did not reach 'Stopped' within 30s." }
}

foreach ($name in $order) {
  $xml = Join-Path $Services "$name.xml"
  if (-not (Test-Path $xml)) { throw "Missing service definition: $xml" }
  $exe   = Join-Path $Services "$name.exe"
  $svcId = "laguna-$name"
  # Remove any existing registration via sc.exe, which works even if the wrapper exe is gone.
  if (Get-CimInstance Win32_Service -Filter "Name='$svcId'" -ErrorAction SilentlyContinue) {
    Write-Host "Service $svcId already exists; removing before reinstall"
    & sc.exe stop $svcId | Out-Null
    # sc.exe stop returns immediately; the wrapper keeps <name>.exe locked until it exits.
    try { (Get-Service $svcId).WaitForStatus('Stopped', (New-TimeSpan -Seconds 30)) }
    catch { Write-Warning "$svcId did not reach 'Stopped' within 30s; continuing to delete." }
    & sc.exe delete $svcId | Out-Null
    Start-Sleep -Seconds 2
  }
  # The wrapper can linger after deletion, still holding <name>.exe, so retry the copy.
  $copied = $false
  foreach ($attempt in 1..10) {
    try { Copy-Item $WinSW $exe -Force -ErrorAction Stop; $copied = $true; break }
    catch { Start-Sleep -Milliseconds 500 }
  }
  if (-not $copied) { Copy-Item $WinSW $exe -Force }
  Write-Host "Installing service: $name"
  & $exe install | Out-Host
}

# --- 2b. Run laguna-postgres as NetworkService -------------------------------------
# WinSW 2.x ignores <serviceaccount> for built-in accounts, and sc.exe config hits error 1639
# from PowerShell, so use Win32_Service.Change().
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

# --- 3b. Verify Caddy came up (an unresolved {$...} placeholder crash-loops it) -----
Start-Sleep -Seconds 3
$caddyState = (Get-Service laguna-caddy -ErrorAction SilentlyContinue).Status
if ($caddyState -ne 'Running') {
  $logTail = ''
  $errLog = Join-Path $Logs 'caddy.err.log'
  if (Test-Path $errLog) { $logTail = (Get-Content $errLog -Tail 15) -join "`n" }
  throw ("laguna-caddy is '$caddyState', not Running. The Caddyfile {`$EDGE_SITE_ADDR}/{`$EDGE_LAN_CIDR} " +
         "placeholders likely didn't resolve. Confirm the machine env vars, then re-run.`n--- caddy.err.log ---`n$logTail")
}
Write-Host "laguna-caddy is Running."

# --- 3c. Verify the telemetry sidecar --------------------------------------------
# Warn, don't throw: a broken sidecar must never fail an otherwise working install.
if ($InstallAlloy) {
  Start-Sleep -Seconds 3
  $alloyState = (Get-Service laguna-alloy -ErrorAction SilentlyContinue).Status
  if ($alloyState -ne 'Running') {
    $logTail = ''
    $errLog = Join-Path $Logs 'alloy.err.log'
    if (Test-Path $errLog) { $logTail = (Get-Content $errLog -Tail 15) -join "`n" }
    Write-Warning "laguna-alloy is '$alloyState', not Running. Telemetry will not reach the cloud; the POS is unaffected.`n--- alloy.err.log ---`n$logTail"
  } else {
    $otlpPorts = 4317, 4318
    $missing = @($otlpPorts | Where-Object {
      -not (Get-NetTCPConnection -State Listen -LocalPort $_ -ErrorAction SilentlyContinue)
    })
    if ($missing) {
      Write-Warning "laguna-alloy is Running but not listening on: $($missing -join ', '). Check logs\alloy.err.log."
    } else {
      Write-Host "laguna-alloy is Running and listening on 127.0.0.1:4317 / :4318."
    }
  }
}

# --- 3d. Updater task: scripts\updater.ps1 as SYSTEM every minute (docs\UPDATE_PROTOCOL.md) ---
$UpdaterTask = 'Laguna Updater'
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSScriptRoot\updater.ps1`""
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
# IgnoreNew: an update takes minutes, and the next tick must not start a second one.
$settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 45) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $UpdaterTask -Action $action -Trigger $trigger `
  -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Registered scheduled task '$UpdaterTask' (offers updates in the POS, installs them on request)."

# --- 4. Windows Firewall: allow :443/:80 ONLY from known tablet IPs ----------------
$ruleName = 'Laguna POS - Caddy (LAN tablets)'
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $ruleName `
  -Direction Inbound -Action Allow -Protocol TCP `
  -LocalPort 443,80 -RemoteAddress $AllowedTabletIPs | Out-Null
Write-Host "Firewall rule set. Allowed: $($AllowedTabletIPs -join ', ')"

# --- 5. Export Caddy's internal root CA and trust it on this box --------------------
# Caddy writes the root on its first cert, so poll. $CaddyData must match the Caddyfile storage root.
$CaddyData  = 'C:\laguna-edge\caddy-data'
$RootCrt    = Join-Path $CaddyData 'pki\authorities\local\root.crt'
$RootExport = 'C:\laguna-edge\laguna-root-ca.crt'
$deadline   = (Get-Date).AddSeconds(30)
while (-not (Test-Path $RootCrt) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
if (Test-Path $RootCrt) {
  Copy-Item $RootCrt $RootExport -Force
  Write-Host "Exported Caddy root CA -> $RootExport"
  Import-Certificate -FilePath $RootCrt -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
  Write-Host "Trusted Caddy root CA in LocalMachine\Root on this box."
} else {
  Write-Warning "Caddy root CA not found at $RootCrt yet (Caddy writes it on its first request)."
  Write-Warning "Once it exists, export it with: Copy-Item '$RootCrt' '$RootExport'"
}

Write-Host ""
$primaryHost = if ($LanHost) { ($LanHost -split ',')[0].Trim() } else { $LanIp }
$altNote     = if ($LanHost) { " (or https://$LanIp)" } else { "" }
Write-Host "Done. Next steps:"
Write-Host "  - Dev PCs / tablets: install $RootExport as a Trusted Root CA, then open https://$primaryHost$altNote"
Write-Host "      Windows client:  Import-Certificate -FilePath laguna-root-ca.crt -CertStoreLocation Cert:\LocalMachine\Root"
Write-Host "  - See provisioning\README.md and certs\README.md"
if ($InstallAlloy) {
  Write-Host "  - Telemetry: set OBSERVABILITY_ENABLED=true and OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4317"
  Write-Host "      in env\edge-node.env, then: .\scripts\update.ps1 -Service edge-node"
  Write-Host "      See docs\TELEMETRY_RUNBOOK.md"
}
