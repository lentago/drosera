# terraform/service_accounts.tf
#
# Stack service accounts that something outside this repo authenticates as.
# Terraform defines the account and its role; it never mints the account's
# tokens. A `grafana_service_account_token` would put the key in remote state
# (solidago's shared S3 bucket), and the token has to be copied to its host by
# hand either way. So tokens are minted in the stack UI under the account
# defined here, per lentago/.github ADR-0011 rule 4 ("Terraform holds slots,
# not values"). The provider does not track tokens it did not create, so later
# applies leave a hand-minted token alone.
#
# Destroying or replacing one of these accounts revokes every token under it.
# Don't rename a resource address here without a `moved` block.
#
# CI's own credential (`terraform-iac`, Admin) is deliberately NOT managed here:
# the credential Terraform authenticates with stays outside the config it drives.

# The brasenia wall display renders dashboards into panes through the stack's
# render API (`GET /render/d/<uid>`) with this account's token, held on pub as
# a systemd credential (lentago/brasenia ADR-0017, #287). Viewer is the smallest
# built-in role that can render. It can read every dashboard in the stack, and
# every dashboard sits in the one `Lentago` folder (ADR-0007), so a
# folder-scoped grant would not narrow it. Minting and placing the token:
# terraform/README.md § Service accounts.
resource "grafana_service_account" "brasenia_viewer" {
  name        = "brasenia-viewer"
  role        = "Viewer"
  is_disabled = false
}
