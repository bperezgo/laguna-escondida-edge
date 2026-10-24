<#
  updater.ps1 -- owner-triggered app updates (edge-node + next). See docs\UPDATE_PROTOCOL.md.

  install.ps1 registers it as the "Laguna Updater" scheduled task: SYSTEM, every minute.
  Each run does at most one thing:
    - an admin pressed "Actualizar" (state\update-requested.json): back up the DB, install the
      staged versions, verify, roll back on failure, write state\update-result.json
    - otherwise, every 30 min: compare what is installed with the cloud backend's version and
      the latest frontend release, download + verify what is newer, and write
      state\update-available.json, which edge-node shows to admins as a banner

  Logs to logs\updater.log. Run by hand (elevated):  .\scripts\updater.ps1 -CheckNow
#>
[CmdletBinding()]
param(
  [switch] $CheckNow   # check for updates even if the last check was less than 30 min ago
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$Root      = Split-Path -Parent $PSScriptRoot
$State     = Join-Path $Root 'state'
$Backups   = Join-Path $Root 'backups'
$LogFile   = Join-Path $Root 'logs\updater.log'
$EnvFile   = Join-Path $Root 'env\edge-node.env'
$PgBin     = Join-Path $Root 'artifacts\postgres\bin'
$GitHubApi = 'https://api.github.com/repos/bperezgo'
$Apps      = 'edge-node','next'   # install order: the backend first, then the UI that calls it
$CheckEvery  = New-TimeSpan -Minutes 30
$KeepBackups = 5

function Log($msg) {
  Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
}

function Now { Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz' }

function Test-Tag($t) { return "$t" -match '^v\d+\.\d+\.\d+$' }

# True if release tag $a is newer than $b.
function Test-NewerTag($a, $b) {
  if (-not (Test-Tag $a) -or -not (Test-Tag $b)) { return $false }
  return [version]$a.Substring(1) -gt [version]$b.Substring(1)
}

function Get-Installed($app) {
  $f = Join-Path $Root "artifacts\$app\RELEASE"
  if (Test-Path $f) { return (Get-Content $f -Raw).Trim() }
  return $null
}

function Get-InstalledTags {
  $tags = [ordered]@{}
  foreach ($a in $Apps) { $tags[$a] = Get-Installed $a }
  return $tags
}

# The banner shows this string and the request must echo it back exactly.
function Format-Version($tags) { return "$($tags['edge-node'])+$($tags['next'])" }

function Format-Tags($tags) { return "edge-node $($tags['edge-node']), next $($tags['next'])" }

# Same rules as godotenv for what we read: KEY=value, an unquoted value ends at " #".
function Read-EnvFile($path) {
  $kv = @{}
  foreach ($line in Get-Content $path) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
      $kv[$Matches[1]] = ($Matches[2] -replace '\s+#.*$', '').Trim().Trim('"', "'")
    }
  }
  return $kv
}

function Read-State($name) {
  $p = Join-Path $State $name
  if (-not (Test-Path $p)) { return $null }
  try { return (Get-Content $p -Raw | ConvertFrom-Json) }
  catch { Log "unreadable ${name}: $($_.Exception.Message)"; return $null }
}

# Write + rename so edge-node never reads a half-written file. WriteAllText adds no BOM.
function Write-State($name, $obj) {
  $p = Join-Path $State $name
  [IO.File]::WriteAllText("$p.tmp", ($obj | ConvertTo-Json -Depth 5))
  Move-Item "$p.tmp" $p -Force
}

function Remove-State($name) {
  Remove-Item (Join-Path $State $name) -Force -ErrorAction SilentlyContinue
}

# Runs one of the scripts next to this one and copies everything it prints into the log.
function Invoke-Script($name, [hashtable] $params) {
  & (Join-Path $PSScriptRoot $name) @params *>&1 | ForEach-Object { Log "    $_" }
}

