"""The acceptance command, end to end against the fake Loki over real HTTP."""

import json
import os
import subprocess
import sys
import unittest
from datetime import datetime, timedelta, timezone

from tests.fakes import SHA_A, SHA_B, FakeLoki, job, live, run

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def recent(minutes_ago):
    # The CLI uses the wall clock, so these events sit inside the real window.
    return (datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


class Cli(unittest.TestCase):
    def setUp(self):
        self.loki = FakeLoki()
        main = run("lentago/drosera", "push", "main", SHA_B, 0, workflow="terraform")
        main.update(created_at=recent(30), updated_at=recent(29))
        apply = job("lentago/drosera", main, 0)
        apply["completed_at"] = recent(28)
        lv = live("lentago/drosera", "alloy-lxc105", SHA_A, 0)
        lv["applied_at"] = recent(1)
        self.loki.add_run(main)
        self.loki.add_job(apply)
        self.loki.add_live(lv)
        self.url = self.loki.start()

    def tearDown(self):
        self.loki.stop()

    def run_cli(self, *args, **env):
        base = {k: v for k, v in os.environ.items() if not k.startswith(("DROSERA_", "GRAFANA_"))}
        return subprocess.run(
            [sys.executable, "-B", "-m", "pipeline_producer", "--config", os.path.join(HERE, "config.json"), *args],
            cwd=HERE, env={**base, **env}, capture_output=True, text=True, timeout=30)

    def creds(self):
        return {"DROSERA_LOKI_URL": self.url, "DROSERA_LOKI_USER": "1", "DROSERA_LOKI_TOKEN": "fake"}

    def test_once_no_push_prints_a_schema_1_document(self):
        proc = self.run_cli("--once", "--no-push", "--out", "-", **self.creds())
        self.assertEqual(proc.returncode, 0, proc.stderr)
        doc = json.loads(proc.stdout)
        self.assertEqual(doc["schema"], 1)
        (repo,) = doc["repos"]
        self.assertEqual(repo["repo"], "lentago/drosera")
        self.assertEqual(repo["head"]["full_sha"], SHA_B)
        self.assertTrue(repo["in_flight"] and repo["stuck"])  # alloy still on SHA_A, 30 min > 10
        self.assertEqual(self.loki.pushes, [])

    def test_refuses_without_the_read_token(self):
        creds = {**self.creds(), "DROSERA_LOKI_TOKEN": ""}
        proc = self.run_cli("--once", "--no-push", "--out", "-", **creds)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("DROSERA_LOKI_TOKEN", proc.stderr)
        self.assertEqual(self.loki.reads, [])

    def test_failed_read_exits_1(self):
        self.loki.fail_reads = 401
        proc = self.run_cli("--once", "--no-push", "--out", "-", **self.creds())
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, "")

    def test_check_config(self):
        self.assertEqual(self.run_cli("--check-config").returncode, 0)


if __name__ == "__main__":
    unittest.main()
