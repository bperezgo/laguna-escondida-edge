#requires -RunAsAdministrator
<#
  apply-release.ps1 -- bring the box to the app versions pinned in versions.json, safely.

  edge-node migrates the database on boot and migrations cannot be undone, so before touching
  it this drains the sync outbox and takes a pg_dump. If anything fails after the services stop,
  the database AND the previous app files are restored together: the box goes back to exactly
  what it ran before.

    1. preflight  schema not dirty, disk space, releases downloaded + verified (no downtime yet)
    2. drain      wait for the outbox to reach pending_sync_ops = 0
    3. backup     stop caddy/next/edge-node, pg_dump, keep the current app files in backups\
    4. apply      install the staged releases, start, scripts\verify-install.ps1
    5. rollback   on any failure in 3-4

  Run after `git pull` (scripts/release.sh moves the pins):
      .\scripts\apply-release.ps1
      .\scripts\apply-release.ps1 -Reinstall       # the release changed Caddyfile or services\*.xml
      .\scripts\apply-release.ps1 -RollbackDrill   # apply, verify, then roll back on purpose

  Outcome: state\update-result.json (read by the updater / admin banner) and logs\update-*.log.
  Exit code 0 = applied (or a drill that rolled back cleanly); anything else = not applied.
#>
[CmdletBinding()]
param(
  [int]    $DrainTimeoutSeconds = 300,
  # Proceed with unsynced ops (e.g. WAN down). They stay queued in the database and in the dump.
  [switch] $AllowPendingSync,
  # Re-run install.ps1 instead of only restarting the app services.
  [switch] $Reinstall,
  # Apply and verify, then restore the backup anyway: proves the rollback path on this box.
  [switch] $RollbackDrill,
  # Reinstall the pinned releases even if they are already installed.
  [switch] $Force,
  [int]    $KeepBackups = 3
)

$ErrorActionPreference = 'Stop'
$Root      = Split-Path -Parent $PSScriptRoot
$Artifacts = Join-Path $Root 'artifacts'
$StateDir  = Join-Path $Root 'state'
$Logs      = Join-Path $Root 'logs'
$PgBin     = Join-Path $Artifacts 'postgres\bin'
$fetch     = Join-Path $PSScriptRoot 'fetch-artifacts.ps1'
$verify    = Join-Path $PSScriptRoot 'verify-install.ps1'
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup    = Join-Path $Root "backups\$stamp"
$logFile   = Join-Path $Logs "update-$stamp.log"
New-Item -ItemType Directory -Force -Path $StateDir, $Logs | Out-Null

function Step($m) { Write-Host ("`n==> " + $m) -ForegroundColor Cyan }

function Read-EnvFile($path) {
  $kv = @{}
  foreach ($line in Get-Content $path) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    $p = $t -split '=', 2
    if ($p.Count -eq 2) { $kv[$p[0].Trim()] = $p[1].Trim() }
  }
  return $kv
}

function Get-Installed($app) {
  $f = Join-Path $Artifacts "$app\RELEASE"
  if (Test-Path $f) { return (Get-Content $f -Raw).Trim() }
  return $null
}

# The Go side reads this file, and its JSON decoder rejects the BOM that PS 5.1's utf8 writes.
function Write-Result($outcome, $message) {
  $r = [ordered]@{
    version     = $appliance
    outcome     = $outcome
    message     = $message
    started_at  = $started.ToString('o')
    finished_at = (Get-Date).ToString('o')
    from        = $from
    to          = $to
    backup      = $backup
    log         = $logFile
  }
  $json = $r | ConvertTo-Json -Depth 5
  [IO.File]::WriteAllText((Join-Path $StateDir 'update-result.json'), $json, (New-Object Text.UTF8Encoding $false))
  if ($outcome -eq 'success' -and $appliance) {
    $i = [ordered]@{ version = $appliance; applied_at = (Get-Date).ToString('o') } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $StateDir 'installed.json'), $i, (New-Object Text.UTF8Encoding $false))
  }
}

# sc.exe + wait, dependents first: SCM refuses to stop a service whose dependents still run.
function Stop-AppServices {
  foreach ($id in 'laguna-caddy','laguna-next','laguna-edge-node') {
    $s = Get-Service $id -ErrorAction SilentlyContinue
    if (-not $s -or $s.Status -eq 'Stopped') { continue }
    Write-Host "  stopping $id"
    & sc.exe stop $id | Out-Null
    $s.WaitForStatus('Stopped', (New-TimeSpan -Seconds 60))
  }
}

