# Migration plan — native 3D viewer for Claude Code telemetry

## Why this migration, scoped narrowly

The current `ae3e-plotly-panel` does what's needed for a personal dashboard
but hits real ceilings:

- **No GPU acceleration worth speaking of.** Plotly's 3D path is WebGL, with
  one big context per panel; the RTX 2080 Ti in this machine sits at <1%.
- **No persistent state between renders.** Camera, selection, hover are all
  reset each Grafana refresh — bad for live exploration.
- **Constrained interaction model.** Hover tooltips, click-to-pin, drag-to-
  rotate are workable but feel slow; particle effects, glow, animated edges
  are off the table.
- **Edge-case bugs.** Variable substitution, data-frame-shape detection, and
  panel sizing all needed iterating around plugin quirks.

Everything else (Grafana 2D panels, Prom, Tempo, Loki, the OTel collector,
hooks, alerts) stays exactly as it is. **The migration is scoped to the 3D
agent-topology view only.** That panel becomes a separate native Linux
application that pulls the same Loki / Prometheus data the Grafana panel
already pulls.

## Goals

- A native Linux app that shows the agent-topology 3D graph at 60 fps with
  smooth orbit / pan / zoom and instant hover tooltips.
- Pulls live data from `localhost:3100` (Loki) and `localhost:9090`
  (Prometheus) on a configurable interval (default 5 s).
- Single binary distribution; no browser; no Electron.
- Same conceptual model as the Plotly panel — query_source nodes, model
  nodes, edges weighted by call count — but with room to grow into other
  3D views (cognitive-throughput surface, entropy field, etc.).

## Non-goals

- Replace Grafana for 2D panels — those work fine in browser.
- Migrate Prom / Tempo / Loki / collector — orthogonal.
- Cross-platform (macOS / Windows). Linux-only is the target.
- Mobile / VR / web export.
- Auth, multi-user, persistence beyond a local config file.

## Stack options

| Stack | Pros | Cons | Time-to-MVP |
|---|---|---|---|
| **Rust + Bevy 0.15** *(recommended)* | Modern wgpu renderer (Vulkan on Linux); ECS fits node/edge model perfectly; built-in animation, materials, particles, post-processing; `bevy_egui` for control panels; force-directed-layout crates exist; single static binary; uses the GPU you actually have | Compile times ~10–30 s incremental; Rust learning curve if unfamiliar | 1–2 days for first usable view, 3–5 days for polished |
| Rust + wgpu + egui (no Bevy) | Lighter dep tree; faster compiles; full control | Have to write the scene-graph / camera / picking yourself | 2–3 days |
| Python + Polyscope | One-import 3D viewer; trivial setup; great for static graphs | Limited animation / shader hooks; awkward for live updates; opinionated UI | <1 day for static, hard to grow |
| Python + PyQt6 + pyqtgraph.opengl | Familiar Qt UI; OpenGL-backed 3D | PyQt6 GL widget is older OpenGL ES style; performance ceiling lower than wgpu; packaging on Linux is finicky | 1–2 days |
| TypeScript + Tauri | Reuse existing Plotly code | Still browser rendering inside the Tauri webview — defeats the goal | n/a |

## Recommended: Rust + Bevy

Justification, given the actual machine and goals:

1. **It's the only stack that turns the 2080 Ti loose.** Bevy uses wgpu →
   Vulkan on Linux. Smooth orbit on graphs with thousands of nodes is the
   floor, not the ceiling.
2. **ECS maps to node/edge graphs without ceremony.** Each query_source,
   model, tool, prompt becomes an entity with components for position,
   metric values, and visual style. Adding new node types later is a
   one-component change.
3. **Animations and shaders are batteries-included.** Pulsing entry-cost
   nodes, flowing edges, depth-of-field, glow on hover — no plugin
   shopping. `bevy_hanabi` for particles when wanted.
4. **`bevy_egui` solves the "I need a control panel" problem cleanly.**
   Dimension dropdowns, time-window slider, layout toggle, all in egui
   panels overlaid on the 3D scene.
5. **Single binary deploys.** `cargo build --release` produces a ~30 MB
   self-contained executable. Add a `.desktop` entry and it shows up in
   the launcher.
