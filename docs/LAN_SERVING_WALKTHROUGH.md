# LAN serving walkthrough — Caddy reverse proxy for the edge box

A step-by-step record of how we exposed the app on **port 3001** to the local network
using Caddy, with the reasoning behind every command and decision. Read this to
understand *why* the network behaves the way it does, not just *what* to type.

> Scenario captured here: a **plain-HTTP** quick test, serving
> `http://192.168.101.49` → the app on `localhost:3001`.
> The HTTPS + DNS production scenario builds on top of this (see the end).

---

## The end-to-end picture

```
Phone (192.168.101.x)
   │  http://192.168.101.49        ← clean URL, standard port 80
   ▼
Windows Firewall  ── Private profile, allow TCP 80 from LocalSubnet only
   ▼
Caddy  (binds :80, all interfaces)   ← the single front door
   │  localhost:3001
   ▼
Your app  (binds ::, dual-stack)     ← does the actual work
```

Every hop exists for a reason: the **firewall** decides *who* may connect, **Caddy**
decides *how* (port, TLS, compression, routing) and is the only thing exposed, and the
**app** stays behind it.

---

## Phase 0 — Understanding the environment

```bash
ls -la C:\Users\USER\dev\laguna-escondida-edge
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' }
Get-Command caddy
```

**Why:** Before changing anything, establish three facts: what the project already is,
the machine's real LAN IP, and whether Caddy is installed.

**Findings:**
- LAN IP is **`192.168.101.49`** on the `Ethernet` interface.
- Also present: `172.17.x` / `172.23.x` — these are **virtual adapters** (WSL, Hyper-V),
  *not* the real network. Binding a service to one of those makes it unreachable from
  the LAN. Always identify the real interface first.
- `caddy` was **not on PATH** — nothing installed globally.

**Concept:** A machine has many IP addresses (one per interface, real or virtual).
"Available on the local network" means reachable at the address on the *same subnet as
your other devices* — here `192.168.101.x`. Only `192.168.101.49` is routable from your
phone.

---

## Phase 1 — Reading the existing project

Read `Caddyfile`, `README.md`, `services/caddy.xml`, `versions.json`; listed `artifacts/`.

**Why:** The repo already had a `Caddyfile`. Editing it blindly would be a mistake — I
needed to know what it was *for*.

**Findings:**
- The existing `Caddyfile` is the **production POS config**: HTTPS `:443`, hostname
  `pos.laguna.lan`, `tls internal`, proxies port **3000**, rejects clients not on
  `192.168.10.0/24`.
- Your situation differs on three axes: app on **3001**, network **192.168.101.x**, and
  you wanted **plain HTTP** for the test.
- Caddy was a **scaffold** — `versions.json` pins `caddy: 2.8.4`, but `artifacts/caddy/`
  was empty (binary never downloaded). `services/caddy.xml` is a WinSW definition that
  would run it as a Windows service once the binary exists.

**Decision:** Because the test parameters differed from production on every axis, editing
the production file would corrupt the real POS config → we used a **separate file**.

---

## Phase 2 — Confirming the preconditions

```powershell
Get-NetTCPConnection -LocalPort 3001 -State Listen
Get-NetTCPConnection -LocalPort 80 -State Listen
```

**Why:** A reverse proxy is useless if there's nothing to proxy *to*, or if the port we
want to listen *on* is taken.

**Findings:**
- Something **is** listening on `3001`, at `LocalAddress ::`.
- Port `80` was **free**.

**Key concept — `::` (the important one):** `::` is the IPv6 "all interfaces" wildcard.
A listener on `::` accepts connections on *any* interface, not just loopback. On Windows,
Node.js-style servers bind `::` in **dual-stack** mode, so they also accept IPv4.

Practical implication: the app on 3001 was *already technically reachable* from the LAN
at `192.168.101.49:3001` — the only thing stopping that was the **Windows Firewall**.
Caddy's value isn't hiding 3001; it's giving you a clean **standard port (80/443)**,
**TLS**, and a **single hardened front door** instead of exposing the raw app port.

