<#
  create-db-roles.ps1 -- create the cluster roles the backend's migrations grant to.

  The app role (laguna) owns the database but cannot create roles, so the 'postgres'
  superuser creates them here. Idempotent. init-postgres.ps1 calls it on a new box; run it
  by hand once on an existing box, before installing edge-node v1.2.0 or newer.

  Example:
    .\scripts\create-db-roles.ps1 -SuperPassword '<postgres superuser password>'
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $SuperPassword,
  [int]    $Port = 5432
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$psql = Join-Path $Root 'artifacts\postgres\bin\psql.exe'

# Same attributes as the backend's migration 000065, which skips creating it when it exists.
$sql = "DO `$LAGUNA`$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='pos_app') THEN " +
       "CREATE ROLE pos_app NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS; END IF; END `$LAGUNA`$;"

$env:PGPASSWORD = $SuperPassword
try {
  & $psql --host=127.0.0.1 "--port=$Port" --username=postgres --dbname=postgres `
          --no-psqlrc -w -v ON_ERROR_STOP=1 -c $sql | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "Failed to create role 'pos_app' (psql exit $LASTEXITCODE)." }
} finally {
  Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
}
Write-Host "Role 'pos_app' is present."
