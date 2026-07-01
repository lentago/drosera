#!/usr/bin/env node
/* eslint-disable */
/**
 * cost-export.mjs — capture finished Claude Code interactive sessions and ship
 * them to the homelab Loki receiver so local cost lands on the "Claude Runner
 * Fleet" Grafana dashboard alongside the bullpen agents.
 *
 * Two phases, run in sequence (default) or individually:
 *   sweep  — scan ~/.claude/projects/**.jsonl, compute per-session tokens + cost
 *            for FINISHED sessions, append one `session_complete` event per
 *            session to the local spool. Idempotent (emit-once, guarded by
 *            emitted.json). Pure/local — works off-LAN.
 *   ship   — drain unsent spool events to Loki :3100. Off-LAN POSTs fail and the
 *            event stays queued; the next on-LAN run drains the backlog.
 *
 * Why a spool instead of POSTing inline: the transcript on disk is the source of
 * truth (survives hard kills that skip the SessionEnd hook), and decoupling
 * capture from shipping is what makes off-LAN buffering work.
 *
 * Token accounting mirrors the empirically-derived rules from the session-report
 * skill: dedupe entries globally by `uuid` (resumed sessions replay history),
 * and dedupe API calls by `requestId` keeping the max `output_tokens` (one
 * response is split across several assistant entries; only the last carries the
 * final output count).
 *
 * Cost is COMPUTED from token counts × pricing.json (Claude Code does not write
 * dollars to the transcript). Prices drift — keep pricing.json current.
 *
 * Env (all optional):
 *   COST_STATE_DIR     state/spool dir         (default ~/.claude/cost-export)
 *   COST_PROJECTS_DIR  transcripts root        (default ~/.claude/projects)
 *   COST_PRICING       pricing.json path       (default <scriptdir>/pricing.json)
 *   COST_LOKI_URL      Loki push endpoint       (default http://192.168.139.20:3100/loki/api/v1/push)
 *   COST_IDLE_MIN      mins idle ⇒ "finished"   (default 30)
 *   COST_LOOKBACK_DAYS only emit sessions active within N days (default 14)
 *   COST_WORKER        worker label             (default hostname)
 *   COST_REJECT_OLD_H  re-stamp Loki ts to now if event older than N h (default 160)
 *
 * Usage: cost-export.mjs [sweep|ship|seed|all]   (no arg = all = sweep + ship)
 *   seed — mark all currently-finished sessions as already-emitted WITHOUT
 *          shipping. Run once at install so only sessions completed AFTER
 *          install ship; avoids a backfill spike. (Deliberate history backfill:
 *          run `sweep` with a larger COST_LOOKBACK_DAYS instead.)
 *
 * Concurrency: invoke under `flock -n <state>/.lock` (the systemd unit and
 * install.sh do). Runs are serialized so the emit-once guard can't be raced by
 * an overlapping sweep (an early install bug shipped each backfill session 3x).
 */

import fs from 'fs'
import os from 'os'
import path from 'path'
import readline from 'readline'
import { execFileSync } from 'child_process'

const HOME = os.homedir()
const STATE_DIR = process.env.COST_STATE_DIR || path.join(HOME, '.claude', 'cost-export')
const PROJECTS_DIR = process.env.COST_PROJECTS_DIR || path.join(HOME, '.claude', 'projects')
const SCRIPT_DIR = path.dirname(new URL(import.meta.url).pathname)
const PRICING_PATH = process.env.COST_PRICING || path.join(SCRIPT_DIR, 'pricing.json')
const LOKI_URL = process.env.COST_LOKI_URL || 'http://192.168.139.20:3100/loki/api/v1/push'
const IDLE_MS = (parseInt(process.env.COST_IDLE_MIN || '30', 10)) * 60 * 1000
const LOOKBACK_MS = (parseInt(process.env.COST_LOOKBACK_DAYS || '14', 10)) * 86400 * 1000
const WORKER = process.env.COST_WORKER || os.hostname()
const REJECT_OLD_MS = (parseInt(process.env.COST_REJECT_OLD_H || '160', 10)) * 3600 * 1000

const SPOOL = path.join(STATE_DIR, 'spool.ndjson')
const SHIPPED = path.join(STATE_DIR, 'shipped.ndjson')
const EMITTED = path.join(STATE_DIR, 'emitted.json')
const DONE_DIR = path.join(STATE_DIR, 'done')