function Start-AppServices {
  foreach ($id in 'laguna-postgres','laguna-edge-node','laguna-next','laguna-caddy') {
    if ((Get-Service $id).Status -ne 'Running') { Write-Host "  starting $id"; Start-Service $id }
  }
}

function Invoke-Sql($sql) {
  $out = & (Join-Path $PgBin 'psql.exe') @pgConn --no-psqlrc -q -v ON_ERROR_STOP=1 -tAc $sql
  if ($LASTEXITCODE -ne 0) { throw "psql failed ($LASTEXITCODE): $sql" }
  return "$out".Trim()
}

function Get-SchemaState {
  $row = Invoke-Sql "SELECT version || ' ' || dirty FROM schema_migrations"
  if (-not $row) { return [pscustomobject]@{ Version = 0; Dirty = $false } }
  $p = $row -split ' '
  return [pscustomobject]@{ Version = [int64]$p[0]; Dirty = ($p[1] -eq 'true') }
}

function Wait-Postgres {
  foreach ($i in 1..60) {
    & (Join-Path $PgBin 'pg_isready.exe') -h $db['DB_HOST'] -p $db['DB_PORT'] -q
    if ($LASTEXITCODE -eq 0) { return }
    Start-Sleep -Seconds 1
  }
  throw 'Postgres is not accepting connections.'
}

function Invoke-Verify([switch] $AnyVersion, [string] $ExpectedVersion) {
  $global:LASTEXITCODE = 0
  $opts = @{ TimeoutSeconds = 300 }
  if ($AnyVersion) { $opts['AnyVersion'] = $true }
  elseif ($ExpectedVersion) { $opts['ExpectedVersion'] = $ExpectedVersion }
  & $verify @opts | Out-Host
  return ($LASTEXITCODE -eq 0)
}

# Puts back what step 3 saved. Only restores the database if the new edge-node may have run.
function Restore-Backup {
  Stop-AppServices
  if ($state.ExeSaved) {
    Write-Host '  restoring the previous edge-node binary'
    Copy-Item (Join-Path $backup 'edge-node\*') (Join-Path $Artifacts 'edge-node') -Force
    if (-not $from['edge-node']) { Remove-Item (Join-Path $Artifacts 'edge-node\RELEASE') -ErrorAction SilentlyContinue }
  }
  if ($state.NextMoved) {
    Write-Host '  restoring the previous next bundle'
    $live = Join-Path $Artifacts 'next'
    if (Test-Path $live) { Remove-Item $live -Recurse -Force }
    Move-Item (Join-Path $backup 'next') $live
  }
  if ($state.Applied -and $state.Dumped) {
    Write-Host "  restoring the database from $backup\db.dump"
    Start-Service laguna-postgres
    Wait-Postgres
    # The app role owns the database and its public schema, so it can drop and rebuild it.
    # A plain --clean would leave tables the new migrations created.
    Invoke-Sql 'SET client_min_messages = warning; DROP SCHEMA public CASCADE; CREATE SCHEMA public;' | Out-Null
    & (Join-Path $PgBin 'pg_restore.exe') @pgConn --no-owner --no-acl --exit-on-error --single-transaction (Join-Path $backup 'db.dump') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "pg_restore failed ($LASTEXITCODE). The dump is intact at $backup\db.dump." }
    $now = Get-SchemaState
    if ($now.Version -ne $state.SchemaBefore.Version -or $now.Dirty) {
      throw "after restore schema is $($now.Version) (dirty=$($now.Dirty)), expected $($state.SchemaBefore.Version)."
    }
    Write-Host "  database back at migration $($now.Version)"
  }
  Start-AppServices
  $old = $from['edge-node']
  if (-not $old -or $old -like 'local-*') { return (Invoke-Verify -AnyVersion) }
  return (Invoke-Verify -ExpectedVersion $old)
}

