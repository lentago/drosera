"""Compute the schema-1 pipeline document from parsed Loki events.

The rules mirror the "By repo" panel of dashboards/change-pipeline.json, which
stays the reference until it reads the ``change_pipeline_state`` stream this
producer writes. The model is ADR-0010: six stages in two SHA-joined halves
(``pushed → pr_open → checks_green`` on the PR head SHA,
``merged → applied → live`` on the merge commit), because the fleet
squash-merges.

State codes are the dashboard's: 3 current/success, 2 failed, 1 waiting or
lagging, 0 no signal.
"""

import json
import re
from datetime import datetime, timezone

SCHEMA = 1
STAGES = ("pushed", "pr_open", "checks_green", "merged", "applied", "live")

# LogQL label matchers are anchored, so the panel's
# job_name=~"(?i)(.* / )?(terraform )?apply" is a fullmatch here.
APPLY_JOB_RE = re.compile(r"(?i)(.* / )?(terraform )?apply")


def parse_ts(value):
    """RFC 3339 (``2026-10-07T21:11:31Z`` or ``…+00:00``) → aware UTC datetime, or None."""
    if not value or not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if dt else None


def short(sha):
    return sha[:7] if sha else None


def same_sha(a, b):
    """Full SHAs compare exactly; a short SHA (≥7) matches as a prefix."""
    if not a or not b:
        return False
    a, b = a.lower(), b.lower()
    n = min(len(a), len(b))
    return n >= 7 and a[:n] == b[:n]


def conclusion_state(conclusion):
    return 3 if conclusion == "success" else 2 if conclusion == "failure" else 1


def commit_url(repo, sha):
    return f"https://github.com/{repo}/commit/{sha}"


def _at(event, field):
    """An event's timestamp field, falling back to the Loki entry time."""
    return parse_ts(event.get(field)) or event["_ts"]


def _newest(events, field):
    return max(events, key=lambda e: _at(e, field), default=None)


def _stage(stage, state=0, sha=None, detail=None, when=None, url=None):
    return {"stage": stage, "state": state, "sha": short(sha), "detail": detail,
            "when": iso(when), "url": url}


def _is_pr_run(run):
    return run.get("event") == "pull_request" and run.get("branch") != "main"


def _is_main_push(run):
    return run.get("event") == "push" and run.get("branch") == "main"


def _pushed(repo, newest_pr):
    if not newest_pr:
        return _stage("pushed")
    sha = newest_pr.get("head_sha")
    return _stage("pushed", 3, sha, newest_pr.get("branch"), _at(newest_pr, "updated_at"),
                  commit_url(repo, sha))


def _pr_open(repo, newest_pr, newest_main):
    # The feed carries no PR number yet (betula#133), so this can only say a PR
    # run is newer than main. It never claims a merge or a close.
    if not newest_pr:
        return _stage("pr_open")
    when = _at(newest_pr, "updated_at")
    newer = newest_main is None or when > _at(newest_main, "created_at")
    state, detail = (1, "awaiting merge") if newer else (0, "no PR newer than main")
    url = f"https://github.com/{repo}/pulls?q=is:pr+head:{newest_pr.get('branch')}"
    return _stage("pr_open", state, newest_pr.get("head_sha"), detail, when, url)


def _checks_green(pr_runs, newest_pr):
    """Worst of the latest attempt of every non-skipped workflow on the newest PR SHA."""
    if not newest_pr:
        return _stage("checks_green")
    sha = newest_pr.get("head_sha")
    latest = {}
    for run in pr_runs:
        if not same_sha(run.get("head_sha"), sha) or run.get("conclusion") == "skipped":
            continue
        key = run.get("workflow")
        rank = (_at(run, "updated_at"), run.get("run_attempt") or 0)
        if key not in latest or rank > latest[key][0]:
            latest[key] = (rank, run)
    if not latest:
        return _stage("checks_green")
    # Worst = lowest code, as the panel's bottomk ranks it (so 1 outranks 2);
    # among equals, the newest run speaks for the stage.
    _, run = min(latest.values(), key=lambda v: (conclusion_state(v[1].get("conclusion")), _neg(v[0][0])))
    conclusion = run.get("conclusion")
    return _stage("checks_green", conclusion_state(conclusion), run.get("head_sha"),
                  f"{run.get('workflow')} · {conclusion}", _at(run, "updated_at"), run.get("html_url"))


def _neg(dt):
    return -dt.timestamp()


def _merged(repo, newest_main):
    if not newest_main:
        return _stage("merged")
    sha = newest_main.get("head_sha")
    return _stage("merged", 3, sha, "main", _at(newest_main, "created_at"), commit_url(repo, sha))


def _applied(repo, runs, jobs, main_pushes, head, terraform):
    """terraform repos: the newest apply job; others: the newest push-to-main run.

    Either way it only counts when it ran on the head SHA, so a merge that
    triggered no apply (a docs-only change in a path-filtered repo) reads 0.
    """
    if terraform:
        run_sha = {(str(r.get("run_id")), str(r.get("run_attempt"))): r.get("head_sha") for r in runs}
        applies = []
        for job in jobs:
            if job.get("conclusion") == "skipped" or not APPLY_JOB_RE.fullmatch(job.get("job_name") or ""):
                continue
            sha = run_sha.get((str(job.get("run_id")), str(job.get("run_attempt"))))
            if sha and parse_ts(job.get("completed_at")):
                applies.append((job, sha))
        if not applies:
            return _stage("applied")
        job, sha = max(applies, key=lambda a: parse_ts(a[0]["completed_at"]))
        if not same_sha(sha, head):
            return _stage("applied")
        conclusion = job.get("conclusion")
        return _stage("applied", conclusion_state(conclusion), sha, f"{job.get('job_name')} · {conclusion}",
                      parse_ts(job["completed_at"]), job.get("html_url"))
    run = _newest(main_pushes, "updated_at")
    if not run or not same_sha(run.get("head_sha"), head):
        return _stage("applied")
    conclusion = run.get("conclusion")
    return _stage("applied", conclusion_state(conclusion), run.get("head_sha"),
                  f"{run.get('workflow')} · {conclusion}", _at(run, "updated_at"), run.get("html_url"))


