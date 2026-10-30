terraform {
  # Remote state in solidago's S3 backend (formerly foundry-platform-demo) — shared account, isolated key.
  # CI authenticates to AWS via the drosera-github-actions-terraform OIDC role
  # (defined in solidago's modules/iam; S3 get/put on this key + the lock table
  # only). See terraform/README.md. The key moved from
  # homelab-observability/terraform.tfstate in #169 (a version-pinned S3 copy plus
  # its lock-table digest). Changing it again needs a state copy first, or the
  # next apply starts from empty state (the workflow's empty-state guard stops it).
  backend "s3" {
    bucket         = "solidago-tfstate-365184644049"
    key            = "drosera/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "solidago-tfstate-lock"
    encrypt        = true
  }
}