$started = Get-Date
$versions  = Get-Content (Join-Path $Root 'versions.json') -Raw | ConvertFrom-Json
$pins      = $versions.artifacts
# The edge release these pins belong to (set by release.sh); absent on an unreleased checkout.
$appliance = if ($versions.appliance_version) { "$($versions.appliance_version)" } else { $null }
$from = [ordered]@{}; $to = [ordered]@{}
foreach ($a in 'edge-node','next') { $from[$a] = Get-Installed $a; $to[$a] = "$($pins.$a.version)" }
$apps = @('edge-node','next' | Where-Object { $Force -or $RollbackDrill -or $from[$_] -ne $to[$_] })

if (-not $apps -and -not $Reinstall) {
  Write-Result 'success' "Already on edge-node $($to['edge-node']), next $($to['next'])."
  Write-Host "Already on edge-node $($to['edge-node']), next $($to['next']). Nothing to do." -ForegroundColor Green
  exit 0
}

$dbFile = Join-Path $Root 'env\edge-node.env'
if (-not (Test-Path $dbFile)) { throw "Missing $dbFile." }
$db = Read-EnvFile $dbFile
$pgConn = @('-h', $db['DB_HOST'], '-p', $db['DB_PORT'], '-U', $db['DB_USER'], '-d', $db['DB_NAME'], '-w')
$state = [pscustomobject]@{ Stopped = $false; Dumped = $false; ExeSaved = $false; NextMoved = $false; Applied = $false; SchemaBefore = $null }

