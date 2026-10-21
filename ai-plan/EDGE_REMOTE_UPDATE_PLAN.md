# Plan — Remote ("signal-driven") updates for the edge appliance

> Status: **draft for discussion** (2026-10-03); open questions 1–5 answered in §11 (2026-10-16). Companion docs:
> `ai-plan/EDGE_DISTRIBUTION_AND_DEPLOYMENT_PLAN.md` — *where artifacts come from* and the
> migration/rollback safety story (source of truth for both; this doc does **not** repeat it),
> `ai-plan/EDGE_WINDOWS_SERVICES_PLAN.md` — how the services are built and run,
> `ai-plan/EDGE_NETWORK_ARCHITECTURE_PLAN.md` — the network the box sits in.
>
> Scope: **how a box learns that a new version exists and installs it without a human on site.**
> One box today, so nothing here is urgent — but the shape of the answer decides how much
> rework the second and tenth box cost.

---

## 0. The ask, restated

> *"Every time I need to do an update I have to repeat a process on every machine. It doesn't
> scale. I'd like to add a new version and send a signal to install it."*

The instinct is right, and the word to interrogate is **"signal."** A push signal to a Windows box
behind a restaurant's NAT is the one thing we cannot have (§3). Everything else in the ask is
achievable, and what we build instead of a push is a **box that continuously asks "what should I
be running?"** — which is strictly better: it survives the box being off, offline, or mid-outage,
and it needs no inbound ports.

So the real work is three separable pieces:

| Piece | Question it answers | Owner |
|---|---|---|
| **A. Release producer** | How does "a new version" become a downloadable, verifiable thing? | app repos' CI |
| **B. Desired state** | Where is it written down that box X should run version Y? | cloud |
| **C. Updater agent** | What on the box notices, applies it safely, and reports back? | this repo |

**A is already planned** as Rung 2 / Phase C of the distribution plan. **B and C are new, and are
what this doc is about.**

---

## 1. What an update costs today (the honest baseline)

To ship a new frontend build to the one box, someone with hands on it (RDP/console) does:

1. `git pull` in **three** repos — `laguna-escondida-edge`, `-backend`, `-frontend`.
2. `.\scripts\build-artifacts.ps1` — which **compiles on the production box**: Go build for
   `edge-node.exe`, `pnpm install --frozen-lockfile` + `pnpm build` for Next, then the
   `copy-standalone.js` + junction-repair dance.
3. `.\scripts\update.ps1 -Service next` — stop, rebuild, restart.
4. If the orchestration itself changed (`Caddyfile`, `services/*.xml`, a new service like
   `laguna-alloy`), re-run `.\scripts\install.ps1` elevated instead.
5. Eyeball `docs/VALIDATION.md` by hand.

### Why it doesn't scale — and these are separate problems

- **It is O(boxes) of human time**, and the human has to be technical (elevated PowerShell, Go,
  pnpm, Developer Mode for symlinks).
- **The build happens on the till.** A production box carries Go, pnpm, `git`, and the full app
  source. `pnpm install` on a restaurant's internet, during service, is a liability. Builds are
  also **non-deterministic across boxes** — box B can produce a different bundle than box A from
  the same commits.
- **There is no record of what a box runs.** `versions.json` is *stamped by the build*
  (`build-artifacts.ps1` → `Stamp`), so it describes *the last build that happened on this box*,
  not a version anyone chose. Nothing reports it anywhere.
- **Nothing is verified.** No checksum, no signature, no "did the thing I intended actually land."
- **Rollback is "rebuild from an older commit"** — and for `edge-node` that is not a rollback at
  all, because `m.Up()` already migrated the DB forward (distribution plan §4.4).
- **The binary cannot tell you what it is.** The Go build uses `-ldflags '-s -w'` with no
  `-X` version stamp, and `/api/edge/status` returns `mode / online / sync_lag_seconds /
  pending_sync_ops` — **no version field**. Remote fleet management needs this first.

