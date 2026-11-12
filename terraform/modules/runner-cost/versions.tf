terraform {
  # No providers: the module only renders text, so a test root can plan it
  # offline (scripts/tests/logql/render.sh).
  required_version = ">= 1.5.0"
}
