terraform {
  # Remote state in foundry-platform-demo's S3 backend (shared account, isolated key).
  # CI authenticates to AWS via the homelab-observability-github-actions-terraform
  # OIDC role (S3 r/w on this key + the lock table only). See terraform/README.md.
  backend "s3" {
    bucket         = "foundry-tfstate-365184644049"
    key            = "homelab-observability/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "foundry-tfstate-lock"
    encrypt        = true
  }
}