const NOW = Date.now()
const phase = (process.argv[2] || 'all').toLowerCase()

function log(...a) { console.error('[cost-export]', ...a) }
function ensureDirs() { for (const d of [STATE_DIR, DONE_DIR]) fs.mkdirSync(d, { recursive: true }) }
function readJson(p, dflt) { try { return JSON.parse(fs.readFileSync(p, 'utf8')) } catch { return dflt } }

// ---------------------------------------------------------------------------
// Pricing
// ---------------------------------------------------------------------------
const PRICING = readJson(PRICING_PATH, null)
if (!PRICING) { log('FATAL: cannot read pricing at', PRICING_PATH); process.exit(2) }
const MULT = PRICING.multipliers

// Normalize a transcript model string to a pricing table key.
// Strips date suffixes ("-20251001") and tier markers ("[1m]"); matches by
// longest-prefix so future point releases still resolve. Unknown → _default.
function priceKeyFor(model) {
  if (!model) return PRICING._default
  let m = String(model).toLowerCase().replace(/\[[^\]]*\]/g, '').trim()
  if (PRICING.models[m]) return m
  m = m.replace(/-\d{6,}$/, '') // drop trailing date
  if (PRICING.models[m]) return m
  let best = null
  for (const k of Object.keys(PRICING.models)) {
    if (m.startsWith(k) && (!best || k.length > best.length)) best = k
  }
  return best || PRICING._default
}

// Cost (USD) for one token bucket given a price key and speed ("fast"/other).
function costFor(key, speed, t) {
  const base = PRICING.models[key] || PRICING.models[PRICING._default]
  const rate = (speed === 'fast' && base.fast) ? base.fast : base
  const inP = rate.input / 1e6, outP = rate.output / 1e6
  return (
    t.inUncached * inP +
    t.cacheRead * inP * MULT.cache_read +
    t.cacheWrite5m * inP * MULT.cache_write_5m +
    t.cacheWrite1h * inP * MULT.cache_write_1h +
    t.output * outP
  )
}

// ---------------------------------------------------------------------------
// Transcript discovery + classification (mirrors session-report)
// ---------------------------------------------------------------------------
function* walk(dir) {
  let ents
  try { ents = fs.readdirSync(dir, { withFileTypes: true }) } catch { return }
  for (const e of ents) {
    const p = path.join(dir, e.name)
    if (e.isDirectory()) yield* walk(p)
    else if (e.isFile() && e.name.endsWith('.jsonl')) yield p
  }
}

// Returns { project (dir-encoded), sessionId } for a transcript path.
// main:     <projectDir>/<sessionId>.jsonl
// subagent: <projectDir>/<sessionId>/.../*.jsonl  → rolls into parent session
function classify(p) {
  const rel = path.relative(PROJECTS_DIR, p)
  const parts = rel.split(path.sep)
  const projectDir = parts[0]
  if (parts.length === 2) return { projectDir, sessionId: path.basename(parts[1], '.jsonl') }
  return { projectDir, sessionId: parts[1] } // deeper ⇒ session dir is parts[1]
}

function emptyTokens() {
  return { inUncached: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, output: 0 }
}

function newSession(projectDir) {
  return {
    projectDir,
    cwd: null,
    firstTs: null,
    lastTs: null,
    humanTurns: 0,
    apiCalls: 0,
    // pricing bucket key `${priceKey}|${speed}` → tokens
    buckets: new Map(),
    // dedupe of API calls by requestId → { output, bucketKey, usage } (keep max output)
    byRequest: new Map(),
  }
}

const sessions = new Map()           // sessionId → session
const seenUuids = new Set()          // global replay dedupe

function isHumanPrompt(e) {
  if (e.type !== 'user') return false
  if (e.isSidechain || e.isMeta || e.isCompactSummary) return false
  const c = e.message && e.message.content
  if (typeof c === 'string') return c.trim().length > 0
  if (Array.isArray(c)) return c.some(b => b && b.type === 'text') // not a tool_result-only turn
  return false
}