Contrast with `127.0.0.1` / `::1` — those are **loopback**, reachable only from the
machine itself. That's the pattern the production design uses: every backend binds
loopback, and only Caddy binds the public interface.

---

## Phase 3 — Installing Caddy

```powershell
New-Item -ItemType Directory -Force -Path artifacts\caddy
Invoke-WebRequest -Uri "https://github.com/caddyserver/caddy/releases/download/v2.8.4/caddy_2.8.4_windows_amd64.zip" -OutFile $zip
Expand-Archive -Path $zip -DestinationPath artifacts\caddy -Force
.\artifacts\caddy\caddy.exe version
```

**Why these specifics:**
- Version **2.8.4** deliberately — the version pinned in `versions.json`. Matching the
  pin means the real `scripts/install.ps1` later finds exactly this binary in exactly
  this location. We filled the scaffold's blank, didn't improvise.
- Extracted into `artifacts/caddy/` because `services/caddy.xml` already points its
  `<executable>` there.

---

## Phase 4 — Writing the config

Created **`Caddyfile.lan`** (new file; production `Caddyfile` untouched):

```caddyfile
{
	auto_https off
}

:80 {
	encode zstd gzip
	reverse_proxy localhost:3001 {
		flush_interval -1
	}
}
```

**Line by line:**
- `auto_https off` — Caddy's flagship feature is automatically provisioning HTTPS. For a
  plain-HTTP test that's the opposite of what we want; this tells Caddy "don't try to get
  a cert or redirect to 443." Without it, Caddy would upgrade `:80` to HTTPS.
- `:80` — the **site address**. A bare port with no hostname means "listen on port 80 on
  all interfaces, plain HTTP." This makes it LAN-reachable on a clean URL.
- `encode zstd gzip` — compress responses. Cosmetic for a test, free to include.
- `reverse_proxy localhost:3001` — forward every request to the app. `localhost` (not
  `127.0.0.1`) lets Caddy reach the app over IPv4 *or* IPv6, since the app binds
  dual-stack `::`.
- `flush_interval -1` — disable response buffering so streaming responses (SSE, live
  updates) reach the client immediately.

---

## Phase 5 — Validating, formatting, first run

```powershell
caddy.exe validate --config Caddyfile.lan --adapter caddyfile
caddy.exe fmt --overwrite Caddyfile.lan
```

**Why:** `validate` parses the config and checks it's well-formed *before* starting —
catches typos without taking down a port. It confirmed `auto_https` was fully disabled
(`automatic HTTPS is completely disabled for server` in the log) — proof the config did
what we intended. `fmt` normalized whitespace.

---

## Phase 6 — The timeout, and what it taught us

**What happened:** Started Caddy, immediately hit `http://localhost/` through it → it
**timed out** at 8s. But hitting the app **directly** on `127.0.0.1:3001`, `[::1]:3001`,
and `localhost:3001` all returned **HTTP 200** instantly. On retry, the proxy worked fine
(HTTP 200, ~20 KB).

**Why it matters:** The proxy path wasn't broken — the *first* request was just slow. The
likely cause is that the app on 3001 is a **dev server that compiles routes on first
access** (Next.js dev mode does exactly this: the first hit to a route triggers an
on-demand build that can take many seconds; later hits are cached and fast). The direct
probes warmed it up, so the proxy retry was fast.

**Lesson for production:** you run the built/standalone app, not the dev server, so
there's no first-hit compile. Persistent slow first-requests = you're proxying a dev
server.

---

## Phase 7 — Why it isn't reachable from the phone yet

```powershell
Get-NetConnectionProfile
```

**Finding:** the `Ethernet` network's category is **`Public`**.

**Concept — the firewall model:** Windows Firewall has three profiles — **Domain**,
**Private**, **Public** — and applies a *different rule set* per active network category.
`Public` (think coffee-shop Wi-Fi) is the most locked-down: it blocks essentially all
unsolicited inbound connections. That single fact is *why*:
- A `New-NetFirewallRule ... -Profile Private` rule never applies while the active profile
  is Public, and
