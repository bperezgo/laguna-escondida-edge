# Plan — Running Frontend + Backend + Caddy as Windows Services

> Status: **decisions locked — ready to implement.** Companion doc:
> `ai-plan/EDGE_LAN_SERVING_PLAN.md` (the networking / TLS / serving design — still valid).
>
> Scope: **how to take the current dev experiment and turn it into an installable edge
> appliance** that runs the Go backend, the Next.js frontend, and Caddy as managed Windows
> services on a single box at the business. This doc reconciles the existing scaffold against
> what the *actual* app repos (`laguna-escondida-frontend`, `laguna-escondida-backend`) need.

---

## 0. Decisions locked (this session)

| Decision | Choice | Why |
|---|---|---|
| Edge model | **`APP_MODE=edge`, syncs to the existing cloud node** | A cloud backend already exists; storage (S3/Spaces) and electronic invoicing go through the online providers; the box pushes/pulls via `CLOUD_SYNC_URL`. |
| Artifact delivery | **Build locally on the box** (`build-artifacts.ps1`) | Both source repos are siblings on the machine, Go + Node are installed. Far simpler than CI/GitHub Releases for a single shop. |
| Frontend output | **`output: 'standalone'`** (one-line change in the frontend repo) | Self-contained `server.js` + minimal deps; matches the service model. |
| Reverse proxy | **Caddy only on the LAN** (unchanged from serving plan) | Single `.exe`, internal-CA HTTPS, streams SSE. |
| Process supervision | **WinSW** (one XML per service) | Declarative, committed to git, auto-restart + boot order. |

---

## 1. The four mismatches we found (scaffold vs. reality)

The serving design was written ahead of reconciling with the apps. Cross-checking the real
repos surfaced four things that change the scaffold:

### 1.1 There is no separate `pos-printing` service or repo
Printing is an **optional edge-mode feature baked into the Go backend binary**
(`POST /api/device/print`, wired at `cmd/main.go:482-495`). It is configured by env vars
(`PRINTER_TRANSPORT`, `PRINTER_TARGET`, `PRINTER_WIDTH_MM`, `PRINTER_CODEPAGE`, `PRINTER_CUT`)
on the backend process itself.

**Consequence:** delete `services/pos-printing.xml` and the `laguna-escondida-pos-printing`
reference in `versions.json`. We drop from 5 services to **4**.

### 1.2 The backend env vars are nothing like the placeholders
The scaffold guesses `HTTP_ADDR` / `DATABASE_URL` / `APP_ENV`. The real backend
(`.env.example`, `internal/.../config.go`) uses:

- `PORT` (required — the process **panics** if unset; `cmd/main.go:532-534`)
- Separate DB vars: `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `DB_SSLMODE`
  (not a single DSN)
- `APP_MODE` = `cloud` | `edge` (not `APP_ENV`)
- **Required secrets** it will refuse to start without: `JWT_SECRET`, `ADMIN_API_KEY`,
  `ELECTRONIC_INVOICE_URL/USER/PASSWORD`, `SPACES_REGION/KEY/SECRET/BUCKET`, `ORGANIZATION_ID`

### 1.3 The backend is built around cloud↔edge sync
In `APP_MODE=edge` it pushes/pulls to a cloud node via `CLOUD_SYNC_URL` + `NODE_SYNC_KEY`
(push/pull crons default to every minute), uses cloud S3 (`SPACES_*`) for storage, and an
online electronic-invoice provider. **This box is not standalone** — its normal operation
assumes connectivity to the cloud for sync/storage/invoicing (it still serves the LAN locally
when offline, then catches up).

### 1.4 The frontend is not built for standalone
`next.config.js` has no `output: 'standalone'`, yet every service XML assumes
`.next/standalone/server.js`. We add the one-line config (decision §0). Also: it's **pnpm +
Next 16**, and the build has the well-known gotcha that `.next/static` and `public` are **not**
copied into `.next/standalone` automatically — the build script must copy them.

### 1.5 (Bonus) Migrations are EMBEDDED in the binary
The backend runs golang-migrate on boot via `iofs.New(migrations.FS, ".")` — `migrations.FS` is
a Go `embed.FS`, so the SQL files are compiled **into** `edge-node.exe` (`cmd/main.go:582`).
**No migrations folder needs to ship.** (An earlier pass mistakenly thought it read a relative
`file://` path; it does not.) `workingdirectory` therefore matters only for `.env` loading
(see §4).

