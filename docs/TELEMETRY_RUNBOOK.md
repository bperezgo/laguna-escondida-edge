# Telemetry — shipping this box's logs, traces and metrics to Grafana Cloud

The box runs a **Grafana Alloy sidecar** (`laguna-alloy`) next to the app. The app emits to
it on localhost; Alloy buffers to disk while the box is offline and forwards everything to
the **cloud backend's telemetry ingest**, which stamps the tenant context and relays it to
Grafana Cloud.

> **This box holds no Grafana Cloud credentials.** It has the ingest address and its own
> node key — the same key the data sync already uses. Rotation happens in the cloud.

Telemetry is **opt-in**. No `env\alloy.env` → no sidecar, and the box behaves exactly as it
did before. That is also the whole of the "uninstall".

```
edge-node ──OTLP 127.0.0.1:4317──▶ ┌─────────┐ ──▶ https://<cloud>/api/telemetry ──▶ Grafana Cloud
          ◀──scrape :9090/metrics─ │  Alloy  │         (X-Node-Key)                   (Loki/Tempo/Mimir)
                                   └────┬────┘
                                        ▼  disk buffer, hard cap, survives restarts
                                   alloy-data\buffer
```

Install root is **`C:\laguna-edge`**. All commands are PowerShell on the box.

---

## 1. Before you start: the clock

**The box must have working NTP.** Every log line, span and sample is timestamped by the
box, not by the cloud. A box whose clock has drifted writes telemetry that lands in the
wrong place on every Grafana time axis — it will look like "no data" for the window you are
actually looking at, and the buffered backlog from an outage lands wrong too.

```powershell
w32tm /query /status                       # check: "Last Successful Sync Time" should be recent
w32tm /resync                              # force a sync now
# If the service isn't running / not configured:
Set-Service w32time -StartupType Automatic; Start-Service w32time
w32tm /config /manualpeerlist:"time.windows.com,0x9" /syncfromflags:manual /update
w32tm /resync
```

Do not skip this. It is the one prerequisite that cannot be fixed after the fact.

---

## 2. Install

### 2.1 Fetch the Alloy binary

```powershell
cd C:\laguna-edge
.\scripts\fetch-artifacts.ps1 -Only alloy
# -> artifacts\alloy\alloy.exe
```

### 2.2 Pin an explicit NODE_ID

Open `env\edge-node.env` and make sure **`NODE_ID` is uncommented and set** to a stable
value for this box (e.g. `laguna-cra-01`).

This is required, not cosmetic: when `NODE_ID` is blank the app *derives* one internally
from the organization, and Alloy cannot reproduce that value — the box's metrics would then
carry a different identity from its logs and traces, and never line up in Grafana.
`install.ps1` refuses to install the sidecar if it is unset.

While you are in that file, turn telemetry on:

```ini
NODE_ID=laguna-cra-01
OBSERVABILITY_ENABLED=true
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4317
OTEL_TRACES_SAMPLER_ARG=0.1
```

### 2.3 Configure the sidecar

```powershell
Copy-Item env\alloy.env.example env\alloy.env
notepad env\alloy.env
```

Four values must be right; the rest have working defaults:

| Setting | Must be |
|---|---|
| `EDGE_TELEMETRY_INGEST_URL` | The cloud backend's `/api/telemetry` base URL. **No** `/v1/logs` suffix — the exporter appends it. |
| `EDGE_NODE_KEY` | Identical to `NODE_SYNC_KEY` in `env\edge-node.env` |
| `EDGE_NODE_ID` | Identical to `NODE_ID` in `env\edge-node.env` |
| `EDGE_ORGANIZATION_ID` | Identical to `ORGANIZATION_ID` in `env\edge-node.env` |

`install.ps1` checks all four against `edge-node.env` and **refuses to install** if any
disagree, so a mismatch fails loudly at install time instead of quietly splitting one box
into two in Grafana.

### 2.4 Install and restart the app

```powershell
# Elevated PowerShell. Re-runnable; also refreshes the other services.
.\scripts\install.ps1

# Pick up the new OBSERVABILITY_* settings in the app:
.\scripts\update.ps1 -Service edge-node
```

`install.ps1` writes the node key to `env\alloy-node-key` (readable only by SYSTEM and
Administrators), exports the rest as machine environment variables, validates
`alloy\config.alloy`, then registers and starts `laguna-alloy`.

### 2.5 Verify

```powershell
Get-Service laguna-alloy | Format-Table Name, Status, StartType     # Running / Automatic

# Listening where the app expects it:
Get-NetTCPConnection -State Listen -LocalPort 4317,4318 | Format-Table LocalAddress, LocalPort

# The app is exporting (no OTLP errors) and the sidecar is quiet:
Get-Content C:\laguna-edge\logs\edge-node.out.log -Tail 20
Get-Content C:\laguna-edge\logs\alloy.err.log     -Tail 20
```

Then in Grafana Cloud, filter by this box:

```logql
{node_id="laguna-cra-01"}
```

All three signals carry `node.id`, `organization.id`, `deployment.mode=edge` and
`service.instance.id`, so the same filter works for logs, traces and metrics.

**Reboot test** — the service is `Automatic` with no dependencies, so it must come back on
its own:

```powershell
Restart-Computer
# after it comes back:
Get-Service laguna-alloy
Get-NetTCPConnection -State Listen -LocalPort 4317,4318
```

---

## 3. Tunables

All of these live in `env\alloy.env` unless marked otherwise. **Re-run `install.ps1` after
editing `env\alloy.env`** — the values become machine environment variables at install
time, so editing the file alone changes nothing.

