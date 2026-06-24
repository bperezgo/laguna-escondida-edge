# Plan — Serving the Edge App to LAN Devices (Windows box)

> Status: **decisions locked — ready to implement.** Companion docs:
> `ai-plan/EDGE_OFFLINE_PLAN.md` (frontend offline architecture),
> `laguna-escondida-backend/docs/playbooks/` (backend / sync playbooks).
>
> Scope: **how to expose the offline-capable web app to Android tablets/POS/kitchen devices on
> the restaurant LAN**, served from a Windows edge box, over HTTPS, with device-access
> restriction. Does **not** change application code (one optional cookie note aside).

---

## 0. Decisions locked (this review session)

| Decision | Choice | Why |
|---|---|---|
| Reverse proxy | **Caddy** | Single `.exe`, automatic internal-CA TLS, streams SSE by default. |
| Where the config lives | **New dedicated repo `laguna-escondida-edge`** (the *installer/appliance* repo — Caddy **and** all service orchestration together) | Caddy fronts all services and is owned by none of the app repos; ports/boot-order/Caddyfile are one coupled unit. |
| TLS on the LAN | **HTTPS via Caddy `tls internal`** | Required by the `Secure` cookie (§1); root cert provisioned onto tablets once. |
| Tablet hostname | **Router local DNS → `pos.laguna.lan`** (DHCP-reserved box IP) | Android browsers don't reliably resolve `.local` mDNS; we control the router. `.lan` avoids the RFC-6762 `.local`/mDNS special-casing. |
| Access control (v1) | **Layers 1 + 2 + 3** (JWT auth + Windows Firewall IP allowlist + POS VLAN/SSID). **Skip mTLS.** | Strong perimeter for a single site without per-device cert provisioning. |

---

## 1. The constraint that drives everything: the Secure cookie

The sign-in route sets the auth cookie with:

```ts
// app/api/auth/signin/route.ts:52
res.cookies.set("access_token", token, {
  httpOnly: true,
  secure: process.env.NODE_ENV === "production", // ← Secure in production
  sameSite: "strict",
});
```

On the edge box (running as `production`), the cookie is **`Secure`**, so the browser will
**only send it over HTTPS**. Consequence:

- Serve the app over plain `http://<lan-ip>` → login silently breaks (cookie is set but never
  returned).
- Therefore we **serve HTTPS on the LAN** via Caddy. This is the single biggest reason to put a
  TLS-terminating reverse proxy in front, and it's why TLS is non-optional here.

(Plain-HTTP fallback with an insecure-cookie override is documented in §10 only as a
break-glass; we are **not** taking it.)

---

## 2. Target architecture

```
Android tablets / POS / kitchen (LAN)
        │  STEP 1 — name resolution: router DNS answers "pos.laguna.lan → 192.168.10.10"
        │  STEP 2 — HTTPS :443
        ▼
   Caddy  (the ONLY LAN-exposed service)  ── 192.168.10.10:443
        │  http://127.0.0.1:3000
        ▼
   Next.js standalone  (node server.js, bound 127.0.0.1:3000)
        │  http://127.0.0.1:8080  (server-side proxy in app/api/*)
        ▼
   Go edge node  (bound 127.0.0.1:8080)
        │           ▲
        │           └──── Go POS-printing service (bound 127.0.0.1:8090)
        ▼
   Postgres (bound 127.0.0.1:5432)
```

