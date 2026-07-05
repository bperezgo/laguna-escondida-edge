# Validation — is the box running as expected?

Run these checks after an install/update, or any time something looks wrong. They go
**bottom-up** (Postgres → edge-node → Next → Caddy → end-to-end), so the first failing layer
tells you exactly where the problem is. Every command is copy-paste from an elevated PowerShell
on the box.

> Convention: install root is `C:\laguna-edge`, LAN IP is `192.168.0.123` (this box's
> `LAGUNA_LAN_IP` from `env\box.env` — the single source of truth; substitute yours). `curl.exe`
> (not the `curl` alias) is used so flags behave like real curl.

---

## Network identity matches reality (check this FIRST after a reboot)

The box's whole config — Caddy's cert SAN, the firewall rule, the URL tablets hit — is pinned to
`LAGUNA_LAN_IP` in `env\box.env`. If the box is on **DHCP** and the router hands it a different
address after a reboot, every service stays `Running` but the box is unreachable at the old IP.
This is the #1 cause of "services are up but `https://<ip>` is dead". Check it before anything else:

```powershell
# What IP does this box ACTUALLY hold right now? (ignores loopback + APIPA 169.254.*)
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } |
  Format-Table IPAddress, InterfaceAlias

# What IP does the config EXPECT?
Get-Content C:\laguna-edge\env\box.env

# Does the app serve on the box itself, regardless of network address?
curl.exe -k -s -o NUL -w "local -> %{http_code}`n" https://127.0.0.1/signin   # -> 200 = stack healthy
```

- **Actual IP == box.env, `local -> 200`** → identity is fine; move on to §1.
- **Actual IP != box.env** → that's the problem. Best fix: set a **DHCP reservation / static IP**
  on the router so this box always gets the same address, then reboot. Quick fix: update
  `LAGUNA_LAN_IP` in `env\box.env` to the new IP and re-run `scripts\install.ps1` (elevated) — but
  a moving IP also breaks the tablets, so the reservation is the real fix.
- **`local` is not 200** → it's not a network/IP issue; Caddy or an upstream is actually down —
  go to §6 and the logs.

---

## 0. One-shot smoke test

If you only run one thing, run this. All four services Running + a relative redirect = healthy.

```powershell
Get-Service laguna-* | Sort-Object Name | Format-Table Name, Status, StartType
curl.exe -k -s -o NUL -w "edge root  -> %{http_code}`n" https://192.168.0.123/
curl.exe -k -s -o NUL -w "edge signin-> %{http_code}`n" https://192.168.0.123/signin
```

Expected: 4× `Running`, root `-> 307`, signin `-> 200`.

---

## 1. Services are registered and Running

```powershell
Get-Service laguna-* | Format-Table Name, Status, StartType
```

Expected — all four **Running**, **Automatic**:

```
Name               Status  StartType
----               ------  ---------
laguna-caddy       Running Automatic
laguna-edge-node   Running Automatic
laguna-next        Running Automatic
laguna-postgres    Running Automatic
```

Per-service detail via the WinSW wrapper:

```powershell
C:\laguna-edge\services\postgres.exe  status
C:\laguna-edge\services\edge-node.exe status
C:\laguna-edge\services\next.exe      status
C:\laguna-edge\services\caddy.exe     status
```

A service stuck in `StartPending` or flapping → check its log (§6) and
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

---

## 2. The right ports are listening

```powershell
# Expect one LISTENING row per port. 443/80 on 0.0.0.0; the rest on 127.0.0.1 ONLY.
netstat -ano | Select-String ':443\s', ':80\s', ':3000\s', ':8080\s', ':5432\s' | Select-String LISTENING
```

Expected:

| Port | Bind address | Service     | Notes                                  |
|------|--------------|-------------|----------------------------------------|
| 443  | `0.0.0.0`    | caddy       | LAN-facing HTTPS                       |
| 80   | `0.0.0.0`    | caddy       | redirects to 443                       |
| 3000 | `127.0.0.1`  | next        | **must NOT** be `0.0.0.0`              |
| 8080 | `127.0.0.1`  | edge-node   | **must NOT** be `0.0.0.0`              |
| 5432 | `127.0.0.1`  | postgres    | **must NOT** be `0.0.0.0`              |

> If 3000/8080/5432 show `0.0.0.0`, an internal service is exposed to the LAN — stop and fix
> the bind before going live.

---

## 3. Postgres accepts connections

```powershell
& C:\laguna-edge\artifacts\postgres\bin\pg_isready.exe -h 127.0.0.1 -p 5432
# -> 127.0.0.1:5432 - accepting connections
```

Confirm the app role + database exist (uses the superuser password from `init-postgres.ps1`):

```powershell
$env:PGPASSWORD = '<postgres-superuser-password>'
& C:\laguna-edge\artifacts\postgres\bin\psql.exe -h 127.0.0.1 -U postgres -d laguna_escondida `
  -tAc "select current_database(), current_user;"
Remove-Item Env:\PGPASSWORD
# -> laguna_escondida|postgres
```