| Knob | Where | Default | What it buys |
|---|---|---|---|
| `OTEL_TRACES_SAMPLER_ARG` | `env\edge-node.env` | `0.1` | Fraction of traces kept. The biggest volume lever. Keep below `1.0`. |
| `EDGE_MIN_LOG_SEVERITY` | `env\alloy.env` | `INFO` | Lowest severity forwarded. `DEBUG`/`TRACE` are dropped at the sidecar and never reach the buffer or the bill. |
| `EDGE_TELEMETRY_BUFFER_BYTES` | `env\alloy.env` | `33554432` (32 MiB) | How much telemetry survives an outage. **See the disk note below.** |
| `EDGE_TELEMETRY_MAX_RETRY_AGE` | `env\alloy.env` | `24h` | How long a failing batch is retried before being dropped. Set above your worst realistic outage. |
| `EDGE_METRICS_SCRAPE_INTERVAL` | `env\alloy.env` | `60s` | Metric resolution vs. volume. If you lower it, lower `EDGE_METRICS_SCRAPE_TIMEOUT` too — Alloy **refuses to start** if the timeout is not below the interval. |
| `EDGE_ALLOY_LOG_LEVEL` | `env\alloy.env` | `warn` | Alloy's own chatter in `logs\alloy.*.log`. Raise to `info` while debugging, put it back after. |

### Budget ~6× the buffer cap in disk

`EDGE_TELEMETRY_BUFFER_BYTES` is applied **per signal** — there are three buffer files
(logs, traces, metrics) — and each file allocates in doublings, so a 32 MiB cap was measured
holding a ~64 MiB file. Worst case for the default is therefore **~192 MiB**, not 32 MiB.
Size the cap against free space on `C:` with that multiplier in mind.

### What happens when the buffer fills

Alloy **keeps what is already buffered and discards newly produced telemetry** until the
backlog drains. There is no drop-oldest mode. So a long enough outage keeps its *beginning*
and loses its *tail* — which is usually the right trade, because the cause is at the start.
You will see this in `logs\alloy.err.log` as:

```
level=error msg="Exporting failed. Rejecting data." error="sending queue is full"
```

That line means the cap is doing its job, not that the box is broken. If you see it during
*ordinary* outages, raise the cap or lower the sample ratio.

### What is never at risk

The app talks to the sidecar over localhost, which is up even when the box is not, and its
exporter is asynchronous. **The POS is never slowed or blocked by telemetry** — not when the
internet is down, not when the buffer is full, not when `laguna-alloy` is stopped entirely.
Nothing depends on the sidecar service, so it also cannot hold up a boot.

---

## 4. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `laguna-alloy` won't start; `alloy.err.log` names a public-preview component | The `stability.level` flag was removed from `services\alloy.xml` | Restore it — the disk buffer needs it. Re-run `install.ps1`. |
| Service starts, nothing in Grafana, ingest returns **401/403** | Node key mismatch, or a stray newline in `env\alloy-node-key` | Confirm `EDGE_NODE_KEY` == `NODE_SYNC_KEY`, then re-run `install.ps1` (it rewrites the key file with no BOM and no trailing newline). |
| Logs and traces arrive, **metrics don't** | The `/metrics` scrape is failing | `curl.exe http://127.0.0.1:9090/metrics` — if empty, check `METRICS_PORT` in `env\edge-node.env` matches `EDGE_METRICS_ADDRESS`. |
| Metrics arrive but under a **different node** than the logs | `EDGE_NODE_ID` ≠ the app's `NODE_ID` | Make them equal and re-run `install.ps1`. (A fresh install can't hit this — the preflight blocks it.) |
| `alloy.err.log` repeats `Exporting failed. Will retry` | The box is offline, or the ingest is down | Nothing to do. This is the buffer working; it drains on reconnect. |
| Nothing at all in Grafana, no errors anywhere | The app isn't exporting | Check `OBSERVABILITY_ENABLED=true` **and** `OTEL_EXPORTER_OTLP_ENDPOINT` are set in `env\edge-node.env`, then `update.ps1 -Service edge-node`. |
| Right data, **wrong time window** | Clock drift | §1. `w32tm /resync`. |
| `alloy-data\` much bigger than expected | The ~6× multiplier above | Lower `EDGE_TELEMETRY_BUFFER_BYTES`, re-run `install.ps1`, restart the service. |

Useful one-liners:

```powershell
# Is the sidecar healthy? (its own status page, localhost only)
curl.exe -s -o NUL -w "alloy %{http_code}`n" http://127.0.0.1:12345/-/ready

# How big is the buffer right now?
Get-ChildItem C:\laguna-edge\alloy-data -Recurse | Measure-Object Length -Sum |
  ForEach-Object { "{0:N1} MB" -f ($_.Sum/1MB) }

# Re-validate the config after hand-editing it (does not restart anything)
& C:\laguna-edge\artifacts\alloy\alloy.exe validate --stability.level=public-preview C:\laguna-edge\alloy\config.alloy
```

---

## 5. Turning it off

Three levels, least to most invasive. None of them touch the POS.

```powershell
# 1. Stop shipping, keep the sidecar installed (app stops exporting):
#    set OBSERVABILITY_ENABLED=false in env\edge-node.env, then
.\scripts\update.ps1 -Service edge-node

# 2. Stop the sidecar (the app tolerates it being gone; buffer is kept on disk):
Stop-Service laguna-alloy

# 3. Remove the sidecar entirely:
Remove-Item env\alloy.env        # so install.ps1 stops registering it
.\scripts\uninstall.ps1
.\scripts\install.ps1            # reinstalls the four POS services without alloy
```

After any of these the box must be fully healthy with no telemetry-related errors — confirm
with [`VALIDATION.md`](VALIDATION.md).
