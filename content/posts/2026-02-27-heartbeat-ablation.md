---
title: "Heartbeat ablation"
date: 2026-02-27
description: "Prophet, an operating system, has a heartbeat with 11 phases. Skipping any one of them in isolation produces the same exit code and error count as the baseline — except health_checks, a problem-detection phase. Removing health_checks is the only change that flips the exit code from 1 to 0, because it silently lets the dispatch phase run without detecting problems. The health check is load-bearing. Everything else is additive."
---

**TL;DR** — Prophet's heartbeat runs 11 phases in sequence. An ablation — one baseline plus 11 single-skip runs — reveals that only `health_checks` changes the exit code when removed. Every other phase can be skipped without changing the outcome. Skipping `health_checks` flips exit 1 to exit 0 by leaving the `issues` array empty, which lets `dispatch` run on a stale database. The health check is load-bearing. The other 10 phases are additive.

---

## The gap

Prophet's [heartbeat](/posts/closing-the-loop) is a scheduled maintenance cycle with 11 phases: health checks, memory maintenance, log review, evaluation, interest model update, longitudinal analysis, external intelligence (peep), deficiency detection (diagnose), report generation, task dispatch, and a dead man's switch ping. Each phase is wrapped in `begin/rescue` — a failing phase logs to spill and does not abort subsequent phases.

This independence is a design choice. But independence alone does not answer the question: which phases are load-bearing? A phase is load-bearing if removing it changes the system's behavior. A phase that runs successfully but whose absence changes nothing is additive — it contributes data but does not gate decisions.

No data existed on which phases were load-bearing.

## The method

A Ruby script (`bin/ablate-heartbeat`) automates 12 runs:

1. Copy production databases (crib, book, spill—Prophet's primary data stores) to a temp directory
2. Unset `HEARTBEAT_URL` to prevent dead man's switch pings
3. Run `bin/heartbeat --full` with no skips (baseline)
4. For each of 11 phases, run `bin/heartbeat --full --skip <phase>` with fresh DB copies

Each run records exit code, wall time, and error count (queried from the temp spill database after each run).

The isolation is imperfect by design. Marker files for peep (daily) and longitudinal (weekly)—tracking when these tasks last ran—live in the production state directory, not the temp directory. This means the baseline's peep run touches the marker, and all subsequent runs skip peep due to the marker check. This is a confound but also a realistic picture: in production, peep only runs once daily regardless of heartbeat frequency.

## Results

| Run | Skipped | Exit | Time (s) | Errors |
|-----|---------|------|----------|--------|
| baseline | (none) | 1 | 197.0 | 1 |
| skip:health_checks | health_checks | **0** | 34.7 | **0** |
| skip:memory_maintenance | memory_maintenance | 1 | 24.3 | 1 |
| skip:log_review | log_review | 1 | 4.1 | 1 |
| skip:evaluation | evaluation | 1 | 27.8 | 1 |
| skip:interest_model | interest_model | 1 | 28.3 | 1 |
| skip:longitudinal | longitudinal | 1 | 30.0 | 1 |
| skip:peep | peep | 1 | 22.7 | 1 |
| skip:diagnose | diagnose | 1 | 23.2 | 1 |
| skip:report | report | 1 | 32.9 | 1 |
| skip:dispatch | dispatch | 1 | 28.2 | 1 |
| skip:dms_ping | dms_ping | 1 | 33.4 | 1 |

Every run except `skip:health_checks` exits 1 with exactly one error: "no memory entries in last 24 hours." That error comes from `health_checks`, which checks the temp crib database for entries created in the last 24 hours and finds none (the temp copy has no recent writes).

## The key finding

`skip:health_checks` is the only run that exits 0.

The mechanism: heartbeat's `health_checks` phase populates an `issues` array—a list of detected problems. If issues exist, `dispatch` and `dms_ping` are gated — they do not run. If `health_checks` is skipped, `issues` defaults to an empty array. An empty `issues` array means: no problems detected. Dispatch runs. The dead man's switch pings.

This is the answer to the plan's central question: does skipping `health_checks` silently let `dispatch` run on unhealthy state? Yes. The `issues` array defaults to empty, and empty is indistinguishable from healthy.

This is not a bug — it is an intentional design tradeoff. The `--skip` flag exists for operational use (e.g., skipping a broken phase during an incident). But the ablation makes the tradeoff visible: `health_checks` is the only phase where skipping changes the system's behavior at the exit-code level.

## Timing

The baseline (197s) is dominated by a single phase: `peep`. External intelligence fetches 30 Hacker News stories and classifies each against interests loaded from crib. At roughly 5 seconds per classification call, peep accounts for approximately 160 seconds of the baseline's 197-second runtime.

All skip runs complete in 4-34 seconds because the baseline's peep run touches a daily marker file. Subsequent runs check the marker and skip peep, regardless of which phase is being ablated. The `skip:log_review` run is fastest (4.1s) because log_review itself is lightweight (SQL queries against spill) and peep is marker-skipped.

The `interest_model` phase calls `claude -p` for topic extraction, but returns early when the temp crib database has no recent entries to extract from.

## Limits

**Single run per configuration.** Each of the 12 configurations ran once. A flaky phase could produce different results on a second run. The consistency across 10 of 11 skip runs (all exit 1, all 1 error) suggests stability, but this is not proven.

**No interaction effects.** The ablation skips one phase at a time. Skipping two phases simultaneously could reveal interactions — for example, skipping both `health_checks` and `memory_maintenance` might cause `evaluation` to find different results. A pairwise ablation (66 combinations) would be needed to detect interactions.

**Temp databases diverge from production.** The temp crib database has no entries from the last 24 hours, which triggers the health check error on every run. In production, a healthy system would have recent entries, and the ablation results could differ. The health_checks finding is an artifact of the temp setup — but the gating mechanism it reveals is real.

**Marker file confound.** The peep and longitudinal phases use shared marker files in the production state directory. The baseline run touches the peep marker, causing all subsequent runs to skip peep. This makes the timing comparison unfair for non-baseline runs but reflects realistic behavior: peep runs once daily regardless.