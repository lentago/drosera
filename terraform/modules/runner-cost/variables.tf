variable "pricing_json" {
  type        = string
  description = "Text of claude-cost-export/pricing.json, the fleet's price table. Only rows with a `runtime` other than claude are rendered; Claude jobs report their own cost."
}

variable "dashboard_json" {
  type        = string
  description = "Text of a dashboard JSON file whose panel expressions carry the placeholder where the cost stage goes."
}

variable "placeholder" {
  type        = string
  default     = "__RUNNER_JOB_COST__"
  description = "Token in the dashboard JSON that the rendered LogQL stage replaces. It stands where a pipeline stage goes, inside a JSON string."
}