---

## 4. edge-node (Go API) is up

```powershell
# It binds 127.0.0.1:8080. Any HTTP response (even 404) means the process is serving.
curl.exe -s -o NUL -w "edge-node -> %{http_code}`n" http://127.0.0.1:8080/
```

A connection refused / `000` means the process isn't listening — check `logs\edge-node.*.log`.
The most common cause is a bad `.env` (missing required var, or `DB_PASSWORD` mismatch → it
can't reach Postgres). Confirm migrations ran and it connected by tailing its log:

```powershell
Get-Content C:\laguna-edge\logs\edge-node.out.log -Tail 40
```

---

## 5. Next.js is serving (directly, behind Caddy)

```powershell
# Hit Next on loopback, bypassing Caddy. Standalone middleware redirects "/" to "/signin".
curl.exe -s -i http://127.0.0.1:3000/ | Select-String "HTTP/|location:"
```

Expected `307` with `location: http://localhost:3000/signin`. **That absolute `localhost:3000`
Location is normal at THIS layer** — Caddy rewrites it to a relative path at the edge (§7). The
point here is only that Next responds.

```powershell
curl.exe -s -o NUL -w "next signin -> %{http_code}`n" http://127.0.0.1:3000/signin   # -> 200
```

---

## 6. Caddy config + TLS

```powershell
# Validate the Caddyfile parses (does not touch the running server):
& C:\laguna-edge\artifacts\caddy\caddy.exe validate `
  --config C:\laguna-edge\Caddyfile --adapter caddyfile

# The running server exposes an admin API on localhost:2019:
curl.exe -s http://localhost:2019/config/ | Select-String "192.168.0.123"   # site is loaded

# The internal CA root must exist and be persisted (tablets trust this):
Test-Path C:\laguna-edge\caddy-data\pki\authorities\local\root.crt           # -> True
```

---

## 7. End-to-end through Caddy (the real path tablets use)

```powershell
# Root: must be a RELATIVE redirect (the localhost:3000 fix). NOT an absolute localhost URL.
curl.exe -k -s -i https://192.168.0.123/ | Select-String "HTTP/|location:"
```

Expected:

```
HTTP/2 307
location: /signin
```

✅ `location: /signin` (relative) — correct.
❌ `location: https://localhost:3000/signin` — the Caddyfile `header_down Location` rule is
missing or not reloaded. See [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) → "redirects to localhost:3000".

```powershell
# Sign-in page renders, and HTTP redirects to HTTPS:
curl.exe -k -s -o NUL -w "signin -> %{http_code}`n" https://192.168.0.123/signin   # -> 200
curl.exe    -s -o NUL -w "http   -> %{http_code}`n" http://192.168.0.123/           # -> 308
```

---

## 8. Firewall is locked to the LAN

```powershell
Get-NetFirewallRule -DisplayName 'Laguna POS - Caddy (LAN tablets)' |
  Get-NetFirewallAddressFilter | Format-List RemoteAddress
# RemoteAddress should be your tablet IPs / subnet, NOT "Any".
```

Defense-in-depth check: a request whose source isn't on `192.168.0.0/24` gets a 403 from
Caddy's `@notlan` guard even if the firewall let it through.

---

## Pass criteria (tick all)

- [ ] 4 services Running / Automatic
- [ ] 443+80 on `0.0.0.0`; 3000+8080+5432 on `127.0.0.1` only
- [ ] `pg_isready` → accepting connections; app DB reachable
- [ ] edge-node returns an HTTP code on :8080; log shows DB connected + migrations done
- [ ] Next returns 200 on `/signin` (loopback)
- [ ] `caddy validate` passes; CA root.crt exists
- [ ] `https://192.168.0.123/` → **307 `location: /signin`** (relative)
- [ ] `https://192.168.0.123/signin` → 200
- [ ] Firewall RemoteAddress = LAN/tablets only
