# DNS setup guide — running local DNS on this dev box

This guide turns this Windows machine into the LAN's DNS server (via Technitium) so a
phone can open **`https://pos.laguna.lan`** in a realistic test. It requires **disabling
Windows ICS and rebooting**, so read the consequences section first — it explains exactly
what changes on your computer and what does *not*.

> **Restoring everything is covered in [`DNS_RESTORE_GUIDE.md`](DNS_RESTORE_GUIDE.md).**
> Nothing here is permanent or destructive.

---

## ⚠️ READ FIRST — what disabling ICS does to your computer

### What is ICS?

**ICS = Internet Connection Sharing**, a Windows service named `SharedAccess`. Its job is
to **share one network connection with other, secondary networks** by doing **NAT**
(translating addresses so the secondary network can reach the internet) and acting as a
small **DNS** helper for them.

On your machine, ICS is currently being used by **WSL2 / Hyper-V's "Default Switch"** —
the virtual network (the `172.x` adapters) that your Linux (WSL) environment and any
Hyper-V virtual machines use to reach the internet. That's *why* ICS is running, and why
it's holding port 53 (the DNS port) that our DNS server needs.

### The key idea (in plain terms)

ICS is **not** your computer's internet connection. Your computer reaches the internet
through your **Ethernet/Wi-Fi → the router**, and that path has **nothing to do with
ICS**. ICS only matters for the *virtual networks inside your PC* (WSL/Hyper-V). Think of
your real network connection as the front door of the house, and ICS as an internal
intercom that lets a guest room (WSL) call out through the front door. Disabling the
intercom doesn't lock the front door — the house still has internet.

### What WILL be affected while ICS is disabled

- **WSL2 (your Linux environment):** the Linux side may **lose internet access** — things
  like `apt update`, `git pull`, `ping google.com`, or `curl` from inside WSL may fail.
  The WSL environment itself still runs; you can still open the Linux shell and use your
  files. It's only the *outbound internet/DNS from inside WSL* that may break.
- **Docker Desktop (if you use the WSL2 backend):** its containers' internet/networking
  may break in the same way, since it rides on WSL2.
- **Hyper-V VMs on the "Default Switch":** any VM using that switch loses internet. (VMs
  on an "External" switch are unaffected — those bridge directly to your physical NIC.)
- **Windows Mobile Hotspot / sharing your PC's internet:** won't work (it's the same
  `SharedAccess` service). Most people never use this.

### What will NOT be affected (your computer stays normal)

- ✅ **Your Windows internet** — browsing, email, downloads, everything on the host: fully
  normal. The host's own connection does not depend on ICS.
- ✅ **All your apps, files, and installed software:** completely untouched. This is a
  reversible service toggle, not an uninstall or a system change.
- ✅ **The LAN serving we're building** (Caddy + Technitium): works fine — that's the whole
  point.
- ✅ **Logging in, your desktop, performance:** no change.

### Is it reversible?

**Yes, completely.** One command (`-Restore`) sets ICS back to its normal startup and a
reboot brings WSL/Hyper-V NAT back exactly as before. See `DNS_RESTORE_GUIDE.md`.

### How to know if WSL is affected (optional check)

After the reboot, if you use WSL, open it and run `ping -c2 8.8.8.8` and `curl -I https://example.com`.
If they fail with network errors, that's the expected ICS effect — restore when you're
done testing. If they work, your WSL build uses a newer networking mode that doesn't need
ICS, and nothing was lost.

### Note: the real restaurant box won't have this problem

This whole ICS dance is **only** because this development machine runs WSL2/Hyper-V. The
dedicated edge box at the restaurant won't have WSL/Hyper-V, so port 53 will be free and
**none of this disabling/rebooting is needed there.**

---

## The setup procedure

Because port 53 can only be freed across a restart, this is a **run → reboot → run**
sequence. All commands run in an **Administrator** PowerShell (open via
**Win+X → "Terminal (Admin)"**).

### Step 1 — First run (disables ICS)

```powershell
PowerShell -ExecutionPolicy Bypass -File "C:\Users\USER\dev\laguna-escondida-edge\scripts\dev-test-here.ps1"
```

ICS can't be stopped while it's running (Hyper-V holds it), so the script **sets it to
Disabled** and prints:

```
>>> REBOOT, then re-run this script. Port 53 will be free after restart. <<<
```

This is expected — it's the message you already saw. ✔

### Step 2 — Reboot

```powershell
Restart-Computer
```

After this restart, ICS will not start, and port 53 will be free.

### Step 3 — Second run (completes the setup)

Open an Administrator PowerShell again and run the **same command**:

```powershell
PowerShell -ExecutionPolicy Bypass -File "C:\Users\USER\dev\laguna-escondida-edge\scripts\dev-test-here.ps1"
```

This time it proceeds through:
1. Confirms ICS is no longer running.
2. Marks the network **Private**.
3. Opens the firewall: **443 + 80** (Caddy) and **53 UDP/TCP** (DNS), LAN-only.
4. **Installs Technitium** — a small installer window appears; **click through it with the
   defaults**. The script resumes automatically when it closes.
5. Configures DNS: `pos.laguna.lan → 192.168.0.123`.

### Step 4 — Start Caddy (normal PowerShell, no admin needed)

```powershell
cd C:\Users\USER\dev\laguna-escondida-edge
.\artifacts\caddy\caddy.exe run --config .\Caddyfile --adapter caddyfile
```

Leave this window open (Ctrl+C stops it). For the real deployment this becomes an
auto-starting Windows service.

### Step 5 — Point the TP-Link router at the box

In the router admin (**http://192.168.0.1**):
- **DHCP → DHCP Settings:** set **Primary DNS = `192.168.0.123`** (leave Secondary blank).
- **DHCP → Address Reservation:** reserve `192.168.0.123` for this box
  (MAC `6C-62-6D-B0-97-8C`).
- Save. Then toggle the phone's Wi-Fi off/on so it picks up the new DNS.

### Step 6 — The phone

- Install the root certificate **`certs\laguna-root.crt`** (transfer it to the phone first):
  - **Android:** Settings → Security → Encryption & credentials → Install a certificate →
    **CA certificate** → accept the warning.
  - **iPhone:** install the profile, then Settings → General → About →
    **Certificate Trust Settings** → enable full trust for the Caddy root.
- Turn **Private DNS → Off** (Android: Settings → Network → Private DNS).
- Open **`https://pos.laguna.lan`** → no warning, the app loads. ✅

---

## Verifying it works (on the box)

```powershell
# DNS answers the local name:
nslookup pos.laguna.lan 192.168.0.123      # should return 192.168.0.123

# Caddy is serving HTTPS on 443:
Get-NetTCPConnection -LocalPort 443 -State Listen
```

(A request to the site *from the box itself* returns **403** by design — the subnet lock
only allows real LAN devices. Test the page from the phone, not the box.)

---

## Quick reference

| Item | Value |
|---|---|
| Box IP | `192.168.0.123` |
| Box MAC | `6C-62-6D-B0-97-8C` |
| Router admin | http://192.168.0.1 |
| Hostname | `pos.laguna.lan` |
| Root cert for phones | `certs\laguna-root.crt` |
| Setup script | `scripts\dev-test-here.ps1` |
| Restore guide | `docs\DNS_RESTORE_GUIDE.md` |
