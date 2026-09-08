# Pane performance — 2026-09-08

Switching preserves terminal instances, but latency increases with the number of retained panes. With 64 panes across 16 tabs, tab switching takes about 87 ms typically and 96 ms at the 95th percentile when idle. Continuous output raises the 95th percentile to 103 ms.

## Measurements

All retained-tab cases have four visible panes. The four-pane baseline measures focus between panes in one tab; the other rows measure switching between tabs. Times include waiting for the selected native terminal to receive focus and completing pending AppKit layout, **not GPU presentation or screenshot-based flash detection**.

| Retained panes | Tabs | Switch type | Idle p50 / p95 | Output p50 / p95 | App RSS, output | App CPU, idle / output |
|---:|---:|---|---:|---:|---:|---:|
| 4 | 1 | Pane focus | 9.7 / 17.1 ms | 10.0 / 21.3 ms | 145 MiB | 7.1% / 13.6% |
| 16 | 4 | Tab switch | 43.2 / 47.6 ms | 42.2 / 49.9 ms | 193 MiB | 9.0% / 20.6% |
| 32 | 8 | Tab switch | 61.8 / 64.1 ms | 63.8 / 65.8 ms | 256 MiB | 9.6% / 25.4% |
| 64 | 16 | Tab switch | 86.9 / 96.2 ms | 78.7 / 102.6 ms | 385 MiB | 11.8% / 48.1% |

A separate foreground run with **16 simultaneously visible panes in a single 4×4 grid** measured 24.3 ms p50 / 26.3 ms p95 pane focus, 241 MiB app RSS, and 20.9% idle app CPU. It had no other retained tabs. The full run also verified lifecycle retention and cleanup with 76 total panes and 16 visible, but its dense-grid timing is excluded because the application lost foreground activation.

CPU is for the benchmark application only; 100% means one fully occupied CPU core. RSS excludes the Herdr server, one terminal-control CLI process per mounted pane, shell/output-generator processes, and memory not represented in process RSS. These figures are not total system memory or CPU costs.

## Method

- This Mac: macOS 26.6.2, 12 logical CPUs, 36 GiB RAM; native window 1440×900 points.
- Production `WorkspaceView`, `TerminalSurface`, and Ghostty implementation, linked into an opt-in harness. Swift release `-O` optimization; whole-module optimization disabled so the harness can replace the app entry point. This is not an instrumented copy of the already-running app executable.
- Real disposable local Herdr server and terminal-control streams; no changes to the user's session. Every tab is visited and terminal content is verified before measurement. Normal session polling remains enabled.
- Forty selection operations per sample, with 75 ms between completed operations. CPU is sampled over three seconds of steady idle/output before the switch loop.
- Output workload: every pane emits a short line approximately ten times per second. The harness verifies output has started and continues through the measurement, then interrupts generators and verifies the shell responds again.
- The final full-run table was collected without a profiler. An independent clean 64-pane run measured 85.1 / 87.2 ms idle p50/p95 and 73.4 / 93.1 ms with output, showing run-to-run variability.
- A 10 ms main-thread heartbeat in the final full run reached 49.6 ms maximum at 64 idle panes and 34.9 ms with output. It runs during the steady-state CPU interval, not during the switch loop, and is not a display frame-time measurement.
- Terminal object identities and live controllers survived every measured switch. Both completed runs released all terminal views on workspace closure and stopped their disposable servers.

## Follow-up target

A separate five-second stack sample showed substantial SwiftUI/AppKit layout and display-list work on the main thread. Code inspection shows that retained split trees and pane cards observe the shared `SessionStore`, so changing selection can invalidate hidden panes as well as visible ones. Narrowing those selection updates is the next optimization to investigate. This is a profiling-supported hypothesis, not a measured before/after fix.

Hidden Ghostty display links are stopped by the visibility path, but terminal streams stay connected and incoming output is still processed to preserve current content. Retention therefore has a resource cost even when a pane is hidden.

## Reproduce

```sh
bash scripts/benchmark-panes.sh
# Selected retained-pane counts:
HERDR_PERF_COUNTS=16,32,64 bash scripts/benchmark-panes.sh
# Four-pane baseline followed by sixteen visible panes:
HERDR_PERF_COUNTS=4 bash scripts/benchmark-panes.sh
```

The script builds and opens a benchmark window, creates disposable panes, prints results, and cleans up. Keep the benchmark foreground during measurement; `active=no` marks a sample whose foreground state was interrupted. The benchmark source is `Tests/HerdrMacTests/PanePerformanceTests.swift`.
