# Updating a box

Two ways to move a box to a new edge release. Both end in the same script,
`scripts\apply-release.ps1`, which is the only thing that touches the services.

| | Who | How |
|---|---|---|
| **Button** | the restaurant manager (admin role) | Banner "Versión X disponible" → **Actualizar ahora** |
| **By hand** | a technician (RDP / console) | `git pull`, then `.\scripts\apply-release.ps1` |

Either way, the developer side is the same: tag the app repo(s), deploy the cloud, then
`scripts/release.sh` (see `DEPLOYMENT_RUNBOOK.md` → "Cutting a release").

## What apply-release.ps1 does

1. **Preflight** (box still serving): the schema is not dirty, there is disk for a backup, and
   the pinned releases download and match their sha256. Any failure → `refused`, nothing changed.
2. **Drain**: waits up to 5 min for `pending_sync_ops = 0`. With the WAN down it refuses;
   `-AllowPendingSync` proceeds anyway (the ops stay queued in the database and in the dump).
3. **Backup** (POS down from here): stops caddy → next → edge-node, `pg_dump` into
   `backups\<time>\db.dump`, keeps the old `edge-node.exe` and moves the old `next` bundle there.
4. **Apply**: installs the staged releases, starts everything (migrations run here), and runs
   `verify-install.ps1` plus a `schema_migrations.dirty` check.
5. **Rollback** on any failure in 3–4: database **and** binaries back together, then verified
   again. Outcome `rolled_back`; if even that fails, `rollback_failed` → `MIGRATION_RECOVERY.md`.

The outcome is in `state\update-result.json`; the full log in `logs\update-<time>.log`. The
last 3 backups are kept.

```powershell
.\scripts\apply-release.ps1                    # normal
.\scripts\apply-release.ps1 -Reinstall         # the release changed Caddyfile / services\*.xml
.\scripts\apply-release.ps1 -RollbackDrill     # apply + verify, then roll back on purpose
```

`update.ps1 -Service <name>` still exists for a single service or infra (caddy, alloy,
postgres), but it takes **no backup**: do not use it for an edge-node with new migrations.

## The button (laguna-updater)

`laguna-updater` is a Windows service (`updater\laguna-updater.ps1`). Every 30 min it reads
`https://github.com/bperezgo/laguna-escondida-edge/releases/latest/download/manifest.json`,
checks its minisign signature against `updater\minisign.pub`, and, if the release is newer,
downloads every artifact and checks its sha256. Only then does the banner appear. Pressing the
button writes a request; the updater copies the release's files in (never `env\`, `certs\`,
data, or the updater itself) and runs `apply-release.ps1`, so the apply needs no network. If the
apply does not succeed, the release's files are put back too.

Contract between the updater, edge-node and the app: `UPDATE_PROTOCOL.md`.

- It never applies on its own, and it never offers a release that changes the infra pins
  (Caddy, Postgres, Node, …): those need a technician.
- It does not update itself. When a release changes `updater\`, the result message says so;
  a technician copies the new files and runs `.\scripts\install.ps1 -ReinstallUpdater`.
- Fallback when the app is broken: `.\scripts\request-update.ps1` (elevated).
- Once a box updates through the button, its folder no longer matches git exactly. Before a
  manual `git pull`, run `git checkout -- .` (per-box files are gitignored and untouched).

## One-time: the signing key (developer machine)

```bash
brew install minisign
minisign -G -p updater/minisign.pub -s ~/.minisign/laguna-edge.key   # choose a password
git add updater/minisign.pub && git commit -m "feat: release signing key" && git push
```

Back up `~/.minisign/laguna-edge.key` and its password (password manager). Never put it in CI.
Losing it means boxes cannot verify new releases until a technician installs a new public key.

## Monday checklist (first real release)

Developer:

- [ ] `cdk deploy bryan-dev-ci`, then rerun the failed backend release job (ECR pull permission).
- [ ] Set `aws-infra/image-tags.json` `laguna` to `v1.1.18`, `cdk deploy bryan-dev-services`,
      check the cloud is healthy.
- [ ] Merge the backend `edge:update` PR, tag the backend (CI builds the Windows asset); merge
      the frontend banner PR and tag the frontend; deploy the new backend tag to the cloud too.
- [ ] Signing key (above), committed.
- [ ] `scripts/release.sh --dry-run`, then `scripts/release.sh`.

On the box (elevated PowerShell, `C:\laguna-edge`), outside service hours:

- [ ] `git pull`
- [ ] `.\scripts\fetch-artifacts.ps1 -Only minisign`
- [ ] Add `LAGUNA_STATE_DIR=C:\laguna-edge\state` to `env\edge-node.env`.
- [ ] **Drill first**: `.\scripts\apply-release.ps1 -RollbackDrill`. It really upgrades
      (migrations 061–064 run), verifies, then restores the old binary and database. Expect
      "Drill passed" and the old version on `/api/edge/status`. Check an old order still opens.
- [ ] For real: `.\scripts\apply-release.ps1 -Reinstall` (registers laguna-updater too).
- [ ] `.\scripts\verify-install.ps1`; on a tablet: log in, open an order, print a ticket.
- [ ] Log in as admin: no banner (up to date). `GET /api/edge/update` shows `installed`.
- [ ] Next release (any small change): `release.sh`, wait ≤30 min, press the button.
