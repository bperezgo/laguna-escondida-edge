# Plan — Restaurant Network Architecture (Edge Appliance Deployment)

> Status: **design — pending hardware purchase.** Companion docs:
> `ai-plan/EDGE_LAN_SERVING_PLAN.md` (Caddy / TLS / cookie / access-control design — still
> valid; this doc resolves its §11 open questions),
> `ai-plan/EDGE_WINDOWS_SERVICES_PLAN.md` (how the box runs the services).
>
> Scope: **the physical and logical network the edge box lives in at the restaurant** — the
> router, DNS, VLAN segmentation, Wi-Fi, WAN, and power. It owns the *network*; the serving
> plan owns everything from Caddy inward. It does **not** change application or service code.

---

## 0. Decisions locked (this session)

| Decision | Choice | Why |
|---|---|---|
| Where DNS lives | **On a capable router** (replace the TP-Link TL-WR850N) | DNS becomes independent of the box and survives box reboots/rebuilds. No Technitium in production. |
| Scale | **Single location** | Optimize for simplicity, low cost, easy recovery — not multi-site fleet tooling. |
| Segmentation | **Isolate POS via VLAN** | POS tablets + box on their own L2/L3 segment; guest/staff devices cannot reach the POS. |
| On-site maintainer | **Semi-technical person** | Favor a single, GUI-managed ecosystem with a clear runbook over CLI-heavy gear (MikroTik/pfSense). |

These four answers point at one recommendation: a **UniFi** stack (best blend of native local-DNS
records + VLANs + guest isolation + a GUI a semi-technical person can run). Alternatives in §7.

---

## 1. What the network must deliver (recap)

From the serving plan, the box exposes **only Caddy on `:443`** at `pos.laguna.lan`; everything
else (Next, Go edge-node, Postgres) binds `127.0.0.1`. So the network has exactly four jobs:

