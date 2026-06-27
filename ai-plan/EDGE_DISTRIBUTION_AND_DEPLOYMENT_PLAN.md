# Plan — Distribution & Deployment of the Edge Appliance

> Status: **draft for discussion.** Companion docs:
> `ai-plan/EDGE_WINDOWS_SERVICES_PLAN.md` (how the 4 services are built & run — source of truth
> for the build pipeline) and `ai-plan/EDGE_LAN_SERVING_PLAN.md` (networking / TLS / serving).
>
> Scope: **how we ship new versions of the edge appliance to the box(es) and how we keep the
> edge backend's schema and sync contract compatible with the cloud over time.** This is the
> "day-2" story — the previous plans get *one* box running; this one is about updating it safely,
> repeatedly, and eventually across more than one site.

---

## 0. The two questions, stated precisely

You raised two things. They are independent and deserve separate answers.

1. **Distribution** — *"Should we keep building on the box, or publish versioned compiled
   artifacts somewhere and just download them?"* This is a packaging / logistics question. The
   answer is a **maturity ladder**, and which rung we want depends on how many boxes we run.

2. **Migrations / cloud compatibility** — *"How do I keep the edge backend's DB changes
   synchronized with the cloud version?"* This is the one you're rightly worried about. But the
   framing hides an assumption worth correcting first (§3), because the fix is different from
   "synchronize the migrations."

---

## 1. What we have today (recap, so the plan is grounded)

- **One installer repo** (`laguna-escondida-edge`) composes **4 services**: Postgres → edge-node
  (Go) → next → caddy. (See the services plan.)
- **Artifacts are built locally on the box** from sibling source repos via
  `scripts/build-artifacts.ps1`:
  - `edge-node.exe` — Go build, **DB migrations are `embed.FS`-compiled into the binary**
    (`cmd/main.go:582`), run on boot with golang-migrate `m.Up()` (`cmd/main.go:579-609`).
  - `next/` — Next.js standalone bundle.
- **Off-the-shelf binaries** (Caddy, Node, Postgres) are downloaded by `fetch-artifacts.ps1`.
- **`versions.json`** pins everything; `build-artifacts.ps1` stamps each app repo's **git
  short-SHA** into it as the artifact "version."
- **`update.ps1 -Service <name>`** swaps one service: rebuild (app) or re-fetch (infra) → stop →
  swap → restart, and re-stages `edge-node`'s `.env`.

So the deployment primitive already exists. What's missing is (a) a decision on *where artifacts
come from*, and (b) a *safe* migration/rollback story around that swap.

---

## 2. Distribution — the maturity ladder

