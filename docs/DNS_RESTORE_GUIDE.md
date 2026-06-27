# DNS restore guide — putting your computer back to normal

This undoes the changes made by [`DNS_SETUP_GUIDE.md`](DNS_SETUP_GUIDE.md): it
**re-enables Windows ICS** (so WSL2 / Hyper-V / Docker networking works again) and
**removes the firewall rules** the setup added. After this, your machine is back to how it
was before the DNS test.

> Use this whenever you're done testing, or sooner if you need your WSL/Hyper-V internet
> back.

---

## What "restore" actually does

| Change made during setup | What restore does |
|---|---|
| ICS (`SharedAccess`) set to **Disabled** | Sets it back to **Automatic** and starts it |
| Network marked **Private** | *Left as-is* (Private is harmless; change manually if you want Public back) |
| Firewall rules: 443, 80, 53 (UDP/TCP) | **Removed** |
| Technitium DNS service | **Stopped and disabled automatically** (so it won't fight ICS for port 53 after reboot). App stays installed unless you remove it (below). |

The most important one is **re-enabling ICS** — that's what brings back NAT/DNS for WSL2,
Hyper-V "Default Switch" VMs, and Docker's WSL2 backend.

### Why a reboot is needed

Just like disabling it, ICS is tied into Hyper-V's virtual switch at boot time. Setting it
back to Automatic isn't enough on its own — the **reboot** is what fully rebuilds the
Default Switch's NAT/DNS so WSL and Hyper-V get their internet back.

---

## The restore procedure

All in an **Administrator** PowerShell (**Win+X → "Terminal (Admin)"**).

### Step 1 — Stop Caddy (if it's still running)

In the window where Caddy is running, press **Ctrl+C**. (Or from any PowerShell:
`Get-Process caddy -ErrorAction SilentlyContinue | Stop-Process -Force`.)

### Step 2 — Run the restore command

```powershell
PowerShell -ExecutionPolicy Bypass -File "C:\Users\USER\dev\laguna-escondida-edge\scripts\dev-test-here.ps1" -Restore
```

This re-enables ICS and removes the firewall rules. You'll see confirmation lines.

### Step 3 — Reboot

```powershell
Restart-Computer
```

After this restart, WSL2 / Hyper-V / Docker networking is back to normal.

### Step 4 — (Optional) Point the router's DNS back

If you changed the TP-Link's **DHCP → Primary DNS** to the box during setup, set it back:
- Clear the Primary DNS field (so the router hands out its own DNS again), **or** set it
  to your normal DNS.
- Toggle the phone's Wi-Fi to pick up the change.

If you skip this, devices will try to use the box (`192.168.0.123`) for DNS, and once the
box's Technitium isn't running, **internet name resolution on the LAN will fail**. So if
you're tearing the test down, **do reset the router DNS.**

---

## Verifying you're back to normal

```powershell
# ICS is enabled again:
Get-Service SharedAccess | Select-Object Name, Status, StartType
# Expect: Status Running (or Stopped/Manual-trigger), StartType Automatic or Manual

# The setup firewall rules are gone:
Get-NetFirewallRule -DisplayName 'Caddy LAN HTTPS 443','Caddy LAN HTTP 80','LAN DNS 53 UDP','LAN DNS 53 TCP' -ErrorAction SilentlyContinue
# Expect: nothing returned
```

If you use WSL, open it and test internet:

```bash
ping -c2 8.8.8.8
curl -I https://example.com
```

Both working = WSL networking is restored.

---

## Fully removing Technitium (optional)

Restore already **stops and disables** Technitium's service (`DnsService`) so it won't grab
port 53 after the reboot — ICS gets it back cleanly. The app stays installed (harmless). To
remove it entirely:

- **Settings → Apps → Installed apps → "Technitium DNS Server" → Uninstall.**

To re-use Technitium again later without uninstalling, set its service back to Automatic
(`Set-Service DnsService -StartupType Automatic`) — but only when ICS is disabled, so the
two don't both try to bind port 53.

---

## Quick reference

| Action | Command |
|---|---|
| Restore (re-enable ICS, drop firewall rules) | `... dev-test-here.ps1 -Restore` |
| Reboot | `Restart-Computer` |
| Check ICS | `Get-Service SharedAccess` |
| Stop Technitium | `Stop-Service DnsService; Set-Service DnsService -StartupType Disabled` |
| Setup guide | `docs\DNS_SETUP_GUIDE.md` |
