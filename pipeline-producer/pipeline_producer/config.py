"""Producer config (JSON, in git) and credentials (env file, never in git).

systemd fills the environment from the 0600 ``/etc/default/drosera-pipeline``
EnvironmentFile. Reads need a ``logs:read`` token, which the collectors'
``logs:write`` token on LXC 105 is not (it answers 401 to any read).
"""

import json
import os
import re

DEFAULT_CONFIG_PATH = "/etc/drosera-pipeline/config.json"

READ_ENV_VARS = ("DROSERA_LOKI_URL", "DROSERA_LOKI_USER", "DROSERA_LOKI_TOKEN")
WRITE_ENV_VARS = ("GRAFANA_CLOUD_LOGS_URL", "GRAFANA_CLOUD_LOGS_USER", "GRAFANA_CLOUD_LOGS_TOKEN")

# Same slug rule clients/loki_push.py applies to `cluster`.
_CLUSTER_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,62}")
_REPO_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
_DURATION_RE = re.compile(r"([1-9][0-9]*)([smhd])")
_UNIT_SECONDS = {"s": 1, "m": 60, "h": 3600, "d": 86400}


class ConfigError(ValueError):
    """The config file or the environment is unusable."""


def parse_duration(value, name):
    match = _DURATION_RE.fullmatch(str(value))
    if not match:
        raise ConfigError(f"{name} must look like '30s' or '24h', got {value!r}")
    return int(match.group(1)) * _UNIT_SECONDS[match.group(2)]


class Config:
    def __init__(self, raw):
        if not isinstance(raw, dict):
            raise ConfigError("config must be a JSON object")
        self.interval = str(raw.get("interval", "30s"))
        self.window = str(raw.get("window", "24h"))
        self.interval_s = parse_duration(self.interval, "interval")
        self.window_s = parse_duration(self.window, "window")
        if self.window_s <= self.interval_s:
            raise ConfigError("window must be longer than interval")
        self.listen = str(raw.get("listen", "0.0.0.0"))
        port = raw.get("port", 8611)
        if not isinstance(port, int) or not 0 < port < 65536:
            raise ConfigError(f"port {port!r} is not a TCP port")
        self.port = port
        self.cluster = raw.get("cluster", "lentago")
        if not isinstance(self.cluster, str) or not _CLUSTER_RE.fullmatch(self.cluster):
            raise ConfigError(f"cluster {self.cluster!r} must be a lowercase slug")
        self.producer = str(raw.get("producer", "drosera pipeline producer"))
        repos = raw.get("terraform_repos", [])
        if not isinstance(repos, list) or not all(isinstance(r, str) and _REPO_RE.fullmatch(r) for r in repos):
            raise ConfigError("terraform_repos must be a list of owner/name strings")
        self.terraform_repos = frozenset(repos)
        budgets = raw.get("budget_minutes", {})
        if not isinstance(budgets, dict):
            raise ConfigError("budget_minutes must be an object")
        self.budget_default = budgets.get("default", 10)
        self.budget_site = budgets.get("site", 20)
        for name, value in (("default", self.budget_default), ("site", self.budget_site)):
            if not isinstance(value, int) or value <= 0:
                raise ConfigError(f"budget_minutes.{name} must be a positive integer")

    def with_overrides(self, interval=None, window=None):
        """Apply --interval / --window from the command line."""
        if interval:
            self.interval, self.interval_s = interval, parse_duration(interval, "--interval")
        if window:
            self.window, self.window_s = window, parse_duration(window, "--window")
        if self.window_s <= self.interval_s:
            raise ConfigError("window must be longer than interval")
        return self

    @classmethod
    def load(cls, path):
        try:
            with open(path, encoding="utf-8") as fh:
                raw = json.load(fh)
        except (OSError, ValueError) as exc:
            raise ConfigError(f"cannot read config {path}: {exc}") from exc
        return cls(raw)


def load_secrets(push, env=None):
    """Return the credential values, or raise ConfigError naming what's missing.

    The read token is always required; the write token only when pushing.
    """
    env = os.environ if env is None else env
    wanted = READ_ENV_VARS + (WRITE_ENV_VARS if push else ())
    missing = [name for name in wanted if not env.get(name)]
    if missing:
        raise ConfigError("missing env var(s): " + ", ".join(missing))
    return {name: env[name] for name in wanted}
