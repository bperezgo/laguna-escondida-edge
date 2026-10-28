# Owner-triggered updates

How a box offers a new backend/frontend to the restaurant and installs it when an admin presses
**"Actualizar ahora"** in the POS. Nobody needs PowerShell, RDP or git for it.

## Pieces

| Piece | Where | Does |
|---|---|---|
| `Laguna Updater` scheduled task | registered by `scripts/install.ps1` | runs `scripts/updater.ps1` every minute as SYSTEM |
| `scripts/updater.ps1` | this repo | checks for updates, stages them, installs on request, rolls back |
| `GET/POST /api/edge/update` | backend (edge mode) | reads the state files; POST only writes `update-requested.json` |
| Update banner | frontend (admins only) | shows the offer, the progress and the result |

The web app never executes anything: it drops a request file, and only the updater acts on it.

## Where "a new version" comes from

Every 30 minutes the updater compares what is installed (`artifacts\<app>\RELEASE`) with:

- **edge-node**: the version the **cloud backend** runs, from `<CLOUD_SYNC_URL>/api/edge/status`
  (`version` is the release tag stamped into the binary). Following the cloud means a box
  never runs a backend newer than the cloud it syncs with.
- **next**: the **latest GitHub Release** of `laguna-escondida-frontend`. Netlify deploys on
  push, so the cloud frontend has no tag to report; the box only needs a tagged Windows build.

A newer version is offered only after its Windows asset has been downloaded and its sha256
verified (`fetch-artifacts.ps1 -DownloadOnly -Tags`), so pressing the button needs no download.
If either check fails (no internet), the previous offer is left as it is.

The offered version is `<edge-node tag>+<next tag>`, e.g. `v1.1.21+v1.0.4`. Both apps are always
installed as that pair.

## State files (`EDGE_STATE_DIR`, `C:\laguna-edge\state`)

Only SYSTEM and Administrators can write here (`install.ps1` sets the ACL). JSON, no BOM, written
to `<name>.tmp` and renamed.

| File | Written by | Meaning |
|---|---|---|
| `update-available.json` | updater | `{version, current, notes_url, components: {edge-node, next}, checked_at}`; removed when up to date |
| `update-requested.json` | edge-node (POST) | `{version, requested_by, requested_at}`; `version` must equal the available one |
| `update-progress.json` | updater | `{version, phase, started_at}` while installing |
| `update-result.json` | updater | `{version, outcome, message, started_at, finished_at, from, to}` |
| `installed.json` | updater | `{version, applied_at}` after a successful update |
| `.last-check` | updater | timestamp of the last 30-minute check |

`outcome` is `success`, `refused` (nothing was changed), `rolled_back` or `rollback_failed`.

## Applying an update

On the next minute tick after the click:

1. `preparing`: the request must match `update-available.json`. The tags come from that file,
   which the updater wrote itself, never from the request.
2. `downloading`: re-verify the staged zips.
3. `backup` (only if edge-node changes): `pg_dump -Fc` to `C:\laguna-edge\backups\`, last 5 kept.
4. `installing`: `update.ps1 -Service edge-node -Tag ...`, then `next`.
5. `verifying`: `verify-install.ps1`, which also checks edge-node reports the new version.

If step 4 or 5 fails, the updater **rolls back**: it stops the app services, restores the
database from the step 3 dump (the old edge-node refuses a schema migrated past what it knows),
reinstalls the previous tags from the local cache (works offline) and verifies again.
The app services are set to Disabled while stopped for the restore, so Windows' restart-on-failure
can't start a crash-looping edge-node against a half-restored database; they are set back to
Automatic before the reinstall, and also if the rollback fails.
Anything written to the database between the backup and the rollback is lost, which is why the
banner asks for no open orders.

If the box loses power mid-update, the next run finds `update-progress.json` with no updater
holding the lock and reports `refused` if the box is healthy, or `rollback_failed` if not.

The log is `logs\updater.log`.

## versions.json vs. what the box runs

`versions.json` is the **install-time baseline**. After a POS update, a box runs newer tags than
its pins; `fetch-artifacts.ps1` keeps them instead of downgrading, and `update.ps1` refuses to
downgrade unless given `-Tag`. `artifacts\<app>\RELEASE` is what is installed.

## Testing on a box

```powershell
# Force a check now instead of waiting up to 30 min (elevated):
.\scripts\updater.ps1 -CheckNow
Get-Content .\state\update-available.json
Get-Content .\logs\updater.log -Tail 30
```

Then log in as an admin: the banner offers the update. After the click, watch
`logs\updater.log`; the banner shows the result when the POS comes back.