# verify-install.ps1 exits non-zero on the first broken layer.
function Assert-Healthy {
  $global:LASTEXITCODE = 0
  Invoke-Script 'verify-install.ps1' @{ TimeoutSeconds = 180 }
  if ($LASTEXITCODE -ne 0) { throw "verify-install.ps1 failed (see the lines above)" }
}

# --- check ------------------------------------------------------------------------------

function Invoke-Check {
  $installed = Get-InstalledTags
  $local = @($Apps | Where-Object { -not (Test-Tag $installed[$_]) })
  if ($local) { Log "check skipped: not a release install ($(Format-Tags $installed))"; return }

  $pins = (Get-Content (Join-Path $Root 'versions.json') -Raw | ConvertFrom-Json).artifacts
  $latest = @{}
  try {
    $cloudUrl = (Read-EnvFile $EnvFile)['CLOUD_SYNC_URL'].TrimEnd('/')
    $latest['edge-node'] = "$((Invoke-RestMethod "$cloudUrl/api/edge/status" -TimeoutSec 20 -UseBasicParsing).version)"
    $release = Invoke-RestMethod "$GitHubApi/$($pins.next.repo)/releases/latest" -TimeoutSec 20 -UseBasicParsing
    $latest['next'] = "$($release.tag_name)"
  } catch {
    # Leave any staged update-available.json alone: it is still valid while we are offline.
    Log "check failed: $($_.Exception.Message)"
    return
  }

  $target = [ordered]@{}
  foreach ($a in $Apps) {
    $target[$a] = $installed[$a]
    if (-not (Test-NewerTag $latest[$a] $installed[$a])) { continue }
    try {
      # Stage it now so pressing the button needs no download, and so a release whose
      # Windows build is missing or corrupt is never offered.
      Invoke-Script 'fetch-artifacts.ps1' @{ Only = @($a); DownloadOnly = $true; Tags = @{ $a = $latest[$a] } }
      $target[$a] = $latest[$a]
    } catch {
      Log "$a $($latest[$a]) not offered: $($_.Exception.Message)"
    }
  }

  $changed = @($Apps | Where-Object { $target[$_] -ne $installed[$_] })
  if (-not $changed) {
    Remove-State 'update-available.json'
    Log "up to date: $(Format-Tags $installed)"
    return
  }
  if ($changed -contains 'next') { $notes = "$($release.html_url)" }
  else { $notes = "https://github.com/bperezgo/$($pins.'edge-node'.repo)/releases/tag/$($target['edge-node'])" }

  Write-State 'update-available.json' ([ordered]@{
    version    = Format-Version $target
    current    = Format-Version $installed
    notes_url  = $notes
    components = $target
    checked_at = Now
  })
  Log "available: $(Format-Tags $target) (installed: $(Format-Tags $installed))"
}

# --- apply ------------------------------------------------------------------------------

function Set-Phase($phase) {
  $script:phase = $phase
  Write-State 'update-progress.json' ([ordered]@{ version = $script:version; phase = $phase; started_at = $script:started })
  Log "phase: $phase"
}

function Write-Result($outcome, $message, $from, $to) {
  Write-State 'update-result.json' ([ordered]@{
    version     = $script:version
    outcome     = $outcome
    message     = $message
    started_at  = $script:started
    finished_at = Now
    from        = $from
    to          = $to
  })
  Log "result: $outcome -- $message"
}

# Runs a Postgres client as the app role. 'Continue' because PS 5.1 turns any stderr line of
# a native command into a terminating error under 'Stop'; the exit code decides instead.
function Invoke-Pg($exe, [string[]] $pgArgs) {
  $db = Read-EnvFile $EnvFile
  $conn = @('-h', $db['DB_HOST'], '-p', $db['DB_PORT'], '-U', $db['DB_USER'], '-d', $db['DB_NAME'], '-w')
  $env:PGPASSWORD = $db['DB_PASSWORD']
  $ErrorActionPreference = 'Continue'
  try {
    & (Join-Path $PgBin $exe) @conn @pgArgs 2>&1 | ForEach-Object { Log "    $_" }
    if ($LASTEXITCODE -ne 0) { throw "$exe exited with $LASTEXITCODE" }
  } finally {
    Remove-Item env:PGPASSWORD -ErrorAction SilentlyContinue
  }
}

