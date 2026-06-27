# Monitoring — keeping the box healthy day to day

[`VALIDATION.md`](VALIDATION.md) answers "is it up *right now*?". This doc is about
**ongoing** health: where the logs are, what to watch, and a copy-paste health check you can
schedule so the box tells you when something breaks — important because there's no one watching
it at the restaurant.

> Install root `C:\laguna-edge`, LAN IP `192.168.101.49`. All commands are PowerShell on the box.

---

## 1. Service health at a glance

```powershell
Get-Service laguna-* | Sort-Object Name | Format-Table Name, Status, StartType
```

All four services have `onfailure action="restart" delay="10 sec"` in their WinSW XML, so a
crashed process is auto-restarted. A service that keeps **flapping** (restarting in a loop) is
the thing to catch — you'll see it as repeated start/stop lines in the wrapper log (§2) and a
recent `StartTime`:

```powershell
# How long has each service's process been alive? A constantly-resetting start time = flapping.
Get-CimInstance Win32_Service -Filter "Name like 'laguna-%'" |
  ForEach-Object {
    $p = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
    [pscustomobject]@{ Name=$_.Name; State=$_.State; PID=$_.ProcessId; Started=$p.StartTime }
  } | Format-Table -Auto
```

---

## 2. Logs — where they are and how to read them

WinSW writes per-service logs into `C:\laguna-edge\logs\`, rolling by size (10 MB, 8 files kept).
File base name = the service's wrapper name:

| File pattern              | What's in it                                         |
|---------------------------|------------------------------------------------------|
| `<svc>.out.log`           | the process's stdout (app logs)                      |
| `<svc>.err.log`           | the process's stderr (errors, stack traces)          |
| `<svc>.wrapper.log`       | WinSW itself — start/stop/restart events             |

where `<svc>` ∈ `postgres`, `edge-node`, `next`, `caddy`. Confirm the actual names once:

```powershell
Get-ChildItem C:\laguna-edge\logs | Sort-Object LastWriteTime -Desc | Format-Table Name, Length, LastWriteTime
```

**Live tail** a log (Ctrl+C to stop):

```powershell
Get-Content C:\laguna-edge\logs\edge-node.out.log -Wait -Tail 30
Get-Content C:\laguna-edge\logs\caddy.err.log     -Wait -Tail 30
```

**Scan all error logs for recent problems:**

```powershell
Get-ChildItem C:\laguna-edge\logs\*.err.log |
  ForEach-Object { Select-String -Path $_ -Pattern 'error|fatal|panic|denied|refused' -SimpleMatch } |
  Select-Object -Last 40 Path, LineNumber, Line
