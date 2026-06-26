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

$initdb = Join-Path $Bin 'initdb.exe'
$pgctl  = Join-Path $Bin 'pg_ctl.exe'
$psql   = Join-Path $Bin 'psql.exe'
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
& $pgctl -D $Data -l $startLog -o "-p $Port -h 127.0.0.1" -w start | Out-Host
try {
  Step "Creating role '$DbUser' and database '$DbName'"
  $env:PGPASSWORD = $SuperPassword
  $sql = @"
SELECT 'CREATE ROLE $DbUser LOGIN PASSWORD ''$DbPassword'''
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DbUser')\gexec
SELECT 'CREATE DATABASE $DbName OWNER $DbUser'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DbName')\gexec
"@
  $sql | & $psql --host=127.0.0.1 --port=$Port --username=postgres --dbname=postgres --no-psqlrc -v ON_ERROR_STOP=1 | Out-Host
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
