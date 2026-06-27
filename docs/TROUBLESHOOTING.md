# Troubleshooting — when something is broken

The "other document you might need." This is the one to open at the restaurant when the box
misbehaves and there's no Claude to ask. Each entry: **symptom → why → fix**. Work top-down;
the layers map to [`VALIDATION.md`](VALIDATION.md) (Postgres → edge-node → Next → Caddy → edge).

> Install root `C:\laguna-edge`, LAN IP `192.168.101.49`. Elevated PowerShell unless noted.

---

## First move, always: find the failing layer

```powershell
Get-Service laguna-* | Format-Table Name, Status, StartType
Get-ChildItem C:\laguna-edge\logs | Sort-Object LastWriteTime -Desc | Select-Object -First 8 Name, LastWriteTime
```

The lowest service that is **not Running** is your culprit (the upper ones depend on it). Open
that service's `*.err.log` first.

---

## "Opening https://192.168.101.49 redirects me to localhost:3000"

**Why:** Next.js in standalone mode builds redirects with `new URL("/signin", request.url)` and
derives the **host** from its own bind origin (`localhost:3000`), not the public `Host` header.
So the browser is told to go to `https://localhost:3000/signin`, which doesn't exist on a tablet.

**Fix:** the `Caddyfile` strips that bogus origin so the redirect becomes relative. Confirm the
rule is present inside the `reverse_proxy 127.0.0.1:3000` block:

```caddyfile
header_down Location "https?://localhost:3000" ""
```

```powershell
Select-String -Path C:\laguna-edge\Caddyfile -Pattern 'header_down Location'   # must match
# Then validate + reload (no restart needed):
& C:\laguna-edge\artifacts\caddy\caddy.exe validate --config C:\laguna-edge\Caddyfile --adapter caddyfile
& C:\laguna-edge\artifacts\caddy\caddy.exe reload   --config C:\laguna-edge\Caddyfile --adapter caddyfile
# Verify: Location must be relative.
curl.exe -k -s -i https://192.168.101.49/ | Select-String "location:"     # -> location: /signin
```

> A device that still "works" while another is broken usually just has a leftover session
> cookie (it skips the `/` redirect). Test in a fresh/incognito tab to compare fairly.

---

## A service won't start / sits in StartPending / flaps

```powershell
C:\laguna-edge\services\<svc>.exe status
Get-Content C:\laguna-edge\logs\<svc>.err.log -Tail 50
Get-Content C:\laguna-edge\logs\<svc>.wrapper.log -Tail 50   # WinSW start/stop/restart events
```

Then by service:

### laguna-postgres
- **`will not run as a user with administrative privileges`** → the service is running as
  LocalSystem instead of NetworkService. `install.ps1` sets this via CIM; re-run it, or fix
  manually:
  ```powershell
  $svc = Get-CimInstance Win32_Service -Filter "Name='laguna-postgres'"
  Invoke-CimMethod -InputObject $svc -MethodName Change -Arguments @{ StartName='NT AUTHORITY\NetworkService'; StartPassword='' }
  Start-Service laguna-postgres
  ```
- **`permission denied` / `could not open file` on the data dir** → NetworkService lacks ACLs.
  Re-grant (idempotent):
  ```powershell
  icacls C:\laguna-edge\artifacts\postgres /grant '*S-1-5-20:(OI)(CI)M' /T /C /Q
  icacls C:\laguna-edge\logs              /grant '*S-1-5-20:(OI)(CI)M' /C /Q
  icacls C:\laguna-edge\services          /grant '*S-1-5-20:(OI)(CI)RX' /T /C /Q
  ```
- **Access denied starting the service (before postgres.exe even runs)** → same as above; the
  `services\` RX grant is the fix. (The wrapper lives under the user profile, which gives
  NetworkService nothing by default.)
- **`could not bind … 5432` / address in use** → another Postgres (e.g. a previously-installed
  official one) owns the port. `Get-NetTCPConnection -LocalPort 5432` to find the PID.

### laguna-edge-node
- **Exits immediately, log shows a missing var panic** → an `(required)` field in
  `artifacts\edge-node\.env` is blank. Fix `env\edge-node.env`, then
  `.\scripts\update.ps1 -Service edge-node` (re-stages the `.env`).
- **`connection refused` / auth failed to Postgres** → `DB_PASSWORD` in `.env` doesn't match
  the password given to `init-postgres.ps1`, or Postgres is down. Verify with `pg_isready`
  (VALIDATION §3). To reset the app role password:
  ```powershell
  $env:PGPASSWORD='<superuser-pw>'
  & C:\laguna-edge\artifacts\postgres\bin\psql.exe -h 127.0.0.1 -U postgres -d postgres `
    -c "ALTER ROLE laguna PASSWORD 'new-pw';"
  Remove-Item Env:\PGPASSWORD   # then set DB_PASSWORD=new-pw in env and update the service
  ```
