"""State rules — the fixtures #266 lists, plus the edges the panel query implies."""

import json
import os
import unittest
from datetime import timedelta

from pipeline_producer import state
from pipeline_producer.config import Config
from tests.fakes import BASE, SHA_A, SHA_B, SHA_PR, at, job, live, parsed, run

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = Config.load(os.path.join(HERE, "config.json"))
DROSERA = "lentago/drosera"
SITE = "lentago/site-example-com"
KALMIA = "lentago/kalmia"


def compute(runs=(), jobs=(), lives=(), minute=30):
    return state.build_document(parsed(runs), parsed(jobs), parsed(lives),
                                BASE + timedelta(minutes=minute), CFG)


def repo(doc, name):
    return next(r for r in doc["repos"] if r["repo"] == name)


def stages(doc, name):
    return {s["stage"]: s for s in repo(doc, name)["stages"]}


def green_drosera():
    """PR on SHA_PR, merged as SHA_B, applied, live on alloy-lxc105."""
    pr1 = run(DROSERA, "pull_request", "agent/x", SHA_PR, 0, workflow="ShellCheck")
    pr2 = run(DROSERA, "pull_request", "agent/x", SHA_PR, 1, workflow="Docs Check")
    main = run(DROSERA, "push", "main", SHA_B, 4, workflow="terraform")
    apply = job(DROSERA, main, 5)
    lv = live(DROSERA, "alloy-lxc105", SHA_B, 7, result="applied")
    return [pr1, pr2, main], [apply], [lv]


class GreenRepo(unittest.TestCase):
    def setUp(self):
        runs, jobs, lives = green_drosera()
        self.doc = compute(runs, jobs, lives, minute=8)
        self.repo = repo(self.doc, DROSERA)
        self.s = stages(self.doc, DROSERA)

    def test_every_stage(self):
        self.assertEqual([s["stage"] for s in self.repo["stages"]], list(state.STAGES))
        self.assertEqual({k: v["state"] for k, v in self.s.items()},
                         {"pushed": 3, "pr_open": 0, "checks_green": 3, "merged": 3, "applied": 3, "live": 3})

    def test_stage_details(self):
        self.assertEqual(self.s["pushed"]["sha"], SHA_PR[:7])
        self.assertEqual(self.s["pushed"]["detail"], "agent/x")
        self.assertEqual(self.s["pr_open"]["detail"], "no PR newer than main")
        self.assertEqual(self.s["pr_open"]["url"],
                         "https://github.com/lentago/drosera/pulls?q=is:pr+head:agent/x")
        self.assertEqual(self.s["merged"], {
            "stage": "merged", "state": 3, "sha": SHA_B[:7], "detail": "main", "when": at(3),
            "url": f"https://github.com/lentago/drosera/commit/{SHA_B}"})
        self.assertEqual(self.s["applied"]["detail"], "apply · success")
        self.assertEqual(self.s["live"]["detail"], "alloy-lxc105 · applied")
        self.assertEqual(self.s["live"]["when"], at(7))

    def test_squash_merge_shas_differ(self):
        # ADR-0010: the pre-merge half keys on the PR head, the rest on the merge commit.
        self.assertEqual(self.s["checks_green"]["sha"], SHA_PR[:7])
        self.assertEqual(self.s["merged"]["sha"], SHA_B[:7])

    def test_head_and_flight(self):
        self.assertEqual(self.repo["head"], {
            "sha": SHA_B[:7], "full_sha": SHA_B, "merged_at": at(3),
            "url": f"https://github.com/lentago/drosera/commit/{SHA_B}"})
        self.assertFalse(self.repo["in_flight"])
        self.assertIsNone(self.repo["in_flight_since"])
        self.assertFalse(self.repo["stuck"])
        self.assertEqual(self.repo["budget_minutes"], 10)
        self.assertEqual(self.repo["surfaces"], [
            {"surface": "alloy-lxc105", "sha": SHA_B[:7], "state": 3, "result": "applied", "when": at(7)}])

    def test_document_envelope(self):
        self.assertEqual(self.doc["schema"], 1)
        self.assertEqual(self.doc["window"], "24h")
        self.assertEqual(self.doc["generated_at"], at(8))
        self.assertEqual(set(self.doc), {"schema", "generated_at", "producer", "window", "repos"})
        json.dumps(self.doc)  # serialisable: no datetimes or private keys left behind