Start-Transcript -Path $logFile | Out-Null
$env:PGPASSWORD = $db['DB_PASSWORD']
$exitCode = 1
try {
  foreach ($a in $apps) { Write-Host ("{0,-10} {1} -> {2}" -f $a, $(if ($from[$a]) { $from[$a] } else { '(unknown)' }), $to[$a]) }

  Step 'Preflight'
  foreach ($exe in 'psql.exe','pg_dump.exe','pg_restore.exe','pg_isready.exe') {
    if (-not (Test-Path (Join-Path $PgBin $exe))) { throw "Missing $PgBin\$exe (run fetch-artifacts.ps1 -Only postgres -Force)." }
  }
  if ((Get-Service laguna-postgres).Status -ne 'Running') { Start-Service laguna-postgres }
  Wait-Postgres
  $state.SchemaBefore = Get-SchemaState
  if ($state.SchemaBefore.Dirty) {
    throw "schema_migrations is dirty at $($state.SchemaBefore.Version): a migration failed earlier. Recover it first (docs\MIGRATION_RECOVERY.md)."
  }
  Write-Host "  schema at migration $($state.SchemaBefore.Version), clean"

  $dbBytes  = [int64](Invoke-Sql 'SELECT pg_database_size(current_database())')
  $freeByte = (Get-PSDrive -Name $Root.Substring(0, 1)).Free
  $needByte = 2 * $dbBytes + 1GB
  if ($freeByte -lt $needByte) {
    throw ("only {0:N1} GB free on {1}:, need {2:N1} GB for the backup." -f ($freeByte / 1GB), $Root.Substring(0, 1), ($needByte / 1GB))
  }
  Write-Host ("  disk ok ({0:N1} GB free, database {1:N0} MB)" -f ($freeByte / 1GB), ($dbBytes / 1MB))

  if ($apps) {
    Write-Host '  downloading + verifying the releases (services still running)'
    & $fetch -Only $apps -DownloadOnly
  }

  if ($apps -contains 'edge-node') {
    Step 'Drain the sync outbox'
    $deadline = (Get-Date).AddSeconds($DrainTimeoutSeconds)
    $status = $null
    while ($true) {
      try { $status = Invoke-RestMethod http://127.0.0.1:8080/api/edge/status -TimeoutSec 5 } catch { $status = $null }
      if ($status -and $status.pending_sync_ops -eq 0) { Write-Host '  outbox empty'; break }
      if ((Get-Date) -ge $deadline) {
        $why = if ($status) { "$($status.pending_sync_ops) ops not synced (online=$($status.online))" } else { 'edge-node is not answering /api/edge/status' }
        if (-not $AllowPendingSync) {
          throw "$why after ${DrainTimeoutSeconds}s. Wait for the WAN, or re-run with -AllowPendingSync (the ops stay queued and are kept in the backup)."
        }
        Write-Warning "$why; continuing (-AllowPendingSync)."
        break
      }
      if ($status) { Write-Host "  $($status.pending_sync_ops) pending (online=$($status.online)), waiting ..." }
      Start-Sleep -Seconds 5
    }
  }

  Step "Backup -> $backup"
  New-Item -ItemType Directory -Force -Path $backup | Out-Null
  Copy-Item (Join-Path $Root 'versions.json') $backup
  Write-Host '  service is down from here until the update is verified'
  $state.Stopped = $true
  Stop-AppServices

  if ($apps -contains 'edge-node') {
    $state.SchemaBefore = Get-SchemaState
    "$($state.SchemaBefore.Version)" | Set-Content (Join-Path $backup 'schema-version.txt') -Encoding ascii
    $dump = Join-Path $backup 'db.dump'
    & (Join-Path $PgBin 'pg_dump.exe') @pgConn -Fc -f $dump
    if ($LASTEXITCODE -ne 0) { throw "pg_dump failed ($LASTEXITCODE)." }
    $toc = & (Join-Path $PgBin 'pg_restore.exe') -l $dump
    if ($LASTEXITCODE -ne 0 -or -not ($toc -match 'schema_migrations')) { throw 'the dump is unreadable or incomplete.' }
    $state.Dumped = $true
    Write-Host ("  db.dump {0:N1} MB at migration {1}" -f ((Get-Item $dump).Length / 1MB), $state.SchemaBefore.Version)

    $exeDir = Join-Path $backup 'edge-node'
    New-Item -ItemType Directory -Force -Path $exeDir | Out-Null
    foreach ($f in 'edge-node.exe','RELEASE') {
      $src = Join-Path $Artifacts "edge-node\$f"
      if (Test-Path $src) { Copy-Item $src $exeDir }
    }
    $state.ExeSaved = $true
  }
  if (($apps -contains 'next') -and (Test-Path (Join-Path $Artifacts 'next'))) {
    # Same volume, so this is a rename, not a copy.
    Move-Item (Join-Path $Artifacts 'next') (Join-Path $backup 'next')
    $state.NextMoved = $true
  }

  Step 'Apply'
  $state.Applied = $true
  if ($apps) { & $fetch -Only $apps -Force }
  Copy-Item $dbFile (Join-Path $Artifacts 'edge-node\.env') -Force
  if ($Reinstall) { & (Join-Path $PSScriptRoot 'install.ps1') } else { Start-AppServices }

  Step 'Verify'
  if (-not (Invoke-Verify)) { throw 'verify-install.ps1 failed on the new release.' }
  $after = Get-SchemaState
  if ($after.Dirty) { throw "schema_migrations is dirty at $($after.Version) after the update." }
  Write-Host "  schema at migration $($after.Version)"
  if ($RollbackDrill) { throw 'rollback drill: the update verified; rolling back on purpose.' }

  Write-Result 'success' "Updated to edge-node $($to['edge-node']), next $($to['next'])."
  $old = @(Get-ChildItem (Join-Path $Root 'backups') -Directory | Sort-Object Name -Descending | Select-Object -Skip $KeepBackups)
  foreach ($d in $old) { Remove-Item $d.FullName -Recurse -Force }
  Write-Host "`nUpdated. Backup kept at $backup" -ForegroundColor Green
  $exitCode = 0
} catch {
  $reason = "$_"
  Write-Host "`n$reason" -ForegroundColor Red
  if (-not $state.Stopped) {
    Write-Result 'refused' $reason
    Write-Host 'Nothing was changed; the box is still serving the old release.' -ForegroundColor Yellow
  } else {
    Step 'Rollback'
    try {
      $ok = Restore-Backup
      if (-not $ok) { throw 'verify-install.ps1 failed after the rollback.' }
      if ($RollbackDrill -and $reason -like 'rollback drill:*') {
        Write-Result 'drill_rolled_back' 'The update verified, and the rollback restored the previous release and database.'
        Write-Host "`nDrill passed: update verified, rollback verified." -ForegroundColor Green
        $exitCode = 0
      } else {
        Write-Result 'rolled_back' $reason
        Write-Host "`nThe update failed and the previous release was restored." -ForegroundColor Yellow
      }
    } catch {
      Write-Result 'rollback_failed' "$reason / rollback: $_"
      Write-Host "`nROLLBACK FAILED: $_" -ForegroundColor Red
      Write-Host "Backup: $backup (db.dump, edge-node\, next\). See docs\MIGRATION_RECOVERY.md." -ForegroundColor Red
      $exitCode = 2
    }
  }
} finally {
  Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
  Stop-Transcript | Out-Null
}
exit $exitCode
