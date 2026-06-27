# laguna-escondida-edge

The **edge appliance**: how the offline-capable POS runs and is served on the restaurant
LAN from a single Windows box. This repo owns *orchestration, config, and provisioning* — it
does **not** contain app source. It assembles **versioned build artifacts** from the app repos
and serves them securely over HTTPS to Android tablets.

Full design + rationale: [`ai-plan/EDGE_LAN_SERVING_PLAN.md`](ai-plan/EDGE_LAN_SERVING_PLAN.md).

## What runs on the box

```
Android tablets (LAN)
   │  router DNS: pos.laguna.lan -> box IP        (e.g. 192.168.10.10)
   │  HTTPS :443
   ▼
 Caddy            <- the ONLY service exposed on the LAN (TLS via internal CA)
   │  127.0.0.1:3000
   ▼
 Next.js (standalone)
   │  127.0.0.1:8080   (server-side, inside Next's /api/* route handlers)
   ▼
 Go edge node (APP_MODE=edge; ticket printing built in) ── cloud sync / S3 / invoicing (online)
   │
   ▼
 Postgres (127.0.0.1:5432)
```

Everything except Caddy binds to `127.0.0.1`, so only Caddy is reachable from the network.

## Layout

| Path | What |
|---|---|
| `Caddyfile` | LAN HTTPS reverse proxy (the only exposed service) |
| `services/*.xml` | WinSW Windows-service definitions (one per process) — see `services/README.md` |
| `scripts/install.ps1` | Register all services + stage edge-node `.env` + firewall rule (run as Admin) |
| `scripts/uninstall.ps1` | Remove all services + firewall rule |
| `scripts/fetch-artifacts.ps1` | Download off-the-shelf binaries (Caddy, Node, Postgres) into `artifacts/` |
| `scripts/update.ps1` | Swap one service to a new pinned version |
| `env/edge-node.env.example` | Template for the backend's per-box config; copy to `env/edge-node.env` (gitignored) |
| `versions.json` | Pinned versions (WinSW, Caddy, Node, Postgres, app artifacts) |
| `certs/` | Exported Caddy root CA for tablets — see `certs/README.md` |
| `provisioning/` | Android tablet setup runbook |
| `artifacts/` | (gitignored) fetched binaries + Next bundle land here |

## Deploy (on the Windows box)

> Install-root convention: **`C:\laguna-edge`** — clone/copy this repo there. If you use a
> different path, update the absolute `storage` path in `Caddyfile`.

```powershell
# 1. Get the binaries (Caddy, Node, Postgres, the 3 app artifacts) into artifacts\
.\scripts\fetch-artifacts.ps1

# 2. Register services + lock the firewall to your tablet IPs (elevated PowerShell)
.\scripts\install.ps1 -AllowedTabletIPs '192.168.10.21','192.168.10.22'

# 3. Provision the LAN + tablets:
#    - Router: DHCP-reserve the box IP + add DNS  pos.laguna.lan -> box IP
#    - Tablets: install the Caddy root cert, then open https://pos.laguna.lan
#    See certs\README.md and provisioning\README.md
```

Manage individual services with `services\<name>.exe status|stop|start` (e.g.
`services\caddy.exe status`).

## Status

Scaffold reconciled with the real apps (4 services: postgres → edge-node → next → caddy).
Phased work to first real install is tracked in
[`ai-plan/EDGE_WINDOWS_SERVICES_PLAN.md`](ai-plan/EDGE_WINDOWS_SERVICES_PLAN.md). Open items:
- Fill the off-the-shelf download steps in `fetch-artifacts.ps1` (Caddy/Node/Postgres) and add a
  local `build-artifacts.ps1` for the Go exe + Next standalone bundle (Phase 2).
- Copy `env/edge-node.env.example` → `env/edge-node.env` and fill in real secrets/sync config.
- Pin real versions in `versions.json`.
- Confirm the router supports local DNS + VLANs (else use the static-IP / SSID fallbacks in the plan).