6. **Active 0.15 release** with stable API for the relevant plugins.

The cost is Rust compile time and a learning ramp if Bevy is new — both
acceptable for a tool that's going to be used daily.

## Architecture

```
┌────────────────────────────────────────────┐
│ cc-viz (native binary)                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │ Loki     │  │ Prom     │  │ Config   │  │
│  │ client   │  │ client   │  │ (TOML)   │  │
│  └─────┬────┘  └─────┬────┘  └─────┬────┘  │
│        └────┬────────┴─────────────┘       │
│             ▼                              │
│   ┌────────────────────┐                   │
│   │ Telemetry resource │ — refreshed every │
│   │ (Bevy Resource)    │   5s by polling   │
│   └─────────┬──────────┘                   │
│             ▼                              │
│   ┌────────────────────┐  ┌──────────────┐ │
│   │ Scene update sys   │  │ Layout sys   │ │
│   │ (spawn/despawn     │◄─│ (force-dir   │ │
│   │  entities, lerp    │  │  or static)  │ │
│   │  positions)        │  └──────────────┘ │
│   └─────────┬──────────┘                   │
│             ▼                              │
│   ┌────────────────────┐  ┌──────────────┐ │
│   │ Render (wgpu)      │  │ egui UI      │ │
│   │ — nodes, edges,    │  │ — controls,  │ │
│   │   labels, glow     │  │   tooltips   │ │
│   └────────────────────┘  └──────────────┘ │
└────────────────────────────────────────────┘
```

Same Loki / Prometheus / OTel collector — the viewer is a *new client* of
the existing data sources, not a replacement.

## Phased rollout

Each phase ends in something runnable.

### Phase 1 — Bootstrap & data plumbing (≤ 4h)
- `cargo new cc-viz`, add Bevy + reqwest + serde + tokio.
- Loki client: HTTP polling for the same five queries the Plotly panel
  uses (per-query_source cost / latency / tokens / requests + edges).
- Prometheus client (light): for tool-decision counts so we can colour
  query_source nodes by current activity rate.
- Test harness: pretty-print the parsed responses to stdout. No render yet.

### Phase 2 — Static 3D scene (≤ 4h)
- Spawn one entity per query_source positioned by (cost, latency_p95,
  output_tokens). Cube primitives initially, sized by request count.
- Spawn model entities at edge-weighted centroids, lifted on Z.
- Edge primitives as cylinders or polylines.
- Free-orbit camera (`bevy_panorbit_camera` crate). Mouse drag to rotate,
  scroll to zoom.

### Phase 3 — Polish (≤ 1d)
- Replace cube primitives with custom shader: PBR sphere with rim glow,
  emissive proportional to recent rate-of-change.
- Edge shader with animated dash flow indicating direction (call → model).
- Hover detection via raycasting; floating tooltip with all four metrics.
- Text labels via `bevy_text` overlay.

### Phase 4 — Live updates (≤ 4h)
- Bevy `Time`-driven system polls Loki every 5 s on a background task.
- Smooth `lerp` between old and new positions / sizes (no jump cuts).
- New nodes fade in; vanished nodes fade out and despawn.

### Phase 5 — Control panel (≤ 4h)
- `bevy_egui` overlay top-left: dropdowns for X / Y / Z dim, time-window
  picker, refresh-rate slider, "pause polling" toggle.
- Persist last-selected dims to `~/.config/cc-viz/config.toml`.

### Phase 6 — Ship (≤ 2h)
- `cargo build --release` → single binary ~30 MB.
- Drop a `.desktop` file in `~/.local/share/applications/` so it shows up
  in the activity launcher.
- Optional: systemd user service if you want it always-on.

**Total effort for production-quality:** ~3–5 days of focused work. MVP
(phases 1–2) in a single afternoon.

## File layout (proposed)