class PrOpen(unittest.TestCase):
    def test_pr_newer_than_main(self):
        runs, jobs, lives = green_drosera()
        runs.append(run(DROSERA, "pull_request", "agent/y", SHA_A, 12, workflow="ShellCheck"))
        s = stages(compute(runs, jobs, lives, minute=13), DROSERA)
        self.assertEqual(s["pr_open"]["state"], 1)
        self.assertEqual(s["pr_open"]["detail"], "awaiting merge")
        self.assertEqual(s["pushed"]["detail"], "agent/y")
        self.assertEqual(s["checks_green"]["sha"], SHA_A[:7])

    def test_pr_with_no_main_push_in_window(self):
        s = stages(compute([run(DROSERA, "pull_request", "agent/y", SHA_PR, 2)]), DROSERA)
        self.assertEqual(s["pr_open"]["state"], 1)
        self.assertEqual((s["merged"]["state"], s["merged"]["sha"]), (0, None))

    def test_no_pr_is_no_signal(self):
        s = stages(compute([run(DROSERA, "push", "main", SHA_B, 2)]), DROSERA)
        for name in ("pushed", "pr_open", "checks_green"):
            self.assertEqual(s[name], {"stage": name, "state": 0, "sha": None, "detail": None,
                                       "when": None, "url": None})


class ChecksGreen(unittest.TestCase):
    def test_worst_latest_attempt_per_workflow(self):
        runs = [
            run(DROSERA, "pull_request", "agent/x", SHA_PR, 0, workflow="A", conclusion="failure", run_id=1),
            run(DROSERA, "pull_request", "agent/x", SHA_PR, 2, workflow="A", conclusion="success", run_id=1, attempt=2),
            run(DROSERA, "pull_request", "agent/x", SHA_PR, 1, workflow="B", conclusion="cancelled"),
            run(DROSERA, "pull_request", "agent/x", SHA_PR, 1, workflow="C", conclusion="skipped"),
            # an older PR SHA's failure doesn't count against the newest one
            run(DROSERA, "pull_request", "agent/x", SHA_A, -5, workflow="D", conclusion="failure"),
        ]
        s = stages(compute(runs), DROSERA)["checks_green"]
        self.assertEqual((s["state"], s["detail"]), (1, "B · cancelled"))

    def test_lowest_code_wins_like_the_panels_bottomk(self):
        runs = [
            run(DROSERA, "pull_request", "agent/x", SHA_PR, 0, workflow="A", conclusion="failure"),
            run(DROSERA, "pull_request", "agent/x", SHA_PR, 1, workflow="B", conclusion="success"),
        ]
        self.assertEqual(stages(compute(runs), DROSERA)["checks_green"]["state"], 2)
        # bottomk ranks by the code, so a cancelled run (1) outranks a failure (2)
        runs.append(run(DROSERA, "pull_request", "agent/x", SHA_PR, 2, workflow="C", conclusion="cancelled"))
        self.assertEqual(stages(compute(runs), DROSERA)["checks_green"]["state"], 1)

    def test_only_skipped_is_no_signal(self):
        runs = [run(DROSERA, "pull_request", "agent/x", SHA_PR, 0, conclusion="skipped")]
        s = stages(compute(runs), DROSERA)
        self.assertEqual(s["pushed"]["state"], 3)
        self.assertEqual((s["checks_green"]["state"], s["checks_green"]["sha"]), (0, None))