---

## 2. Architecture risk we investigated and cleared: the `NEXT_PUBLIC_API_URL` question

`NEXT_PUBLIC_API_URL` carries the `NEXT_PUBLIC_` prefix, which normally means the **browser**
reads it — and it points at `localhost:8080`. On a tablet, `localhost` is the *tablet itself*,
so that would break. We traced the actual call path:

- The browser **only ever calls relative `/api/*`** (`lib/api/config.ts`: `url = \`/api${endpoint}\``).
- Those hit **Next's own route handlers on the box** (`app/api/**/route.ts`), which proxy
  server-side to the Go backend via `config.apiUrl` (`lib/api/server.ts`:
  `url = \`${config.apiUrl}${endpoint}\``).
- SSE is the same shape: the browser opens `new EventSource("/api/sse/...")`
  (`components/kitchen/KitchenCommandItemsView.tsx:69`) → Next route → backend.

**Conclusion:** `NEXT_PUBLIC_API_URL` is effectively **server-only** here. Setting it to
`http://127.0.0.1:8080/api` on the box is **correct** — the tablets never resolve it. And
**Caddy stays simple**: it proxies only to Next on `127.0.0.1:3000`; Next handles `/api`
internally. The single `flush_interval -1` proxy covers SSE.

```
Tablet browser
  │  relative /api/*  +  EventSource("/api/sse/...")
  ▼  HTTPS :443
Caddy  ──►  Next.js :3000  ──►  (server-side)  Go backend :8080  ──►  Postgres :5432
                                                     │
                                                     └──►  cloud sync / S3 / invoicing (online)
```

### 2.1 Decision: keep `127.0.0.1:8080` — do NOT give the backend a DNS name (reviewed)

There are **two distinct "API URLs"**, and conflating them is the source of the confusion:
- **Browser → box:** always **relative** `/api/*`, served by Caddy under `pos.laguna.lan`. No
  `localhost` anywhere; the tablet never needs to know where the backend lives.
- **Box's Next server → Go backend:** `127.0.0.1:8080`, a same-machine hop. This is the *only*
  place `localhost` appears, and it is evaluated **on the box**, where `localhost` correctly
  means "the Go backend next to me."

Options considered and rejected:
- **Point `NEXT_PUBLIC_API_URL` at `https://pos.laguna.lan/api`** — **breaks (infinite loop).**
  It is used server-side, so Next's `/api/products` handler would fetch
  `https://pos.laguna.lan/api/products` → Caddy → the same handler → itself. The Go backend is
  not reachable under `pos.laguna.lan` (only Next is).
- **Frontend logic to "detect" the backend** — solves a non-problem; the server always knows the
  backend is at `127.0.0.1:8080`.
- **Give the backend its own LAN DNS** — works but strictly worse: breaks the core security
  property (only Caddy is LAN-exposed; everything else binds `127.0.0.1`), adds a network hop +
  TLS handshake per internal call, and needs another cert.

**Kept:** `127.0.0.1:8080`. The only real issue is cosmetic — the `NEXT_PUBLIC_` prefix
mislabels a server-only value.
- **Optional cleanup (frontend repo, not required to ship):** rename to `BACKEND_INTERNAL_URL`
  (drop the `NEXT_PUBLIC_` prefix), used only in `lib/api/server.ts`, to document intent.
- **Convention to preserve:** ALL backend data access stays behind the server-side proxy
  (`lib/api/server.ts` / `app/api/*` handlers). No client component should fetch the Go backend
  directly. If client-direct calls were ever needed, the answer would be a Caddy route to the
  backend — but the app is not built that way and does not need to be.

---

## 3. Target services (final)