- Even the raw app on `192.168.101.49:3001` wasn't reachable from the LAN.

**The fix (one-time, needs Administrator):**
```powershell
# 1. Mark this LAN as a trusted Private network (currently Public)
Set-NetConnectionProfile -InterfaceAlias "Ethernet" -NetworkCategory Private

# 2. Allow inbound HTTP :80 from LAN devices only
New-NetFirewallRule -DisplayName "Caddy LAN HTTP 80" -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 80 -Profile Private -RemoteAddress LocalSubnet
```
1. **Reclassify as Private** — declaring "this is my trusted LAN," which relaxes the
   default inbound block. Correct designation for a restaurant's own network.
2. **Open inbound TCP 80, Private, `RemoteAddress LocalSubnet`** — allow port 80, but only
   from devices on your own subnet. `LocalSubnet` is a safety scope: even if the box were
   bridged to a wider network, only same-subnet devices get in.

**Why admin is required:** changing a network's trust category and editing firewall rules
are system-level security operations. Running Caddy itself does **not** need admin
(Windows lets normal users bind port 80, unlike Linux where ports < 1024 are privileged) —
only this one-time network setup does.

---

## Managing Caddy

```powershell
# Stop a running instance
Get-Process caddy -ErrorAction SilentlyContinue | Stop-Process -Force

# Run in the foreground (logs visible; Ctrl+C to stop)
cd C:\Users\USER\dev\laguna-escondida-edge
.\artifacts\caddy\caddy.exe run --config .\Caddyfile.lan --adapter caddyfile
```

---

## Reference: facts about this box

| Fact | Value |
|---|---|
| LAN IP | `192.168.101.49` (Ethernet) |
| Subnet | `192.168.101.0/24` |
| Router / gateway | `192.168.101.1` |
| DNS server handed out by DHCP | `192.168.101.1` (the router) |
| Box MAC (for DHCP reservation) | `6C-62-6D-B0-97-8C` |
| Caddy version | `2.8.4` at `artifacts/caddy/caddy.exe` |
| App port | `3001` (binds `::`, dual-stack) |

---

---

# Part 2 — HTTPS + DNS (the real restaurant scenario)

Moving from "HTTP on an IP" to "HTTPS on a hostname" adds **two new problems** the simple
version didn't have:

1. **Name resolution (DNS):** the phone types `https://pos.laguna.lan`; something must
   translate that to `192.168.101.49`. `pos.laguna.lan` isn't a real public domain, so
   you must answer it yourself — via **router local DNS** (cleanest) or a **DNS server
   running on the box**. This depends on your router.
2. **Certificate trust:** HTTPS needs a certificate the phone trusts. Caddy's
   `tls internal` mints one from a private CA — but no phone trusts that CA until you
   **install Caddy's root certificate** on it. Without it you get a "not secure" warning.

## What we changed in the production `Caddyfile`

We adapted the real production config (not a separate file) to this box's reality:

| Setting | Was | Now | Why |
|---|---|---|---|
| Upstream port | `127.0.0.1:3000` | `127.0.0.1:3001` | your app's actual port |
| Subnet lock | `192.168.10.0/24` | `192.168.101.0/24` | your actual LAN |
| Hostname | `pos.laguna.lan` | `pos.laguna.lan` | unchanged |
| TLS | `tls internal` | `tls internal` | private CA, no public domain needed |

`tls internal` + a hostname site address makes Caddy **automatically** (a) mint a cert
from its internal CA and (b) redirect `:80 → :443`. We confirmed both in the validate log:
`enabling automatic HTTP->HTTPS redirects`.

## What we proved on the box (no admin, no phone needed)

- Caddy bound **80 and 443** and generated its **internal CA** on first handshake:
  `C:\laguna-edge\caddy-data\pki\authorities\local\root.crt` (+ `intermediate.crt`).
- A loopback request returned **`HTTP 403`** — proof the **subnet lock works**: a source
  that isn't on `192.168.101.0/24` is rejected at the app layer. (This also means you
  **cannot fully test from the box itself** — local curl is always "off-subnet." Real
  end-to-end testing happens from a phone on the LAN.)
