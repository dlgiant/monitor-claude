# Claude Code OTel Monitoring — Sketch

Drop-in stack for cost/performance analytics across many Claude Code runs.

```
Claude Code  ──OTLP/gRPC──▶  OTel Collector  ──┬─▶ Prometheus (metrics)
                                               ├─▶ Tempo      (traces)
                                               └─▶ Loki       (events as logs)
                                                       │
                                                       └──▶ Grafana
```

## Run

```bash
docker compose up -d
```

Then point Claude Code at the collector — env vars MUST be set before
`claude` starts (the SDK reads them once at boot):

```bash
source ./claude-otel.env
claude              # interactive — required for metrics
```

`claude -p` (headless one-shot) only initializes the *log* exporter, not
metrics. Use an interactive session for the dashboard to populate.

Open Grafana at http://localhost:3000 — anonymous admin enabled, no login.

## Verify the pipeline

Before trusting the dashboard, confirm metrics actually arrive:

```bash
curl -s 'http://localhost:9090/api/v1/label/__name__/values' \
  | python3 -c 'import json,sys; print("\n".join(n for n in json.load(sys.stdin)["data"] if "claude" in n.lower()))'
```

If the actual names differ from what the dashboard expects (e.g. unit suffix
present/absent, `_total` vs not), edit `grafana/provisioning/dashboards/claude-code.json`
— Grafana picks up changes within 30s with no restart.

## What you get

**Top-row stats (window-aggregated)**

| Panel | Why it matters |
|---|---|
| Total cost | Window spend, model-filtered |
| Cache hit ratio | Cache reads cost ~10% of input. Single highest-leverage knob. |
| Cost per accepted edit | Closest thing to real ROI |
| Sessions | Volume baseline |
| Cost per session | ROI per task started |
| Cache savings $ | Estimated USD avoided by cache reads (tune `$/MTok` variable per model) |
| Edit accept rate | Trust regression detector |
| Active time | Wall-clock CLI usage |

**Time-series**

| Panel | Source | Why |
|---|---|---|
| Cost rate by model ($/hour) | Prom | Catches model-routing regressions |
| Cost rate by effort tier | Prom | xhigh thinking is usually the biggest spend knob |
| Tokens by type | Prom | Cache creation spikes = stale CLAUDE.md / prompt churn |
| API request latency p50/p95/p99 | Loki LogQL | From `claude_code.api_request` events |
| Edit-tool decisions (accept/reject) | Prom | Quality trend |
| Tool result size p95 by tool | Loki LogQL | Find tools eating context budget |
| Activity heatmap | Prom | Density of CLI active time |

**Breakdown panels**

| Panel | Source | Why |
|---|---|---|
| Edits accepted by language | Prom | Where Claude is actually working |
| Auxiliary vs main spend (donut) | Prom | Subagent vs direct-prompt split |
| Auxiliary cost table (subagent proxy) | Prom | Per-model/effort auxiliary spend; replace with TraceQL once spans flow |
| Cost breakdown table | Prom | Full model × effort × source matrix |

## Subagent attribution

The metrics endpoint is dimensioned by model/tool, not by subagent name.
For per-subagent cost, use traces:

1. Make sure `OTEL_TRACES_EXPORTER=otlp` is set in your shell.
2. In Grafana → Explore → Tempo, run TraceQL:
   ```
   { resource.service.name = "claude-code" }
   ```
3. Inspect span attributes on a real trace first — the exact attribute key
   for subagent identity may vary by Claude Code version. Likely candidates:
   `agent.name`, `subagent.type`, `claude.agent`. Once you know the key, group:
   ```
   { resource.service.name = "claude-code" } | by(span.agent.name)
   ```

## Performance notes

- Collector: `memory_limiter` first (back-pressure), then `batch` (5s/1024).
  Hard cap 384MiB, spike +96MiB. Container limit 512MiB.
- High-cardinality / per-identity attributes scrubbed in the collector
  (`session.id`, `user.id`, `user.email`, `user.account_id`,
  `user.account_uuid`, `organization.id`) before Prometheus ingest. If you
  want per-session or per-user attribution, edit `attributes/scrub_metrics`
  in `otel-collector-config.yaml`. Expect TSDB growth.
- Loki indexes only `service.name` and `service.version` as labels; every
  other attribute (incl. high-cardinality IDs) becomes structured metadata.
  Filter via `{service_name="claude-code"} | event_name = "..."` and unwrap
  numeric attrs (`duration_ms`, `*_tokens`, `cost_usd`, `*_size_bytes`) for
  quantile_over_time / sum_over_time aggregations.
- Prometheus retention 30d, native histograms enabled.
- Tempo retention 7d, local backend (fine for a single dev; swap for S3 if
  you scale this to a team).
- Loki retention 7d, filesystem backend, single-binary mode.
- Telemetry export is async in Claude Code itself — sub-10ms overhead per op.

## Tearing down

```bash
docker compose down              # keep data
docker compose down -v           # nuke volumes
```

## Known sharp edges

1. **Claude Code emits DELTA-temporality sums; Prometheus' OTLP receiver
   only accepts CUMULATIVE.** Symptom: collector receives metrics fine but
   `cc-prometheus` logs `invalid temporality and type combination`. Fix is
   already applied two ways: (a) the collector runs the `deltatocumulative`
   processor, (b) `claude-otel.env` sets
   `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative`.
2. **Metric names depend on Prometheus's OTLP translation.** The dashboard
   assumes the standard convention (`.` → `_`, unit suffix appended,
   `_total` for counters). Always run the verification curl before debugging
   "no data" panels.
3. **`OTEL_LOGS_EXPORTER=otlp` is enabled** but this stack ships logs to the
   collector's `debug` exporter (stdout). Add Loki + a logs pipeline if you
   want event search. Most cost/perf questions are answered by metrics alone.
4. **Tempo is single-binary, local-disk.** Fine for personal use; for a team,
   run it backed by S3/GCS and put the WAL on fast disk.
5. **Telemetry support is in beta.** Metric names and attribute keys can shift
   between Claude Code versions. Re-run the verification curl after upgrades.