| Service id | Runs | Binds | Depends on | Notes |
|---|---|---|---|---|
| `laguna-postgres` | portable/installed Postgres 16 | 127.0.0.1:5432 | — | data dir persisted |
| `laguna-edge-node` | `edge-node.exe` (Go backend) | 127.0.0.1:8080 | postgres | `APP_MODE=edge`; migrations auto-run; printing built in |
| `laguna-next` | bundled `node.exe server.js` | 127.0.0.1:3000 | edge-node | Next standalone bundle |
| `laguna-caddy` | `caddy.exe` | **:443 / :80 (LAN)** | next | only LAN-exposed service; internal-CA TLS |

Boot order: **Postgres → edge-node → next → caddy**. Everything but Caddy binds `127.0.0.1`.

---

## 4. Secrets & config handling (implemented)

The backend already loads a `.env` file from its working directory on startup
(`cmd/main.go:41`, `godotenv.Load()`). That is cleaner than injecting env through WinSW, so we
use it as the **single source of truth** for ALL edge-node config (not just secrets):

- **`services/edge-node.xml` carries NO `<env>`** — it only sets `workingdirectory` to
  `artifacts/edge-node`, where the binary finds its `.env`.
- All config (ports, `DB_*`, `APP_MODE`, sync vars, `SPACES_*`, `ELECTRONIC_INVOICE_*`,
  `PRINTER_*`, secrets) lives in **`env/edge-node.env`** (gitignored).
- **`env/edge-node.env.example`** is committed as the template; `env/*.env` is gitignored.
- `scripts/install.ps1` copies `env/edge-node.env` → `artifacts/edge-node/.env` on install.

(WinSW `<envFile>` is therefore not needed. Non-secret config for the other services — next,
postgres, caddy — stays inline in their XML, since they have no secrets.)

---

## 5. Work plan (phased)

### Phase 1 — Reconcile the scaffold with the real apps (all in THIS repo) — ✅ DONE
- [x] Delete `services/pos-printing.xml`; remove `pos-printing` from `versions.json`,
      `install/uninstall/update.ps1`, README tables, and the serving-plan service list.
- [x] Rewrite `services/edge-node.xml`: no `<env>`; set `workingdirectory` to
      `artifacts/edge-node`; config loaded from `.env` (§4). All real vars (§1.2) documented in
      the env template instead.
- [x] Create `env/edge-node.env.example` (full edge-mode var set) + add `env/*.env` to
      `.gitignore`.
- [x] `workingdirectory` set for `.env` loading. Migrations are embedded in the exe (§1.5) — no
      folder to ship.
- [x] `scripts/install.ps1` stages `env/edge-node.env` → `artifacts/edge-node/.env`.
- [x] `services/next.xml`: kept `NEXT_PUBLIC_API_URL=http://127.0.0.1:8080/api` (verified
      correct, §2). Node/server.js paths confirmed against the standalone layout in Phase 2.
- [x] Updated `services/README.md` + root `README.md` boot-order/tables (4 services).

### Phase 2 — Local build pipeline (build on the box) — ✅ DONE & verified
- [x] Frontend repo: added `output: 'standalone'` **and** `outputFileTracingRoot: __dirname`
      to `next.config.js` (the latter keeps `server.js` un-nested + silences the lockfile-root
      warning).
- [x] New `scripts/build-artifacts.ps1`:
  - Go: `go build -ldflags '-s -w' -o artifacts/edge-node/edge-node.exe ./cmd` (CGO off).
    **Migrations are embedded** (§1.5). ✅ verified: 38 MB exe builds.
  - Next: `pnpm install --frozen-lockfile && pnpm build`, then assemble `artifacts/next/` (see
    "standalone copy" below) and add `.next/static` (+ `public` if present). pnpm runs via
    `cmd /c "... 2>&1"` to dodge the PowerShell-5.1 native-stderr → terminating-error trap.
    Stamps each repo's git short-SHA into `versions.json`.
    ✅ verified: bundle boots (`node server.js` → `Ready`, HTTP 307 redirect to login), 41 MB.
- [x] `scripts/fetch-artifacts.ps1` trimmed to off-the-shelf only (Caddy/Node/Postgres
      implemented; app artifacts now point to `build-artifacts.ps1`).