- Exported the root cert to **`certs\laguna-root.crt`** (the file the phone installs).
  Subject `CN=Caddy Local Authority - 2026 ECC Root`, valid ~10 years.

## The three things still required for a phone to load it

### 1. Firewall + trusted network (one-time, Administrator)

```powershell
# Trust the LAN (currently classified Public)
Set-NetConnectionProfile -InterfaceAlias "Ethernet" -NetworkCategory Private

# Open HTTPS (443) and HTTP (80, for the auto-redirect), LAN subnet only
New-NetFirewallRule -DisplayName "Caddy LAN HTTPS 443" -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 443 -Profile Private -RemoteAddress LocalSubnet
New-NetFirewallRule -DisplayName "Caddy LAN HTTP 80" -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 80 -Profile Private -RemoteAddress LocalSubnet
```

### 2. DNS — make `pos.laguna.lan` resolve to `192.168.101.49`

**The deployment router is a TP-Link TL-WR850N**, which has **no local-DNS / host-records
feature** (its "Dynamic DNS" is for WAN/external names; "Static Routing" is an IP route
table — neither resolves local names). So we use the **DNS-server-on-the-box** approach:

1. Run **Technitium DNS Server** on the box (script: `scripts/setup-technitium-dns.ps1`).
   It answers `pos.laguna.lan → 192.168.101.49` and forwards everything else to the
   internet.
2. On the TP-Link, point DHCP at the box so every device uses it:
   - **DHCP → DHCP Settings**: set **Primary DNS = `192.168.101.49`**. Leave Secondary
     blank (or also the box) — do **not** put a public DNS there, or `pos.laguna.lan`
     resolution becomes intermittent.
   - **DHCP → Address Reservation**: bind the box MAC `6C-62-6D-B0-97-8C → 192.168.101.49`.
3. Renew the lease on a test device (toggle Wi-Fi) so it picks up the new DNS.

> **Port 53 caveat:** Technitium needs UDP/TCP 53. On a Windows box running WSL/Hyper-V,
> the ICS (`SharedAccess`) service squats on port 53 — the setup script detects this and
> tells you how to free it. A dedicated edge box without WSL/Hyper-V has 53 free.

> **Phone gotcha:** disable **Private DNS / DNS-over-TLS** on the phone (Android: Settings →
> Network → Private DNS → Off), or it bypasses your LAN DNS and the name won't resolve.

### 3. Install the root cert on the phone

Transfer `certs\laguna-root.crt` to the phone, then:

- **Android:** Settings → Security → Encryption & credentials → Install a certificate →
  **CA certificate** → accept the warning. (A persistent "network may be monitored" notice
  is normal for a private CA.)
- **iPhone:** install the `.crt` profile (Settings → General → VPN & Device Management →
  install), **then** Settings → General → About → **Certificate Trust Settings** → toggle
  full trust ON for the Caddy root. iOS requires this second step explicitly.

### Then

On the phone (on the restaurant Wi-Fi): open **`https://pos.laguna.lan`** → no warning,
the app loads, and the `Secure` auth cookie works.

## Running it

```powershell
cd C:\Users\USER\dev\laguna-escondida-edge
.\artifacts\caddy\caddy.exe run --config .\Caddyfile --adapter caddyfile
```

For the real box this is done as a Windows service via `scripts/install.ps1` +
`services/caddy.xml` (auto-start on boot), not a foreground run.

## Order of operations checklist

1. [x] App running on `127.0.0.1:3001`
2. [x] Production `Caddyfile` adapted (port 3001, subnet 192.168.101.0/24)
3. [x] Caddy 2.8.4 in `artifacts\caddy\`
4. [x] Internal CA generated, root exported to `certs\laguna-root.crt`
5. [ ] Admin: set network Private + open 443/80 firewall
6. [ ] DNS: `pos.laguna.lan → 192.168.101.49` (router or box DNS) + DHCP reservation
7. [ ] Phone: install `laguna-root.crt`, Private DNS off
8. [ ] Test `https://pos.laguna.lan` from the phone
