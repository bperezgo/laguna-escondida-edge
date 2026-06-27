# Deployment runbook — fresh Windows box

Exact, in-order steps to take a **brand-new Windows box** from nothing to a running edge
appliance serving the POS over HTTPS on the LAN. Follow top to bottom. Every command is
copy-paste; nothing here needs improvising.

> **Golden rule:** the install root is **`C:\laguna-edge`**. The `Caddyfile` hard-codes this
> path (`storage … root C:\laguna-edge\caddy-data`) and the Next.js bundle stores **absolute**
> junction targets under it. If you deploy anywhere else, the build and the TLS data dir break.
> Use `C:\laguna-edge`. Don't move the folder after building.

---

## 0. What you are building

Five things run as Windows services, started in this order. Only Caddy is reachable from the
network; everything else binds `127.0.0.1`.

```
tablets ──HTTPS:443──> Caddy ──:3000──> Next.js ──:8080──> edge-node (Go) ──:5432──> Postgres
                       (the only LAN-exposed service)
```

| Service id        | Listens on        | Built/fetched by            |
|-------------------|-------------------|-----------------------------|
| `laguna-postgres` | 127.0.0.1:5432    | `fetch-artifacts.ps1`       |
| `laguna-edge-node`| 127.0.0.1:8080    | `build-artifacts.ps1` (Go)  |
| `laguna-next`     | 127.0.0.1:3000    | `build-artifacts.ps1` (pnpm)|
| `laguna-caddy`    | 0.0.0.0:443, :80  | `fetch-artifacts.ps1`       |

---

## 1. Prerequisites on the box

You need these **before** you start. Confirm each one.

```powershell
# Run an ELEVATED PowerShell for the whole runbook unless a step says otherwise.
# (Start menu → type "PowerShell" → right-click → Run as administrator.)

# a) Build toolchain — needed to compile the two app artifacts ON THIS BOX.
go version            # Go must be on PATH   (https://go.dev/dl/)
pnpm --version        # pnpm must be on PATH (npm i -g pnpm, or corepack enable)
git --version         # to clone the repos and stamp build SHAs

# b) Symlink capability — "next build" (standalone) needs it. EITHER run builds elevated,
#    OR enable Developer Mode once (recommended), then normal shells can build:
Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" `
  AllowDevelopmentWithoutDevLicense 1 -Type DWord -Force
```

> **No Go/pnpm on the restaurant box?** Alternative: build the `artifacts\` folder on a
> machine that *does* have them, at the **same path** `C:\laguna-edge`, then copy the whole
> `artifacts\` folder over. The Next bundle's junctions are absolute and only valid if the
> install root matches exactly. See `scripts\build-artifacts.ps1` (step 2 comment).

---

## 2. Lay down the source

Copy/clone **three** repos as siblings. The edge repo MUST live at `C:\laguna-edge`; the app
repos are the build sources (defaults are siblings of the edge repo's parent).

```
C:\laguna-edge\                     <- THIS repo (laguna-escondida-edge), at this exact path
C:\...\laguna-escondida-backend\    <- Go backend source  (build input)
C:\...\laguna-escondida-frontend\   <- Next.js frontend source (build input)
```

```powershell
# Example: clone the app repos next to a working folder, then place edge at C:\laguna-edge
git clone <backend-url>  C:\src\laguna-escondida-backend
git clone <frontend-url> C:\src\laguna-escondida-frontend
git clone <edge-url>     C:\laguna-edge
cd C:\laguna-edge
```

If your app repos are NOT default siblings, pass them explicitly in step 4.

---

## 3. Fetch the off-the-shelf binaries

Downloads Caddy, Node, and Postgres (versions pinned in `versions.json`) into `artifacts\`.

```powershell
cd C:\laguna-edge
.\scripts\fetch-artifacts.ps1
# -> artifacts\caddy\caddy.exe, artifacts\node\node.exe, artifacts\postgres\bin\postgres.exe
```

This does NOT create the Postgres data dir — step 5 does that.

---

## 4. Build the two app artifacts (on this box, at this path)

```powershell
cd C:\laguna-edge
.\scripts\build-artifacts.ps1
# If the app repos are elsewhere:
# .\scripts\build-artifacts.ps1 -BackendRepo C:\src\laguna-escondida-backend `
#                               -FrontendRepo C:\src\laguna-escondida-frontend
```

Produces `artifacts\edge-node\edge-node.exe` and `artifacts\next\server.js` (+ static assets,
real `node_modules`). The frontend's API URL is baked to `http://127.0.0.1:8080/api`. The built
git SHAs are stamped back into `versions.json` for traceability.