function Backup-Database {
  New-Item -ItemType Directory -Force -Path $Backups | Out-Null
  $file = Join-Path $Backups ("pre-update-{0}.dump" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  Invoke-Pg 'pg_dump.exe' @('-Fc', '-f', $file)
  Get-ChildItem $Backups -Filter 'pre-update-*.dump' | Sort-Object Name -Descending |
    Select-Object -Skip $KeepBackups | Remove-Item -Force
  Log "database backed up to $file"
  return $file
}

# The old edge-node refuses a schema migrated past what it knows, so a backend rollback
# needs the pre-update DB. Recreating public also drops tables the new migrations added.
function Restore-Database($file) {
  Invoke-Pg 'psql.exe' @('-v', 'ON_ERROR_STOP=1', '-c', 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;')
  Invoke-Pg 'pg_restore.exe' @('--clean', '--if-exists', '--no-owner', '--no-privileges',
                               '--single-transaction', '--exit-on-error', $file)
  Log "database restored from $file"
}

# A crash-looping service shows Stopped between restarts and Windows' failure action starts it
# again, even mid-restore. Disabling it cancels those restarts; Enable-AppServices undoes it.
function Stop-AppServices {
  foreach ($name in 'caddy','next','edge-node') {
    $svc = Get-Service "laguna-$name" -ErrorAction SilentlyContinue
    if (-not $svc) { continue }
    Set-Service "laguna-$name" -StartupType Disabled
    $deadline = (Get-Date).AddSeconds(60)
    while ($true) {
      $svc.Refresh()
      if ($svc.Status -eq 'Stopped') { break }
      if ((Get-Date) -gt $deadline) { throw "laguna-$name did not stop within 60s" }
      if ($svc.Status -eq 'Running') { & sc.exe stop "laguna-$name" | Out-Null }
      Start-Sleep -Seconds 1
    }
  }
}

function Enable-AppServices {
  foreach ($name in 'caddy','next','edge-node') {
    if (Get-Service "laguna-$name" -ErrorAction SilentlyContinue) {
      Set-Service "laguna-$name" -StartupType Automatic
    }
  }
}

function Start-AllServices {
  Enable-AppServices
  foreach ($name in 'postgres','edge-node','next','caddy','alloy') {
    if (Get-Service "laguna-$name" -ErrorAction SilentlyContinue) { Start-Service "laguna-$name" }
  }
}

function Invoke-Apply {
  $script:started = Now
  $req   = Read-State 'update-requested.json'
  $avail = Read-State 'update-available.json'
  $from  = Get-InstalledTags
  $script:version = "$($req.version)"
  $script:phase   = 'preparing'

  Set-Phase 'preparing'
  Remove-State 'update-requested.json'
  Log "update requested by $($req.requested_by): $script:version"

  $dump = $null
  $to = [ordered]@{}
  $touched = $false   # false = nothing on the box changed yet, so a failure needs no rollback
  try {
    # Only ever install what this script staged itself, never tags taken from the request.
    if (-not $avail -or "$($avail.version)" -ne $script:version) {
      throw "la versión $script:version ya no está disponible"
    }
    foreach ($a in $Apps) {
      $to[$a] = "$($avail.components.$a)"
      if (-not (Test-Tag $to[$a])) { throw "update-available.json has no valid $a tag" }
    }
    $changed = @($Apps | Where-Object { $to[$_] -ne $from[$_] })

    Set-Phase 'downloading'
    foreach ($a in $changed) {
      Invoke-Script 'fetch-artifacts.ps1' @{ Only = @($a); DownloadOnly = $true; Tags = @{ $a = $to[$a] } }
    }

    if ($changed -contains 'edge-node') {
      Set-Phase 'backup'
      $dump = Backup-Database
    }

    $touched = $true
    Set-Phase 'installing'
    foreach ($a in $changed) { Invoke-Script 'update.ps1' @{ Service = $a; Tag = $to[$a] } }

    Set-Phase 'verifying'
    Assert-Healthy

    Write-State 'installed.json' ([ordered]@{ version = $script:version; applied_at = Now })
    Remove-State 'update-available.json'
    Write-Result 'success' "Actualizado a $(Format-Tags $to)." $from $to
  } catch {
    $err = "$($_.Exception.Message)"
    $failedPhase = $script:phase
    Log "FAILED during ${failedPhase}: $err"
    if (-not $touched) {
      Write-Result 'refused' "$err (no se instaló nada)" $from $from
      return
    }

    Set-Phase 'rolling_back'
    try {
      Stop-AppServices
      if ($dump) { Restore-Database $dump }
      Enable-AppServices
      foreach ($a in $changed) {
        if ((Get-Installed $a) -ne $from[$a]) { Invoke-Script 'update.ps1' @{ Service = $a; Tag = $from[$a] } }
      }
      Start-AllServices
      Assert-Healthy
      Write-Result 'rolled_back' "Falló en '$failedPhase' ($err). Se restauró $(Format-Tags $from)." $from $from
    } catch {
      # Left disabled, the services would not come back after a reboot.
      try { Enable-AppServices } catch { Log "could not re-enable the services: $($_.Exception.Message)" }
      $msg = "Falló en '$failedPhase' ($err) y la restauración también falló: $($_.Exception.Message)."
      if ($dump) { $msg += " Copia de la base de datos: $dump" }
      Write-Result 'rollback_failed' $msg $from (Get-InstalledTags)
    }
  } finally {
    Remove-State 'update-progress.json'
  }
}

# A progress file nobody holds the lock for means the box lost power (or the task was killed)
# mid-update. Report it instead of leaving the banner on "updating" forever.
function Resolve-Interrupted {
  $progress = Read-State 'update-progress.json'
  $script:version = "$($progress.version)"
  $script:started = "$($progress.started_at)"
  Remove-State 'update-progress.json'
  Log "found an interrupted update ($script:version, phase $($progress.phase))"
  $installed = Get-InstalledTags
  try {
    Start-AllServices
    Assert-Healthy
    Write-Result 'refused' "La actualización se interrumpió; el sistema sigue con $(Format-Tags $installed)." $installed $installed
  } catch {
    Write-Result 'rollback_failed' "La actualización se interrumpió y el sistema no responde: $($_.Exception.Message)" $installed $installed
  }
}

# --- main -------------------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $State, (Split-Path $LogFile) | Out-Null
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 5MB) {
  Move-Item $LogFile "$LogFile.1" -Force
}

# The task never overlaps itself (IgnoreNew); this also covers a run started by hand.
$mutex = New-Object System.Threading.Mutex($false, 'Global\LagunaUpdater')
# WaitOne only throws when the previous holder died, and then this run owns the mutex.
try { $owned = $mutex.WaitOne(0) } catch { $owned = $true }
if (-not $owned) { exit 0 }

$exitCode = 0
try {
  $lastCheck = Join-Path $State '.last-check'
  if (Test-Path (Join-Path $State 'update-requested.json')) {
    Invoke-Apply
  } elseif (Test-Path (Join-Path $State 'update-progress.json')) {
    Resolve-Interrupted
  } elseif ($CheckNow -or -not (Test-Path $lastCheck) -or
            ((Get-Date) - (Get-Item $lastCheck).LastWriteTime) -ge $CheckEvery) {
    # Stamped before the check, so a failing check retries in 30 min, not every minute.
    Set-Content $lastCheck (Now)
    Invoke-Check
  }
} catch {
  Log "ERROR: $($_ | Out-String)"
  $exitCode = 1
} finally {
  $mutex.ReleaseMutex()
}
exit $exitCode