> The one-box reality: this is annoying but safe, because *you* are the one doing it and you can
> see the screen. Every failure mode above becomes severe the moment the person at the box is a
> restaurant manager instead.

---

## 2. First: what *is* "a new version"?

This is the question that decides the whole design, and it has an uncomfortable answer: **a box's
version is a tuple, not a number.**

```
box state = ( edge repo rev          ← scripts/, Caddyfile, services/*.xml, alloy/config.alloy
            , edge-node release      ← Go binary (+ embedded migrations)
            , next release           ← Next standalone bundle
            , infra pins             ← winsw / caddy / alloy / node / postgres from versions.json
            , per-box config         ← env/*.env, certs — MUST NOT be touched by an update
            )
```

Two consequences:

1. **Updating "the app" is not enough.** Half of what makes the box work lives in *this* repo. A
   release that bumps `next` but not the `Caddyfile` is fine; one that adds a service (as Alloy
   did) needs `install.ps1` to re-run. So the unit of remote update should be an **appliance
   release**: one manifest that pins all five rows above. That is Rung 3 of the distribution
   plan — and remote updating is the thing that *forces* Rung 3, earlier than "many sites" would.
2. **Config is not code.** `env/box.env`, `env/edge-node.env`, `env/alloy.env`, `certs/`,
   `caddy-data/` and the Postgres data dir are **per-box state**. An updater that unpacks a zip
   over the install root and clobbers those bricks the box. The split must be explicit and
   enforced in the updater, not remembered.

### Recommended version scheme

An **appliance release** `v1.4.0` = a signed manifest + the artifacts it points at:

```jsonc
{
  "appliance_version": "1.4.0",
  "published_at": "2026-10-03T12:00:00Z",
  "components": {
    "edge":      { "git_tag": "v1.4.0", "url": "…/edge-1.4.0.zip",      "sha256": "…" },
    "edge-node": { "git_tag": "be-v2.9.1", "url": "…/edge-node-2.9.1.zip", "sha256": "…",
                   "max_migration": 54, "sync_contract_version": 1 },
    "next":      { "git_tag": "fe-v3.2.0", "url": "…/next-3.2.0.zip",   "sha256": "…" }
  },
  "infra": { "winsw": "2.12.0", "caddy": "2.8.4", "alloy": "1.19.2", "node": "20.18.0", "postgres": "16.4" },
  "apply": { "mode": "install" },          // "install" = re-run install.ps1; "swap" = update.ps1 per service
  "min_appliance_version": "1.2.0"         // refuse to jump from older than this
}
```

`max_migration` and `sync_contract_version` are exactly the metadata the distribution plan (§2
Rung 2, §4.3) wants recorded — this manifest is where they live, and what makes the
cloud↔edge compatibility gate mechanical instead of a memory exercise.

---

## 3. Design constraints (why the obvious designs are wrong)

These come from this codebase and this network, and they rule things out:

1. **No inbound connections to the box. Ever.** The network plan is explicit: *"Outbound-only:
   nothing here requires inbound ports from the internet. Do not port-forward to the box."*
   `install.ps1` opens :443/:80 **only to `LAGUNA_LAN_CIDR`**. ⇒ **No push channel.** Any
   "signal" is the box polling outbound, or it is a hole in the security model.
2. **The WAN is unreliable and the box gets powered off.** The box is designed to serve the LAN
   fully offline and catch up later; incident 06 documents a **nightly power-off**. ⇒ The updater
   must be **convergent** (desired-state reconciliation), not **event-driven** (a missed event
   must never mean a missed update).
3. **The box is a till during service hours.** An update restarts Postgres and the app. ⇒ A
   **maintenance window** is a hard requirement, not a nicety. "Signal arrives → install now" is
   wrong during lunch.
