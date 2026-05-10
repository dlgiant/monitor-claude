#!/usr/bin/env python3
"""
agent-flame-sync — synthesize OTLP traces from Claude Code log events.

Polls Loki for `tool_result` and `api_request` events, groups them by
`prompt_id`, builds one OTLP trace per prompt (root span = the prompt,
child spans = each tool / API call with their durations), and pushes
the trace to the OTel collector at localhost:4318/v1/traces. Tempo then
renders proper flame graphs in Grafana → Explore → Tempo.

Run:
    ./sync.py --once          # one iteration, print, exit
    ./run.sh                  # background loop, default 30 s interval

Tunables via env:
    LOKI_URL                  default http://localhost:3100
    OTLP_URL                  default http://localhost:4318/v1/traces
    STATE_FILE                default /tmp/agent-flame.state
    PROMPT_QUIET_SECS         default 60   (consider prompt complete after this idle period)
    POLL_INTERVAL_SECS        default 30
    LOOKBACK_SECS             default 86400 (look back this far for events on each poll)
"""
from __future__ import annotations

import argparse
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path

LOKI = os.getenv("LOKI_URL", "http://localhost:3100")
OTLP = os.getenv("OTLP_URL", "http://localhost:4318/v1/traces")
STATE_FILE = Path(os.getenv("STATE_FILE", "/tmp/agent-flame.state"))
PROMPT_QUIET_SECS = int(os.getenv("PROMPT_QUIET_SECS", "60"))
POLL_INTERVAL_SECS = int(os.getenv("POLL_INTERVAL_SECS", "30"))
LOOKBACK_SECS = int(os.getenv("LOOKBACK_SECS", str(24 * 3600)))


def loki_query_range(query: str, start_ns: int, end_ns: int, limit: int = 5000) -> dict:
    url = (
        f"{LOKI}/loki/api/v1/query_range"
        f"?query={urllib.parse.quote(query)}"
        f"&start={start_ns}&end={end_ns}&limit={limit}"
    )
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.load(r)


def fetch_events(start_ns: int, end_ns: int) -> list[dict]:
    """One dict per Loki entry, with the structured metadata flattened in."""
    out: list[dict] = []
    for event_name in ("tool_result", "api_request"):
        q = f'{{service_name="claude-code"}} | event_name = `{event_name}`'
        data = loki_query_range(q, start_ns, end_ns)
        for stream in data.get("data", {}).get("result", []):
            meta = stream.get("stream", {}) or {}
            for v in stream.get("values", []):
                ts_ns = int(v[0])
                out.append({"_event_name": event_name, "_ts_ns": ts_ns, **meta})
    return out


def to_float(x, default=0.0) -> float:
    try:
        return float(x)
    except (TypeError, ValueError):
        return default


def to_int(x, default=0) -> int:
    try:
        return int(float(x))
    except (TypeError, ValueError):
        return default


def hex_id(nbytes: int) -> str:
    return secrets.token_hex(nbytes)


def attr(key: str, value) -> dict:
    """Build an OTLP key-value attribute, picking the right scalar type."""
    if isinstance(value, bool):
        return {"key": key, "value": {"boolValue": value}}
    if isinstance(value, int):
        return {"key": key, "value": {"intValue": str(value)}}
    if isinstance(value, float):
        return {"key": key, "value": {"doubleValue": value}}
    return {"key": key, "value": {"stringValue": str(value)}}


