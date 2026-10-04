variable "cluster" {
  type        = string
  description = "The owning org's slug — the `cluster` label on every uvularia event (e.g. \"lentago\"). Selects the dashboard's default org and scopes every alert query."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_-]*$", var.cluster))
    error_message = "cluster must be the lowercase org slug the emitters push as the cluster label."
  }
}

variable "folder_uid" {
  type        = string
  description = "UID of the Grafana folder that holds the dashboard and the rule group."
}

variable "contact_point" {
  type        = string
  description = "Name of an existing Grafana contact point the three rules route to."
}

variable "repeat_interval" {
  type        = string
  default     = "4h"
  description = "How often a still-firing rule re-notifies the contact point."
}

variable "group_by" {
  type        = list(string)
  default     = null
  description = "Labels to group notifications by. null keeps Grafana's default grouping."
}

variable "loki_datasource_uid" {
  type        = string
  default     = "grafanacloud-logs"
  description = "UID of the Loki datasource. Every Grafana Cloud stack provisions its logs datasource as grafanacloud-logs."
}

variable "dashboard_uid" {
  type        = string
  default     = "uvularia-pipeline"
  description = "UID for the dashboard. Load-bearing once links point at it; changing it is a destroy/create."
}

variable "rule_group_name" {
  type        = string
  default     = null
  description = "Rule group name. Defaults to \"Uvularia pipeline — <cluster>\" (names are unique per folder)."
}

variable "stale_digest_minutes" {
  type        = number
  default     = 30
  description = "Fire when the latest published digest has not been reported served for this many minutes."
}

variable "cap_alert_fraction" {
  type        = number
  default     = 0.2
  description = "Fire when the Ask function's remaining daily cap falls below this fraction of the day's cap."

  validation {
    condition     = var.cap_alert_fraction > 0 && var.cap_alert_fraction < 1
    error_message = "cap_alert_fraction must be between 0 and 1."
  }
}