4. **The updater is the recovery path, so it must not depend on what it recovers.** Tempting
   design: piggyback the desired version on the existing `GET /api/sync/pull` response (the edge
   already polls it every minute via `SYNC_PULL_CRON`). But if `edge-node` is crash-looping — the
   exact case where a remote fix matters most — that channel is dead. ⇒ The updater **polls on its
   own**, as its own process, with its own channel. (Piggybacking stays available later as a
   latency optimization, never as the only path.)
5. **Migrations are forward-only and can brick a box.** `m.Up()` on boot; a failed migration sets
   `schema_migrations.dirty` and the node **refuses to boot until a human clears it**. The
   distribution plan calls this the highest-severity operational risk in the design, and that was
   written for *attended* updates. Unattended updates make it worse. ⇒ Drain + `pg_dump` + health
   gate + rollback are **preconditions** for enabling remote updates on `edge-node`, not Phase 2
   polish.
6. **The Next bundle is not relocatable as built.** `build-artifacts.ps1` step 2 replaces pnpm's
   store symlinks with **junctions that store absolute targets**, with an explicit warning: *"build
   the artifact at its final install location (do not build then move)."* A CI runner building at
   `D:\a\work\...` produces a bundle whose junctions are garbage on the box. ⇒ Shipping a
   prebuilt Next bundle needs one of:
   - **(a)** pnpm `node-linker=hoisted` for the release build, so `node_modules` is flat and the
     zip is trivially portable (cleanest; verify Next standalone is happy with it), or
   - **(b)** a box-side re-assemble step after unpack, which needs only `artifacts\node\node.exe`
     (already on every box) to re-run `copy-standalone.js` + recreate junctions — **no Go, no
     pnpm, no source**, which is the whole point.
7. **The box holds write credentials for its own Spaces bucket** (`SPACES_KEY`/`SPACES_SECRET` in
   `env/edge-node.env`). ⇒ Release artifacts must **not** live behind those credentials (§7).

---

## 4. The shape: desired-state reconciliation

```
   developer                 cloud (system of record)              box (C:\laguna-edge)
   ─────────                 ────────────────────────              ────────────────────
   git tag v1.4.0
       │
       ├─► CI builds + signs ──► release store ──────────────┐  (GitHub Releases / Spaces, read-only)
       │                        manifest + artifacts         │
       │                                                     │
       └─► "set desired = 1.4.0                               │
            for org X / channel stable"                       │
                    │                                         │
                    ▼                                         │
            nodes.desired_appliance_version ◄──── GET /api/fleet/desired ──┐
            nodes.reported_* (version, health, last_seen) ◄── POST /api/fleet/report ──┤
                                                                           │
                                                              laguna-updater (6th service)
                                                              every 5 min, outbound only:
                                                                1. ask: what should I run?
                                                                2. same as installed? → report, sleep
                                                                3. in maintenance window? → else sleep
                                                                4. verify signature + sha256 ◄─────────┘
                                                                5. drain outbox → pg_dump
                                                                6. apply (install.ps1 / update.ps1)
                                                                7. health-gate → rollback on fail
                                                                8. report outcome + installed version
```

The "signal" the ask wants is step 1 inverted: **you change one row in the cloud, and within one
poll interval every box that should move, moves.** Latency is the poll interval; correctness does
not depend on delivery.

---

## 5. The signal channel — options

