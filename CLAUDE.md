# CLAUDE.md — Homelab Observability

**Read [README.md](README.md) first** for architecture, setup, credentials, Alloy vs Cloud split, and kiosk (public dashboard). This file keeps **conventions and query patterns** that stay true after the Grafana Cloud migration; it does not duplicate the full setup guide.

## Persona — introduce yourself

When Claude initializes in this directory, open the first response with a
brief self-introduction as **Observability Claude** — steward of the Alloy +
Grafana Cloud configs in this repo (the LXC 105 host that runs these
configs is Home Claude's turf — see `~/CLAUDE.md`). One sentence is
plenty; don't make a meal of it.

## Project overview

Firewalla home-network observability: **Grafana Cloud** (dashboards + Mimir + Loki) plus **Grafana Alloy** on a Proxmox LXC for ingestion. Firewalla ships Zeek (DNS, conn) and ACL alarm logs to Alloy’s Loki-compatible receiver; Alloy forwards to Grafana Cloud Loki. Metrics: native Alloy blackbox probes (ICMP / HTTP), `node_exporter` on Proxmox hosts, and Home Assistant’s `/api/prometheus` — all remote-written to Grafana Cloud Mimir.

Dashboard JSON lives in [`dashboards/`](dashboards/) and is applied by [`terraform/`](terraform/).

## Stack (current)

| Layer | What |
|-------|------|
| **Grafana Cloud** | UI, `grafanacloud-logs` / `grafanacloud-prom` datasources, dashboards (Terraform-managed) |
| **Alloy** (single `docker compose` service) | `loki.source.api` on `:3100` (Promtail target), `prometheus.exporter.blackbox`, scrapes for node + HA, `remote_write` + `loki.write` to Cloud |
| **Bare metal** | `node_exporter` on Proxmox hosts (not in Docker) — see `scripts/deploy-node-exporter.sh` |

Legacy self-hosted Loki + Prometheus + Grafana in one compose file is **removed**; do not reintroduce without an issue.

## File structure (high level)

```
docker-compose.yml          # Alloy only
alloy/config.alloy          # scrape + receive + forward
alloy/blackbox.yml          # icmp, http_2xx modules
alloy/ha_token              # HA bearer token (gitignored); see alloy/ha_token.example
dashboards/*.json           # dashboard source of truth (Terraform reads these)
terraform/*.tf              # Grafana Cloud resources (folder, dashboards, …)
scripts/deploy-node-exporter.sh
scripts/inventory-cloud.sh  # optional snapshot of Cloud API (needs GRAFANA_* env)
```

## Key conventions

- **Dashboard UIDs**: `firewalla-<name>` (e.g. `firewalla-network-overview`).
- **Loki labels**: `log_source` is the main stream selector — current values are `zeek_dns`, `zeek_conn`, `zeek_ssl`, `firewalla_acl`. After Alloy → Cloud, queries may also see `cluster="homelab"` from `external_labels` in Alloy — use both if a panel is empty.
- **Log parsing**: Zeek panels use `| json | line_format "{{.log}}" | json` to unwrap nested JSON.
- **Template variables**: DNS & Traffic dashboards use `$device_ip` for per-device filtering.
- **Dashboard JSON**: Grafana schema v39 — no `__inputs` or `__requires` (repo is source of truth, not “import package”).

## node_exporter

Runs as **systemd on Proxmox hosts**, not in Docker (`/proc`, `/sys`, ZFS). Deploy with `scripts/deploy-node-exporter.sh`. Alloy scrapes `192.168.139.8:9100` and `192.168.139.7:9100` by default — update [`alloy/config.alloy`](alloy/config.alloy) if your IPs differ.

## Metrics / probes (Alloy)

Blackbox targets and HA scrape mirror the old Prometheus jobs: ICMP to key LAN IPs, HTTP to Home Assistant, bearer token from `alloy/ha_token`. Probe list lives in [`alloy/config.alloy`](alloy/config.alloy) (`prometheus.exporter.blackbox` targets + `prometheus.scrape` blocks).

## Loki query patterns

```logql
{log_source="zeek_dns"} | json | line_format "{{.log}}" | json | __error__=""
```

Metric panels use `count_over_time`, `rate`, `sum_over_time` (with `unwrap` where needed).

## Office display (kiosk)

Self-hosted anonymous Viewer URLs **no longer apply**. Use **public dashboard sharing** for `firewalla-office-display` (see README § “Office display”). The dashboard mixes Mimir + Loki panels. Prometheus queries use the **friendly label scheme Alloy publishes** — `instance="pve"` / `"pve2"` for `node_exporter`, and `job="integrations/blackbox/<target_name>"` (e.g. `firewalla`, `pve`, `pve2`, `neptune`, `ap-office`, `homeassistant-icmp`, `homeassistant-http`, `alloy`, `grafana-cloud`) for blackbox probes. The target IP/URL lives in the Alloy config, not in the dashboard query — if a target moves, edit `alloy/config.alloy` (no dashboard change needed). If the target is renamed, update the dashboard's job-label match.

Playlist URLs on self-hosted Grafana are obsolete; use Cloud playlists or a single public dashboard URL.

## Testing changes

- Validate dashboard JSON: `python3 -m json.tool dashboards/<file>.json > /dev/null`
- Validate Alloy syntax: `alloy fmt /path/to/config.alloy` (with Alloy binary) or rely on `docker compose` logs after deploy
- After dashboard edits: `cd terraform && terraform plan && terraform apply` (no Grafana container restart)

## Contributing / PRs

PR workflow + auto-merge arming protocol is fleet-wide; see `~/repos/CLAUDE.md`.
