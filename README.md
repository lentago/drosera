# Homelab Observability

**Authorship:** The Terraform, Alloy config, dashboards, scripts, and documentation in this repo are co-written with [Claude](https://claude.ai) (Anthropic). I direct the work and review the output; Claude writes the code. I'm an infrastructure operator, not a software engineer — please don't read this repo as a portfolio of coding ability.

**Agents / contributors:** setup, architecture, and credentials are documented here. Conventions (LogQL, dashboard UIDs, `node_exporter` model, kiosk) are in [CLAUDE.md](CLAUDE.md); PR norms in [CONTRIBUTING.md](CONTRIBUTING.md).

Git-driven observability for a Firewalla home network, powered by [Grafana
Cloud](https://grafana.com/products/cloud/) (free tier) on the visualization
side and a single [Grafana Alloy](https://grafana.com/docs/alloy/) container on
the ingestion side.

Everything is declarative:

- Dashboards live as JSON in [`dashboards/`](dashboards/).
- Cloud-side resources (folders, dashboards, future alerts) are managed by
  [Terraform](terraform/) with the [`grafana/grafana`](https://registry.terraform.io/providers/grafana/grafana/latest) provider.
- LXC-side ingestion is a single declarative [`alloy/config.alloy`](alloy/config.alloy)
  spun up by `docker compose`.

## Architecture

Node metrics **push** from each host (host-local Alloy → Mimir, 15s); the
central Alloy on the LXC handles only blackbox probes, the Home Assistant
scrape, and the Loki receiver. **Full rendered diagram, paths, and label
conventions: [docs/metrics-flow.md](docs/metrics-flow.md).**

```
  HOSTS ×6 (neptune, pve, pve2, pve3, pve4, pve5)
    each: node_exporter:9100 → local Alloy ── remote_write 15s ─┐
                                                                ├─▶ Grafana Cloud
  CENTRAL ALLOY (LXC 105)                                       │    (pitzilabs)
    blackbox ICMP/HTTP ───────────────── remote_write ─────────┤    ├─ Mimir (metrics)
    Home Assistant /api/prometheus → HA scrape → remote_write ──┤    ├─ Loki  (logs)
    Firewalla Promtail → Loki receiver :3100 ── loki push ──────┘    └─ Grafana
                                                                          │
                                                  public share ──▶ Office Display
```

## Repo layout

```
.envrc.example                 # template for direnv — copy to .envrc, fill in secrets
docker-compose.yml             # spins up Alloy on the LXC (one service)
alloy/
  config.alloy                 # Alloy collector config (scrape + push + receive)
  blackbox.yml                 # blackbox prober module definitions
  ha_token.example             # template; real ha_token is gitignored
alloy-host/                    # gitops deploy for the central Alloy on the LXC
  gitops-pull.sh               # 5-min pull + validate + reload-on-drift
  alloy-gitops.{service,timer} # systemd units (bootstrap-only)
  README.md                    # bootstrap + ops
dashboards/                    # source of truth for Grafana dashboard JSON
  network-overview.json
  dns-security.json
  traffic-devices.json
  infra-health.json
  office-display.json
  neptune-nas.json             # Neptune NAS real-time activity (CPU/disk/net/RAID/temps)
terraform/                     # manages Cloud-side resources
  *.tf
scripts/
  inventory-cloud.sh           # snapshot current state of pitzilabs.grafana.net
  deploy-node-exporter.sh      # install node_exporter on a host
  deploy-alloy.sh              # install a host-local Alloy push agent (15s remote_write)
.github/workflows/
  terraform.yml                # fmt/validate/plan on PR
```

## First-time setup

### 1. Grafana Cloud credentials

- **Stack service account** (drives Terraform + future CLI tooling). In
  `https://pitzilabs.grafana.net` → **Administration → Users and access → Service
  accounts**, create a service account named `terraform-iac` with role **Admin**,
  then **Add token** and copy the value. This becomes `GRAFANA_AUTH`.
- **Access policy tokens** (drive Alloy remote_write / log push). At
  `https://grafana.com` → **My Account → Access Policies**, create one policy
  with scopes **`metrics:write`** and **`logs:write`** for the `pitzilabs` stack.
  Generate a token; copy the **username** (a numeric stack ID per signal type)
  and **token** and the **push URLs** from the stack details page.

Drop all of the above into `.envrc`:

```bash
cp .envrc.example .envrc
$EDITOR .envrc           # fill in real values
direnv allow
```

### 2. Terraform — adopt Cloud-side resources

```bash
cd terraform
terraform init
terraform plan           # should show: import folder + 5 dashboards, then update them
terraform apply
```

After `apply`, back up `terraform/terraform.tfstate` to the NAS — it is not
committed to git (see [terraform/README.md](terraform/README.md) for the
rationale and recovery procedure).

The first apply rewrites datasource UIDs in each dashboard from `loki` /
`prometheus` (the old self-hosted UIDs) to `grafanacloud-pitzilabs-logs` /
`grafanacloud-pitzilabs-prom` (the pitzilabs stack's auto-provisioned UIDs).
The original JSON files in `dashboards/` are not modified — the rewrite happens
in-memory at apply time via `replace()` in `terraform/locals.tf`.

### 3. Delete orphan datasources in Cloud

The Cloud migration wizard created `loki` and `prometheus` datasources pointing
at the self-hosted LXC, which Grafana Cloud cannot reach. After `terraform
apply` repoints dashboards to `grafanacloud-*`, delete the orphans:

```bash
for uid in loki prometheus; do
  curl -sS -X DELETE \
    -H "Authorization: Bearer $GRAFANA_AUTH" \
    "$GRAFANA_URL/api/datasources/uid/$uid"
done
```

### 4. Alloy on the Proxmox LXC

```bash
# On the LXC (or any host with docker), in this repo:
cp alloy/ha_token.example alloy/ha_token
$EDITOR alloy/ha_token             # paste your HA long-lived access token
docker compose up -d
docker compose logs -f alloy       # confirm "remote_write succeeded" etc.
open http://<lxc-ip>:12345         # Alloy debug UI
```

After Alloy is up:

- Confirm logs arrive in Cloud: **Explore → grafanacloud-pitzilabs-logs** → `{cluster="homelab"}`.
- Confirm metrics arrive: **Explore → grafanacloud-pitzilabs-prom** →
  `up{cluster="homelab"}` should return 1 for each scrape target.
- Visit a dashboard (e.g. **Firewalla / Network Overview**) and confirm panels
  render data.

### 5. Office display (kiosk)

Grafana Cloud doesn't allow anonymous viewers. Use **public dashboard sharing**:

1. Open `firewalla-office-display` in the Cloud UI.
2. **Share → Public dashboard → Enable**.
3. Copy the public URL and point the kiosk Chromium at it.

The public URL bypasses auth for that one dashboard only; nothing else in the
stack is exposed.

### 6. CI

Add **repository** secrets (Settings → Secrets and variables → **Actions**,
not Dependabot) so the `terraform plan` job can authenticate to Grafana:

- `GRAFANA_URL` — full stack URL, e.g. `https://pitzilabs.grafana.net` (no
  trailing slash).
- `GRAFANA_AUTH` — the same Grafana Cloud **service account token** you use in
  `.envrc` as `GRAFANA_AUTH` / `GRAFANA_SA_TOKEN`.

Both must be non-empty. If either is missing, the plan job fails immediately
with a clear log message instead of a misleading Terraform provider error.

GitHub Actions runs `terraform fmt -check`, `validate`, and `plan` on every PR
that touches `terraform/**` or `dashboards/**`, and posts the plan as a PR
comment. Applies stay local.

## Day-to-day

### Edit a dashboard

1. Edit the JSON file in `dashboards/` (or edit in the Cloud UI and copy the
   exported JSON back into the file).
2. `cd terraform && terraform plan` → review diff → `terraform apply`.
3. Back up `terraform.tfstate` to the NAS.

### Add a new dashboard

1. Drop a new JSON file in `dashboards/`.
2. Add an entry to the `firewalla_dashboards` local in
   [`terraform/locals.tf`](terraform/locals.tf).
3. `terraform apply`.

### Add new scrape targets / new log sources

Edit [`alloy/config.alloy`](alloy/config.alloy), open a PR, merge. The central
Alloy on the grafana-stack LXC is **gitops-managed**: `alloy-gitops.timer`
pulls `origin/main` every 5 minutes, validates with `alloy fmt`, and reloads the
collector on drift (`SIGHUP` for `alloy/` changes, `docker compose up -d` for
compose changes). No hand-editing on the LXC — see
[`alloy-host/README.md`](alloy-host/README.md). To deploy immediately instead of
waiting for the timer: `systemctl start alloy-gitops.service` on the LXC.

### node_exporter

Bare-metal node_exporter on each host is the metric source. Run
`scripts/deploy-node-exporter.sh` against any new host you add. How those
metrics reach Grafana Cloud depends on the collection model below.

### Collection models: central pull vs. host-local push

There are two ways a host's node_exporter metrics get to Mimir, and the repo
supports both side by side with identical labels (`job="node"`,
`instance="<host>"`), so dashboards never care which is in use:

- **Central pull (default/legacy):** the Alloy on LXC 105 scrapes the host's
  `:9100` over the LAN. Add the host to the `prometheus.scrape "node"` target
  list in [`alloy/config.alloy`](alloy/config.alloy).
- **Host-local push (standardized):** the host runs its own Alloy that scrapes
  `localhost:9100` and `remote_write`s to Mimir at 15s. Tighter cadence,
  buffers across network blips, and each host owns its own shipping. Deploy
  with [`scripts/deploy-alloy.sh`](scripts/deploy-alloy.sh):

  ```bash
  source .envrc                     # exports GRAFANA_CLOUD_METRICS_*
  # on the target host (root, or via sudo):
  ./deploy-alloy.sh <instance-label>   # e.g. neptune, pve, pve3
  ```

  The script installs Alloy from the Grafana apt repo, writes
  `/etc/alloy/config.alloy` (canonical config embedded in the script) and a
  `0600 /etc/default/alloy` holding the push token, then enables the service.

**Don't run both for the same host** — that double-counts series. When you move
a host to push, delete it from the central `prometheus.scrape "node"` block.
The rollout target is neptune + all five Proxmox nodes on push; HAOS stays on
the central HA `/api/prometheus` scrape (it can't run a system Alloy).

### Series budget / HA export trim

Grafana Cloud free tier caps **active series at 15,000**. Home Assistant's
`/api/prometheus` export is the single biggest consumer — it emits a series
for nearly every entity plus per-entity change-counters, "last updated"
timestamps, availability flags, and `*_created` markers. None of that is used
by any dashboard, so the `prometheus.relabel "ha_trim"` component in
[`alloy/config.alloy`](alloy/config.alloy) drops those families before
remote_write, reclaiming ~5.8k series. The real numeric HA metrics
(temperatures, fan RPM, battery, climate, brightness, sensor states) are kept.

Check current usage with the `grafanacloud-usage` datasource:
`grafanacloud_instance_active_series`. If you add a host (each node_exporter is
~1.3k series), watch the headroom — trim more (e.g. node_exporter discard/flush
families) or the rollout will hit `err-mimir-max-active-series`.

### Check Loki label health

`scripts/check-loki-labels.sh` queries Loki for active `log_source` values over
the last 24h and diffs against the expected set (`zeek_dns`, `zeek_conn`,
`zeek_ssl`, `firewalla_acl`).  Run it manually as a sanity check, or wire it to
a cron / GitHub Actions schedule to alert on silent log streams:

```bash
source .envrc
./scripts/check-loki-labels.sh
```

Exits 0 when all four values are present; exits 1 and prints the missing names to
stderr otherwise.

## Why this layout

The original incarnation of this repo ran Loki, Prometheus, Grafana, and
blackbox-exporter all on a single LXC via `docker compose`, with file-based
provisioning. That worked but had three pain points:

1. **Storage on the LXC** — Prometheus TSDB + Loki chunks meant disk pressure
   and another thing to monitor.
2. **Dashboards drifted between repo and UI** — anything edited in the UI was
   lost on the next provisioner reload.
3. **No upgrade story** for Grafana itself — each `docker compose pull` was a
   gamble.

Migrating to Grafana Cloud free tier + Alloy fixes all three: storage moves to
the Cloud's free 50GB logs / 10K active series allotment; Terraform plus
checked-in dashboard JSON makes the repo the source of truth (UI edits get
overwritten on next apply); and Cloud handles Grafana upgrades.

## License

[MIT](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