function ingestFile(p) {
  return new Promise((resolve) => {
    const { projectDir, sessionId } = classify(p)
    if (!sessions.has(sessionId)) sessions.set(sessionId, newSession(projectDir))
    const s = sessions.get(sessionId)
    const rl = readline.createInterface({ input: fs.createReadStream(p, { encoding: 'utf8' }), crlfDelay: Infinity })
    rl.on('line', (line) => {
      if (!line) return
      let e
      try { e = JSON.parse(line) } catch { return }
      if (e.uuid) { if (seenUuids.has(e.uuid)) return; seenUuids.add(e.uuid) }

      if (e.cwd && !s.cwd) s.cwd = e.cwd
      const ts = e.timestamp ? Date.parse(e.timestamp) : NaN
      if (!isNaN(ts)) {
        if (s.firstTs === null || ts < s.firstTs) s.firstTs = ts
        if (s.lastTs === null || ts > s.lastTs) s.lastTs = ts
      }
      if (isHumanPrompt(e)) s.humanTurns++

      if (e.type !== 'assistant') return
      const msg = e.message || {}
      const u = msg.usage
      if (!u) return
      const key = e.requestId || msg.id || e.uuid
      if (!key) return
      const out = u.output_tokens || 0
      const prev = s.byRequest.get(key)
      if (prev && prev.output >= out) return // keep the entry with max output_tokens
      const priceKey = priceKeyFor(msg.model)
      const speed = (u.speed === 'fast' || e.speed === 'fast') ? 'fast' : 'standard'
      s.byRequest.set(key, { output: out, priceKey, speed, usage: u, model: msg.model })
    })
    rl.on('close', resolve)
    rl.on('error', () => resolve())
  })
}

// Fold the deduped per-request usage into pricing buckets + apiCalls.
function finalizeSession(s) {
  for (const r of s.byRequest.values()) {
    s.apiCalls++
    const bk = `${r.priceKey}|${r.speed}`
    let t = s.buckets.get(bk)
    if (!t) { t = emptyTokens(); s.buckets.set(bk, t) }
    const u = r.usage
    const cc = u.cache_creation || {}
    const w5 = cc.ephemeral_5m_input_tokens
    const w1 = cc.ephemeral_1h_input_tokens
    const ccTotal = u.cache_creation_input_tokens || 0
    if (w5 != null || w1 != null) {
      t.cacheWrite5m += w5 || 0
      t.cacheWrite1h += w1 || 0
    } else {
      t.cacheWrite5m += ccTotal // no breakdown ⇒ assume 5m TTL
    }
    t.inUncached += u.input_tokens || 0
    t.cacheRead += u.cache_read_input_tokens || 0
    t.output += u.output_tokens || 0
  }
}

// ---------------------------------------------------------------------------
// Sweep
// ---------------------------------------------------------------------------
function projectLabel(s) {
  let base
  if (s.cwd) base = path.basename(s.cwd)
  else base = decodeURIComponent(s.projectDir).replace(/^-/, '').split('-').pop()
  if (!base || base === path.basename(HOME)) base = 'home'
  return base.toLowerCase().replace(/[^a-z0-9_.-]+/g, '-').replace(/^-+|-+$/g, '') || 'home'
}

