import os
import unittest

from pipeline_producer.config import Config, ConfigError, load_secrets

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
READ = {"DROSERA_LOKI_URL": "https://l", "DROSERA_LOKI_USER": "1", "DROSERA_LOKI_TOKEN": "t"}
WRITE = {"GRAFANA_CLOUD_LOGS_URL": "https://l", "GRAFANA_CLOUD_LOGS_USER": "1", "GRAFANA_CLOUD_LOGS_TOKEN": "w"}


class Configs(unittest.TestCase):
    def test_shipped_config(self):
        cfg = Config.load(os.path.join(HERE, "config.json"))
        self.assertEqual((cfg.interval_s, cfg.window_s, cfg.port), (30, 86400, 8611))
        self.assertIn("lentago/.github", cfg.terraform_repos)
        self.assertIn("lentago/solidago", cfg.terraform_repos)

    def test_overrides(self):
        cfg = Config({}).with_overrides("1m", "2h")
        self.assertEqual((cfg.interval_s, cfg.window, cfg.window_s), (60, "2h", 7200))

    def test_rejects(self):
        for raw in ({"interval": "30"}, {"interval": "1h", "window": "30m"}, {"port": 0},
                    {"cluster": "Lentago"}, {"terraform_repos": ["drosera"]}, {"budget_minutes": {"site": 0}}):
            with self.assertRaises(ConfigError, msg=raw):
                Config(raw)


class Secrets(unittest.TestCase):
    def test_read_token_always_required(self):
        with self.assertRaisesRegex(ConfigError, "DROSERA_LOKI_TOKEN"):
            load_secrets(push=False, env={**READ, "DROSERA_LOKI_TOKEN": ""})

    def test_write_token_only_when_pushing(self):
        self.assertEqual(set(load_secrets(push=False, env=READ)), set(READ))
        with self.assertRaisesRegex(ConfigError, "GRAFANA_CLOUD_LOGS_TOKEN"):
            load_secrets(push=True, env=READ)
        self.assertEqual(set(load_secrets(push=True, env={**READ, **WRITE})), set(READ) | set(WRITE))


if __name__ == "__main__":
    unittest.main()