```
cc-viz/                         # new sibling project to monitor-claude
├── Cargo.toml
├── README.md
├── src/
│   ├── main.rs                 # Bevy App setup
│   ├── data/
│   │   ├── mod.rs
│   │   ├── loki.rs             # query_range / instant queries
│   │   └── prom.rs
│   ├── scene/
│   │   ├── mod.rs              # Bevy plugin: spawn / update entities
│   │   ├── nodes.rs
│   │   ├── edges.rs
│   │   └── layout.rs           # dimension projection
│   ├── ui/
│   │   ├── mod.rs              # egui plugin
│   │   ├── controls.rs
│   │   └── tooltip.rs
│   └── config.rs
├── assets/
│   ├── shaders/
│   │   ├── node_glow.wgsl
│   │   └── edge_flow.wgsl
│   └── fonts/Inter-Regular.ttf
├── packaging/
│   ├── cc-viz.desktop
│   └── cc-viz.service          # optional systemd user unit
└── docs/
    └── DESIGN.md
```

Lives beside `monitor-claude/`, not inside, because it's a separate
artifact with a different toolchain. Both projects are independently
buildable.

## Dependencies to install

Already on this machine:
- ✅ Ubuntu 24.04 (noble)
- ✅ Vulkan loader + GPU drivers (NVIDIA RTX 2080 Ti)
- ✅ Python 3.12 (only needed for the existing stack, not the viewer)

To add:
- `rustup` toolchain (`curl https://sh.rustup.rs -sSf | sh`)
- Build prerequisites: `sudo apt install build-essential pkg-config
  libssl-dev libudev-dev libasound2-dev libxkbcommon-dev libwayland-dev
  libx11-dev` (Bevy's standard Linux deps)

## Open decisions

These need a call before / during implementation:

1. **Layout algorithm** — fixed positioning by metric values (current
   Plotly behaviour, intuitive) vs. force-directed (groups by edge
   weight, prettier, loses metric encoding). My pick: keep metric-based
   for X/Y/Z, optionally add a "spread" button for force-directed
   adjustment.
2. **Time scope** — match Grafana's `$__range`, or always show the
   last 30 min? My pick: configurable, default 1 h.
3. **Beyond agent topology** — should `cc-viz` grow into a multi-view
   app (3D entropy field, cognitive-throughput surface, latency density
   plot) or stay single-purpose? My pick: single-purpose first; refactor
   if a second view becomes obvious.
4. **Always-on or launched** — systemd user service vs. desktop launcher
   only? My pick: launcher only initially; systemd unit later if the
   refresh becomes part of your routine.
5. **Distribution to others** — keep private or eventually publish
   `cc-viz` as a generic Claude Code observability viewer? My pick: build
   it private, decide after 2 weeks of daily use.

## Migration steps for the existing dashboard

When `cc-viz` ships, the Plotly panel becomes redundant but isn't strictly
harmful. Recommended:

1. Keep panel id 26 in `claude-code.json`, but mark its title as
   "(legacy — see cc-viz desktop app)" so future readers know.
2. Delete it after 2 weeks of `cc-viz` usage if it's not missed.
3. Leave the dashboard variables `x_dim`, `y_dim`, `z_dim` in place — they
   don't cost anything and could be reused if a 2D variant of the
   topology view is added to Grafana later.

## Risks & mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Bevy API churn (new minor versions break things) | Medium | Pin to `bevy = "0.15"` exactly in Cargo.toml; only bump intentionally. |
| Loki query shape changes when Claude Code updates telemetry | Medium | Keep the data-fetch layer thin, version it (`v1`), assert on response shape with helpful errors. |
| First-time Rust compile takes 5+ minutes | High | Expected — `cargo build` once, then incremental builds are fast. Use `cargo --no-default-features` for faster dev cycles. |
| GPU drivers misbehave under wgpu | Low | NVIDIA + Vulkan is well-supported; fallback to OpenGL via `WGPU_BACKEND=gl` env var if needed. |
| Scope creep — feature requests pile up before MVP ships | High | Phases 1–2 ship first, period. Polish in 3+ only after the basic pipeline is real. |

## Success criteria

The migration is done when:

- The `cc-viz` binary launches in <2 s from cold start.
- The view holds 60 fps while orbiting with all 4 query_source nodes,
  ~20 model/tool nodes, ~50 edges live.
- Hover-to-inspect feels instant (<16 ms).
- A 5 s polling cycle shows new prompts joining the graph without flicker.
- I (Ricardo) prefer it over the Grafana Plotly panel for daily use.

That last bullet is the only one that matters. The others are how to get
there.