- [x] `update.ps1` rebuilds app artifacts (`build-artifacts.ps1`) or re-fetches infra, then
      swaps the one service; re-stages `edge-node`'s `.env`.

#### Build prerequisite (Windows): symbolic-link permission
`next build` (standalone) **creates symlinks**; Windows blocks that without the privilege, so a
default box fails with `EPERM: symlink`. `build-artifacts.ps1` preflights it and stops in <1s
with the remedy. Fix once: **enable Developer Mode** (`Settings > Privacy & security > For
developers > Developer Mode = On`, or elevated
`Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" AllowDevelopmentWithoutDevLicense 1 -Type DWord -Force`),
or run the build elevated. (Done on this box.)

#### The pnpm + standalone copy problem (and the fix — `scripts/copy-standalone.js`)
Getting a **portable** standalone bundle out of pnpm on Windows was the hard part. `.next/standalone/node_modules`
is a web of symlinks into pnpm's `.pnpm` store, and every naive copy fails differently:
- `Copy-Item -Recurse` → **Access denied** traversing the store's reparse points.
- preserve symlinks verbatim → at runtime Node can't follow them: **`realpathSync` EPERM** (Developer
  Mode lets you *create* symlinks but these still EPERM on *follow*).
- `fs.cpSync({dereference:true})` → the store has a symlink **cycle** → stack overflow.
- `node-linker=hoisted` → no help; pnpm keeps the `.pnpm` store + symlinks regardless.