| Option | Latency | New infra | Works when `edge-node` is down | Verdict |
|---|---|---|---|---|
| **1. Static manifest in object storage** (`https://…/channels/stable.json`), polled on a cron | poll interval | none — a public-read bucket/Release asset | ✅ | **Start here.** Zero cloud work; the manifest *is* the desired state. Weakness: one manifest for everyone — no per-box pin, no reporting. |
| **2. Cloud desired-state endpoint** (`GET /api/fleet/desired`, `X-Node-Key` auth) | poll interval | one table + two handlers in the existing backend | ✅ | **The target.** Reuses `NodeAuthMiddleware` and the `nodes` table verbatim. Per-box pin, canary, kill switch, and reporting all fall out of it. |
| **3. Long-poll / SSE on that endpoint** (`?wait=60`) | seconds | held connections | ✅ | Add **only if** "within 5 minutes" proves too slow. The app already does SSE, so the pattern is known. |
| **4. Piggyback on `GET /api/sync/pull`** | ≤1 min | ~none | ❌ | Rejected as the primary channel (§3.4). Fine as a *nudge* later. |
| **5. Broker (MQTT/NATS) or an RMM / Tailscale+Ansible** | seconds | a broker, or a third-party agent + subscription | ✅ | Real tools, wrong scale. Revisit at ~10+ sites (§8). |

**Recommendation: build 1, then 2.** Option 1 is a day's work and immediately removes "RDP into
the box" from routine updates. Option 2 is the one that makes the fleet *manageable* — and it is
genuinely small here, because the auth, the identity, and the table already exist.

### What option 2 needs on the cloud

`nodes` today is `(id, name, kind, created_at)` (migration `000046_create_sync_tables`). Add:

```sql
ALTER TABLE nodes ADD COLUMN release_channel              VARCHAR(32) NOT NULL DEFAULT 'stable';
ALTER TABLE nodes ADD COLUMN desired_appliance_version    VARCHAR(32) NULL;  -- NULL = follow channel
ALTER TABLE nodes ADD COLUMN update_paused                BOOLEAN NOT NULL DEFAULT false;  -- kill switch
ALTER TABLE nodes ADD COLUMN maintenance_window           VARCHAR(32) NOT NULL DEFAULT '03:00-05:00';
ALTER TABLE nodes ADD COLUMN reported_appliance_version   VARCHAR(32) NULL;
ALTER TABLE nodes ADD COLUMN reported_at                  TIMESTAMPTZ NULL;
ALTER TABLE nodes ADD COLUMN last_update_outcome          JSONB NULL;
```

Additive and nullable/defaulted — exactly the discipline the distribution plan §4.1 mandates. Two
handlers, both behind the existing `handler.NodeAuthMiddleware(cfg)` (which **fails closed** when
no node key is configured — the right default):

- `GET  /api/fleet/desired` → the resolved manifest URL + version for *this* node.
- `POST /api/fleet/report`  → installed version, service health, last outcome, migration version.

Both are `APP_MODE=cloud`-only routes, siblings of `/api/sync/push` and `/api/telemetry/v1/*`.

**Prerequisite, worth doing regardless:** stamp the version into the binary
(`-ldflags "-X main.version=…"`) and add `appliance_version` / `schema_migration_version` to
`/api/edge/status`. Right now nothing on the box can answer "what are you running?" — and fleet
management is impossible without that.

---

## 6. The updater agent (`laguna-updater`)

A **sixth WinSW service**, modelled on how `laguna-alloy` was added: outside the dependency chain,
nothing depends on it, so it can never hold up the till.

### Non-negotiable properties

1. **It never updates itself in place.** A self-replacing updater that crashes mid-swap leaves a
   box with no way back. Either keep it deliberately tiny and stable (a PowerShell script + WinSW
   wrapper, changed rarely and by hand), or do a two-slot swap where the *old* updater installs
   the new one and exits. **Decide this before writing it**, and treat "who updates the updater" as
   a first-class question, not a footnote.
