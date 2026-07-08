terraform {
  # Remote state in solidago's S3 backend (formerly foundry-platform-demo) — shared account, isolated key.
  # CI authenticates to AWS via the homelab-observability-github-actions-terraform
  # OIDC role (S3 r/w on this key + the lock table only). See terraform/README.md.
  # The role name and state key keep the pre-rename homelab-observability prefix
  # (repo renamed to drosera 2026-07-04) — do not rename them; the key would orphan state.
  backend "s3" {
    bucket         = "solidago-tfstate-365184644049"
    key            = "homelab-observability/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "solidago-tfstate-lock"
    encrypt        = true
  }
}