1. **Resolve** `pos.laguna.lan → 192.168.10.10` for the POS tablets (the box's reserved IP).
2. **Carry HTTPS** from tablets to the box on the POS segment, and **keep everyone else off it**.
3. **Give the box internet** for edge→cloud sync, S3/Spaces storage, and electronic invoicing
   (`APP_MODE=edge`; it still serves the LAN when the internet is down and catches up later).
4. **Stay up** through reboots and brief power blips without corrupting Postgres.

`.lan` (not `.local`) is deliberate — it sidesteps Android's mDNS special-casing (serving plan §6).

---

## 2. Physical topology

```
            ISP modem / ONT
                  │  (WAN)
                  ▼
        UniFi gateway + controller            ← routing, DHCP, DNS, VLANs, firewall
                  │  (LAN trunk, all VLANs tagged)
                  ▼
        UniFi PoE switch  ─────────────┬ ─────────────────────┐
          │           │                │ (access, POS VLAN)   │ (access, POS VLAN)
          │ (PoE)     │ (PoE)          ▼                      ▼
          ▼           ▼         ┌────────────────┐   ┌────────────────────────┐
       UniFi AP    UniFi AP     │  KITCHEN KDS   │   │  EDGE BOX (Win)        │
       (dining)    (kitchen)    │  wired kiosk   │   │  Caddy :443            │
          ┊           ┊         │  192.168.10.15 │   │  Next/Go/PG local      │
       Wi-Fi SSIDs (→ VLANs)    └────────────────┘   │  USB → thermal printer │
          ┊                      wired, POS VLAN 10  │  wired, 192.168.10.10  │
   ┌──────┴───────┐                                  └────────────────────────┘
   ▼              ▼              ▼
 POS tablets   Guest phones   Staff
 (VLAN 10)     (VLAN 30)      (VLAN 20)
```

Notes:
- **The box is wired**, not on Wi-Fi — a server on Wi-Fi is the #1 avoidable reliability bug.
- **The kitchen display (KDS) is wired too**, on the POS VLAN — *not* on Wi-Fi. A busy-night field
  incident took down a *wireless* KDS via Wi-Fi airtime saturation (§6b); a wired KDS is immune to
  it. This is the single highest-value change that incident produced.
- **The thermal printer is USB-attached to the box** (`PRINTER_TRANSPORT=windows`) and driven by
  the backend's print endpoint. It is **not a network device** — no IP, no VLAN membership, no open
  port — so nothing in the network design has to account for it.
- An all-in-one gateway (UniFi Dream Router) collapses gateway+controller+one AP+one PoE port into
  a single box — fine for a small floor (see §7).

---

## 3. Logical design — VLANs, subnets, DHCP

| VLAN | Name | Subnet | Members | Gateway/DNS | DHCP |
|---|---|---|---|---|---|
| 10 | **POS** | `192.168.10.0/24` | edge box (`.10`, static/reserved), **wired KDS** (`.15`), POS tablets | router `.1` | reservations for box + KDS + tablets |
| 20 | **Staff** | `192.168.20.0/24` | manager laptop, back-office PC, personal staff phones | router `.1` | dynamic |
| 30 | **Guest** | `192.168.30.0/24` | customer Wi-Fi | router `.1` | dynamic, client isolation ON |

- Keep `192.168.10.10` for the box to match the serving plan and the Caddy `remote_ip`
  `192.168.10.0/24` rule — **no app/Caddy change needed.**
- Tablets get **reserved** IPs (`.20`, `.21`, …) by MAC. The serving plan's Windows-Firewall
  IP-allowlist (§7) keys off these; the VLAN is now the *primary* isolation and the firewall
  allowlist is defense-in-depth.
- A separate **management VLAN** for the network gear itself is optional at single-site scale;
  skip it for now to keep the maintainer's mental model small.

---

## 4. DNS design (resolves serving-plan §11)

The router is the DNS server for every VLAN and holds **one local record**:

```
pos.laguna.lan  A  192.168.10.10        # UniFi: Settings → Routing & DNS → Local DNS records
```

- Everything else is **forwarded upstream** (ISP DNS, or 1.1.1.1 / 8.8.8.8). So `pos.laguna.lan`
  resolves locally and normal internet name resolution keeps working — even while the box is down.
- **No Technitium in production.** That whole port-53/ICS dance was a dev-box artifact; here the
  router owns DNS and the box just serves the app.
- **Tablet gotcha (carry over from serving plan §6):** each tablet's DNS must be the router
  (the DHCP default) and **Private DNS / DoH must be OFF**, or it bypasses the router and
  `pos.laguna.lan` fails to resolve. This goes in the provisioning runbook.
- **Fallback** if a record can't be added for any reason: point Caddy at the IP
  (`192.168.10.10 { tls internal }`) and skip DNS — ugly URL, but the serving plan already
  documents it (§5).

---

## 5. Segmentation & inter-VLAN firewall

Default stance: **VLANs cannot talk to each other**; open only what's needed.

| From → To | Allowed? | Purpose |
|---|---|---|
| POS → POS | ✅ | tablets → box `:443` (printer is USB on the box, not on the network) |
| POS → Internet | ✅ (box) / optional (tablets) | box needs sync/S3/invoicing. Tablets are kiosk-locked to the POS and can be denied internet for a tighter perimeter. |
| Staff → POS | ⛔ by default | open a **single** rule only if a manager laptop / printer-admin UI must reach the box (answer the §13 device question first) |
| Staff → Internet | ✅ | normal back-office use |
| Guest → POS / Staff | ⛔ | guests never touch internal segments |
| Guest → Guest | ⛔ (client isolation) | guests can't see each other |
| Guest → Internet | ✅ | the only thing guest Wi-Fi does |

This is the network-layer realization of serving-plan §7 "layer 3" (POS VLAN). With real VLAN
isolation in place, the Windows Firewall allowlist becomes a second line rather than the only one.

---

## 6. Wi-Fi / SSIDs

Map SSIDs to VLANs on the AP(s):

| SSID | VLAN | Notes |
|---|---|---|
| `Laguna-POS` | 10 | hidden or not; WPA2/WPA3; tablets only. Keep on its own SSID even though it's also VLAN-tagged. |
| `Laguna-Staff` | 20 | back-office devices |
| `Laguna-Guest` | 30 | UniFi "Guest" network type → client isolation + captive portal optional |

- Size APs to the **floor**, not the device count: one AP rarely covers a full dining room +
  kitchen through walls/equipment. Two modest APs beat one big one.
- Prefer 5 GHz for tablets where coverage allows; let the AP band-steer.
- Place an AP near the **kitchen** for any device that *must* stay wireless — stainless steel and
  appliances murder 2.4/5 GHz. (The KDS itself is now **wired** — §6b — so this is about coverage
  for phones/tablets, not the kitchen display.)

---

## 6b. Performance isolation (QoS) — the layer VLANs don't cover

> **Field incident (motivates this section).** During a busy service, customer phones joining the
> guest Wi-Fi saturated the shared radio. Server phones slowed to a crawl taking orders and the
> **wireless** kitchen tablet (SSE live view) dropped its connection and became unusable. The box
> and its LAN app were fine — this was purely a Wi-Fi **RF** problem, not a WAN or app problem (the
> POS runs fully offline — §8). Orders fell back to sticky notes.

**VLANs isolate; they do not allocate.** VLAN segmentation (§3/§5) is a *security* boundary — it
stops guests from *reaching* the POS. It does **nothing** for bandwidth or Wi-Fi airtime, because
every SSID on one access point shares the same physical radio. Two devices on different VLANs but
the same AP still fight for the same airtime. Performance isolation is a separate job:

1. **Wire the critical fixed devices.** The kitchen display and any stationary order-review device
   go on **Ethernet**, not Wi-Fi (topology §2). A wired KDS is immune to airtime contention — this
   is the single highest-value fix for the incident above, and it matches the plan's own rule that
   "a server on Wi-Fi is the #1 avoidable reliability bug." Use a mini-PC / Pi kiosk, or a tablet
   with a USB-C or PoE → Ethernet adapter.
2. **Cap the guest network.** Set a **per-client** *and* a **total** bandwidth limit on the guest
   WLAN so no single customer — or the whole guest crowd — can starve operations. UniFi/Omada
   expose this directly on the guest network / user-group settings.
3. **Put POS on 5 GHz.** 5 GHz has far more airtime and shorter range (less co-channel bleed). Keep
   POS devices on 5 GHz; let guests band-steer. Enable **airtime fairness / WMM** so one weak,
   distant client can't monopolize the channel.
4. **Mind rate-vs-range.** A far-away client negotiates a low data rate, and each of its frames then
   occupies the channel *longer*, dragging down **every** device on that AP — not just itself. This
   is why "the tablet was far from the switch" and "the phones got slow" were the *same* failure.
   Fix by wiring the far device (#1) or adding an AP near it (§6).

Net: **segmentation keeps guests *out* of the POS; QoS + wiring keep guests from *drowning* it — you
need both.** A second ISP line addresses neither (the app is offline-capable — §8), so it's a
nice-to-have for cleanly separating customer internet, not a fix for this incident.

---

## 7. Recommended hardware (bill of materials)

Prices are **approximate (USD) — verify current pricing/SKUs before buying.** All three options
do local-DNS records + VLANs + guest isolation; they differ in ease-of-management.

### Recommended — UniFi (best fit for "VLAN + semi-technical maintainer")

Two ways to buy it; pick by floor size:

**A. Modular (better coverage, expandable):**
| Item | Approx. | Role |
|---|---|---|
| UniFi Cloud Gateway Ultra (UCG-Ultra) | ~$129 | gateway + controller (no Wi-Fi); local DNS, VLANs, IDS/IPS, ~300 clients |
| UniFi PoE switch (e.g. USW-Lite-8-PoE) | ~$109 | powers APs, wires the box + printer |
| 1–2× UniFi AP (U6+ ~$129 / U7 Pro ~$189) | ~$129–$378 | Wi-Fi; number depends on floor |

**B. All-in-one (simplest, small floor):**
| Item | Approx. | Role |
|---|---|---|
| UniFi Dream Router (UDR) | ~$199 | gateway + controller + Wi-Fi 6 + 1 PoE port in one box; ~700 Mbps WAN |

Why UniFi: native **Local DNS records** and **VLAN/guest** in one GUI/app a semi-technical person
can run, one vendor to learn, business-grade reliability, and trivial to add an AP later. Start
with the UDR if the dining area is small; go modular (UCG-Ultra + AP + PoE switch) if you need to
place APs apart for coverage.

### Budget alternative — TP-Link Omada
ER605 gateway (~$60) + Omada PoE switch + EAP AP(s), managed by the Omada controller (software or
a small hardware controller). VLANs are native; **local DNS records are cleanest with the Omada
controller running** (standalone DNS config is per-WAN/global). Cheaper, slightly less polished,
controller adds a moving part.

### Power-user / cheapest-capable — MikroTik
hAP ax³ (~$90–100) does DNS + VLANs + Wi-Fi in one inexpensive box and is extremely capable —
but **RouterOS is CLI/Winbox-heavy**. Good only if *you* configure it once and the on-site person
never has to touch it. Against the "semi-technical maintainer" goal otherwise.

> Not recommended here: pfSense/OPNsense (most powerful, most operational overhead — overkill for
> a single shop with a non-dedicated admin).

---

## 8. Internet / WAN resilience

- The box's normal operation **assumes connectivity** for sync/S3/invoicing, but it **serves the
  LAN fully offline** and catches up when the link returns (`APP_MODE=edge`, serving plan + windows
  plan). So a dropped WAN degrades *cloud sync and new e-invoices*, **not** taking orders locally.
- If electronic invoicing must stay near-real-time, add **WAN failover**: a second WAN or an
  LTE/5G modem (UniFi gateways support a backup WAN). Optional for a single shop — decide based on
  how the invoicing provider tolerates delay.
- Outbound-only: nothing here requires inbound ports from the internet. **Do not port-forward to
  the box.** Remote admin, if needed, should be via the gateway's own remote-access (UniFi
  Site Manager / Teleport VPN), not a forwarded RDP.

---

## 9. Power / UPS (do not skip)

Postgres on the box can be **corrupted by an abrupt power loss**, and a restaurant's power is not
clean. Put the **box + gateway + switch + (kitchen AP)** on a small **line-interactive UPS**
(~$80–150, e.g. APC/CyberPower 600–900 VA). Two wins:

1. Rides out brief brownouts/flickers with zero downtime.
2. On a real outage, gives time for a **graceful shutdown** — configure the box to shut down on
   "battery low" (UPS USB + Windows power settings, or the vendor's agent) so Postgres closes clean.

This is the single highest-value reliability item after wiring the box.

---

## 10. Failure modes & recovery (runbook for the on-site maintainer)

| Symptom | Likely cause | First action |
|---|---|---|
| Tablets show cert/connection error, `pos.laguna.lan` won't load | box down or app service stopped | check box is on; restart in boot order (Postgres→edge-node→next→caddy) — see windows plan |
| Page says **403 / Forbidden** | device is **not on the POS VLAN** (wrong SSID) | reconnect the tablet to `Laguna-POS` |
| `pos.laguna.lan` "server not found", but Wi-Fi works | tablet **Private DNS** got turned on, or it's not using the router for DNS | turn Private DNS **off**; forget/rejoin Wi-Fi |
| Everything down (no Wi-Fi at all) | router/switch power or the UPS | check UPS + gateway power; power-cycle gateway, then switch, then APs |
| POS works but "sync" warnings / no e-invoices | internet/WAN down | this is expected-degraded; orders still work; check ISP/modem |
| **POS slow + KDS drops under customer load** | **Wi-Fi airtime saturation** — guests + POS sharing one radio; distant KDS | wire the KDS; cap guest bandwidth; POS on 5 GHz (§6b) |
| All tablets lost trust after a box rebuild | Caddy internal-CA root changed | restore `caddy-data/` from backup, or re-install the root cert on tablets (serving plan §8) |

Keep this table (plus the box boot-order and the cert-reinstall steps) printed near the box.

---

## 11. Deployment checklist

**Router / network**
- [ ] Replace TL-WR850N with the chosen gateway; create VLANs 10/20/30 (§3).
- [ ] Add local DNS record `pos.laguna.lan → 192.168.10.10` (§4).
- [ ] DHCP-reserve the box (`.10`), the wired KDS (`.15`), and each tablet by MAC (§3). (Printer is USB on the box — no network reservation needed.)
- [ ] Create SSIDs mapped to VLANs; enable guest client-isolation (§6).
- [ ] **Cap guest Wi-Fi** — per-client + total bandwidth limits; POS SSID on 5 GHz + airtime fairness (§6b).
- [ ] Apply inter-VLAN firewall rules; verify guest/staff **cannot** reach `192.168.10.10` (§5).

**Box**
- [ ] Wire the box to the switch on the POS VLAN; confirm it gets `192.168.10.10`.
- [ ] **Wire the kitchen display** to the switch on the POS VLAN; confirm it gets its reserved `.15` (§2, §6b).
- [ ] (Carry-over) bind Next/Go/Postgres to `127.0.0.1`; only Caddy on `:443` (serving plan).
- [ ] Windows Firewall inbound `:443` scoped to tablet IPs as defense-in-depth (serving plan §7).
- [ ] Put box + network gear on the UPS; configure graceful shutdown on low battery (§9).

**Tablets (per device — serving plan §8)**
- [ ] Join `Laguna-POS`; confirm DNS = router and **Private DNS OFF** (§4).
- [ ] Install Caddy root CA; open `https://pos.laguna.lan` warning-free; kiosk-lock to it.

**Verify end-to-end**
- [ ] From a tablet: login persists (Secure cookie over HTTPS), kitchen SSE updates live.
- [ ] From a guest device: `https://pos.laguna.lan` is **unreachable** (isolation works).
- [ ] **Load test:** with many guest devices saturating the guest Wi-Fi, POS phones stay responsive and the **wired** KDS SSE holds (§6b).
- [ ] Pull box power briefly: UPS holds; or on long outage, box shuts down clean and recovers.

---

## 12. How this resolves the serving plan's open questions (§11)

- ✅ **Router supports local DNS overrides** → yes, on the recommended gateways (§4, §7).
- ✅ **Router supports VLANs** → yes; full segmentation design in §3/§5.
- ⏳ **Non-tablet devices needing LAN access** → see §13 (one input still needed).
- ✅ **POS subnet CIDR / box IP** → `192.168.10.0/24`, box `192.168.10.10` (unchanged from plan).

---

## 13. Inputs still needed

1. **Floor size / layout** → decides UDR (all-in-one) vs UCG-Ultra + separate AP(s), and how many
   APs. Rough sq-meters + whether the kitchen is walled off is enough.
2. **Non-tablet devices on the POS side?** A manager laptop, a printer admin page, a backup KDS —
   anything that must reach `192.168.10.10` needs an explicit Staff→POS allow rule (§5) and a
   firewall-allowlist entry. List them now to avoid a confusing "it's blocked" later.
   *(The primary **wired KDS** lives directly **on** the POS VLAN — §2/§6b — so it needs only a DHCP
   reservation, **no** inter-VLAN rule.)*
3. **Invoicing latency tolerance** → whether to budget for LTE WAN failover (§8).
4. **ISP setup**: standalone modem/ONT, or an ISP router you can't remove? If the latter, we run
   the UniFi gateway behind it (double-NAT is fine for outbound-only) or put the ISP box in
   bridge mode.

> Resolved: the **printer is USB-attached to the box** (`PRINTER_TRANSPORT=windows`), so it's not
> a network device — removed from the topology, VLAN, firewall, and reservations above.
```