2. **It touches code, never config or data.** Hard allowlist of paths it may replace
   (`artifacts\`, `scripts\`, `services\*.xml`, `Caddyfile`, `alloy\config.alloy`) and a hard
   denylist it must refuse to write (`env\`, `certs\`, `caddy-data\`, `artifacts\postgres\data`,
   `logs\`, `alloy-data\`). A path-escape check, same spirit as the existing
   `"refusing to modify $linkPath (outside bundle)"` guard in `build-artifacts.ps1`.
3. **It verifies before it executes.** Signature **and** `sha256`, checked before anything is
   unpacked — it runs as LocalSystem, so an unverified artifact is remote root (§7).
4. **It stops on a bad outcome.** After N consecutive failed applies on the same version, pin
   itself, report loudly, stop retrying. A box retrying a broken update every 5 minutes through a
   dinner service is worse than a box that stayed on the old version.

### Apply sequence (reuses what exists)

The safety steps are **already specified** in the distribution plan §5 — this is that runbook,
automated, in that order:

```
1. poll        GET desired → version differs? → proceed
2. gate        update_paused? in maintenance window? outbox healthy? disk free? → else sleep
3. fetch       download manifest artifacts to a staging dir; verify signature + sha256; refuse on mismatch
4. drain       (edge-node only) trigger push; wait pending_sync_ops → 0  (/api/edge/status already exposes it)
5. backup      (edge-node only) pg_dump + record current schema_migrations version and versions.json
6. apply       unpack to the install root per the path allowlist;
               apply.mode == "swap"    → scripts\update.ps1 -Service <each>
               apply.mode == "install" → scripts\install.ps1   (already idempotent + self-healing)
7. verify      services Running; Caddy up; /api/edge/status 200; a push/pull round-trip; schema not dirty
8a. success    write versions.json as INSTALLED state; POST report
8b. failure    restore dump + previous artifacts TOGETHER (never one without the other); restart;
               POST report with the failure; pin and stop
```

Step 6's `install` mode is the payoff of work already done: `install.ps1` is explicitly
*"re-runnable: it refreshes each service and the firewall rule,"* it self-heals ghost service
registrations, retries the locked-wrapper copy, preflights `box.env` against reality, validates
`config.alloy` before starting Alloy, and verifies Caddy actually came up. **An unattended updater
is mostly a matter of calling it and checking the result** — the hard part was already built.

### Staged rollout

With §5 option 2, canarying is a `WHERE` clause: set `desired_appliance_version` on one box, wait
for its `reported_*` to come back healthy for 24h, then move the channel. Worth building the day
there are three boxes; worth *designing for* now, which is why desired state is per-node and not
just per-channel.

---

## 7. Security — the part to get right before anything is automated

**A remote update channel is a remote code execution channel.** That is its purpose. Today a
compromise needs hands on the box; afterwards, whoever can publish a manifest owns every till
(payment-adjacent machines, on a LAN with the POS tablets).

- **Sign the manifest, not just checksum it.** HTTPS + `sha256` proves the download matches the
  manifest; it proves nothing about *who wrote the manifest*. Sign it (minisign/cosign/Authenticode
  — any one, consistently), ship the **public** key with the appliance, and have the updater
  refuse an unsigned or badly-signed manifest. The `sha256` per artifact then chains trust from it.
- **The node key is an authentication token, not an authorization boundary.** `X-Node-Key` is a
  **shared secret already present in plaintext** on the box (`env/edge-node.env`; and incident 11
  is literally *"plaintext credentials in env file"*). It is fine for "which box is asking"; it
  must never be the only thing standing between an attacker and code execution. Hence signatures.
- **Don't serve releases from the box's own Spaces credentials.** `SPACES_KEY`/`SPACES_SECRET` on
  the box are **write** credentials for the app's bucket. Releases belong in a separate,
  **read-only / public-read** location (GitHub Releases is enough), with the download origin
  allowlisted in the updater.
- **Keep the channel single-purpose.** The temptation — "while we have an agent, let it run
  arbitrary remote commands" (restart a service, collect logs, run a diagnostic) — turns a narrow,
  signature-gated update path into a general backdoor. Scope v1 to **"apply this signed release"**
  and nothing else. Remote shell, if ever needed, goes through the gateway's VPN (the network plan
  already points at UniFi Teleport/WireGuard for remote admin), with a human on both ends.
- **Log it.** The updater's decisions and outcomes should go to `logs\` and, where telemetry is
  enabled, out through Alloy — so "which box applied what, when, and did it work" is observable
  without RDP. That is the fleet visibility the ask is really after.

---

## 8. Off-the-shelf alternatives (and when they win)

| Approach | Why not now | When to reconsider |
|---|---|---|
| **RMM / endpoint management** (NinjaOne, Datto, Intune) | Per-seat cost, another agent, and it still doesn't know how to drain an outbox or `pg_dump` before a migration — the domain-specific half stays ours | Many sites with mixed hardware, or when someone else does the ops |
| **MSI + Windows Update / winget** | Rung 3 packaging + a code-signing cert, and MSI fights the per-box config + Postgres data-dir model | If a non-technical person must ever do the *first* install unaided |
| **Tailscale/WireGuard + Ansible/DSC push** | Inverts the trust model (inbound reachability into the till LAN); pull-converge is a better fit for a box that is off every night | A real ops team that wants imperative, interactive control |
| **Docker/Compose on the box** | Would genuinely solve "builds on prod" and relocatability — but it is a rewrite of the entire Windows-services design, and Postgres-in-a-container on a restaurant box with abrupt power loss is its own risk | A greenfield second-generation appliance, not an increment |

None of them removes pieces B and C; they replace the *transport*, which is the cheapest piece.
That is why building the small thing is the right call at this scale.

---

## 9. Phased plan

### Phase 1 — Stop building on the till (the prerequisite; biggest single win)
- [x] CI in `-backend` / `-frontend`: on tag, build the Windows artifact, `sha256`, publish to
      GitHub Releases with metadata (`max_migration`, `sync_contract_version`). *(= distribution
      plan Phase C — this is the dependency, not a parallel track.)*
- [x] Make the Next bundle **relocatable**: pick §3.6(a) hoisted-linker or (b) box-side
      re-assemble; prove a CI-built bundle runs on a box with **no Go/pnpm/source**.
- [x] `fetch-artifacts.ps1`: fetch *app* artifacts by pinned version, **verify checksum, refuse on
      mismatch**.
- [~] Stamp the version into `edge-node.exe` (`-ldflags -X`) and surface `appliance_version` +
      `schema_migration_version` on `/api/edge/status`.
- [x] `versions.json` flips meaning: **desired/installed state**, no longer stamped by a local build.

### Phase 2 — Make one update safe to run unattended
- [ ] Add **drain + `pg_dump` + schema-version snapshot** to the `edge-node` path of
      `update.ps1` (distribution plan Phase A).
- [ ] Add a **verify** step (health, services Running, push/pull round-trip, `dirty` check) and a
      **paired rollback** (restore dump **and** swap artifacts back).
- [ ] Write the golang-migrate `dirty`-state recovery runbook (`provisioning/`).
- [ ] Run the whole sequence **by hand, end to end, on the real box** at least twice. Nothing gets
      automated until the manual version is boring.

### Phase 3 — The pull loop (the "signal")
- [ ] Publish a **signed channel manifest** (§2) alongside the releases; ship the public key.
- [ ] `laguna-updater` service: poll → gate (window, pause, health) → verify signature+hash →
      Phase-2 sequence → report to `logs\` + Alloy. Path allowlist/denylist enforced.
- [ ] Decide and document **how the updater itself is updated** (§6.1).
- [ ] Prove the failure paths deliberately: bad signature, bad hash, failed migration, failed
      health, WAN loss mid-download, power loss mid-apply.

### Phase 4 — Fleet (when box #2 exists)
- [ ] `nodes` columns + `GET /api/fleet/desired` / `POST /api/fleet/report` (§5).
- [ ] Per-box pin, kill switch, per-box maintenance window; a one-screen "who runs what" view.
- [ ] Canary → channel promotion.
- [ ] Optional: long-poll for seconds-latency (§5 option 3).

> **Sequencing note:** Phases 1 and 2 are valuable *with one box* and are pure risk reduction.
> Phase 3 is the first phase that only pays off at scale — but it is also small *once 1 and 2 are
> done*, and nearly impossible before. If the next 6 months stay at one box, doing 1 and 2 and
> stopping is a perfectly good outcome.

---

## 10. Open questions

1. **How many boxes in 12 months, honestly?** 1 → Phases 1–2 only. 2–5 → Phase 3 pays off.
   10+ → re-open §8 (RMM / MSI) before writing our own agent.
2. **Who will be on site?** You, or a restaurant manager? If the latter, the **first install**
   also needs to be unattended-friendly (Rung 3 bundle), which is a bigger job than updates.
3. **What is the acceptable update latency** — 5 minutes (cron poll) or seconds (long-poll)? This
   is the only question that decides §5 option 2 vs 3, and 5 minutes is almost certainly fine.
4. **What is the maintenance window?** Needs the real closing time + the nightly power-off from
   incident 06. An updater that fires while the box is powered off is fine (it converges on next
   boot) — but then "update at 03:00" never happens, and the window has to be *after boot*, before
   opening.
5. **Who may publish a release, and where does the signing key live?** Just you, or CI? If CI, a
   compromised CI token owns every till — which is an argument for a key that is *not* in CI.
6. **Does the cloud deploy stay in lockstep?** The distribution plan's rule is **cloud first, then
   edges**. An automated edge updater can violate that by racing ahead; the manifest's
   `sync_contract_version` + a cloud-side compatibility check is what enforces it.
7. **Off-box backups?** The pre-update `pg_dump` protects the un-pushed outbox. If the box's disk
   is also what dies, the dump dies with it. Does it go to Spaces (and with which credentials,
   given §7)?

---

## 11. Decisions (2026-10-16)

Answers to §10, and what they change in the plan.

| # | Question | Answer | Consequence |
|---|---|---|---|
| 1 | Boxes in 12 months | **3**, all friendly operators | Phases 1–3. **Phase 4 (fleet endpoint) is skipped** — §5 option 1 (static manifest) is enough. Re-open option 2 only if a box needs its own pin. |
| 2 | Who is on site | **The restaurant manager** | Nothing on the update path may need PowerShell, RDP, Go, pnpm or git. The first install also needs a manager-friendly bundle (distribution plan Rung 3) — separate job. |
| 3 | Update latency | **5 min is fine; more is acceptable** | Plain polling. No long-poll / SSE. Poll every 15–60 min is fine since a human triggers the apply anyway. |
| 4 | Maintenance window | **Replaced by owner consent** | The manager decides *when*. No auto-apply at 03:00 (which the nightly power-off would defeat anyway). |
| 5 | Who publishes / signing key | **Me (the developer)** | CI builds component artifacts automatically; promoting them to an appliance release (and signing the manifest) is a local, human step. Key never in CI. |

### Where artifacts live: **GitHub Releases** (not S3)

Both app repos are **public**, CI is already GitHub Actions, and the backend already releases on
`v*` tags. GitHub Releases therefore costs nothing, needs **no credentials on the box** (respects
§3.7 / §7 — the box's Spaces/AWS keys stay write-only for app data), and gives immutable,
per-tag URLs with an audit trail for free.

S3 would only win if (a) the repos go private — then every box needs a GitHub token, and a
public-read bucket is simpler — or (b) bandwidth/rate limits bite, which they won't at 3 boxes.
Moving later is cheap: the updater only follows URLs that the signed manifest contains.

Layout:

```
laguna-escondida-backend  release vX.Y.Z   → edge-node-windows-amd64-vX.Y.Z.zip  + .sha256
                                              (same tag already pushes the cloud image to ECR,
                                               so cloud and edge are the same build of the code)
laguna-escondida-frontend release vA.B.C   → next-standalone-vA.B.C.zip          + .sha256
laguna-escondida-edge     release vN.N.N   → edge-vN.N.N.zip (scripts, Caddyfile, services, alloy)
                                              manifest.json + manifest.json.minisig
```

The updater polls one stable URL:
`https://github.com/bperezgo/laguna-escondida-edge/releases/latest/download/manifest.json`
(+ `.minisig`). Not the REST API — that is rate-limited to 60 req/h per IP unauthenticated.

**Rule:** an edge release is only cut *after* the cloud runs the backend version it pins
(cloud first, then edges — §10.6).

### Owner-triggered updates — revised flow

The updater no longer applies on its own. It **prepares**; the manager **presses the button**.

```
laguna-updater (every 30 min, outbound only)
  1. fetch manifest + signature → verify → newer than installed?
  2. download artifacts to staging\ → verify sha256           ← happens in the background
  3. write state\update-available.json  { version, notes, staged: true }
                                │
     manager opens the app ─────┘
     banner: "Versión 1.5.0 disponible — Actualizar ahora"  (admin role only)
  4. click → edge-node writes state\update-requested.json   (edge-node does NOT run anything itself)
  5. updater sees the request → drain → pg_dump → apply → verify → rollback on failure
  6. writes state\update-result.json → banner shows success / "se restauró la versión anterior"
```

Why the split: the web app never gets the power to execute anything — it only drops a flag file;
the LocalSystem updater is still the only thing that acts, and only on a **signed, already
verified** staged release. Because step 2 is done ahead of time, the apply itself is offline-safe
and typically a couple of minutes (mostly the Postgres dump and service restarts).

Fallback if the app is the broken thing: a desktop shortcut "Actualizar Laguna" that writes the
same request flag.

### New blocker found: per-box values baked into the Next bundle

`NEXT_PUBLIC_ORDER_ACTION_PIN` (env/next.env) is **inlined at build time** per box. A single
CI-built bundle cannot carry three different PINs — and a public GitHub Release would publish
whichever PIN it was built with. **Before Phase 1 ships the frontend artifact**, move per-box values
to runtime: read them server-side (env in `services/next.xml`) and hand them to the client from a
server component or a small `/api/config` route. Rule going forward: **no per-box value may be a
`NEXT_PUBLIC_*`.** (Worth doing regardless — a PIN in client JS is readable by anyone on the LAN.)

### Revised phases

- **Phase 1** — unchanged, plus the `NEXT_PUBLIC_*` → runtime move above. New `release.yml` jobs:
  backend adds a `windows` job next to `push-image`; frontend gets its first workflow.
- **Phase 2** — unchanged (the safety sequence, proven by hand twice).
- **Phase 3** — updater stages + waits for consent (flow above) instead of a maintenance window;
  admin-only banner in the frontend; `GET/POST /api/edge/update` on edge-node that only reads the
  state files / writes the request flag.
- **Phase 4** — dropped for now.

### Phase 1 status (2026-10-16)

Done, not yet exercised by a real tag:
- **Relocatable Next:** (a) hoisted linker, set CI-only in the frontend release workflow. Verified
  locally: 0 symlinks in the standalone output; the bundle served `/`, a static chunk and
  `public/` after being moved to another folder with the build's `node_modules` deleted. The
  workflow repeats that smoke test on `windows-latest` and fails on any reparse point.
- **PIN** fixed to `1234` at build time in CI (database-backed PIN is a separate plan).
- **Backend** `edge-windows` job (cross-compiled, `-X buildinfo.Version=<tag>`), and
  `/api/edge/status` returns `version`. The cloud image is stamped too.
- **Box side:** `fetch-artifacts.ps1` installs the pinned tags with sha256 verification (staged
  cache, `-DownloadOnly`, installed tag in `artifacts\<app>\RELEASE`); `update.ps1` uses it
  (download before stop) and keeps `-FromSource` for local builds.
- Not done: `schema_migration_version` on `/api/edge/status`, manifest metadata
  (`max_migration`, `sync_contract_version`) — both land with Phase 2/3.
