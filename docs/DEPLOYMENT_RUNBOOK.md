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
Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" AllowDevelopmentWithoutDevLicense 1 -Type DWord -Force

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
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

## 4. Install the two app artifacts (downloaded, not built)

`fetch-artifacts.ps1` (step 3) also downloads the app builds: the GitHub Release of each app
repo pinned in `versions.json` (`artifacts.edge-node.version`, `artifacts.next.version` are
release **tags**), each checked against its `.sha256` and refused on mismatch.

```powershell
cd C:\laguna-edge
.\scripts\fetch-artifacts.ps1 -Only edge-node,next
# -> artifacts\edge-node\edge-node.exe, artifacts\next\server.js  (+ RELEASE = installed tag)
```

No Go, pnpm, git or app source is needed on the box. The frontend's API URL is baked to
`http://127.0.0.1:8080/api` and the order-action PIN to `1234` by the frontend's release
workflow.

Developer fallback for **unreleased** code (needs Go + pnpm + Developer Mode, and must be run at
the final install path): `.\scripts\build-artifacts.ps1`. A local build records
`local-<sha>` in `artifacts\<app>\RELEASE`, so the next `fetch-artifacts.ps1` replaces it
with the pinned release.

### Cutting a release (developer)

1. Tag the app repo: `git tag v1.2.0 && git push origin v1.2.0`.
   - backend: CI pushes the cloud image to ECR **and** attaches
     `edge-node-windows-amd64-v1.2.0.zip` (+ `.sha256`) to the GitHub Release.
   - frontend: CI attaches `next-standalone-windows-v1.2.0.zip` (+ `.sha256`), after a
     relocated smoke test.
2. Deploy the cloud first: point `aws-infra/image-tags.json` `laguna` at the backend tag and
   `cdk deploy bryan-dev-services`.
