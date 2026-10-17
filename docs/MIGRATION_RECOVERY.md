# Recovering from a failed migration

edge-node runs its embedded migrations (golang-migrate) on every boot. If one fails halfway,
golang-migrate marks the version **dirty** and edge-node refuses to start until a human decides
what state the database is in. Symptom: `laguna-edge-node` restarts every 10 seconds and
`logs\edge-node.err.log` says `Dirty database version N. Fix and force version.`

`scripts\apply-release.ps1` normally handles this for you: it took a `pg_dump` before the update
and restores it together with the old binary. This page is for when that did not happen
(`update-result.json` says `rollback_failed`, or someone used `update.ps1` directly).

All commands run in an elevated PowerShell in `C:\laguna-edge`. Set up a `psql` shortcut first
(credentials come from `env\edge-node.env`):

```powershell
$e = @{}; Get-Content env\edge-node.env | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } |
  ForEach-Object { $e[$Matches[1]] = $Matches[2].Trim() }
$env:PGPASSWORD = $e.DB_PASSWORD
function sql { & .\artifacts\postgres\bin\psql.exe -h 127.0.0.1 -U $e.DB_USER -d $e.DB_NAME -w @args }
sql -c "SELECT version, dirty FROM schema_migrations"
```

## Option A: go back to the backup (preferred)

Use the newest folder in `backups\` whose `schema-version.txt` is below the dirty version.

```powershell
$b = 'backups\<stamp>'
sc.exe stop laguna-caddy; sc.exe stop laguna-next; sc.exe stop laguna-edge-node
sql -c "SET client_min_messages = warning; DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
.\artifacts\postgres\bin\pg_restore.exe -h 127.0.0.1 -U $e.DB_USER -d $e.DB_NAME -w `
  --no-owner --no-acl --exit-on-error --single-transaction "$b\db.dump"
Copy-Item "$b\edge-node\*" artifacts\edge-node\ -Force
if (Test-Path "$b\next") { Remove-Item artifacts\next -Recurse -Force; Move-Item "$b\next" artifacts\next }
sql -c "SELECT version, dirty FROM schema_migrations"     # = schema-version.txt, dirty f
Start-Service laguna-caddy                                  # starts next, edge-node, postgres
.\scripts\verify-install.ps1 -AnyVersion
```

Anything written to the database after the dump is lost. apply-release takes the dump with the
services stopped, so for a failed update that is nothing.

## Option B: finish the migration by hand

Only when there is no usable dump. Find the migration in the backend repo:
`internal/platform/postgres/migrations/<N>_*.up.sql`.

1. Work out how far it got. Each statement either took effect or did not; check them one by one
   (`sql -c "\d <table>"`). Migrations that are a single statement are usually all-or-nothing
   (Postgres DDL is transactional), so most dirty states are "nothing happened".
2. Make the database match *one* of the two clean states:
   - **nothing applied:** undo any partial statements, then
     `sql -c "UPDATE schema_migrations SET version = <N-1>, dirty = false"`. The next boot retries N.
   - **all applied:** run the remaining statements by hand, then
     `sql -c "UPDATE schema_migrations SET dirty = false"`.
3. `Start-Service laguna-caddy` and run `.\scripts\verify-install.ps1 -AnyVersion`.

If the migration itself is broken, retrying it will fail again: put the old binary back (from
`backups\<stamp>\edge-node\`) and fix the migration in a new backend release.

## Before you start

- Take a dump of the current (dirty) state first, so step B can be undone:
  `.\artifacts\postgres\bin\pg_dump.exe -h 127.0.0.1 -U $e.DB_USER -d $e.DB_NAME -w -Fc -f backups\dirty.dump`
- Never `DROP SCHEMA` without a dump you have just checked with `pg_restore -l <file>`.