```

What "normal" looks like per service:

- **postgres** — `database system is ready to accept connections`. Noise to ignore: occasional
  `LOG: checkpoint`. Watch for: `FATAL`, `could not bind`, `permission denied` on the data dir.
- **edge-node** — startup line, migrations applied, `listening on :8080`. Watch for: DB
  connection refused (Postgres down or `DB_PASSWORD` wrong), missing-required-env panics, and
  the **cloud-sync** lines (see §5).
- **next** — `Listening on … 3000` / ready. Watch for: `EADDRINUSE`, module-not-found
  (broken `node_modules` junctions → rebuild with `update.ps1 -Service next`).
- **caddy** — `serving initial configuration`. Watch for: `tls`/cert errors, upstream
  `dial tcp 127.0.0.1:3000: connectex` (Next is down).

---

## 3. Reachability + latency

```powershell
# Edge path (what tablets hit). Prints HTTP code + total time.
curl.exe -k -s -o NUL -w "edge %{http_code}  %{time_total}s`n" https://192.168.101.49/signin
```

A sudden jump in `time_total`, or a non-200, is your earliest external signal of trouble.

---

## 4. Disk — the silent killer

Three dirs grow or must never be lost. Postgres data growing unbounded, or the system drive
filling, will take the box down.

```powershell
"{0,-16} {1,8:N1} MB" -f 'logs',       ((Get-ChildItem C:\laguna-edge\logs       -Recurse | Measure-Object Length -Sum).Sum/1MB)
"{0,-16} {1,8:N1} MB" -f 'postgres-data',((Get-ChildItem C:\laguna-edge\artifacts\postgres\data -Recurse | Measure-Object Length -Sum).Sum/1MB)
"{0,-16} {1,8:N1} MB" -f 'caddy-data',  ((Get-ChildItem C:\laguna-edge\caddy-data -Recurse | Measure-Object Length -Sum).Sum/1MB)
Get-PSDrive C | Select-Object Used, Free
```

- `logs\` is self-capping (8 × 10 MB per stream) — fine.
- `caddy-data\` is tiny but **precious**: it holds the internal CA root. If it's ever lost, the
  root cert changes and **every tablet must re-trust HTTPS**. Back it up (see the runbook /
  TROUBLESHOOTING).
- `artifacts\postgres\data\` grows with real data — keep an eye on free space on `C:`.

---

## 5. Cloud sync (if enabled)

If `CLOUD_SYNC_URL` is set, edge-node pushes/pulls on a cron (default every minute). Watch its
log for sync results:

```powershell
Select-String -Path C:\laguna-edge\logs\edge-node.out.log -Pattern 'sync' -SimpleMatch | Select-Object -Last 20
```

> **Known issue (non-blocking):** the PULL leg can fail with
> `user_roles_role_id_fkey (SQLSTATE 23503)` — roles aren't upserted before `user_roles`. This
> is a **backend-repo** bug; it does **not** affect local POS serving. If you see only this
> error repeating, the box is still fine to use. Tracked separately in the backend repo.

---

## 6. A scheduled health check (recommended)

Drop this script on the box and run it from Task Scheduler every few minutes. It writes a
heartbeat line and only shouts (event log) when something is actually wrong — so the box is
self-reporting even though nobody's watching it.

Save as `C:\laguna-edge\scripts\healthcheck.ps1`:

```powershell
$ErrorActionPreference = 'SilentlyContinue'
$stamp  = Get-Date -Format 's'
$bad    = @()

# 1. all services Running?
foreach ($s in 'laguna-postgres','laguna-edge-node','laguna-next','laguna-caddy') {
  if ((Get-Service $s).Status -ne 'Running') { $bad += "$s not Running" }
}
# 2. edge path answers 200 on /signin?
$code = (curl.exe -k -s -o NUL -w "%{http_code}" https://192.168.101.49/signin)
if ($code -ne '200') { $bad += "edge /signin -> $code" }
# 3. disk free on C: above 2 GB?
$free = (Get-PSDrive C).Free / 1GB
if ($free -lt 2) { $bad += ("C: free {0:N1} GB" -f $free) }

$line = if ($bad) { "$stamp UNHEALTHY: $($bad -join '; ')" } else { "$stamp OK" }
Add-Content C:\laguna-edge\logs\healthcheck.log $line
if ($bad) {
  # Surface to the Windows event log so it's visible in Event Viewer / any monitoring agent.
  Write-EventLog -LogName Application -Source 'Laguna POS' -EventId 9001 -EntryType Warning `
    -Message $line -ErrorAction SilentlyContinue
}
```

Register it (one-time, elevated):

```powershell
# Create the event-log source once so Write-EventLog works:
New-EventLog -LogName Application -Source 'Laguna POS' -ErrorAction SilentlyContinue

$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\laguna-edge\scripts\healthcheck.ps1'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName 'Laguna POS Healthcheck' -Action $action -Trigger $trigger `
  -RunLevel Highest -User 'SYSTEM'
```

Read the heartbeat any time:

```powershell
Get-Content C:\laguna-edge\logs\healthcheck.log -Tail 20
```

---

## 7. Reload Caddy after a Caddyfile edit (no restart)

Editing the `Caddyfile` (e.g. tweaking the redirect fix or headers) doesn't need a service
restart — reload in place so existing connections aren't dropped:

```powershell
& C:\laguna-edge\artifacts\caddy\caddy.exe validate --config C:\laguna-edge\Caddyfile --adapter caddyfile
& C:\laguna-edge\artifacts\caddy\caddy.exe reload   --config C:\laguna-edge\Caddyfile --adapter caddyfile
```

`validate` first — a reload with a broken config is rejected and the old config keeps serving.
