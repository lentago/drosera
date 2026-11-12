output "stage" {
  description = "The LogQL label_format stage that sets `cost` on a job_complete line (see main.tf)."
  value       = local.stage
}

output "dashboard_json" {
  description = "var.dashboard_json with every placeholder replaced by the stage."
  value       = replace(var.dashboard_json, var.placeholder, local.stage_json)

  precondition {
    condition     = strcontains(var.dashboard_json, var.placeholder)
    error_message = "The dashboard JSON does not contain ${var.placeholder}, so no panel would be priced."
  }

  precondition {
    condition = alltrue([
      for id, r in local.rows : can(r.prices[0]) && alltrue([
        for i, p in r.prices :
        can(tonumber(p.input)) && can(tonumber(p.cached_input)) && can(tonumber(p.output))
        && (try(p.cache_write, null) == null || can(tonumber(p.cache_write)))
        && (i == 0 ? !can(p.from) : can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", p.from)))
      ])
    ])
    error_message = "Every runner row in pricing.json needs a non-empty `prices` list. Each entry needs numeric input, cached_input and output (and cache_write, if any); the first entry has no `from`, and every later entry has a `from` date YYYY-MM-DD."
  }

  precondition {
    condition = alltrue([
      for id, r in local.rows : (
        join(",", sort([for p in slice(r.prices, 1, length(r.prices)) : p.from]))
        == join(",", [for p in slice(r.prices, 1, length(r.prices)) : p.from])
        && length(distinct([for p in slice(r.prices, 1, length(r.prices)) : p.from])) == length(r.prices) - 1
      )
    ])
    error_message = "A runner row's `prices` entries must run in strictly increasing `from` order."
  }

  precondition {
    condition     = length(distinct(values(local.label))) == length(local.label)
    error_message = "Two runner rows flatten to the same LogQL label (characters outside [a-zA-Z0-9_] become \"_\"), so their tokens cannot be told apart."
  }
}