def build_trace(prompt_id: str, events: list[dict]) -> dict | None:
    if not events:
        return None
    events.sort(key=lambda e: e["_ts_ns"])

    trace_id = hex_id(16)
    root_span_id = hex_id(8)

    # Estimate prompt start: timestamp of the earliest event minus its
    # duration (events fire when *finished*).
    first = events[0]
    last = events[-1]
    root_start = first["_ts_ns"] - int(to_float(first.get("duration_ms")) * 1e6)
    root_end = last["_ts_ns"]

    session_id = first.get("session_id", "")
    spans = [
        {
            "traceId": trace_id,
            "spanId": root_span_id,
            "name": f"prompt {prompt_id[:8]}",
            "kind": 1,
            "startTimeUnixNano": str(root_start),
            "endTimeUnixNano": str(root_end),
            "attributes": [
                attr("prompt.id", prompt_id),
                attr("session.id", session_id),
                attr("agent.event_count", len(events)),
            ],
        }
    ]

    for e in events:
        end_ns = e["_ts_ns"]
        start_ns = end_ns - int(to_float(e.get("duration_ms")) * 1e6)
        if e["_event_name"] == "tool_result":
            tool = e.get("tool_name") or "?"
            name = f"tool: {tool}"
        else:
            model = e.get("model") or "request"
            name = f"api: {model}"

        attrs = [
            attr("event.name", e["_event_name"]),
            attr("duration_ms", to_float(e.get("duration_ms"))),
        ]
        for src, dst in [
            ("tool_name", "tool.name"),
            ("model", "model"),
            ("effort", "effort"),
            ("query_source", "query_source"),
            ("speed", "speed"),
            ("success", "success"),
        ]:
            if e.get(src):
                attrs.append(attr(dst, e[src]))
        for src, kind in [
            ("input_tokens", "int"),
            ("output_tokens", "int"),
            ("cache_read_tokens", "int"),
            ("cache_creation_tokens", "int"),
            ("cost_usd", "float"),
            ("tool_input_size_bytes", "int"),
            ("tool_result_size_bytes", "int"),
        ]:
            if e.get(src) not in (None, ""):
                v = to_int(e[src]) if kind == "int" else to_float(e[src])
                attrs.append(attr(src, v))

        spans.append(
            {
                "traceId": trace_id,
                "spanId": hex_id(8),
                "parentSpanId": root_span_id,
                "name": name,
                "kind": 1,
                "startTimeUnixNano": str(start_ns),
                "endTimeUnixNano": str(end_ns),
                "attributes": attrs,
            }
        )

    return {
        "resourceSpans": [
            {
                "resource": {
                    "attributes": [
                        attr("service.name", "claude-code-prompts"),
                        attr("service.version", "agent-flame-sync/1"),
                    ]
                },
                "scopeSpans": [
                    {"scope": {"name": "agent-flame-sync"}, "spans": spans}
                ],
            }
        ]
    }


def push_trace(trace: dict) -> None:
    body = json.dumps(trace).encode()
    req = urllib.request.Request(
        OTLP, data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        r.read()


def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except json.JSONDecodeError:
            pass
    return {"emitted_prompts": []}


def save_state(state: dict) -> None:
    STATE_FILE.write_text(json.dumps(state))


def run_once(verbose: bool = True) -> int:
    state = load_state()
    emitted = set(state.get("emitted_prompts", []))

    now_ns = time.time_ns()
    start_ns = now_ns - LOOKBACK_SECS * 1_000_000_000
    events = fetch_events(start_ns, now_ns)

    by_prompt: dict[str, list[dict]] = defaultdict(list)
    for e in events:
        pid = e.get("prompt_id")
        if pid:
            by_prompt[pid].append(e)

    quiet_threshold_ns = now_ns - PROMPT_QUIET_SECS * 1_000_000_000
    new_count = 0
    for prompt_id, evs in by_prompt.items():
        if prompt_id in emitted:
            continue
        latest = max(e["_ts_ns"] for e in evs)
        if latest > quiet_threshold_ns:
            continue  # still active, wait
        trace = build_trace(prompt_id, evs)
        if not trace:
            continue
        try:
            push_trace(trace)
            emitted.add(prompt_id)
            new_count += 1
            if verbose:
                print(
                    f"emitted trace prompt={prompt_id[:12]}… spans={len(evs)+1}"
                )
        except (urllib.error.URLError, urllib.error.HTTPError) as ex:
            print(f"push failed prompt={prompt_id[:12]}: {ex}", file=sys.stderr)

    # Cap state size.
    state["emitted_prompts"] = list(emitted)[-2000:]
    save_state(state)
    return new_count


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.strip().split("\n")[0])
    p.add_argument("--once", action="store_true", help="run one iteration and exit")
    p.add_argument(
        "--reset",
        action="store_true",
        help="forget which prompts have been emitted (re-emits all)",
    )
    args = p.parse_args()

    if args.reset:
        if STATE_FILE.exists():
            STATE_FILE.unlink()
        print(f"removed {STATE_FILE}")

    if args.once:
        n = run_once()
        print(f"emitted {n} trace(s)")
        return 0

    print(
        f"agent-flame-sync running — loki={LOKI} otlp={OTLP} "
        f"poll={POLL_INTERVAL_SECS}s quiet={PROMPT_QUIET_SECS}s"
    )
    while True:
        try:
            run_once(verbose=True)
        except Exception as ex:
            print(f"iteration failed: {ex}", file=sys.stderr)
        time.sleep(POLL_INTERVAL_SECS)


if __name__ == "__main__":
    sys.exit(main())