def _surfaces(lives, head):
    """The newest live event per surface: 3 when it runs the head SHA, else 1."""
    newest = {}
    for event in lives:
        name = event.get("surface")
        if name and (name not in newest or _at(event, "applied_at") >= _at(newest[name], "applied_at")):
            newest[name] = event
    out = []
    for name in sorted(newest):
        event = newest[name]
        out.append({"surface": name, "sha": short(event.get("sha")),
                    "state": 3 if same_sha(event.get("sha"), head) else 1,
                    "result": event.get("result"), "when": iso(_at(event, "applied_at")),
                    "_event": event})
    return out


def _live(repo, surfaces):
    if not surfaces:
        return _stage("live")
    # Worst surface wins; among equals, the most recent report.
    worst = min(surfaces, key=lambda s: (s["state"], _neg(_at(s["_event"], "applied_at"))))
    event = worst["_event"]
    return _stage("live", worst["state"], event.get("sha"), f"{worst['surface']} · {event.get('result')}",
                  _at(event, "applied_at"), commit_url(repo, event.get("sha")))


def budget_minutes(repo, surfaces, cfg):
    """ADR-0010 propagation budget: sites get the longer one."""
    if repo.split("/", 1)[-1].startswith("site-") or any(s["surface"].startswith("site-") for s in surfaces):
        return cfg.budget_site
    return cfg.budget_default


def repo_state(repo, runs, jobs, lives, now, cfg):
    pr_runs = [r for r in runs if _is_pr_run(r)]
    main_pushes = [r for r in runs if _is_main_push(r)]
    newest_pr = _newest(pr_runs, "updated_at")
    newest_main = _newest(main_pushes, "created_at")
    # Head = the newest push-to-main run's SHA. A branch-head event from betula
    # would see merges that trigger no push workflow; prefer it once it exists.
    head = newest_main.get("head_sha") if newest_main else None
    merged_at = _at(newest_main, "created_at") if newest_main else None

    surfaces = _surfaces(lives, head)
    stages = [
        _pushed(repo, newest_pr),
        _pr_open(repo, newest_pr, newest_main),
        _checks_green(pr_runs, newest_pr),
        _merged(repo, newest_main),
        _applied(repo, runs, jobs, main_pushes, head, repo in cfg.terraform_repos),
        _live(repo, surfaces),
    ]
    budget = budget_minutes(repo, surfaces, cfg)
    # In flight while no surface has reported the head SHA in the window. Any
    # report counts, not only the newest: a surface that already moved past
    # head (a later merge the push workflows didn't see) is not in flight.
    in_flight = bool(surfaces and head and not any(same_sha(e.get("sha"), head) for e in lives))
    stuck = bool(in_flight and (now - merged_at).total_seconds() > budget * 60)
    return {
        "repo": repo,
        "head": {"sha": short(head), "full_sha": head, "merged_at": iso(merged_at),
                 "url": commit_url(repo, head)} if head else None,
        "in_flight": in_flight,
        "in_flight_since": iso(merged_at) if in_flight else None,
        "stuck": stuck,
        "budget_minutes": budget,
        "stages": stages,
        "surfaces": [{k: v for k, v in s.items() if k != "_event"} for s in surfaces],
    }


def build_document(runs, jobs, lives, now, cfg):
    """Events are parsed JSON lines, each with ``repo`` and ``_ts`` (Loki time) set."""
    by_repo = {}
    for kind, events in (("runs", runs), ("jobs", jobs), ("lives", lives)):
        for event in events:
            if event.get("repo"):
                by_repo.setdefault(event["repo"], {"runs": [], "jobs": [], "lives": []})[kind].append(event)
    return {
        "schema": SCHEMA,
        "generated_at": iso(now),
        "producer": cfg.producer,
        "window": cfg.window,
        "repos": [repo_state(repo, e["runs"], e["jobs"], e["lives"], now, cfg)
                  for repo, e in sorted(by_repo.items())],
    }


def state_streams(document, cluster, ts_ns):
    """One Loki stream per repo, one line per stage, for ``change_pipeline_state``.

    Deliberately no ``pipeline``/``stage`` labels: the dashboard selects the
    real live events with ``{pipeline="change", stage="live"}``.
    """
    streams = []
    for repo in document["repos"]:
        head = repo["head"]["sha"] if repo["head"] else None
        values = []
        for i, stage in enumerate(repo["stages"]):
            line = {"stage": stage["stage"], "state": stage["state"], "sha": stage["sha"],
                    "detail": stage["detail"], "when": stage["when"], "url": stage["url"],
                    "head": head, "in_flight": repo["in_flight"], "stuck": repo["stuck"]}
            # One nanosecond apart keeps the six lines in pipeline order.
            values.append([str(ts_ns + i), json.dumps(line, separators=(",", ":"))])
        streams.append({"stream": {"log_source": "change_pipeline_state", "cluster": cluster,
                                   "repo": repo["repo"]}, "values": values})
    return streams
