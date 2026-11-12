# ADR-0012: Peer-runtime transcripts ship only through labelled links

**Status:** Accepted (2026-11-12)

## Context

The worker transcript shipper (`alloy/runner-transcript.alloy`, #71) tails
Claude Code's session files and ships a scrubbed live stream,
`job="claude_transcript"`, to Grafana Cloud Loki. A private project stays off
Cloud because of its path. run-job checks it out under `/home/claude/private/`,
and the Claude glob matches only `-home-claude-work*`. lentago/claytonia#166
(review decision 4) requires `offbox_transcript: false` to keep holding for
every runtime it adds.

Gemini CLI writes `~/.gemini/tmp/<slug>/chats/session-*.jsonl`, and Codex CLI
writes `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Gemini's slug is a bare
basename, and Codex's path is a date, so neither tells a private checkout from
a public one. Neither carries the runid. `loki.source.file` labels a stream
only from the tailed file's path, so no sibling file can supply those labels.

## Decision

1. **The shipper never globs a runtime's own session directory.** For Gemini
   and Codex it reads one prefix only:
   `/home/claude/.claytonia/live/<runtime>/<project>/<runid>/<session_id>.jsonl`.
2. **claytonia owns the links.** Its runner links each live session file into
   that prefix, only for checkouts under `/home/claude/work/`, owned by
   `claude`, and removes the link after a grace period. A private project
   therefore has no link and ships nothing. The structure below the prefix is
   the contract between the two repos. The prefix itself is claytonia's call,
   and the shipper's globs follow it.
3. **Every label comes from the link's path**: `runtime`, `project`, `runid`
   and `session_id`. Alloy follows a symlink and keeps tailing as the target
   grows, and `filename` is the link's path, not the target's (#305, Alloy
   v1.21.3). A hard link works as well.
4. **One pipeline per runtime, and the Claude block stays as it is.** Each
   runtime has its own match, source and process components with its own
   scrub, which is #71's posture re-derived for that runtime: narration text and
   tool names only.
5. **The file is tested as deployed.** `scripts/tests/transcript/run.sh` runs
   it in the workers' Alloy version against a throwaway Loki. It plants a
   `LEAK-` marker in every field that must not ship, and in unlinked
   private-project files, and fails if any marker arrives.

## Alternatives considered

- **Glob `~/.gemini` and `~/.codex` directly.** It is simple, but it ships
  private projects and cannot label runid or project.
- **A content sidecar** that the runner writes in place of a link, holding a
  re-encoded copy of the session. It would duplicate the transcript on disk,
  and claytonia would become the scrubber, which splits the egress posture
  across two repos.
- **Label from a sibling metadata file.** `loki.source.file` cannot read one
  (the obstacle #93 ran into).

## Consequences

- **Each new runtime is a pipeline here plus a link writer in claytonia.**
  Nothing ships until claytonia writes links, so the drosera side can merge
  first and stays inert until then.
- **A link-writer bug can ship a private project.** For example, linking a
  checkout outside `/home/claude/work/`. That rule lives in claytonia's code and
  tests, not here.
- **The scrub is per runtime.** A runtime's CLI changing its line format needs
  its pipeline and fixture updated, and the test catches a format the pipeline
  no longer reads.
- **`transcript-test` is not a required check on `main`.** A config that fails
  to load would stop all transcript shipping, Claude included, on every worker
  at the next `transcript-shipper-sync` tick. Until the check is required, arm
  a PR that touches the file only on a head where `transcript-test` is green.
