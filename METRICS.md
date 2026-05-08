# Claude Code Telemetry — Metrics Reference

What every metric, label, and panel in the dashboard actually means, in plain
English. Read this when a number looks weird and you're not sure what it's
measuring.

---

## How telemetry flows

Claude Code's OpenTelemetry SDK fires two streams whenever you use the CLI:

- **Metrics** — pre-aggregated counters and histograms. Cheap, low-cardinality,
  perfect for dashboards. These end up in **Prometheus**.
- **Log events** — structured JSON-like records, one per "thing that happened"
  (an API request, a tool call, a user prompt). Rich attributes, higher
  cardinality. These end up in **Loki**, with their numeric attributes
  available via LogQL `unwrap`.

The OTel collector also derives a third stream: **counters synthesized from
log events** via the `count` connector. We use this to make Shannon-entropy
calculations possible (PromQL has `ln()`, LogQL doesn't).

---

## Prometheus metrics (native)

Each of these is a counter (monotonically increasing) reported by Claude Code
itself. Use `increase(metric[window])` to get totals, `rate(metric[5m])` to
get a per-second rate.

### `claude_code_cost_usage_USD_total`

**Plain English:** Total US dollars billed to your Anthropic account by
Claude Code. Includes input, output, cache-read, and cache-creation token
charges, summed per model.

| Label | Meaning |
|---|---|
| `model` | The model that did the work (e.g. `claude-opus-4-7`, `claude-opus-4-7[1m]`). The `[1m]` suffix means the 1M-context variant — pricier per token. |
| `effort` | The thinking-effort tier the request used (`low`, `medium`, `high`, `xhigh`). xhigh costs the most because it produces the most thinking tokens. |
| `query_source` | `main` for your direct prompts, `auxiliary` for subagent / background work. |
| `terminal_type` | What terminal Claude was running in (`gnome-terminal`, `iTerm`, etc.). |

**Watch for:** sudden cost spikes — usually `effort=xhigh` exploding, or a
subagent (`query_source=auxiliary`) spiraling.

### `claude_code_token_usage_tokens_total`

**Plain English:** Total tokens, broken down by what they were used for.

| Label | Meaning |
|---|---|
| `type` | One of: `input` (you/the agent sent), `output` (Claude generated), `cacheRead` (read from prompt cache, ~10% of input price), `cacheCreation` (written to cache, ~1.25× input price). |
| `model`, `effort`, `query_source` | Same as above. |

**Watch for:** `cacheCreation` spikes mean stale CLAUDE.md or churning prompts
— Claude is rebuilding its cache instead of reusing it. `cacheRead` should be
the dominant slice; if it isn't, your cache strategy is leaking.

### `claude_code_session_count_total`

**Plain English:** How many *fresh* `claude` sessions started.

| Label | Meaning |
|---|---|
| `start_type` | `new` for a fresh session, `resume` for `claude --resume <id>`. |

**Gotcha:** Resumed sessions DO increment this with `start_type=resume`, but
many dashboard panels filter to `new` only. The "Sessions (window)" panel
counts both unless you narrow it.

### `claude_code_active_time_seconds_total`

**Plain English:** Wall-clock seconds during which Claude Code's CLI was
actively doing something (not idle waiting for you to type).

| Label | Meaning |
|---|---|
| `type` | Currently always `cli` — placeholder for future activity types (e.g. background agents). |

**Useful for:** computing $/hour ratios, finding sessions where the agent
spent more time computing than producing output.

### `claude_code_lines_of_code_count_total`

**Plain English:** Lines of code added or removed by Claude (across all
Edit/Write/MultiEdit operations you accepted).

| Label | Meaning |
|---|---|
| `type` | `added` or `removed`. |

**Useful for:** tracking real productivity. Compare $/line over time; a
healthy project gets cheaper per line as the cache warms.

### `claude_code_code_edit_tool_decision_total`

**Plain English:** Every time Claude *suggested* an edit (Edit/Write/
MultiEdit), did you accept it or reject it?

| Label | Meaning |
|---|---|
| `decision` | `accept` or `reject`. |
| `tool_name` | The specific tool that proposed the change (`Edit`, `Write`, `MultiEdit`). |
| `language` | Detected source language (`Python`, `TypeScript`, `Rust`, `YAML`, ...). Useful for spotting where Claude is strong/weak. |
| `source` | How the decision was registered (`config` = auto-accept rule, `user_temporary` = you clicked, etc.). |

**Watch for:** drop in accept rate — early sign that Claude is suggesting
worse edits than usual (model regression, context drift, or a CLAUDE.md
that's gotten out of sync with your code).

---

## Prometheus metrics (derived)

Synthesized by the OTel collector from log events. Here only because they're
useful for PromQL math (entropy etc.).

### `claude_tool_decision_count_total`

**Plain English:** Every tool decision Claude made (any tool, not just code
edits). Built from `claude_code.tool_decision` events via the `count`
connector in the collector.

| Label | Meaning |
|---|---|
| `tool_name` | `Bash`, `Read`, `Edit`, `Write`, `Grep`, `Glob`, `Monitor`, `Task`, ... |
| `decision` | `accept` or `reject` (currently almost always `accept` because most tools are auto-allowed). |

**Used by:** the Tool-decision Shannon entropy panel.

---

## Loki log events

Three event names matter. They're queried as
`{service_name="claude-code"} | event_name = "<name>"` (note: backticks in
LogQL string literals).

### `claude_code.api_request`

**Plain English:** One record per HTTP call Claude makes to Anthropic's API.

Useful numeric attributes (queryable with `| unwrap <attr>`):

| Attribute | Meaning |
|---|---|
| `duration_ms` | How long the API request took, end-to-end (ms). |
| `input_tokens` | Tokens sent that weren't already cached. |
| `output_tokens` | Tokens Claude generated, including thinking. |
| `cache_read_tokens` | Tokens served from the prompt cache (~10× cheaper than input). |
| `cache_creation_tokens` | Tokens written to the cache for future reuse (~1.25× input price). |
| `cost_usd` | Dollars billed for this single request. |

Useful string attributes:

| Attribute | Meaning |
|---|---|
| `model` | Which model handled the request. |
| `effort` | Thinking-effort tier. |
| `query_source` | `repl_main_thread`, `auxiliary`, etc. (finer-grained than the Prom label). |
| `speed` | `normal` / `fast`. Fast mode is Opus 4.6 served via priority infra. |
| `request_id` | Anthropic's `req_011...` ID. Useful if you need to file a bug report. |

**Used by:** API latency p50/p95/p99 panel, cognitive-throughput panel.

### `claude_code.tool_decision`

**Plain English:** One record per tool call Claude *decided* to make (before
the tool actually runs).

Useful attributes:

| Attribute | Meaning |
|---|---|
| `tool_name` | The tool. |
| `decision` | `accept` or `reject`. |
| `source` | What triggered the decision (`config` auto-accept, `user_permanent`, `user_temporary`). |
| `prompt_id` | Groups all tool decisions from a single user prompt — useful for sequencing. |

### `claude_code.tool_result`

**Plain English:** One record per tool call that *finished* — has the
outcome.

Useful numeric attributes:

| Attribute | Meaning |
|---|---|
| `duration_ms` | How long the tool ran (ms). |
| `tool_input_size_bytes` | Size of the arguments Claude sent in. |
| `tool_result_size_bytes` | Size of the result the tool returned (back into Claude's context window). |

Useful string attributes:

| Attribute | Meaning |
|---|---|
| `tool_name` | Which tool. |
| `success` | `true` / `false`. |
| `decision_type`, `decision_source` | Same shape as on `tool_decision`. |

**Used by:** Tool-result-size p95 panel. Find which tools eat your context
budget. The high-value insight: if a Bash call returns 50KB of log output,
that's 50KB Claude has to re-process on every subsequent request — you've
just made every later turn slower and more expensive.

---

## Dashboard panels

Where the metrics get assembled into something useful. Below, "PromQL"
queries hit Prometheus, "LogQL" queries hit Loki.

### Top-row stats (window-aggregated)

| # | Panel | What it tells you |
|---|---|---|
| 1 | **Total cost (window)** | Dollars spent on Claude Code in the visible time range, model-filtered. |
| 2 | **Cache hit ratio** | `cacheRead / (cacheRead + input)` — the fraction of input that came free from the cache. >70% is good; <40% means you're paying too much for input. |
| 3 | **Cost per accepted edit** | Total spend / accepted edits. The cleanest single-number ROI signal. Watch it trend. |
| 4 | **Sessions (window)** | Number of session starts in the window. Doesn't include `--resume`. |
| 9 | **Cost per session** | Total spend / session count. "How expensive is one task?" |
| 10 | **Cache savings $ (approx)** | Estimate of dollars *avoided* by cache reads vs. paying full input price. Net of cache-creation overhead. Tune the `$/MTok` dashboard variable to your model. |
| 11 | **Edit accept rate** | Acceptance rate for code-edit suggestions. Drops here = trust regression. |
| 12 | **Active time** | Total wall-clock seconds Claude was actively running. |

### Time-series panels

| # | Panel | What it tells you |
|---|---|---|
| 5 | **Cost rate by model ($/hour)** | Burn rate per model. Catches model-routing regressions ("why is everything suddenly on Opus?"). |
| 13 | **Cost rate by effort tier ($/hour)** | Stacked area showing how much you're spending at each thinking depth. xhigh is usually the biggest knob. |
| 6 | **Tokens by type** | Stacked rate of input / output / cacheRead / cacheCreation tokens. Shape of the cacheCreation line is your "cache health" signal. |
| 14 | **API latency p50/p95/p99** | Quantile latency from `api_request` events, grouped by model. Big p99 spikes = Anthropic-side slow days, or you're sending huge contexts. |
| 7 | **Edit-tool decisions (accept vs reject)** | Bar chart of accept/reject events over time. Easy visual on quality. |
| 15 | **Tool result size p95 by tool** | Which tools are pumping the most bytes back into Claude's context. Bash and Read are usually the heavyweights. |
| 16 | **Activity heatmap** | Density of CLI active time over time. Tall stripes = focus blocks; gaps = downtime. Useful for finding your real working hours. |
| 20 | **Cognitive throughput by effort tier** | Output-tokens-per-second of API time, grouped by effort. *The* "is the agent in flow" indicator. Drops while effort climbs = wrestling a hard problem. Climbs steady = fluent execution. |
| 21 | **Tool-decision Shannon entropy (bits)** | Diversity of tool usage in a 5-minute window. 0 bits = stuck on one tool (loop / dead end). log₂(N) bits = uniform across N distinct tools (broad exploration). Sudden collapses are the telemetry signature of a thought-loop. Companion series shows count of distinct active tools. |

### Breakdown panels

| # | Panel | What it tells you |
|---|---|---|
| 17 | **Edits accepted by language** | Where Claude is actually doing work in your repos. |
| 18 | **Auxiliary vs main spend (donut)** | Subagent vs. direct-prompt spend split. A high auxiliary share = subagent-heavy workflow (lots of `/ultrareview`-style fan-out). |
| 19 | **Auxiliary cost (subagent proxy)** | Top auxiliary spend by model + effort. Closest available proxy for per-subagent cost — true per-name attribution requires Tempo traces, which Claude Code doesn't currently emit. |
| 8 | **Cost breakdown** | Full model × effort × query_source matrix. Drill-down for everything else. |

---

## Reading the dashboard

A typical "is this session healthy?" scan, in order:

1. **Cache hit ratio** > 70%. If not, something's burning your prompt cache.
2. **Cost rate by effort** — is xhigh dominating? Sometimes that's right
   (hard problem). Often it's a knob you forgot to turn down.
3. **Edit accept rate** trend — flat or rising = trusting the model;
   declining = quality regression.
4. **Cognitive throughput** during the worst minutes — was Claude
   *thinking* (low TPS, high effort) or *stuck* (low TPS, low effort)?
5. **Tool-decision entropy** during those same minutes — entropy near 0
   while throughput is also low = the agent was looping. Time to interrupt.

---

## What's NOT exposed (and why)

By design, telemetry **does not include the actual content** Claude
generates or thinks about. You see counts, sizes, durations, costs — never
prose. This is a privacy choice in the SDK.

Specifically you cannot get:

- Chat names / titles (sessions are anonymized UUIDs)
- The text of thinking / reasoning steps
- Prompt or response bodies
- File contents Claude read or wrote
- True per-subagent attribution (currently — would need traces with
  `agent.name` spans, which Claude Code doesn't emit yet)

If you want any of that, you'd build it yourself with a Claude Code hook
(e.g. a `PostToolUse` hook that logs structured events to Loki).
