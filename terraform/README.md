# Terraform — Grafana Cloud

Manages everything in the `pitzilabs` Grafana Cloud stack as code: dashboards, folders,
data sources, contact points, notification policies, alert rules, and service accounts.

Dashboard JSON files live in [`../dashboards/`](../dashboards/) and are the source of truth.
Terraform rewrites the original self-hosted datasource UIDs (`loki`, `prometheus`) to the
Grafana Cloud equivalents (`grafanacloud-logs`, `grafanacloud-prom`) at apply time, so the
JSON files stay portable.
Terraform reads them via `file()` and pushes them to Grafana Cloud — never the other way
around. Drift introduced via the Grafana UI gets overwritten on the next `apply`.

## State

Local state, **not** checked into git (see root `.gitignore`). Back up `terraform.tfstate`
to the NAS after each successful `apply`. If the laptop dies before backup, the state can be
reconstructed by re-running `terraform import` for each resource — the imports are
idempotent because every resource has a stable UID.

## Prerequisites

- Terraform `>= 1.5` (for `import` blocks)
- direnv loading `../.envrc` so `GRAFANA_URL` and `GRAFANA_AUTH` are in your shell
- Service account token in `GRAFANA_AUTH` with **Admin** role on the stack

## Day-to-day

```bash
cd terraform
terraform init           # one time, or after provider version bumps
terraform plan           # show drift / pending changes
terraform apply          # apply pending changes
```

## Adopting a new resource that already exists in Cloud

1. Add an `import` block in `imports.tf`:

   ```hcl
   import {
     to = grafana_dashboard.my_new_dashboard
     id = "my-dashboard-uid"
   }
   ```

2. Add the matching `resource` definition in the appropriate `.tf` file.
3. Run `terraform plan` — it should show "1 to import, 0 to add" with no diff.
4. Run `terraform apply`.
5. (Optional) Remove the `import` block once the resource is in state.

## Creating a new dashboard from scratch

1. Drop a JSON file in `../dashboards/`.
2. Add an entry to the `firewalla_dashboards` map in [`locals.tf`](locals.tf) (the `grafana_dashboard` resource uses `for_each` over that map in [`dashboards.tf`](dashboards.tf)).
3. Add a matching `import` block in [`imports.tf`](imports.tf) if the dashboard was already created in the UI (otherwise Terraform creates it on first apply).
4. `terraform apply`.
