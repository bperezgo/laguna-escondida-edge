# Windows services (WinSW)

## What is WinSW?

**WinSW** ("Windows Service Wrapper") is a small open-source `.exe` that turns *any* program
into a proper **Windows Service** — so it starts automatically on boot, restarts if it crashes,
and starts in the correct order relative to other services. Postgres, a Go binary, `caddy.exe`,
and `node server.js` are all just normal programs; WinSW is what makes Windows treat each one as
a managed background service.

You describe each service in a small **XML file** (what to run, env vars, dependencies). Those
XML files live in this folder and are version-controlled, so the whole appliance config is
reviewable in git. (NSSM is a popular alternative that does the same thing via a CLI/GUI instead
of XML — we chose WinSW so the config is declarative and committed.)

## How it works here (the "rename" convention)

WinSW finds a service's config by **matching filenames**: a wrapper exe named `caddy.exe` looks
for `caddy.xml` next to it. So `scripts/install.ps1`:

1. Downloads `WinSW-x64.exe` once → `services/winsw.exe` (gitignored).
2. For each definition, copies `winsw.exe` → `services/<name>.exe`.
3. Runs `services/<name>.exe install` then `... start`.

You normally never touch this manually — `install.ps1` / `uninstall.ps1` do it. To poke a single
service after install:

```powershell
services\caddy.exe status
services\edge-node.exe stop
services\next.exe start
```

## Path variables in the XML

- `%BASE%` = the folder containing the wrapper exe = this `services\` folder.
- `%BASE%\..` = the install root (`C:\laguna-edge`), so artifacts resolve as
  `%BASE%\..\artifacts\<name>\...`.

## The services + boot order

| File | Service id | Binds | Depends on |
|---|---|---|---|
| `postgres.xml` | `laguna-postgres` | 127.0.0.1:5432 | — |
| `edge-node.xml` | `laguna-edge-node` | 127.0.0.1:8080 | postgres |
| `next.xml` | `laguna-next` | 127.0.0.1:3000 | edge-node |
| `caddy.xml` | `laguna-caddy` | **:443/:80 (LAN)** | next |

`<depend>` makes Windows start dependencies first (and refuse to start a service if its
dependency failed). That gives us: Postgres → edge-node → next → caddy.

> Ticket printing is **not** a separate service — it is built into the edge-node binary
> (`POST /api/device/print`, edge mode) and configured via the `PRINTER_*` vars in
> `env/edge-node.env`.

## Editing service config (env, ports)

Two patterns, depending on the service:

- **edge-node** reads ALL its config (ports, DB, secrets, sync, printer) from a `.env` file in
  its working directory — the Go binary loads it on startup (`godotenv.Load()`). That config
  lives in `env/edge-node.env` (gitignored); `install.ps1` copies it to
  `artifacts/edge-node/.env`. Edit `env/edge-node.env` and re-run `install.ps1` (re-runnable).
  Start from the committed template `env/edge-node.env.example`. We keep **no** `<env>` in
  `edge-node.xml` so there is a single source of truth and no secrets in committed XML.
- **next / postgres / caddy** have non-secret config defined **inline** in their XML via
  `<env name="..." value="..."/>`. To change a port, edit the XML and re-run `install.ps1`.

**Before first real install:**
- Copy `env/edge-node.env.example` → `env/edge-node.env` and fill in the real values
  (DB password, `JWT_SECRET`, `ADMIN_API_KEY`, `SPACES_*`, `ELECTRONIC_INVOICE_*`, cloud-sync
  vars, printer target).

Logs for every service roll under `..\logs\` (configured via `<logpath>` + `<log>`).
