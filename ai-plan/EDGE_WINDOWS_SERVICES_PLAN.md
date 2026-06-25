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

### 1.5 (Bonus) Migrations auto-run on startup from a relative path
The backend runs golang-migrate on boot from `file://internal/platform/postgres/migrations`
(`cmd/main.go:578-612`). The **`migrations/` folder must ship next to the exe** and the service
`workingdirectory` must make that relative path resolve.

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

## 4. Secrets handling (new requirement)

The backend needs real secrets (`JWT_SECRET`, `ADMIN_API_KEY`, `SPACES_*`,
`ELECTRONIC_INVOICE_*`, `NODE_SYNC_KEY`, DB password). These must **not** be committed in the
service XML.

Plan:
- Non-secret config (ports, `APP_MODE`, hostnames, crons, printer transport) stays inline in
  `services/edge-node.xml`.
- Secrets move to **`env/edge-node.env`** (gitignored), loaded by WinSW via `<envFile>`.
- Commit **`env/edge-node.env.example`** as the template (placeholder values + comments).
- Add `env/*.env` to `.gitignore` (keep `*.example`).

---

## 5. Work plan (phased)

### Phase 1 — Reconcile the scaffold with the real apps (all in THIS repo)
- [ ] Delete `services/pos-printing.xml`; remove `pos-printing` from `versions.json`, README
      tables, and the serving-plan service list.
- [ ] Rewrite `services/edge-node.xml` env to real vars (§1.2): `PORT`, `DB_*`, `APP_MODE=edge`,
      edge-sync vars (`CLOUD_SYNC_URL`, `NODE_SYNC_KEY`, `CLOUD_NODE_ID`, push/pull crons),
      `ORGANIZATION_ID`, printer vars. Reference secrets via `<envFile>`.
- [ ] Create `env/edge-node.env.example` + add `env/*.env` to `.gitignore`.
- [ ] Set `laguna-edge-node` `workingdirectory` so the relative `migrations/` path resolves;
      confirm the migrations folder ships with the exe (Phase 2 build copies it).
- [ ] `services/next.xml`: keep `NEXT_PUBLIC_API_URL=http://127.0.0.1:8080/api` (verified
      correct, §2); confirm `node.exe` + `server.js` paths for the standalone layout.
- [ ] Update `services/README.md` boot-order table (4 services).

### Phase 2 — Local build pipeline (build on the box)
- [ ] Frontend repo: add `output: 'standalone'` to `next.config.js`.
- [ ] New `scripts/build-artifacts.ps1`:
  - Go: `go build -o artifacts/edge-node/edge-node.exe ./cmd/main.go` from the backend repo;
    copy the `internal/platform/postgres/migrations` tree into the artifact layout.
  - Next: `pnpm install && pnpm build` with `NEXT_PUBLIC_API_URL` set at build time; copy
    `.next/standalone` → `artifacts/next/`, then copy `.next/static` and `public` into it
    (the standalone gotcha).
- [ ] Trim `scripts/fetch-artifacts.ps1` to off-the-shelf only: Caddy (done), Node runtime,
      Postgres. Implement the real downloads (currently TODO).
- [ ] Update `update.ps1` to rebuild+swap a single artifact.

### Phase 3 — Postgres
- [ ] Choose portable-bundled vs official installer (default: **portable**, keeps everything
      under the install root and uninstall clean).
- [ ] Init data dir; create `laguna` role + database; set `DB_*` to match.
- [ ] If using the official installer instead, delete `services/postgres.xml` and repoint the
      `<depend>` to the installer's service name (already noted in that XML).

### Phase 4 — Wire up & validate on this dev box
- [ ] `fetch-artifacts.ps1` → `build-artifacts.ps1` → `install.ps1`.
- [ ] Bring all 4 services up in order; check `logs/`.
- [ ] Verify end-to-end over HTTPS: `Secure` cookie round-trips (login persists), SSE streams
      live (kitchen view updates without buffering), edge→cloud sync connects.

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

- Postgres: portable bundle vs official installer (Phase 3 default = portable).
- Does the edge box need a scheduled `caddy-data/` + Postgres backup job, or is cloud sync
  considered the source of truth for data (so only the CA root needs backing up)?
- Any non-tablet device (manager laptop, printer admin UI) that also needs LAN access added to
  the firewall allowlist?