async function sweep(seedOnly = false) {
  ensureDirs()
  const emitted = readJson(EMITTED, {})
  const doneMarkers = new Set(fs.existsSync(DONE_DIR) ? fs.readdirSync(DONE_DIR) : [])

  for (const f of walk(PROJECTS_DIR)) await ingestFile(f)

  let emittedCount = 0
  const spoolLines = []
  for (const [sessionId, s] of sessions) {
    if (emitted[sessionId]) continue                       // emit-once guard
    if (s.lastTs === null) continue
    if (NOW - s.lastTs > LOOKBACK_MS) continue              // too old to bother
    const finished = doneMarkers.has(sessionId) || (NOW - s.lastTs > IDLE_MS)
    if (!finished) continue                                 // still active — don't emit a partial

    if (seedOnly) { emitted[sessionId] = { seeded: true, at: NOW }; emittedCount++; continue }

    finalizeSession(s)
    if (s.apiCalls === 0) { emitted[sessionId] = { skipped: 'no-api-calls', at: NOW }; continue }

    let cost = 0
    const tokTotals = emptyTokens()
    let topModel = null, topOut = -1
    for (const [bk, t] of s.buckets) {
      const [priceKey, speed] = bk.split('|')
      cost += costFor(priceKey, speed, t)
      for (const k of Object.keys(tokTotals)) tokTotals[k] += t[k]
      if (t.output > topOut) { topOut = t.output; topModel = bk.split('|')[0] }
    }
    cost = Math.round(cost * 1e6) / 1e6
    const durationSec = s.firstTs && s.lastTs ? Math.round((s.lastTs - s.firstTs) / 1000) : 0
    const project = projectLabel(s)
    const inputTotal = tokTotals.inUncached + tokTotals.cacheRead + tokTotals.cacheWrite5m + tokTotals.cacheWrite1h

    const event = {
      event: 'session_complete',
      session_id: sessionId,
      source: 'local',
      worker: WORKER,
      project,
      model: topModel || 'unknown',
      status: 'completed',
      cost_usd: cost,
      num_turns: s.humanTurns,
      api_calls: s.apiCalls,
      duration_sec: durationSec,
      input_tokens: inputTotal,
      output_tokens: tokTotals.output,
      cache_read_tokens: tokTotals.cacheRead,
      cache_write_tokens: tokTotals.cacheWrite5m + tokTotals.cacheWrite1h,
      cwd: s.cwd || '',
      started: s.firstTs ? new Date(s.firstTs).toISOString() : '',
      finished: s.lastTs ? new Date(s.lastTs).toISOString() : '',
    }
    const labels = {
      job: 'claude_local', service: 'claude_runner', source: 'local',
      project, model: event.model, worker: WORKER, status: 'completed',
    }
    spoolLines.push(JSON.stringify({ labels, finished_ms: s.lastTs, line: JSON.stringify(event) }))
    emitted[sessionId] = { cost_usd: cost, finished: event.finished, at: NOW }
    emittedCount++
  }

  if (spoolLines.length) fs.appendFileSync(SPOOL, spoolLines.join('\n') + '\n')
  fs.writeFileSync(EMITTED, JSON.stringify(emitted, null, 0))
  // clear done markers we've now consumed
  for (const m of doneMarkers) if (emitted[m]) { try { fs.unlinkSync(path.join(DONE_DIR, m)) } catch {} }
  log(`${seedOnly ? 'seed' : 'sweep'}: ${emittedCount} session(s) ${seedOnly ? 'claimed (not shipped)' : 'spooled'} (${sessions.size} scanned)`)
  return emittedCount
}

// ---------------------------------------------------------------------------
// Ship
// ---------------------------------------------------------------------------
function postToLoki(rec) {
  let tsMs = rec.finished_ms || NOW
  if (NOW - tsMs > REJECT_OLD_MS) tsMs = NOW   // avoid Loki reject-old; true time stays in the line
  const tsNs = String(tsMs) + '000000'
  const payload = JSON.stringify({ streams: [{ stream: rec.labels, values: [[tsNs, rec.line]] }] })
  try {
    execFileSync('curl', ['-sf', '-m', '10', '-XPOST', LOKI_URL,
      '-H', 'Content-Type: application/json', '--data-binary', payload],
      { stdio: ['ignore', 'ignore', 'ignore'] })
    return true
  } catch { return false }
}

function ship() {
  if (!fs.existsSync(SPOOL)) { log('ship: spool empty'); return }
  const lines = fs.readFileSync(SPOOL, 'utf8').split('\n').filter(Boolean)
  if (!lines.length) { try { fs.unlinkSync(SPOOL) } catch {}; return }
  const remaining = [], shipped = []
  let okCount = 0, failCount = 0
  for (const ln of lines) {
    let rec
    try { rec = JSON.parse(ln) } catch { continue } // drop corrupt lines
    if (postToLoki(rec)) { shipped.push(ln); okCount++ }
    else { remaining.push(ln); failCount++ }
  }
  // rewrite spool with only the unshipped; append shipped to the audit log
  if (remaining.length) fs.writeFileSync(SPOOL, remaining.join('\n') + '\n')
  else { try { fs.unlinkSync(SPOOL) } catch {} }
  if (shipped.length) fs.appendFileSync(SHIPPED, shipped.join('\n') + '\n')
  log(`ship: ${okCount} sent, ${failCount} queued (off-LAN?)`)
}

// ---------------------------------------------------------------------------
const main = async () => {
  if (phase === 'seed') { await sweep(true); return }
  if (phase === 'sweep' || phase === 'all') await sweep(false)
  if (phase === 'ship' || phase === 'all') ship()
}
main().catch((e) => { log('error:', e && e.stack || e); process.exit(1) })
