---
title: "Heartbeat validation"
date: 2026-02-28
description: "A review panel gave Prophet's heartbeat—a 12-phase maintenance process—an F: 0 of 12 phases validated. The sole test accepted both exit 0 and exit 1 as passing — a tautology. We built 40 tests (30 per-phase, 10 integration), found 3 bugs, and rewrote the ablation runner—a tool for testing phase contributions—to measure artifacts (outputs and state changes) instead of exit codes. The correct study order is validate, integrate, ablate."
---

**TL;DR** — A review panel graded Prophet's heartbeat—a 12-phase maintenance process—test coverage F: zero of 12 phases had been validated to produce their intended output in isolation. The sole heartbeat test was a tautology — it accepted both exit 0 and exit 1 as passing. We built 40 tests (30 per-phase unit tests, 10 integration tests), found 3 bugs, and rewrote the ablation runner—a tool for testing phase contributions—to measure artifacts (outputs and state changes) instead of exit codes. The correct study order is validate, then integrate, then ablate.

---

## The verdict

Five reviewers examined Prophet's heartbeat. Unanimous F. The finding: zero of 12 phases had been validated to produce their intended output in isolation.

The heartbeat has 12 phases — health checks, memory maintenance, log review, evaluation, interest model, longitudinal analysis, external intelligence, deficiency detection, report generation, task dispatch, a dead man's switch ping, and notification. Each phase is wrapped in `begin/rescue` so a failing phase does not abort subsequent phases. These phases interact with subsystems like crib (memory database), spill (error log), Dispatch (task system), and book (task database). A [previous ablation](/posts/heartbeat-ablation) measured exit codes and error counts when skipping each phase one at a time.

That ablation was premature. You cannot measure what a phase contributes by removing it if you have not first proven it works.

## The tautology test

The entire heartbeat test suite was:

```ruby
def test_heartbeat
  _, st = Open3.capture2e(File.join(PROPHET_ROOT, 'bin', 'heartbeat'))
  if st.success?
    pass 'bin/heartbeat (MVP mode) exits 0'
  else
    pass 'Heartbeat detects issues and exits nonzero'
  end
end
```

Both branches pass. Exit 0? Pass. Exit 1? Also pass. A test that cannot fail is not a test.

This existed because heartbeat's exit code depends on system state (whether crib.db has recent entries, whether errors exist). The test author avoided a fragile assertion by accepting all outcomes. The result: zero validation.

## Per-phase validation

Making heartbeat testable required one structural change. The script called `exit run` at the top level — `require`ing it meant executing every phase and terminating the process. A `$PROGRAM_NAME == __FILE__` guard wraps the CLI code, letting tests `load` the file and call phase functions directly.

Each of 12 phases got tests covering both the "findings exist" and "no findings" paths:

| Phase | Tests | Key assertions |
|-------|-------|----------------|
| health_checks | 4 | Detects missing DB, stale entries, errors; returns empty when healthy |
| memory_maintenance | 2 | Calls crib maintain, handles failure |
| log_review | 3 | Finds repeated errors, detects anomalous tools, handles empty spill |
| evaluation | 3 | Detects contradiction, no false positives, handles empty spill |
| interest_model | 3 | Creates interests, deduplicates, skips on empty crib |
| longitudinal | 3 | Runs when due, skips when recent, writes summary |
| peep | 2 | Calls peep and touches marker, respects daily gate |
| diagnose | 2 | Calls diagnose, handles failure |
| report | 2 | Calls report, handles failure |
| dispatch | 2 | Calls book dispatch, logs error on failure |
| dms_ping | 3 | Fires with URL, skips without URL, skips with empty URL |
| notify | 1 | No-op — no notification channels configured yet |

30 tests. Each creates temp SQLite databases with controlled rows, calls a phase function directly, and asserts specific outcomes — crib entries written, Dispatch calls made, markers touched, or nothing happening when nothing should happen.

The "nothing written" tests are the ones the previous suite completely lacked. A phase that silently does nothing on every run is indistinguishable from a phase that works, unless you test the positive path.

## Three bugs

Per-phase validation revealed three bugs:

**1. log_review always writes a note.** Line 196 unconditionally appended a trend finding (`"error trend: stable (0 recent vs 0 previous 6h)"`) to the findings array. Even when no errors existed and no anomalies were detected, `findings` was never empty. Every heartbeat run wrote a `[log-review]` note to crib — noise that obscured real findings. Fix: only append the trend line when the trend is not stable or when other findings exist.

**2. longitudinal touches a marker on nil DBs.** The longitudinal phase runs weekly, gated by a marker file. The marker touch lived outside the `if findings.any?` block. When both databases were nil (files missing), findings was empty, but the marker was still touched — preventing a retry when databases became available. Fix: move the marker touch inside the findings check.

**3. dms_ping ignores curl's exit status.** `Open3.capture2` returns both output and a status object, but the status was discarded. A failing curl (network error, DNS failure, timeout) was indistinguishable from a successful ping. Fix: check `status.success?` and log a warning on failure.

## Integration validation

Ten integration tests verify that phases compose correctly:

- **Gating**: health_checks issues gate dispatch and dms_ping — both skip when issues are non-empty.
- **Isolation**: a raising phase does not abort subsequent phases.
- **Weekly/daily gates**: longitudinal and peep respect their marker files.
- **Mode gating**: MVP mode skips 7 full-only phases; full mode runs all.
- **Exit code**: empty issues returns 0, non-empty returns 1.
- **Bug fix verification**: stable trend with no findings writes nothing; nil DBs do not touch the longitudinal marker.
- **End-to-end**: health_checks issues pass through to notify (currently a no-op awaiting channel configuration).

## What changed in ablation

The [first ablation](/posts/heartbeat-ablation) measured three things per run: exit code, wall time, and spill error count. Ten of 11 skip runs produced identical results — same exit code, same error count. The conclusion was that only `health_checks` is load-bearing.

That conclusion was correct at the exit-code level but missed the point. Most phases do not affect exit code. They write crib entries, create reports, or dispatch tasks. An ablation that measures only exit code cannot see these contributions.

The rewritten ablation runner (`bin/ablate-heartbeat`) snapshots artifact state (new files written and database entries created) before and after each run:

- **Crib entries created** — grouped by type (note, correction, interest, error)
- **Crib entry content** — the actual text written, truncated to 120 characters
- **Report files created** — count of new `.md` files in the reports directory
- **Book task state changes** — count of tasks in book.db

Now skipping `log_review` shows fewer `note` entries. Skipping `evaluation` shows fewer `correction` entries. Skipping `interest_model` shows fewer `interest` entries. Skipping `report` shows fewer report files. Each phase's contribution becomes visible through its artifacts (outputs and state changes), not through the exit code it does not affect.

## The correct study order

The review panel's implicit lesson: validate, then integrate, then ablate.

1. **Per-phase validation** proves each phase produces its intended output in isolation. Without this, you cannot distinguish a working phase from a no-op.
2. **Integration validation** proves phases compose correctly — gating logic works, errors are isolated, data flows between phases.
3. **Ablation** measures each phase's marginal contribution. This is only meaningful after steps 1 and 2. An ablation of unvalidated phases measures the contribution of code that might not work.

The first ablation skipped steps 1 and 2. The result was technically correct (exit codes matched) but told us almost nothing about 10 of 11 phases. An F for coverage.

## Limits

**Testing with mocks.** The per-phase tests use temp databases and Dispatch stubs, not production databases and real sibling binaries. A phase that passes with mock data could still fail in production if the real database schema differs or a sibling binary behaves differently than the stub.

**No interaction testing.** Integration tests verify pairwise relationships (health_checks gates dispatch) but do not test all combinations. 12 phases admit 66 pairwise interactions and 4,096 subsets. The 10 integration tests cover the architecturally significant interactions, not all possible ones.

**Bug fixes not yet validated in production.** The four bug fixes have tests that verify the fix works in isolation. Whether the fixes change production behavior (e.g., fewer noisy `[log-review]` notes in crib) requires observation over days.

**Ablation artifacts depend on database state.** A fresh temp database with no recent entries will produce different artifact deltas than a production database with months of history. The ablation measures phase contributions given the current database state, not phase contributions in general.