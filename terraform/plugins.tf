# terraform/plugins.tf
#
# Grafana Cloud plugin installations.
#
# This is the ONLY file in this repo that talks to the Grafana Cloud API rather
# than the stack API, and it needs its own credential to do so. The two are
# separate auth domains: GRAFANA_AUTH is a stack service-account token and can
# manage dashboards, datasources, folders, and alert rules, but it cannot install
# a plugin. Plugin installation is a Cloud-Portal operation gated by an access
# policy token with the stack-plugins:read / :write / :delete scopes.
#
# Why codify this at all: every other surface on this stack is terraform-enforced
# from this repo, and apply-on-merge reverts anything that is not. A hand-installed
# plugin would be live state with no source of truth — the exact failure mode that
# silently reverted a dashboard revamp in #119. If the plugin can be managed here,
# it should be.

variable "grafana_cloud_access_policy_token" {
  type        = string
  sensitive   = true
  description = "Grafana Cloud access policy token with stack-plugins:read/write/delete. Set via TF_VAR_grafana_cloud_access_policy_token; never committed (public repo)."

  validation {
    condition     = length(trimspace(var.grafana_cloud_access_policy_token)) > 0
    error_message = "The TF_VAR_grafana_cloud_access_policy_token secret resolved to an empty string. GitHub Actions renders a MISSING repo secret as empty rather than failing, so 'no default' alone does not catch an unset secret — this check does."
  }
}

variable "grafana_stack_slug" {
  type        = string
  default     = "lentago"
  description = "Grafana Cloud stack slug (the <slug>.grafana.net subdomain). Not a secret."
}

# Aliased provider: Cloud API auth, distinct from the default stack-scoped provider
# in providers.tf. Only the plugin-installation resource below uses it.
provider "grafana" {
  alias                     = "cloud"
  cloud_access_policy_token = var.grafana_cloud_access_policy_token
}

# The Axiom datasource plugin, required by grafana_data_source.solidago_axiom in
# datasources.tf. Version is pinned deliberately — an unpinned plugin would drift
# under us on every apply, and this is the query path for the site traffic panels.
#
# The pin must equal the version Grafana Cloud REPORTS as installed, not the one
# we asked for: `version` is ForceNew and the provider's Read stores the API's
# installed version. The original 0.7.0 pin came back from Cloud as 0.7.2, so
# every plan showed `version = "0.7.2" -> "0.7.0" # forces replacement` and
# reinstalled the plugin on every apply (#221). If that line reappears with a
# newer version on the left, Cloud has upgraded the plugin — bump this pin to it.
resource "grafana_cloud_plugin_installation" "axiom" {
  provider = grafana.cloud

  stack_slug = var.grafana_stack_slug
  slug       = "axiomhq-axiom-datasource"
  version    = "0.7.2"
}