---

## 5. Initialize the Postgres cluster

Creates the data dir, the `laguna` app role, and the `laguna_escondida` database. **Does not
need admin** (runs as you). **Remember the password you choose — it must match `.env` in step 6.**

```powershell
cd C:\laguna-edge
.\scripts\init-postgres.ps1 -DbPassword 'pick-a-strong-db-password'
```

It prints the `postgres` superuser password at the end — **store it in your password manager**.
The app does not use it, but you need it for DB admin later. Re-running requires `-Force` (which
**wipes** the data dir — destructive).

---

## 6. Fill in the per-box config (secrets)

```powershell
cd C:\laguna-edge
Copy-Item env\edge-node.env.example env\edge-node.env
notepad env\edge-node.env
```

Fill every `CHANGE_ME` / `(required)` value. **Critical:** `DB_PASSWORD` must equal the
`-DbPassword` you used in step 5. Key fields:

- `DB_PASSWORD` — must match step 5.
- `ORGANIZATION_ID`, `JWT_SECRET`, `ADMIN_API_KEY` — required, the box won't start without them.
- `CLOUD_SYNC_URL` + `NODE_SYNC_KEY` — set to enable cloud sync; leave blank for local-only.
- `SPACES_*`, `ELECTRONIC_INVOICE_*` — required for storage + invoicing features.
- `PRINTER_TRANSPORT=windows`, `PRINTER_TARGET=<exact Windows printer name>`.

> `env\edge-node.env` is **gitignored** and holds real secrets. Never commit it. `install.ps1`
> copies it to `artifacts\edge-node\.env`, which the backend loads on startup.

---

## 7. Install the services + lock the firewall

**Elevated PowerShell.** Registers all four services in dependency order, stages the `.env`,
sets the Postgres logon account to `NetworkService`, and adds the firewall rule.

```powershell
cd C:\laguna-edge
# Use your real DHCP-reserved tablet IPs (or the subnet) — must match the Caddyfile @notlan CIDR.
.\scripts\install.ps1 -AllowedTabletIPs '192.168.101.0/24'
```

The script is **re-runnable / self-healing** — if anything failed, fix it and run it again.

---

## 8. Verify it's up

Run the smoke check (full version in [`VALIDATION.md`](VALIDATION.md)):

```powershell
Get-Service laguna-* | Format-Table Name, Status, StartType
# All four should be Running.

curl.exe -k -i https://192.168.101.49/        # expect: 307, Location: /signin  (RELATIVE)
curl.exe -k -i https://192.168.101.49/signin  # expect: 200, HTML
```

If `https://192.168.101.49/` redirects to `localhost:3000`, the Caddyfile `header_down Location`
fix is missing — see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

---

## 9. Network + tablets

1. **Router:** add a DHCP reservation binding the box's MAC → `192.168.101.49` so the IP never
   changes. (The Caddy cert SAN and the firewall rule are tied to this IP.)
2. **Tablets:** install the Caddy internal-CA root cert so HTTPS is trusted, then open
   `https://192.168.101.49`. Export the root with:
   ```powershell
   # The root lives under the persisted data dir; export it for tablet install:
   Copy-Item C:\laguna-edge\caddy-data\pki\authorities\local\root.crt C:\laguna-edge\laguna-root-ca.crt
   ```
   See `certs\README.md` / `provisioning\README.md` for the per-tablet steps.

---

## Day-2 operations (quick reference)

```powershell
# Status / start / stop one service (use the WinSW wrapper):
C:\laguna-edge\services\caddy.exe status
C:\laguna-edge\services\caddy.exe stop
C:\laguna-edge\services\caddy.exe start

# Swap ONE service to a freshly built/fetched version (minimal downtime):
.\scripts\update.ps1 -Service next        # rebuilds from frontend repo
.\scripts\update.ps1 -Service edge-node   # rebuilds from backend repo + refreshes .env
.\scripts\update.ps1 -Service caddy       # re-fetches pinned binary

# Remove everything (keeps artifacts\ and caddy-data\ so the CA root survives):
.\scripts\uninstall.ps1
```

To change config: edit `env\edge-node.env`, then `.\scripts\update.ps1 -Service edge-node`
(it re-stages the `.env` and restarts). Editing the `Caddyfile` only needs a Caddy reload —
see [`MONITORING.md`](MONITORING.md).