Fix: **`scripts/copy-standalone.js`** walks the tree, resolves each link with **`readlinkSync`**
(reads the target string without following — no EPERM), copies **real** dirs/files, and uses
ancestor-based **cycle detection**. Then `build-artifacts.ps1` recreates the top-level packages
(`next`, `react`, …) as **junctions** into the bundle's own `.pnpm` (junctions follow fine at
runtime; symlinks don't). ⚠️ Junctions store an **absolute** target → **build the artifact at its
final install location** (don't build then move `artifacts\next`).

> Alternative still worth noting for the future: build on a separate dev/build machine and copy
> `artifacts/` to the POS box — keeps Go/pnpm/Developer-Mode off production. (Not used now; we
> build in place per the locked decision.)

### Phase 3 — Postgres ✅ DONE & verified
- [x] Chose **portable-bundled** (EnterpriseDB "binaries" zip, vanilla open-source PostgreSQL —
      no license cost, dev or prod). Everything stays under the install root; uninstall is clean.
- [x] `fetch-artifacts.ps1 -Only postgres` downloads + flattens `pgsql/` → `artifacts\postgres\`
      (`bin\postgres.exe --version` = PostgreSQL 16.4). NB: a corrupt/partial `pg.zip` from an
      interrupted download will fail with "end of central directory record not found" — re-fetch.
- [x] `init-postgres.ps1` inits the cluster, creates role `laguna` + db `laguna_escondida`,
      prints the random superuser password once. Verified: the `laguna` role connects over TCP
      to its db and can create/insert/select/drop (exit 0).
- [x] `services/postgres.xml` serves `artifacts\postgres\data` as `laguna-postgres`
      (`postgres.exe -D ...\data -h 127.0.0.1 -p 5432`); edge-node `<depend>`s on it.
- [ ] Operator: set `DB_PASSWORD` in `env\edge-node.env` to the password passed to
      `init-postgres.ps1` (other `DB_*` already match the script defaults).
- [ ] If using the official installer instead, delete `services/postgres.xml` and repoint the
      `<depend>` to the installer's service name (already noted in that XML).

**Windows handle-inheritance trap (cost real debugging time — do not reintroduce).**
`pg_ctl start` launches a **detached** postgres server that **inherits pg_ctl's stdio handles**.
Any method that makes PowerShell wait on those handles **deadlocks forever**, because the server
keeps them open long after pg_ctl itself has exited:
- `pg_ctl start | Out-Host` — the server holds the pipe's write end; the reader never sees EOF.
- `Start-Process -Wait -RedirectStandardOutput <file>` — `-Wait` also waits for the redirected
  streams to reach EOF, which the inherited handles prevent.
The symptom both times: output freezes right after "servidor iniciado", server is actually up.
**Fix used in `init-postgres.ps1`:** launch NON-blocking (no `-Wait`), send pg_ctl's stdio to
**files** (never a PS pipe), then poll `pg_isready` until the server accepts connections. Also:
pass pg_ctl args as ONE pre-quoted string (`-ArgumentList` arrays don't re-quote space-containing
elements, which split `-o "-p 5432 -h 127.0.0.1"`); and `psql` runs with `-w` so a bad password
fails fast instead of hanging on a prompt with no TTY.

### Phase 4 — Wire up & validate on this dev box — ✅ DONE & verified
- [x] Artifacts present (`fetch-artifacts.ps1` + `build-artifacts.ps1` already run): all four
      built — `edge-node.exe`, `next\server.js`, `caddy.exe`, `node.exe`, `postgres\` + `data\`.
- [x] **Direct-binary validation (non-elevated), the keystone path proven end-to-end:**
  - Postgres up; reconciled `DB_PASSWORD` in `env\edge-node.env` to the role the cluster
    actually has (`8GnbzBc14L7pqx05jFRH3yWS`; a stale `sk_live_…` value would have failed auth).
  - `edge-node.exe` (working dir `artifacts\edge-node`, loads `.env`): **migrations ran &
    completed**, SSE + cron + edge-sync schedulers started, `GET /api/health` → **200**,
    `GET /api/products` → **401** (auth gate correct).
  - `node server.js` (Next standalone, prod env): up on :3000; `GET /` → **307** (auth redirect);
    **`GET /api/products` via Next → 401**, i.e. the server-side `/api` proxy → Go backend works.
  - **Cloud sync connects**: edge→cloud `GET /api/sync/pull` returns HTTP 200 from
    `CLOUD_SYNC_URL`. ⚠️ but the pull then **fails to apply**: `upsert users: insert user roles:
    user_roles_role_id_fkey (SQLSTATE 23503)` — a **backend data-sync bug** (roles not upserted
    before `user_roles`, or missing from the pull payload), repeating every minute. Not a
    services-wiring issue; **track in the backend repo**. Local serving is unaffected.
  - `caddy validate` on `Caddyfile` → **Valid**. Box IP is **192.168.101.49** (matches the
    Caddyfile site address) and Developer Mode is on, so this box is the target box.
- [x] Fixed `install.ps1` firewall default `192.168.10.0/24` → **`192.168.101.0/24`** to match
      the Caddyfile `@notlan` guard and this LAN.
- [x] **`scripts\install.ps1` (elevated) brings all four up as services.** Verified end state:
      `laguna-postgres` (NetworkService) / `laguna-edge-node` / `laguna-next` / `laguna-caddy` all
      **Running**; ports 5432/8080/3000/443 listening; postgres serving real queries; edge-node
      migrations clean + cloud-sync pull returns 200. HTTPS over the internal CA verified:
      `GET https://192.168.101.49/` → 307 (auth redirect), `GET …/api/products` → 401
      (full chain Caddy → Next → server-side proxy → Go backend).
- [ ] Still to validate from an actual **tablet**: `Secure` cookie round-trips (login persists),
      SSE streams live without buffering. (Server-side path proven; only the browser leg remains.)

#### The Postgres-as-a-Windows-service gotchas (cost the most time — all fixed in the scripts)
Running portable Postgres under WinSW hit a chain of Windows-specific traps. Each is now handled
by `services\postgres.xml` + `scripts\install.ps1`, so a fresh box just works — but know them:
1. **postgres.exe refuses to run as an admin account.** WinSW services default to **LocalSystem**
   (privileged) → postgres exits immediately ("will not run as a user with administrative
   privileges") and the service loops in StartPending. Must run as a low-priv account.
2. **WinSW 2.x ignores `<serviceaccount>` for built-in virtual accounts** (NetworkService/
   LocalService) — it only applies it for real user accounts with a password. So the XML can't set
   it; `install.ps1` sets it **after install** via the `Win32_Service` CIM `Change()` method
   (`StartName='NT AUTHORITY\NetworkService'`, empty password).
3. **`sc.exe config … obj= … password= ""` fails under PowerShell with error 1639** (arg/quoting
   parsing). The CIM method above avoids `sc.exe` entirely. (`sc.exe stop/delete <id>` is fine —
   single bare arg — and is used for the self-heal in #5.)
4. **`--` is illegal inside XML comments.** A `--` in a `postgres.xml` comment made WinSW fail with
   "An XML comment cannot contain '--'". Keep comments dash-pair-free.
5. **A half-removed service blocks reinstall.** If `uninstall` fails mid-way (e.g. the XML couldn't
   parse), the SCM registration survives as a *ghost* (wrapper exe gone) and `install` then errors
   "service already exists". `install.ps1`'s install loop is now **self-healing**: it `sc.exe
   delete`s any existing `laguna-<name>` before installing, so re-running always recovers.
6. **NetworkService had no access to files under the user profile.** The wrapper
   `services\postgres.exe`, the data dir, and `logs\` all sit under `C:\Users\USER\…`, which grants
   NetworkService nothing → the service start fails with **"Access denied" before postgres even
   launches** (telltale: `postgres.err.log` doesn't change; Event Log SCM 7000 = Acceso denegado).
   `install.ps1` grants NetworkService (SID `S-1-5-20`, locale-independent) **Read/Execute on
   `services\`** and **Modify on `artifacts\postgres\` + `logs\`** via icacls (inheritable).

> NB: `artifacts\next` was built in place, and pnpm junctions store **absolute** targets — keep
> the repo at `C:\Users\USER\dev\laguna-escondida-edge` (do not move it after build, or rebuild
> `next` at the new location). Caddy stores its CA at `C:\laguna-edge\caddy-data` (created on
> first run; independent of repo location — back this dir up, §Phase 5).

### Phase 5 — Harden for the business install
- [ ] Secrets checklist filled (`env/edge-node.env`), nothing secret in git.
- [ ] `caddy-data/` (internal CA root) backup procedure — if lost, every tablet must re-trust.
- [ ] Finalize router + tablet provisioning (already drafted in `provisioning/` + `certs/`).

---

## 6. Inputs needed from the operator (not blocking Phases 1–2)

- Cloud sync: `CLOUD_SYNC_URL`, `NODE_SYNC_KEY`, `CLOUD_NODE_ID`, `ORGANIZATION_ID`.
- Storage: `SPACES_REGION/KEY/SECRET/BUCKET` (+ `SPACES_ENDPOINT` if not DigitalOcean).
- Invoicing: `ELECTRONIC_INVOICE_URL/USER/PASSWORD` (+ prefixes if non-default).
- Auth: `JWT_SECRET`, `ADMIN_API_KEY` (must match the cloud where relevant).
- Printer: model + connection — Windows driver name (`PRINTER_TRANSPORT=windows`) vs network
  IP (`PRINTER_TRANSPORT=network`, `PRINTER_TARGET=<ip:port>`); ticket width/codepage/cut.
- Business/ticket text: `BUSINESS_NAME/NIT/ADDRESS`, `TICKET_FOOTER`, `TICKET_LEGAL_NOTICE`.

---

## 7. Dev vs. production note

The current dev experiment uses `Caddyfile.lan` (plain HTTP :80 → `localhost:3001`). Production
uses `Caddyfile` (HTTPS :443 → `127.0.0.1:3000`). Keep `Caddyfile.lan` as the dev/share path,
but the install path targets the production `Caddyfile`. The port difference (3001 dev vs 3000
prod) is intentional; the service runs Next on 3000.

---

## 8. Open questions

- ~~Postgres: portable bundle vs official installer~~ → **RESOLVED: portable bundle** (Phase 3 done).
- Does the edge box need a scheduled `caddy-data/` + Postgres backup job, or is cloud sync
  considered the source of truth for data (so only the CA root needs backing up)?
- Any non-tablet device (manager laptop, printer admin UI) that also needs LAN access added to
  the firewall allowlist?