| Rung | What it is | Good when | Cost |
|---|---|---|---|
| **0 — build on the box** *(today)* | Clone all 3 repos onto the box, `build-artifacts.ps1` compiles in place | **1 site, you have hands on the box**, Go+pnpm+Developer-Mode already set up | Slowest install; toolchain + source on a production box; non-deterministic (build host drift) |
| **1 — build on a dev/build machine, copy `artifacts/`** | Build once on your machine, copy the `artifacts/` tree to the box | 1–few sites; you want the box clean of Go/pnpm | Manual copy; **junction caveat** below |
| **2 — versioned artifact registry** *(the thing you're asking about)* | Each app repo publishes a compiled, checksummed release; the box downloads the pinned version | **2+ sites, or unattended boxes**; you want reproducible, auditable installs and instant rollback | CI to build+publish; a place to host (GitHub Releases is enough) |
| **3 — single appliance bundle / installer** | One signed zip (or MSI) = all 4 services + env template, versioned as a unit | Many sites, non-technical installer at the restaurant | More packaging machinery; code-signing cert |

### Recommendation

- **Now (this iteration):** stay at **Rung 0/1**. It works, you're hands-on, one site. Don't
  build registry machinery before there's a second box to justify it.
- **Plan toward Rung 2** as the next real step, because it's what *unblocks rollback and
  fleet*, and it's cheap with GitHub Releases. It is also the rung that makes the migration story
  (§3–§4) tractable, because a release is the natural place to **record the embedded schema
  version** and run **migration tests in CI before the artifact ever reaches a box**.

### Rung 2, concretely (what to build when we get there)

1. **Each app repo** (`laguna-escondida-backend`, `laguna-escondida-frontend`) gets a CI job that,
   on a tagged release:
   - builds the Windows artifact (`edge-node.exe`; Next standalone bundle),
   - computes a **SHA-256 checksum**,
   - records **metadata** alongside it — for the backend: the **max embedded migration number**
     (e.g. `48`) and the **sync wire-contract version** (§4.3),
   - publishes them as a **GitHub Release asset** under a semver tag (e.g. `v1.4.0`).
2. **`versions.json`** moves from git-SHA strings to **semver tags** per artifact, plus a recorded
   checksum.
3. **`fetch-artifacts.ps1`** gains a path to download the *app* artifacts (not just infra) by
   pinned version, **verify the checksum**, and refuse on mismatch.
4. `build-artifacts.ps1` stays for local dev / Rung 0–1, but the production install path uses
   fetch-by-version.

> ⚠️ **Junction caveat carries to every rung.** The Next bundle uses **junctions with absolute
> targets** (services plan §Phase 2). A bundle built or unpacked at one path **cannot be moved**
> to another — it must be assembled/unpacked at its **final install location** (`C:\laguna-edge`).
> Any Rung-1/2 "copy the artifacts" step must unpack to the install root, not stage-then-move. The
> backend `edge-node.exe` and the infra binaries have no such constraint.

---

## 3. The migration concern — first, correct the mental model

You described it as *"migrations for the backend to synchronize the changes with the cloud
version."* That phrasing implies **one shared database** that both cloud and edge migrate. **That
is not how this works**, and the correct model makes the problem smaller and clearer:

- **The edge and the cloud each have their own Postgres.** The edge box runs a *local* Postgres
  (`127.0.0.1:5432`); the cloud runs its own. They are never the same database.
- **Each node self-migrates its own DB on boot**, independently, from migrations **compiled into
  its own binary** (`m.Up()`, forward-only, monotonic — see SYNC-INV-20 in
  `laguna-escondida-backend/docs/playbooks/SYNC_ACCEPTANCE_SPEC.md`).
- So there is **no "synchronize migrations to the cloud DB" step at all.** Nobody runs the edge's
  migrations against the cloud, or vice-versa.

**What actually couples the two nodes is not the schema — it's three narrower things:**

1. **The sync wire contract.** Data crosses the wire as **explicit, versioned JSON DTOs with named
   fields** (`internal/domain/dto/sync.go`: `ProductSyncPayload`, `UserSyncPayload`,
   `OpenBillSyncPayload`, …) — **not** `SELECT *`. This is the single most important fact for your
   worry: **the wire format is decoupled from the raw table layout.** You can add a column to a
   table and, as long as you don't change the DTO, sync neither knows nor cares.
2. **Shared seed data with cross-node-stable IDs.** The `roles` table is **seeded identically by
   migration on both nodes**, and role IDs are treated as **stable cross-node constants**
   (`dto/sync.go:144-146`, the `UserSyncPayload.RoleIDs` comment). If a migration ever assigns
   different role IDs on edge vs cloud, user-role replication silently maps to the wrong role.
3. **Compatible business semantics** behind each entity type (`open_bill`, `purchase_entry`,
   `bill`, `product`, `user`, `supplier`) — both sides must agree what an op *means*.

So the question to engineer around is **not** "how do edge and cloud migrations stay in sync" but:

> **"How do we evolve the edge binary's schema and the sync DTOs so that an edge running version X
> stays compatible with a cloud running version Y, across the window where they differ?"**

That window is unavoidable: you deploy the cloud and the edge boxes at different times, and a box
can be offline for hours/days, then reconnect. **Skew is the normal state, not the exception.**

---

## 4. The real migration risks (and how to manage each)

### 4.1 Risk: schema skew breaks sync apply

A newer cloud emits a DTO field whose value the older edge must store, but the edge's binary
predates the migration that added the backing column (or the applier that handles it).

- **JSON is forward-compatible by default in Go:** `encoding/json` **ignores unknown fields**, so
  an *older* receiver tolerating a *newer* sender's extra field is generally safe. The dangerous
  direction is when a field becomes **required** to apply an op (e.g. a new NOT NULL column the
  applier writes).
- **Mitigations:**
  - **Additive-only, backward-compatible schema changes** as the default discipline: new columns
    are **nullable or defaulted**; never rename/drop a column that an applier or a DTO still reads
    in a version that may still be live. Renames become **add-new + backfill + (later) drop**
    across *two* releases, never one.
  - **The applier must tolerate a zero/absent DTO field** (treat new fields as optional on apply
    until every live node emits them).
  - Make this a **review checklist item** on the backend repo (see §4.3).

### 4.2 Risk: golang-migrate "dirty" state bricks an unattended box

If a migration fails partway, golang-migrate marks `schema_migrations.dirty = true` and **the node
refuses to boot until a human clears it.** On a restaurant box with no on-site engineer, this is
the highest-severity operational risk in the whole design.

- **Mitigations:**
  - **Always back up before applying a new edge-node version** (§4.4) — a failed migration becomes
    *restore + roll back binary*, not *debug Postgres on-site*.
  - **Test every migration on a copy of representative data in CI** (Tier-2 boot test already
    exists as a target: SYNC-INV-20). No migration ships without a green boot+migrate run for
    **both `APP_MODE=cloud` and `APP_MODE=edge`**.
  - **Write a `dirty`-state recovery runbook** (detect via the boot log / a health probe; the fix
    is `force <version>` + re-run, or restore-and-rollback). Put it in `provisioning/`.
  - Consider a tiny **migration pre-flight** in `update.ps1`: snapshot `schema_migrations` version
    before swap so rollback knows the prior state.

### 4.3 Risk: the sync DTO contract drifts incompatibly

The DTOs in `internal/domain/dto/sync.go` are the actual cross-node API. They currently have **no
version marker**, so nothing detects an incompatible change at the boundary.

- **Mitigations:**
  - **Introduce a sync contract version** (an integer, bumped only on a breaking DTO change) and
    send it on push/pull (header or envelope field). The cloud can then **reject or downgrade** for
    an edge that's too old, *loudly* (SYNC-INV-21 is the model: fail loud, never silent).
  - **Treat `dto/sync.go` as a published API:** changes go through review with an explicit
    compatibility note; additive fields are fine, removals/renames/semantic changes require a
    version bump + a migration window where both shapes are accepted.
  - **Record the contract version in the release metadata** (§2 Rung 2) and in `versions.json`, so
    a box's compatibility is auditable without reading code.

### 4.4 Risk: you can't roll back, because a binary swap already migrated the DB

`m.Up()` is **forward-only at runtime** — rolling the `edge-node.exe` back to an older version does
**not** undo the schema change the newer one applied. The older binary may then fail against a
schema that's *ahead* of it. **Binary rollback alone is not a rollback.**

- **Mitigations (this is the backbone of the deploy procedure, §5):**
  - **`pg_dump` immediately before every edge-node update.** Rollback = restore the dump **and**
    swap the binary back, as a pair. Keep the last N dumps on the box (and ideally off-box).
  - Keep **down-migrations** working and shipped (they're in the repo:
    `*.down.sql`) so a *controlled* rollback is possible, but treat **restore-from-dump as the
    primary** rollback — it's the only thing that's reliable when a migration failed mid-way.
  - Because the **cloud is the system of record** for pushed orders/bills (SYNC-INV-10), the truly
    irreplaceable edge state is the **un-pushed outbox backlog**. The pre-update dump protects
    exactly that. (If the outbox is drained to 0 before updating — see §5 step 2 — a botched
    update loses nothing that isn't already on the cloud.)

### 4.5 Risk: migration number collisions across branches

Migrations are sequentially numbered (`000048_…`). Two feature branches each adding `000049_…`
collide on merge, and an edge built from the wrong merge order gets a different `000049` than the
cloud.

- **Mitigation:** keep the existing sequential scheme but enforce **"renumber on merge / no
  duplicate numbers"** in backend CI (a trivial check: fail if two files share a number). This
  lives in the backend repo, but it directly protects edge↔cloud schema agreement.

---

## 5. The deployment procedure (target state)

A single, repeatable runbook for updating one box — built on what `update.ps1` already does, plus
the safety steps from §4:

1. **Pre-flight**
   - Record current versions (`versions.json`) and current `schema_migrations` version.
   - Confirm the new artifact's **checksum** (Rung 2) and its **recorded schema/contract version**
     against the cloud's (compatibility gate, §4.3).
2. **Drain** *(edge-node updates only)*
   - Trigger a sync push; wait for the **outbox pending count → 0** (the edge status endpoint
     already exposes this — `EdgeSyncHealth.PendingOps`). Now the cloud has everything; a failed
     update can't lose un-pushed orders.
3. **Back up** *(edge-node updates only)* — `pg_dump` the local DB; keep it with the version stamp.
4. **Swap** — `update.ps1 -Service <name>` (stop → rebuild/fetch → swap → re-stage `.env` →
   start). On `edge-node` start, migrations auto-apply.
5. **Verify** — health endpoint 200; sync tables present (SYNC-INV-20); a test push/pull cycle
   succeeds; `Secure` cookie + SSE still work end-to-end (services plan Phase 4 checklist).
6. **Roll back if needed** — restore the dump **and** swap the binary back together (§4.4). Never
   one without the other.

> **Ordering rule for cloud-coordinated releases:** because additive/backward-compatible changes
> are the norm (§4.1), **deploy the cloud first, then the edges.** A newer cloud talking to older
> edges is the safe direction (older edges ignore unknown fields); the reverse (new edge emitting a
> field/op an old cloud can't apply) is what the contract version (§4.3) must catch.

---

## 6. Phased work plan

### Phase A — Safety on the current setup (do first, low effort, high value)
- [ ] Add **pre-update `pg_dump`** + **outbox-drain wait** to `update.ps1` for `edge-node`.
- [ ] Write the **golang-migrate `dirty`-state recovery runbook** in `provisioning/`.
- [ ] Add a **backend CI check**: no duplicate migration numbers; boot+migrate test for **both**
      `APP_MODE`s (lands SYNC-INV-20 as a gate).
- [ ] Document the **additive-only / rename-in-two-releases** schema discipline in the backend repo
      (CONTRIBUTING or the sync spec).

### Phase B — Make the contract explicit
- [ ] Add a **sync contract version** to push/pull; cloud rejects/handles an incompatible edge
      **loudly** (extend SYNC-INV-21 thinking to the wire contract).
- [ ] Record **embedded schema version + contract version** in release metadata and surface them in
      the edge **status/health endpoint** (so a box's compatibility is observable remotely).

### Phase C — Rung-2 distribution (when a 2nd box appears, or unattended boxes)
- [ ] Backend & frontend CI: build Windows artifact on tag → checksum → publish GitHub Release with
      metadata (schema/contract version).
- [ ] `versions.json` → semver tags + checksums.
- [ ] `fetch-artifacts.ps1`: download *app* artifacts by pinned version, **verify checksum**, refuse
      on mismatch. Keep `build-artifacts.ps1` for local dev.
- [ ] Compatibility **pre-flight gate** in the deploy procedure (§5 step 1).

### Phase D — Fleet (only if/when many sites)
- [ ] Single versioned appliance bundle (Rung 3) + code-signing.
- [ ] Central record of which box runs which version + remote health rollup.
- [ ] Staged rollout (canary one box before the rest).

---

## 7. Open questions (need your input)

1. **Do you control the cloud backend's release cadence** (same `laguna-escondida-backend` repo,
   `APP_MODE=cloud`)? The whole §5 "cloud-first, then edges" ordering assumes yes. If the cloud is
   operated separately, the contract-version gate (§4.3) becomes mandatory, not optional.
2. **How many boxes in 6–12 months?** 1 → stay Rung 0/1; 2–10 → Rung 2 is worth it now;
   10+ → start sketching Rung 3. This single number drives most of §2 and Phase C/D.
3. **Who performs updates on-site** — you/an engineer, or a non-technical operator? Drives how much
   of §5 must be a one-button script vs. a runbook.
4. **Backup destination** — is the pre-update `pg_dump` enough kept locally, or do we also push it
   off-box (the cloud is system-of-record for pushed data, but not for the un-drained outbox)?
5. **Where do release artifacts live** at Rung 2 — GitHub Releases (assumed here), or an internal
   store? Affects `fetch-artifacts.ps1`'s download + auth path.
```
