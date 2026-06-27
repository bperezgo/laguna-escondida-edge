# Edge box docs — index

Operational docs for running the Laguna Escondida edge appliance on the restaurant Windows box.
Written to be self-sufficient: an operator with no developer help can install, verify, watch,
and fix the box from these alone. Install root is **`C:\laguna-edge`**, LAN IP
**`192.168.0.123`**.

## Start here

| When… | Open |
|---|---|
| Setting up a brand-new box, start to finish | [`DEPLOYMENT_RUNBOOK.md`](DEPLOYMENT_RUNBOOK.md) |
| Just installed/updated — confirm it's correct | [`VALIDATION.md`](VALIDATION.md) |
| Box is live — watch health, read logs, set alerts | [`MONITORING.md`](MONITORING.md) |
| Something is broken — symptom → fix | [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) |

## Background / design (the "why")

| Doc | What |
|---|---|
| [`LAN_SERVING_WALKTHROUGH.md`](LAN_SERVING_WALKTHROUGH.md) | How the Caddy LAN reverse proxy was built up, with reasoning |
| [`DNS_SETUP_GUIDE.md`](DNS_SETUP_GUIDE.md) / [`DNS_RESTORE_GUIDE.md`](DNS_RESTORE_GUIDE.md) | Optional local-DNS hostname setup + rollback |
| [`../ai-plan/EDGE_WINDOWS_SERVICES_PLAN.md`](../ai-plan/EDGE_WINDOWS_SERVICES_PLAN.md) | Full Windows-services design + phased plan |

## The 60-second mental model

```
tablets ──HTTPS:443──> Caddy ──:3000──> Next.js ──:8080──> edge-node (Go) ──:5432──> Postgres
                       (only LAN-exposed)   all of these bind 127.0.0.1 — invisible to the LAN
```

Four Windows services (`laguna-postgres`, `laguna-edge-node`, `laguna-next`, `laguna-caddy`),
started in that order, each auto-restarting on failure. Config + secrets live in
`env\edge-node.env`; logs in `logs\`; the TLS CA root in `caddy-data\` (back it up).