Key property: **only Caddy listens on the LAN.** Next + both Go services + Postgres bind to
`127.0.0.1`, so they cannot be hit directly from the network. (Ports above are the proposed
defaults — pin them in the installer repo's env files.)

---

## 3. Why Caddy (decided)

Caddy is a single static binary with **automatic TLS via a built-in internal CA**, **streams
SSE by default** (`flush_interval -1`, the equivalent of nginx `proxy_buffering off;`), and
runs cleanly as a Windows service. nginx-on-Windows is a known weak spot (no true multi-worker,
file-handle limits) and needs manual cert generation/renewal. IIS+ARR and Traefik were
considered and rejected as heavier than needed at this scale.

The app routes already send `X-Accel-Buffering: no`, which Caddy also honors — belt and braces
for the SSE channels (`/api/sse/commands/[area]`, `/api/sse/open-bill-products/[area]`).

---

## 4. The installer repo: `laguna-escondida-edge`

The edge box is its own **appliance** that composes build artifacts from three app repos plus
two off-the-shelf services (Postgres, Caddy). That orchestration is owned by none of the app
repos, so it gets its own repo. Caddy lives here **with** the rest of the service config — not
in a separate repo — because the Caddyfile, the service ports, and the boot order are one
tightly-coupled unit (change a port → both would change in lockstep).

### Boundary

The edge repo owns **orchestration, config, and provisioning**. It does **not** own app source —
it consumes **versioned build artifacts**: the two Go `.exe`s (backend edge node + pos-printing)
and the frontend's `.next/standalone` bundle + a pinned Node runtime. Same model as a
docker-compose repo referencing image tags rather than vendoring source.

### Structure

```
laguna-escondida-edge/
  Caddyfile                      # the only LAN-exposed service (§5)
  versions.json                  # pinned artifact versions per app repo
  services/                      # WinSW (or NSSM) service definitions; encode boot order
    postgres.xml                 #   boot order: Postgres → edge-node →
    edge-node.xml                #               pos-printing → next → caddy
    pos-printing.xml
    next.xml
    caddy.xml
  env/                           # per-service env: ports, bind 127.0.0.1, API URLs
    edge-node.env
    pos-printing.env
    next.env                     #   PORT=3000 HOSTNAME=127.0.0.1
                                 #   NEXT_PUBLIC_API_URL=http://127.0.0.1:8080/api
  scripts/
    fetch-artifacts.ps1          # download pinned builds (GitHub Releases / CI artifacts)
    install.ps1                  # register services, set boot order, firewall rules
    uninstall.ps1
    update.ps1                   # swap a single service to a new pinned version
  certs/                         # Caddy root CA export → installed on each tablet
  provisioning/                  # tablet setup runbook (§8)
  artifacts/                     # (gitignored) fetched .exe's + Next bundle + Node land here
  README.md
```

### Artifact flow

1. Each app repo publishes a release artifact (GitHub Release or CI build).
2. `versions.json` pins the version of each.
3. `fetch-artifacts.ps1` downloads them into `artifacts/`.
4. `install.ps1` lays them out and registers the five Windows services.

---

## 5. The Caddyfile (final, secure)

```caddy
pos.laguna.lan {
    tls internal                 # Caddy's own internal CA — no public domain needed

    encode zstd gzip

    # Defense-in-depth (firewall in §6 is the primary control):
    # reject anything not on the POS subnet at the app layer too.
    @notlan not remote_ip 192.168.10.0/24
    respond @notlan "Forbidden" 403

    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options    "nosniff"
        X-Frame-Options           "DENY"
        Referrer-Policy           "strict-origin-when-cross-origin"
        -Server
    }

    reverse_proxy 127.0.0.1:3000 {
        flush_interval -1        # stream SSE immediately, no buffering
    }
}
```

- `tls internal` → Caddy issues short-lived leaf certs from its **own long-lived root CA**,
  auto-renewed. The **root CA** (in Caddy's data dir) is the thing we export and install on each
  tablet once during provisioning; afterwards HTTPS is warning-free and the `Secure` cookie
  flows.
- Run Next bound to localhost so it's not directly reachable (from `env/next.env`):

```
PORT=3000
HOSTNAME=127.0.0.1
NEXT_PUBLIC_API_URL=http://127.0.0.1:8080/api
node .next/standalone/server.js
```

> **Fallback (only if the router can't do local DNS):** change the site name to the box's
> reserved IP (`192.168.10.10 { tls internal }`). Ugly URL, cert SAN is the IP, but works
> anywhere.

---

## 6. Hostname resolution (router local DNS)

Android browsers don't reliably resolve `.local` mDNS names, and we control the router, so:

1. **DHCP-reserve** a fixed IP for the box (e.g. `192.168.10.10`).
2. **Router local DNS entry:** `pos.laguna.lan → 192.168.10.10`.
3. Caddy site name = `pos.laguna.lan`; tablets are kiosk-locked to `https://pos.laguna.lan`.

**Android resolution gotchas (handle in provisioning):**
- Ensure each tablet uses the **router as its DNS server** (the DHCP default).
- **Disable Private DNS / DNS-over-HTTPS** on each tablet, or it will bypass the router and
  fail to resolve `pos.laguna.lan`.
- We use `.lan` (not `.local`) precisely to avoid the OS multicast-DNS special-casing.

---

## 7. Restricting access to known devices (layers 1 + 2 + 3)

**You cannot reliably filter by MAC at the app or proxy layer** — by the time a request reaches
Caddy or Node only the **IP** is visible. MAC filtering belongs on network gear and is weak
anyway (spoofable, randomized). So we layer real controls:

1. **App auth (already implemented)** — the JWT httpOnly cookie + sign-in is the real access
   control. Everything below is defense-in-depth.
2. **DHCP reservations + Windows Firewall IP allowlist** — pin each tablet to a fixed IP by its
   MAC on the router; add a Windows Firewall **inbound rule on :443 scoped to that IP set**.
   This is the practical "MAC allowlist," enforced at the right layer. The Caddy `remote_ip`
   rule (§5) is the app-layer backup.
3. **POS VLAN or dedicated SSID** — isolate tablets from guest Wi-Fi. Use a **VLAN** if the
   router supports it; otherwise a **dedicated POS SSID** is the lighter substitute.

**Skipped for v1: mTLS client certs.** True cryptographic device identity, but per-tablet
provisioning cost isn't justified for a single site with no compliance driver. Revisit if hard
device identity is ever required (`tls { client_auth { mode require_and_verify … } }`).

---

## 8. Windows services, boot order & tablet provisioning

### Services (registered by `install.ps1`, via WinSW or NSSM)

Boot order: **Postgres → Go edge node → Go pos-printing → Next standalone → Caddy.**
- Caddy's data dir (its internal CA + certs) **must persist across restarts** — back it up; if
  it's lost, the root cert changes and every tablet must re-trust.

### Tablet provisioning runbook (`provisioning/`)

1. Install **Caddy's root CA cert** (export from the box's Caddy data dir). On Android: Settings
   → Security → install CA certificate. Chrome/PWA then trust `https://pos.laguna.lan`.
   (Android shows a persistent "network may be monitored" notice for user CAs — acceptable on a
   locked-down kiosk device.)
2. Confirm the tablet's DNS = router, **Private DNS off** (§6).
3. DHCP-reserve the tablet's IP (needed for the firewall allowlist, §7).
4. Kiosk-lock the browser to `https://pos.laguna.lan`.

---

## 9. Implementation checklist

**Edge repo bootstrap**
- [ ] Create `laguna-escondida-edge`; add `Caddyfile`, `versions.json`, `services/`, `env/`,
      `scripts/`, `provisioning/`, `README.md` per §4.
- [ ] Each app repo publishes a fetchable release artifact (Go `.exe`s, Next standalone bundle).
- [ ] `fetch-artifacts.ps1` + `install.ps1` register the five services with the §8 boot order.

**Networking & TLS**
- [ ] Bind Next + both Go services + Postgres to `127.0.0.1`; expose only Caddy on the LAN (§2).
- [ ] `tls internal`; verify `Secure` cookie flows over HTTPS end-to-end (login works on a
      tablet).
- [ ] `flush_interval -1`; verify SSE streams without buffering on a tablet.
- [ ] Persist Caddy's data dir across restarts (§8).

**Hostname**
- [ ] DHCP-reserve the box IP; add router local DNS `pos.laguna.lan → box IP` (§6).
- [ ] Confirm Android tablets resolve it (DNS = router, Private DNS off).

**Access control**
- [ ] DHCP-reserve each tablet; Windows Firewall inbound allow on :443 scoped to tablet IPs (§7).
- [ ] Caddy `remote_ip` backup rule in place (§5).
- [ ] POS VLAN if the router supports it, else dedicated POS SSID (§7).

**Provisioning**
- [ ] Export Caddy root CA; install on each tablet; kiosk-lock to `https://pos.laguna.lan` (§8).

---

## 10. Break-glass fallback: plain HTTP (NOT taking this)

Documented only so we don't rediscover it under pressure. If TLS provisioning ever has to be
deferred, flip the cookie:

```ts
secure: process.env.EDGE_INSECURE_HTTP !== "true" && process.env.NODE_ENV === "production",
```

Trade-offs: loses Secure-cookie protection on the LAN and blocks future secure-context features
(PWA/service worker, camera). We are serving HTTPS via Caddy instead — it's nearly free here.

---

## 11. Remaining open questions

- Confirm the restaurant's router actually supports **local DNS overrides** (most prosumer /
  UniFi / MikroTik / OpenWrt / pfSense do; some ISP-locked units don't). If not → static-IP
  fallback (§5).
- Confirm the router supports **VLANs**; if not, fall back to a dedicated POS SSID (§7).
- Any **non-tablet devices** (manager laptop, printer config UI) that also need LAN access and
  must be added to the firewall allowlist / DNS?
- Pick concrete **port numbers** and the **POS subnet CIDR** to bake into `env/` and the
  Caddyfile `remote_ip` rule.
</content>
</invoke>
