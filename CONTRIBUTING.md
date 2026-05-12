# Contributing

Personal homelab observability: **Grafana Cloud** + **Grafana Alloy** on a Proxmox LXC, with dashboards and Cloud resources driven from this git repo. Stability and clarity matter.

**Before opening a PR or asking setup questions**, read [README.md](README.md) (architecture, Promtail → Alloy → Cloud, credentials, Terraform apply, public kiosk) and [terraform/README.md](terraform/README.md) (state, imports).

## Reporting issues

Include:

- What you expected vs what happened
- Host OS and Docker / Compose versions (for Alloy on the LXC)
- Relevant logs: `docker compose logs alloy`
- For Cloud/Terraform: sanitized `terraform plan` output (no tokens)

## Pull requests

1. **Open an issue first** for non-trivial changes
2. **Keep scope small** — one fix or feature per PR
3. **Follow conventions** — dashboard UID pattern `firewalla-*`, schema v39 JSON without `__inputs`/`__requires`, `log_source` label usage in LogQL
4. **Dashboards** — edit JSON under [`dashboards/`](dashboards/) and wire through [`terraform/locals.tf`](terraform/locals.tf) / [`terraform/dashboards.tf`](terraform/dashboards.tf) as needed; do not rely on UI-only changes without updating the repo
5. **Don’t add Docker services** without discussion — the LXC is meant to stay at one Alloy container plus optional tiny helpers agreed in an issue

## Code of conduct

Be kind, be constructive, be respectful.