3. Cut the edge release from your machine (git, gh, jq):
   ```bash
   scripts/release.sh --dry-run   # resolve + check only
   scripts/release.sh             # latest app releases with a Windows asset, bump patch
   scripts/release.sh --backend v1.2.0 --frontend v1.0.3 --version v1.1.0
   ```
   It refuses a backend newer than the cloud's `image-tags.json` pin and an app tag whose
   release has no Windows asset (failed CI). Then it pins `versions.json`, commits, tags this
   repo, and publishes a GitHub Release with `edge-vX.Y.Z.zip` (tracked files only, never
   `env/` or `certs/`) and a `manifest.json` (every component's tag, URL and sha256).
4. On each box: `git pull` then `.\scripts\update.ps1 -Service edge-node` (or `next`).
   `update.ps1` downloads and verifies *before* stopping the service; `GET /api/edge/status`
   reports the running backend tag in `version`.

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
- `STORAGE_*`, `ELECTRONIC_INVOICE_*` — required for storage + invoicing features.
- `PRINTER_TRANSPORT=windows`, `PRINTER_TARGET=<exact Windows printer name>`.

> `env\edge-node.env` is **gitignored** and holds real secrets. Never commit it. `install.ps1`
> copies it to `artifacts\edge-node\.env`, which the backend loads on startup.

---

## 6b. Set this box's network identity (`box.env`)

`env\box.env` is the **single source of truth** for the box's LAN IP and subnet. The `Caddyfile`
uses `{$LAGUNA_LAN_IP}` / `{$LAGUNA_LAN_CIDR}` placeholders, the firewall rule derives from the
same CIDR, and Caddy's cert SAN comes from the IP — so they can't drift apart. **Never hardcode
an IP in the Caddyfile.**

```powershell
cd C:\laguna-edge
Copy-Item env\box.env.example env\box.env
notepad env\box.env
```

Set both values for THIS box:

- `LAGUNA_LAN_IP` — the box's static / DHCP-reserved IPv4 address (e.g. `192.168.0.123`). Pin it
  with a router DHCP reservation (step 9) so it never changes.
- `LAGUNA_LAN_CIDR` — the POS subnet in CIDR form (e.g. `192.168.0.0/24`). `LAGUNA_LAN_IP` must
  fall inside it.

`install.ps1` **preflights** these against reality — if the box doesn't actually hold
`LAGUNA_LAN_IP`, or the IP isn't inside `LAGUNA_LAN_CIDR`, it aborts with a clear message instead
of leaving you with "services Running but nothing reachable."

---

## 7. Install the services + lock the firewall

**Elevated PowerShell.** Registers all four services in dependency order, stages the `.env`,
exports the network identity from `box.env`, sets the Postgres logon account to `NetworkService`,
verifies Caddy came up, and adds the firewall rule.

```powershell
cd C:\laguna-edge
.\scripts\install.ps1
# The firewall defaults to LAGUNA_LAN_CIDR from box.env. Pass -AllowedTabletIPs ONLY to
# tighten to specific DHCP-reserved tablet IPs, e.g.:
# .\scripts\install.ps1 -AllowedTabletIPs '192.168.0.21','192.168.0.22'
```

The script is **re-runnable / self-healing** — if anything failed, fix it and run it again.

---

## 8. Verify it's up

Run the smoke check (full version in [`VALIDATION.md`](VALIDATION.md)):

```powershell
Get-Service laguna-* | Format-Table Name, Status, StartType
# All four should be Running.

# Use the LAGUNA_LAN_IP you set in box.env (this box: 192.168.0.123).
curl.exe -k -i https://192.168.0.123/        # expect: 307, Location: /signin  (RELATIVE)
curl.exe -k -i https://192.168.0.123/signin  # expect: 200, HTML
```

> **`curl: (28) ... Couldn't connect`** = the IP isn't reachable: `LAGUNA_LAN_IP` in `box.env`
> doesn't match the address this box actually holds (run `Get-NetIPAddress -AddressFamily IPv4`).
> Fix `box.env` and re-run `install.ps1` — its preflight now catches this before it bites.

If `https://<LAGUNA_LAN_IP>/` redirects to `localhost:3000`, the Caddyfile `header_down Location`
fix is missing — see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

---

## 9. Network + tablets

1. **Router:** add a DHCP reservation binding the box's MAC → its `LAGUNA_LAN_IP` (this box:
   `192.168.0.123`) so the IP never changes. (The Caddy cert SAN and the firewall rule are tied
   to this IP.)
2. **Why HTTPS shows "not private" (`ERR_CERT_AUTHORITY_INVALID`):** the Caddyfile uses
   `tls internal`, so Caddy signs the LAN cert with its **own private CA**. The cert is valid;
   the client just doesn't trust the CA that signed it. Every client (dev PC + tablet) must
   install Caddy's **root CA** once. `install.ps1` already exports it to
   `C:\laguna-edge\laguna-root-ca.crt` and trusts it on the box itself. If you need to re-export:
   ```powershell
   Copy-Item C:\laguna-edge\caddy-data\pki\authorities\local\root.crt C:\laguna-edge\laguna-root-ca.crt
   ```
3. **Dev PC (Windows):** copy `laguna-root-ca.crt` off the box, then in an elevated PowerShell:
   ```powershell
   Import-Certificate -FilePath laguna-root-ca.crt -CertStoreLocation Cert:\LocalMachine\Root
   ```
   Then **fully restart the browser** — Chrome caches its trust decision per-process and keeps
   background processes alive, so a plain close-and-reopen often isn't enough:
   ```powershell
   Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
   ```
   Reopen `https://192.168.0.123`. Note: modern Chrome shows a **sliders/"tune" icon**, not a
   padlock — that icon is still "secure". Click it; it should read *"Connection is secure"*.
   If it still says "Not secure" after a full restart, confirm the bar shows `https://` (not
   `http://`) and that you imported the root on **this** machine (each client has its own store).
4. **Tablets:** install the same `laguna-root-ca.crt` as a trusted CA cert, then open
   `https://192.168.0.123`. See `certs\README.md` / `provisioning\README.md` for the per-tablet steps.

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