- **`.env` not found** → `install.ps1` copies `env\edge-node.env` → `artifacts\edge-node\.env`.
  Confirm `env\edge-node.env` exists (not just the `.example`) and re-run install/update.

### laguna-next
- **`Error: Cannot find module …` / module resolution fails** → the standalone `node_modules`
  junctions are broken (often from copying `artifacts\next` to a different path — junctions are
  **absolute**). Rebuild in place: `.\scripts\update.ps1 -Service next`.
- **`EADDRINUSE :3000`** → a stray `node.exe` from a previous run. Find and kill it:
  ```powershell
  Get-NetTCPConnection -LocalPort 3000 | Select-Object OwningProcess
  Stop-Process -Id <pid> -Force
  Start-Service laguna-next
  ```

### laguna-caddy
- **`dial tcp 127.0.0.1:3000: connectex: No connection`** → Next is down; fix `laguna-next`
  first (Caddy depends on it).
- **Caddyfile parse error on start** → run `caddy validate` (VALIDATION §6) to see the line.

---

## "next build" fails: cannot create symbolic link

**Why:** Windows blocks symlink creation without Developer Mode or elevation; the standalone
packer needs it.

**Fix:** enable Developer Mode once, then rebuild:

```powershell
Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" `
  AllowDevelopmentWithoutDevLicense 1 -Type DWord -Force
# …or just run build-artifacts.ps1 from an elevated PowerShell.
```

---

## Tablet shows "connection not private" / cert warning

**Why:** the tablet doesn't trust Caddy's internal CA root.

**Fix:** install the root cert on the tablet. Export it from the box:

```powershell
Copy-Item C:\laguna-edge\caddy-data\pki\authorities\local\root.crt C:\laguna-edge\laguna-root-ca.crt
```

Transfer `laguna-root-ca.crt` to the tablet and install it as a trusted CA (see
`provisioning\README.md`). One root serves all tablets.

---

## Tablet can't reach the box at all (timeout, not a cert error)

Check, in order:

```powershell
# 1. Is the box actually at the expected IP?
Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -like '192.168.101.*'
# 2. Is the firewall allowing the tablet's IP?
Get-NetFirewallRule -DisplayName 'Laguna POS - Caddy (LAN tablets)' |
  Get-NetFirewallAddressFilter | Format-List RemoteAddress
# 3. Is Caddy listening on 443?
netstat -ano | Select-String ':443\s' | Select-String LISTENING
```

- IP changed → set a **DHCP reservation** on the router (box MAC → `192.168.101.49`). A changed
  IP also invalidates the cert SAN.
- Tablet IP not in the firewall `RemoteAddress` → re-run
  `install.ps1 -AllowedTabletIPs '<the tablet IPs or subnet>'`.
- Tablet not on the `192.168.101.0/24` subnet → Caddy's `@notlan` guard returns **403** even if
  it connects. Put the tablet on the POS subnet.

---

## "403 Forbidden" from the box itself

`@notlan` allows only `192.168.101.0/24`. If the box's own request source IP isn't on that
subnet (e.g. you're on a VPN/virtual adapter), you'll get 403. Test from a real LAN client, or
temporarily widen the CIDR in the `Caddyfile`, `validate` + `reload`.

---

## I need to start completely over (clean reinstall)

```powershell
.\scripts\uninstall.ps1          # removes services + firewall rule; KEEPS artifacts\ + caddy-data\
# To also wipe the database (DESTRUCTIVE):
#   .\scripts\init-postgres.ps1 -DbPassword '...' -Force
.\scripts\install.ps1 -AllowedTabletIPs '192.168.101.0/24'
```

`uninstall.ps1` deliberately keeps `caddy-data\` so the **CA root survives** and tablets keep
trusting HTTPS after a reinstall. Only delete `caddy-data\` if you intend to re-provision every
tablet.

---

## Back up the things you can't regenerate

Two dirs are not reproducible from source — back them up off-box:

```powershell
# CA root (lose it → re-trust every tablet) + the live database.
Copy-Item C:\laguna-edge\caddy-data <backup>\caddy-data -Recurse -Force
# Postgres: use pg_dump for a consistent logical backup (service can stay running):
$env:PGPASSWORD='<superuser-pw>'
& C:\laguna-edge\artifacts\postgres\bin\pg_dump.exe -h 127.0.0.1 -U postgres `
  -d laguna_escondida -F c -f <backup>\laguna_escondida.dump
Remove-Item Env:\PGPASSWORD
```

Everything else (`artifacts\` binaries, the bundles) is rebuildable from `versions.json` + the
app repos via `fetch-artifacts.ps1` / `build-artifacts.ps1`.
