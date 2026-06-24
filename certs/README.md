# Caddy internal CA → tablet trust

Caddy serves HTTPS on the LAN using its **own internal Certificate Authority** (`tls internal`
in the `Caddyfile`). Browsers don't trust that CA by default, so each tablet must install the
**root certificate** once. After that, `https://pos.laguna.lan` is warning-free and the `Secure`
auth cookie flows.

## Where the root cert lives

Caddy stores its CA under the persisted data dir set in the `Caddyfile`
(`C:\laguna-edge\caddy-data`). The root cert is at roughly:

```
C:\laguna-edge\caddy-data\pki\authorities\local\root.crt
```

> Keep `caddy-data\` backed up. If it's lost, Caddy generates a NEW root and every tablet must
> re-trust. (`caddy-data\` is gitignored — it's per-box runtime state.)

## Export it for provisioning

Copy `root.crt` into this `certs/` folder (gitignored) to hand to tablets, or use Caddy's helper
on the box:

```powershell
artifacts\caddy\caddy.exe trust          # trusts it on the box itself
# then copy caddy-data\pki\authorities\local\root.crt  ->  certs\laguna-root.crt
```

## Install on an Android tablet

1. Transfer `laguna-root.crt` to the tablet (USB, or a one-time download).
2. Settings → Security → **Encryption & credentials → Install a certificate → CA certificate**.
3. Confirm the security warning (expected for a private CA).
4. Open `https://pos.laguna.lan` — no warning.

Android shows a persistent "network may be monitored" notice while a user CA is installed. That's
normal for a private CA and acceptable on a locked-down kiosk device.

See `../provisioning/README.md` for the full tablet runbook (DNS, Private DNS off, kiosk lock).
