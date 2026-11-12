# runner-cost: render pricing.json's runner rows into one LogQL stage that
# prices a claytonia job_complete line, and put that stage into a dashboard.
#
# Claude jobs report their own cost_usd. Gemini and Codex jobs report cost_usd
# null and their tokens (lentago/claytonia#173), as job totals and per model:
#
#   "tokens":          {"in", "cached", "cache_write", "out", "thinking"}
#   "tokens_by_model": {"<model id>": {"in", "cached", "cache_write", "out", "thinking"}}
#
# The five fields are disjoint, and a null one is dropped by `| json`. LogQL's
# json parser flattens tokens_by_model.<model>.<field> into a single label,
# turning every character outside [a-zA-Z0-9_] into "_" (tokens_by_model_gemini_3_8_flash_in).
#
# The rendered stage is a label_format that sets `cost`:
#   - cost_usd when the line has one;
#   - else the sum, over the rows this table has, of
#       in * input + cached * cached_input + cache_write * cache_write + (out + thinking) * output
#     per MTok, at the row's price for the job's `finished` date, but only when the
#     tokens those rows priced add up to the job's totals. A model with no row,
#     write tokens on a row with no cache_write rate, or a dated row on a line
#     with no `finished` leaves tokens unpriced, so the sums differ and `cost` is
#     empty: the job is unknown, never partly priced and never priced as another
#     model. A zero-token entry prices nothing either way, so a model with no row
#     makes a job unknown only when it has tokens (claytonia keeps entries for
#     models a CLI called at zero tokens);
#   - empty for a line with no token totals (a failure that never produced
#     JSON) or with no priced token at all: an all-zero count is unknown, not $0.
#
# Panels then filter `cost!=""` and `unwrap cost`, or count `cost=""` as unknown.
# The template variables are $priced_usd and $priced_tok. Grafana leaves a
# $name alone unless the dashboard has a variable of that name, so the
# dashboard must never define either.

locals {
  pricing = jsondecode(var.pricing_json)

  # Runner rows: any row with a runtime other than claude. The Claude rows, the
  # multipliers and _default never reach the stage.
  rows = {
    for id, r in local.pricing.models : id => r
    if try(r.runtime, "claude") != "claude"
  }

  label = {
    for id in keys(local.rows) : id => "tokens_by_model_${replace(id, "/[^a-zA-Z0-9_]/", "_")}"
  }

  fields = ["in", "cached", "cache_write", "out", "thinking"]

  # One entry per price period: [from, to) in UTC dates, "" for open-ended.
  periods = flatten([
    for id, r in local.rows : [
      for i, p in r.prices : {
        tok  = { for f in local.fields : f => "(or .${local.label[id]}_${f} 0)" }
        from = try(p.from, "")
        to   = try(r.prices[i + 1].from, "")
        rate = p
      }
    ]
  ])

  blocks = [
    for p in local.periods : join("", [
      # When the row has more than one period, the price depends on the job's
      # finished date: a line without one matches no period and stays unknown.
      length(compact([p.from, p.to])) == 0 ? "" : format("{{ if and .finished %s }}", join(" ", compact([
        p.from == "" ? "" : format("(ge .finished \"%s\")", p.from),
        p.to == "" ? "" : format("(lt .finished \"%s\")", p.to),
      ]))),
      format(
        "{{ $priced_usd = addf $priced_usd (mulf %s %s) (mulf %s %s) (mulf (addf %s %s) %s)%s }}",
        p.tok["in"], tostring(p.rate.input),
        p.tok["cached"], tostring(p.rate.cached_input),
        p.tok["out"], p.tok["thinking"], tostring(p.rate.output),
        try(format(" (mulf %s %s)", p.tok["cache_write"], tostring(p.rate.cache_write)), ""),
      ),
      # Write tokens count as priced only when the period has a write rate.
      format(
        "{{ $priced_tok = addf $priced_tok %s %s %s %s%s }}",
        p.tok["in"], p.tok["cached"], p.tok["out"], p.tok["thinking"],
        try(p.rate.cache_write, null) == null ? "" : " ${p.tok["cache_write"]}",
      ),
      length(compact([p.from, p.to])) == 0 ? "" : "{{ end }}",
    ])
  ]

  stage = join("", [
    "label_format cost=`{{ if .cost_usd }}{{ .cost_usd }}{{ else }}{{ $priced_usd := 0.0 }}{{ $priced_tok := 0.0 }}",
    join("", local.blocks),
    "{{ if and .tokens_in .tokens_out (gt $priced_tok 0.0) (eq $priced_tok (addf .tokens_in (or .tokens_cached 0) (or .tokens_cache_write 0) .tokens_out (or .tokens_thinking 0))) }}",
    "{{ round (divf $priced_usd 1000000) 6 }}{{ end }}{{ end }}`",
  ])

  # The placeholder sits inside a JSON string, so the stage goes in JSON-escaped.
  stage_json = substr(jsonencode(local.stage), 1, length(jsonencode(local.stage)) - 2)
}