class Applied(unittest.TestCase):
    def test_docs_only_merge_in_path_filtered_repo(self):
        # SHA_A ran terraform and applied; the docs-only SHA_B only ran Docs
        # Check, so there's no apply on head. alloy still reports SHA_B.
        main_a = run(DROSERA, "push", "main", SHA_A, 2, workflow="terraform")
        main_b = run(DROSERA, "push", "main", SHA_B, 10, workflow="Docs Check")
        doc = compute([main_a, main_b], [job(DROSERA, main_a, 4)],
                      [live(DROSERA, "alloy-lxc105", SHA_B, 12, result="applied")], minute=13)
        s = stages(doc, DROSERA)
        self.assertEqual((s["applied"]["state"], s["applied"]["sha"]), (0, None))
        self.assertEqual(s["merged"]["sha"], SHA_B[:7])
        self.assertEqual(s["live"]["state"], 3)
        self.assertFalse(repo(doc, DROSERA)["in_flight"])

    def test_failed_push_to_main_deploy(self):
        main_a = run(DROSERA, "push", "main", SHA_A, 0, workflow="terraform")
        main_b = run(DROSERA, "push", "main", SHA_B, 10, workflow="terraform", conclusion="failure")
        jobs = [job(DROSERA, main_a, 1), job(DROSERA, main_b, 11, conclusion="failure")]
        lives = [live(DROSERA, "alloy-lxc105", SHA_A, 2, result="applied"),
                 live(DROSERA, "alloy-lxc105", SHA_A, 14)]
        for minute, stuck in ((15, False), (20, True)):
            doc = compute([main_a, main_b], jobs, lives, minute=minute)
            r, s = repo(doc, DROSERA), stages(doc, DROSERA)
            self.assertEqual(s["applied"]["state"], 2)
            self.assertEqual(s["applied"]["detail"], "apply · failure")
            self.assertTrue(r["in_flight"])
            self.assertEqual(r["in_flight_since"], at(9))  # main_b's created_at
            self.assertEqual(r["stuck"], stuck, minute)  # budget 10 min from 9

    def test_failed_site_deploy_uses_the_workflow(self):
        main = run(SITE, "push", "main", SHA_B, 10, workflow="Deploy", conclusion="failure")
        doc = compute([main], [], [live(SITE, "site-example-com", SHA_A, 12)], minute=40)
        r, s = repo(doc, SITE), stages(doc, SITE)
        self.assertEqual((s["applied"]["state"], s["applied"]["detail"]), (2, "Deploy · failure"))
        self.assertEqual(r["budget_minutes"], 20)
        self.assertTrue(r["stuck"])

    def test_terraform_apply_job_name_variants(self):
        for name in ("apply", "Terraform Apply", "terraform / apply", "tf / Terraform apply"):
            main = run(DROSERA, "push", "main", SHA_B, 2, workflow="terraform")
            s = stages(compute([main], [job(DROSERA, main, 3, name=name)]), DROSERA)
            self.assertEqual(s["applied"]["state"], 3, name)
        main = run(DROSERA, "push", "main", SHA_B, 2, workflow="terraform")
        jobs = [job(DROSERA, main, 3, name="plan"), job(DROSERA, main, 3, name="apply", conclusion="skipped")]
        self.assertEqual(stages(compute([main], jobs), DROSERA)["applied"]["state"], 0)

    def test_job_without_its_run_is_ignored(self):
        main = run(DROSERA, "push", "main", SHA_B, 2)
        orphan = job(DROSERA, {**main, "run_id": 42}, 3)
        self.assertEqual(stages(compute([main], [orphan]), DROSERA)["applied"]["state"], 0)


