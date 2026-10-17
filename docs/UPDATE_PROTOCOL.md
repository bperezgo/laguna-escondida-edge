# Owner-triggered updates: the contract between the updater, edge-node and the app

The box updates itself only when the restaurant manager presses a button. Three parts are
involved, and they only talk through **JSON files in `C:\laguna-edge\state\`**:

| Part | Runs as | Does |
|---|---|---|
| `laguna-updater` (`updater/laguna-updater.ps1`, this repo) | LocalSystem service | Polls the signed manifest, downloads + verifies the release, applies it on request |
| edge-node (backend) `GET/POST /api/edge/update` | its service | **Only** reads the state files and writes the request file. Never runs anything. |
| frontend admin banner | browser | Shows "Versión X disponible — Actualizar ahora" to admins, posts the request, shows the result |

```
updater (every 30 min)            edge-node                       frontend (admin)
  manifest + .minisig verified
  release downloaded + verified
  -> update-available.json  ───►  GET /api/edge/update  ───────►  banner
                                  POST /api/edge/update  ◄──────  "Actualizar ahora"
  update-requested.json  ◄──────  (writes the file, 202)
  (polls every 10 s)
  apply-release.ps1: drain, pg_dump, swap, verify, rollback
  (the POS is down for a few minutes; edge-node restarts)
  -> update-result.json  ───────►  GET /api/edge/update  ───────►  "Actualizado" / "se restauró la versión anterior"
```

All files are UTF-8 **without BOM**, written atomically (write `<name>.tmp`, then rename).
Unknown fields must be ignored by readers. Times are RFC 3339.

## State files

### `installed.json` (writer: updater / apply-release)

```json
{ "version": "v1.0.0", "applied_at": "2026-10-19T15:02:11-05:00" }
```

The appliance (edge repo) release the box runs. Missing = unknown (a box installed by hand).

### `update-available.json` (writer: updater)

Present only when a **newer, signed, fully downloaded and verified** release is staged.

```json
{
  "version": "v1.0.1",
  "current": "v1.0.0",
  "published_at": "2026-10-19T14:00:00Z",
  "notes_url": "https://github.com/bperezgo/laguna-escondida-edge/releases/tag/v1.0.1",
  "components": { "edge-node": "v1.1.19", "next": "v1.0.3" },
  "checked_at": "2026-10-19T14:30:00-05:00"
}
```

### `update-requested.json` (writer: edge-node; consumer: updater)

```json
{ "version": "v1.0.1", "requested_by": "<user id>", "requested_at": "2026-10-19T15:00:00-05:00" }
```

The updater deletes it when it starts applying (so a request is handled once) and refuses a
request whose `version` is not the staged `update-available.json` version.

### `update-progress.json` (writer: updater)

```json
{ "version": "v1.0.1", "phase": "applying", "started_at": "2026-10-19T15:00:05-05:00" }
```

Present while an apply runs; removed when it ends. `phase`: `applying`. (During most of the
apply edge-node itself is stopped, so the UI mostly sees this right before and after.)

### `update-result.json` (writer: apply-release / updater)

The outcome of the last attempt.

```json
{
  "version": "v1.0.1",
  "outcome": "success",
  "message": "Updated to edge-node v1.1.19, next v1.0.3.",
  "started_at": "...", "finished_at": "...",
  "from": { "edge-node": "v1.1.18", "next": "v1.0.2" },
  "to":   { "edge-node": "v1.1.19", "next": "v1.0.3" }
}
```

`outcome` is one of:

| outcome | Meaning | Banner |
|---|---|---|
| `success` | Applied and verified | "Actualizado a v1.0.1" |
| `refused` | A precondition failed (outbox not synced, low disk, download/signature/checksum); **nothing changed** | "No se pudo actualizar: …" + retry |
| `rolled_back` | Applied, failed verification, previous release + database restored | "La actualización falló; se restauró la versión anterior" |
| `rollback_failed` | Applied, failed, and the restore failed too | "Error grave: contacte soporte" |
| `drill_rolled_back` | A deliberate rollback drill (technician only) | (nothing) |

## edge-node API (`APP_MODE=edge` only)

Config: `LAGUNA_STATE_DIR` (env). Unset = the feature is off: `GET` returns
`{"enabled": false}`, `POST` returns 404. In the appliance it is `C:\laguna-edge\state`.

Both routes require a JWT **with the `edge:update` permission** (granted to the admin role).

### `GET /api/edge/update` → 200

```json
{
  "enabled": true,
  "installed": { "version": "v1.0.0", "applied_at": "..." },
  "available": { ...update-available.json... },
  "requested": { ...update-requested.json... },
  "in_progress": { ...update-progress.json... },
  "last_result": { ...update-result.json... }
}
```

Each field is `null` when its file is missing. A file that exists but does not parse is
treated as missing (and logged); it must never make the endpoint fail.

### `POST /api/edge/update` body `{"version": "v1.0.1"}`

| Status | When |
|---|---|
| 202 | `version` equals `update-available.json` `version`; `update-requested.json` written |
| 409 | No staged release, `version` differs from it, or a request / apply is already pending |
| 400 | Missing / malformed `version` |
| 404 | Feature off (`LAGUNA_STATE_DIR` unset) |

edge-node never writes any other file in `state\`, never deletes files there, and never runs
a process. The updater is the only thing that acts, and only on a release whose manifest
signature and artifact checksums it verified itself.

## Desktop fallback

If the app is the broken part, `scripts\request-update.ps1` (elevated) writes the same
`update-requested.json` for the staged version.
