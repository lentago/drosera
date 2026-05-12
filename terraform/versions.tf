terraform {
  required_version = ">= 1.5.0" # `import` blocks land in 1.5

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 3.18"
    }
  }
}