class Live(unittest.TestCase):
    def test_surface_lagging_behind_head(self):
        main = run(DROSERA, "push", "main", SHA_B, 10)
        lives = [live(DROSERA, "alloy-lxc105", SHA_A, 12)]
        doc = compute([main], [], lives, minute=13)
        s = stages(doc, DROSERA)["live"]
        self.assertEqual((s["state"], s["sha"], s["detail"]), (1, SHA_A[:7], "alloy-lxc105 · noop"))
        self.assertTrue(repo(doc, DROSERA)["in_flight"])

    def test_two_surfaces_one_lags_worst_wins(self):
        main = run(SITE, "push", "main", SHA_B, 10, workflow="Deploy")
        lives = [live(SITE, "site-a", SHA_B, 15, result="applied"), live(SITE, "site-b", SHA_A, 16)]
        doc = compute([main], [], lives, minute=17)
        r = repo(doc, SITE)
        self.assertEqual(stages(doc, SITE)["live"]["state"], 1)
        self.assertEqual(stages(doc, SITE)["live"]["detail"], "site-b · noop")
        self.assertEqual([(x["surface"], x["state"]) for x in r["surfaces"]], [("site-a", 3), ("site-b", 1)])
        # one surface already runs head, so the change has landed somewhere
        self.assertFalse(r["in_flight"])

    def test_newest_event_per_surface(self):
        main = run(DROSERA, "push", "main", SHA_B, 10)
        lives = [live(DROSERA, "alloy-lxc105", SHA_A, 5), live(DROSERA, "alloy-lxc105", SHA_B, 12, "applied")]
        doc = compute([main], [], lives, minute=13)
        self.assertEqual(stages(doc, DROSERA)["live"]["state"], 3)
        self.assertEqual(len(repo(doc, DROSERA)["surfaces"]), 1)

    def test_surface_past_the_visible_head_is_not_in_flight(self):
        # SHA_B merged and went live; a later docs-only merge (no push run)
        # moved alloy on to SHA_A. live reads 1 (the panel's rule) but the
        # head did land, so nothing is in flight.
        main = run(DROSERA, "push", "main", SHA_B, 2)
        lives = [live(DROSERA, "alloy-lxc105", SHA_B, 4, "applied"), live(DROSERA, "alloy-lxc105", SHA_A, 30, "applied")]
        doc = compute([main], [], lives, minute=60)
        self.assertEqual(stages(doc, DROSERA)["live"]["state"], 1)
        self.assertFalse(repo(doc, DROSERA)["in_flight"])

    def test_rolled_back_head_stays_in_flight(self):
        main = run(DROSERA, "push", "main", SHA_B, 2)
        rolled = {**live(DROSERA, "alloy-lxc105", SHA_A, 4, "rolled_back"), "previous_sha": SHA_B}
        doc = compute([main], [], [rolled], minute=30)
        self.assertTrue(repo(doc, DROSERA)["stuck"])

    def test_repo_with_no_surface_is_never_in_flight(self):
        main = run(KALMIA, "push", "main", SHA_B, 0, workflow="terraform")
        doc = compute([main], [job(KALMIA, main, 1, conclusion="failure")], [], minute=600)
        r, s = repo(doc, KALMIA), stages(doc, KALMIA)
        self.assertEqual((s["live"]["state"], s["live"]["sha"]), (0, None))
        self.assertEqual(r["surfaces"], [])
        self.assertFalse(r["in_flight"])
        self.assertFalse(r["stuck"])


class Document(unittest.TestCase):
    def test_repos_sorted_and_any_event_counts(self):
        doc = compute([run(SITE, "push", "main", SHA_A, 1)], [],
                      [live(DROSERA, "alloy-lxc105", SHA_A, 1), live(KALMIA, "x", SHA_A, 1)])
        self.assertEqual([r["repo"] for r in doc["repos"]], [DROSERA, KALMIA, SITE])
        self.assertIsNone(repo(doc, DROSERA)["head"])
        self.assertFalse(repo(doc, DROSERA)["in_flight"])

    def test_state_streams(self):
        runs, jobs, lives = green_drosera()
        doc = compute(runs, jobs, lives, minute=8)
        streams = state.state_streams(doc, "lentago", 1_000)
        self.assertEqual(len(streams), 1)
        self.assertEqual(streams[0]["stream"],
                         {"log_source": "change_pipeline_state", "cluster": "lentago", "repo": DROSERA})
        values = streams[0]["values"]
        self.assertEqual([v[0] for v in values], [str(1_000 + i) for i in range(6)])
        lines = [json.loads(v[1]) for v in values]
        self.assertEqual([l["stage"] for l in lines], list(state.STAGES))
        self.assertEqual(set(lines[0]), {"stage", "state", "sha", "detail", "when", "url", "head", "in_flight", "stuck"})
        self.assertEqual(lines[5]["head"], SHA_B[:7])


if __name__ == "__main__":
    unittest.main()
