<#
  init-postgres.ps1 -- one-time initialization of the local Postgres cluster used by
  the edge node. Creates the data dir, a superuser, and the app role + database.

  Run AFTER fetch-artifacts.ps1 has placed the Postgres binaries in artifacts\postgres\.
  Does NOT need admin (initdb/pg_ctl run as the current user). The laguna-postgres
  Windows service (postgres.xml) serves this data dir afterwards.

  Example:
    .\scripts\init-postgres.ps1 -DbPassword 'a-strong-password'
#>
[CmdletBinding()]
param(
  [string] $DbUser         = 'laguna',
  [Parameter(Mandatory)]
  [string] $DbPassword,                 # password for the app role (use as DB_PASSWORD in env\edge-node.env)
  [string] $DbName         = 'laguna_escondida',
  [string] $SuperPassword,              # superuser 'postgres' password; random if omitted
  [int]    $Port           = 5432,
  [switch] $Force                       # wipe an existing data dir and re-init
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$PgHome = Join-Path $Root 'artifacts\postgres'
$Bin    = Join-Path $PgHome 'bin'
$Data   = Join-Path $PgHome 'data'
$Logs   = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $Logs | Out-Null

function Step($m) { Write-Host ("`n==> " + $m) -ForegroundColor Cyan }

$initdb    = Join-Path $Bin 'initdb.exe'
$pgctl     = Join-Path $Bin 'pg_ctl.exe'
$psql      = Join-Path $Bin 'psql.exe'
$pgisready = Join-Path $Bin 'pg_isready.exe'
if (-not (Test-Path $initdb)) { throw "Postgres binaries not found at $Bin. Run fetch-artifacts.ps1 -Only postgres first." }

if ((Test-Path $Data) -and -not $Force) {
  throw "Data dir already exists at $Data. Use -Force to wipe and re-init (DESTROYS existing data)."
}
if (Test-Path $Data) {
  Step "Removing existing data dir (-Force)"
  Remove-Item $Data -Recurse -Force
}

if (-not $SuperPassword) {
  $SuperPassword = [Convert]::ToBase64String([Guid]::NewGuid().ToByteArray()).Substring(0, 16)
}

# 1. initdb -- create the cluster. Superuser is 'postgres'; password via temp pwfile.
Step "Initializing cluster at $Data"
$pwfile = Join-Path $env:TEMP ("pg-super-" + [Guid]::NewGuid().ToString('N') + '.txt')
Set-Content -Path $pwfile -Value $SuperPassword -NoNewline -Encoding ascii
try {
  & $initdb --pgdata=$Data --username=postgres --pwfile=$pwfile `
            --auth-host=scram-sha-256 --auth-local=trust --encoding=UTF8 | Out-Host
} finally {
  Remove-Item $pwfile -Force -ErrorAction SilentlyContinue
}

# 2. Start a TEMPORARY server (127.0.0.1 only) to create the app role + db.
Step "Starting a temporary server on 127.0.0.1:$Port"
$startLog = Join-Path $Logs 'pg-init.log'
$startOut = Join-Path $Logs 'pg-ctl-start.out'
$startErr = Join-Path $Logs 'pg-ctl-start.err'
# WINDOWS HANDLE-INHERITANCE TRAP: 'pg_ctl start' launches a DETACHED postgres server that
# inherits pg_ctl's stdio handles. Any approach that makes PowerShell wait on those handles
# deadlocks, because the server keeps them open long after pg_ctl exits:
#   - `pg_ctl start | Out-Host`           -> server holds the pipe's write end; reader never EOFs.
#   - `Start-Process -Wait -Redirect...`  -> -Wait also waits for the redirected streams to EOF.
# Fix: launch NON-blocking (no -Wait), send pg_ctl's stdio to FILES (never a PS pipe), then poll
# pg_isready ourselves until the server accepts connections. Pass args as ONE pre-quoted string
# (Start-Process -ArgumentList does not reliably re-quote array elements containing spaces, which
# would split "-p $Port -h 127.0.0.1" into separate tokens). No -w: we do the waiting via polling.
$startArgs = "-D `"$Data`" -l `"$startLog`" -o `"-p $Port -h 127.0.0.1`" start"
Start-Process -FilePath $pgctl -ArgumentList $startArgs -NoNewWindow `
  -RedirectStandardOutput $startOut -RedirectStandardError $startErr | Out-Null

$ready = $false
for ($i = 0; $i -lt 60; $i++) {
  & $pgisready --host=127.0.0.1 --port=$Port --quiet 2>$null
  if ($LASTEXITCODE -eq 0) { $ready = $true; break }
  Start-Sleep -Milliseconds 500
}
if (-not $ready) {
  Get-Content $startLog, $startErr -ErrorAction SilentlyContinue | Out-Host
  throw "Postgres did not become ready on 127.0.0.1:$Port within 30s. See $startLog"
}
Write-Host "  server is accepting connections."
try {
  Step "Creating role '$DbUser' and database '$DbName'"
  $env:PGPASSWORD = $SuperPassword
  # -w (--no-password): NEVER prompt. If auth fails, psql errors out immediately instead of
  # blocking on an interactive password prompt with no TTY (which hangs a non-interactive run).
  $psqlArgs = @('--host=127.0.0.1', "--port=$Port", '--username=postgres',
                '--dbname=postgres', '--no-psqlrc', '-w', '-v', 'ON_ERROR_STOP=1')
  $pwEsc = $DbPassword.Replace("'", "''")  # single-quote-safe for SQL string literal

  # Role: idempotent via DO block (CREATE ROLE may run inside a transaction).
  $roleSql = "DO `$LAGUNA`$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='$DbUser') THEN CREATE ROLE $DbUser LOGIN PASSWORD '$pwEsc'; END IF; END `$LAGUNA`$;"
  & $psql @psqlArgs -c $roleSql | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "Failed to create/verify role '$DbUser' (psql exit $LASTEXITCODE)." }

  # Database: CANNOT run inside a transaction/DO block -> check then create.
  $dbExists = (& $psql @psqlArgs -tAc "SELECT 1 FROM pg_database WHERE datname='$DbName'" | Out-String).Trim()
  if ($LASTEXITCODE -ne 0) { throw "Failed to query databases (psql exit $LASTEXITCODE)." }
  if ($dbExists -eq '1') {
    Write-Host "  database '$DbName' already exists -- skip."
  } else {
    & $psql @psqlArgs -c "CREATE DATABASE $DbName OWNER $DbUser" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Failed to create database '$DbName' (psql exit $LASTEXITCODE)." }
  }
}
finally {
  Step "Stopping the temporary server"
  & $pgctl -D $Data -w stop | Out-Host
  Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
}

Step "Done"
Write-Host @"
Cluster ready at: $Data
  App role:     $DbUser
  Database:     $DbName

NEXT:
  - Set these in env\edge-node.env (the backend loads them on startup):
        DB_HOST=127.0.0.1
        DB_PORT=$Port
        DB_USER=$DbUser
        DB_PASSWORD=<the password you passed>
        DB_NAME=$DbName
        DB_SSLMODE=disable
  - The 'postgres' superuser password is:
        $SuperPassword
    (store it somewhere safe; needed for admin tasks. Not used by the app.)
  - Install the service so Windows serves this data dir:  scripts\install.ps1
"@ -ForegroundColor Green
