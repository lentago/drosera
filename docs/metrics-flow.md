# Metrics & logs flow

How telemetry gets from the homelab into Grafana Cloud, after the move to
**host-local Alloy push** for node metrics (see README §
"Collection models"). This is the canonical flow diagram — the older
`docs/architecture.svg` predates the push model and is no longer accurate.

```mermaid
flowchart LR
  subgraph hosts["Homelab hosts (×6)"]
    direction TB
    names["neptune · pve · pve2<br/>pve3 · pve4 · pve5"]
    ne["node_exporter :9100"]
    agent["Alloy agent<br/>scrapes localhost, 15s"]
    ne --> agent
  end

  haos["Home Assistant (HAOS)<br/>/api/prometheus"]
  fw["Firewalla<br/>Promtail: Zeek + ACL logs"]

  subgraph central["Central Alloy — LXC 105 (grafana-stack)"]
    direction TB
    bb["blackbox probes<br/>ICMP / HTTP"]
    hascrape["HA scrape → ha_trim<br/>(drops export noise)"]
    lokirecv["loki.source.api :3100"]
  end

  subgraph cloud["Grafana Cloud (pitzilabs)"]
    direction TB
    mimir[("Mimir<br/>metrics")]
    lokidb[("Loki<br/>logs")]
    grafana["Grafana<br/>dashboards + Explore"]
    mimir --> grafana
    lokidb --> grafana
  end

  display["Office Display<br/>public dashboard share"]

  agent -- "remote_write 15s · job=node" --> mimir
  haos --> hascrape
  bb -- "remote_write · job=integrations/blackbox/*" --> mimir
  hascrape -- "remote_write · job=homeassistant" --> mimir
  fw -- "Loki push" --> lokirecv
  lokirecv -- "loki.write" --> lokidb
  grafana --> display

  classDef metric fill:#16683f,stroke:#39d98a,color:#fff;
  classDef logs fill:#7a4d00,stroke:#ffb020,color:#fff;
  classDef sink fill:#1d3b6b,stroke:#5b8def,color:#fff;
  class ne,agent,bb,hascrape,haos metric;
  class fw,lokirecv logs;
  class mimir,lokidb,grafana,display sink;
```

## The paths

**Node metrics (push).** Every host runs its own Alloy agent that scrapes the
local `node_exporter` on `127.0.0.1:9100` and `remote_write`s to Mimir every
15s, labelled `job="node"`, `instance="<host>"`. Hosts own and buffer their own
shipping; the central collector no longer pulls them. Deploy with
`scripts/deploy-alloy.sh`. *(Was: central Alloy scraped each host's `:9100` over
the LAN — replaced because it's tighter, buffers across blips, and scales.)*

**Blackbox probes (central).** The central Alloy runs ICMP/HTTP probes against
key LAN IPs + endpoints and `remote_write`s them as
`job="integrations/blackbox/<target>"`. Target list lives in
`alloy/config.alloy`.

**Home Assistant metrics (central).** The central Alloy scrapes HAOS's
`/api/prometheus`, routes it through the `ha_trim` relabel (drops ~5.8k series of
per-entity export noise — see README § "HA export trim"), and `remote_write`s
the rest as `job="homeassistant"`.

**Logs (central).** The Firewalla's Promtail pushes Zeek (DNS/conn) and ACL
logs to the central Alloy's `loki.source.api` on `:3100`; Alloy's `loki.write`
forwards to Grafana Cloud Loki with `cluster="homelab"`. *(Log shipping is the
next area to align.)*

**Consumption.** Dashboards (Terraform-managed, `dashboards/*.json`) and Explore
read Mimir + Loki. The public **Office Display** is a shared dashboard.

## Label conventions

| Source | job | key labels |
|---|---|---|
| Host node_exporter (push) | `node` | `instance` ∈ {neptune, pve, pve2, pve3, pve4, pve5} |
| Blackbox probe | `integrations/blackbox/<target>` | — |
| Home Assistant | `homeassistant` | `entity`, `friendly_name`, `domain` |
| Firewalla logs (Loki) | — | `log_source` ∈ {zeek_dns, zeek_conn, zeek_ssl, firewalla_acl}, `cluster="homelab"` |

## Deploy flow (config → collectors)

```mermaid
flowchart LR
  repo["Git: PitziLabs/homelab-observability (main)"]
  repo -- "terraform apply" --> dash["Grafana Cloud dashboards"]
  repo -- "alloy-gitops.timer (5 min, on the LXC)" --> central["Central Alloy config"]
  repo -- "deploy-alloy.sh (per host)" --> agents["Host Alloy agents"]
```

- **Dashboards** → `terraform apply` (manual; CI plans on PR).
- **Central Alloy** → gitops pull loop on LXC 105 (`alloy-host/`), auto-deploys
  merged `main` within ~5 min.
- **Host agents** → `scripts/deploy-alloy.sh <instance>` per host (one-time;
  config is embedded in the script).
