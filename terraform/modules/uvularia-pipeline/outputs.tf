output "dashboard_uid" {
  value       = grafana_dashboard.pipeline.uid
  description = "UID of the provisioned dashboard."
}

output "dashboard_url" {
  value       = grafana_dashboard.pipeline.url
  description = "URL of the provisioned dashboard."
}

output "rule_group_name" {
  value       = grafana_rule_group.pipeline.name
  description = "Name of the provisioned rule group."
}
