---
title: "Interface contracts"
date: 2026-02-27
description: "Prophet, my operating system, had seven modules, each with a doctor subcommand that checked liveness — process can start, dependencies present. But liveness is not correctness. A module can start and still produce wrong output. Adding protocol_version to every module and output-shape probes to each doctor extends the contract from 'alive' to 'alive and speaking the expected language.'"
---

**TL;DR** — Prophet, my operating system, has a `bin/doctor` that checked whether each module was alive. It did not check whether each module produced the right output shape. Adding a `protocol_version` field and per-module output-shape probes to each doctor extends the contract from liveness to correctness-of-shape. Seven probes now run across seven modules. Five pass cleanly, one warns (a module called trick extracted no memories from a minimal transcript), one skips (a module called peep lacked a CRIB_DB—an environment variable—in the aggregator context). Shape is not semantics, but it catches a class of failures that liveness cannot.

---

## The gap

Prophet has seven modules: crib (memory), hooker (policy engine), screen (classifier), book (task queue), spill (structured log), trick (memory extraction), and peep (external intelligence). Each module has a `doctor` subcommand. Before this work, every doctor answered one question: can this module start?

A doctor check for crib verified that Ruby, SQLite, ollama, and the embedding model were present. It did not verify that a write-then-retrieve round-trip produced XML in the expected `<memory context_time="...">` envelope. A doctor check for screen verified that ollama was reachable. It did not verify that a trivially true classification produced `yes` on stdout.

The [observable-by-default post](/posts/observable-by-default) established `bin/doctor` as the system's primary health surface. But a liveness check is a necessary condition, not a sufficient one. A module can be alive and produce output in a format its callers do not expect.

Two things were missing: a version contract (does this module speak the same protocol as its caller?) and a shape contract (does the output look right?).

## The method

### Protocol version

Prophet's aggregator already declared an expected protocol version per module (version 1 for all seven) and checked each doctor's response for a `protocol_version` field. No module reported one. Every module doctor produced a warning: `no protocol_version reported`.

Fix: one line per module. `report['protocol_version'] = 1` before the `report['ok']` calculation. Seven files, seven one-line changes.

### Output-shape probes

Each module's doctor gained a `--probe` flag. When present, the doctor runs a self-contained test after the existing liveness checks and adds a `probe` key to its JSON report. Prophet's aggregator calls each module's `doctor --probe` and collects results under `probe:module_name` keys.

Design constraints:

- **Model-dependent probes are gated on ollama reachability.** Screen and trick require a running model. If ollama is down, their probes report `"skipped": "ollama unavailable"` instead of failing.
- **Write probes use temp databases.** Crib, book, and trick probes create isolated databases in `/tmp`, run their round-trip, and clean up. Production data is never touched.
- **Probe failures are warnings, not hard failures.** A probe that fails sets `"ok": true` with a `"warn"` key. The overall doctor health is not affected. This prevents flaky model output from blocking deployments while still surfacing the issue.

PreToolUse is an event type representing a tool about to be invoked.

The probe table:

| Module | Probe | Validates |
|--------|-------|-----------|
| crib | Write to temp DB, retrieve via FTS | Output contains `<memory context_time=` |
| hooker | Pipe minimal PreToolUse event | Exit 0; if output present, JSON with `hookSpecificOutput` key |
| screen | Feed trivially true classification | Exactly `yes` or `no` on stdout |
| book | Init temp DB, add task, call `next` | JSON with `id` and `description` keys |
| spill | Query last 5 log entries | Each entry is JSON-serializable |
| trick | Feed single-fact transcript with temp DB | At least one entry written to temp DB |
| peep | Run with `--dry-run` | Exit 0 with stdout (empty is valid) |

### Aggregator

Prophet's `bin/doctor` already ran a liveness loop calling each module's `doctor` subcommand. A second pass now calls each module's `doctor --probe` and extracts the `probe` key from the response.

## Results

Running `bin/doctor` with probes enabled:

| Module | Liveness | Protocol | Probe |
|--------|----------|----------|-------|
| crib | ok | 1 | ok |
| hooker | ok | 1 | ok (allow, no matching policies) |
| screen | ok | 1 | ok (answer: `yes`) |
| book | ok | 1 | ok |
| spill | ok | 1 | ok (5 lines) |
| trick | ok | 1 | warn: no entries extracted |
| peep | ok | 1 | skipped: CRIB_DB unavailable |

Five of seven probes pass cleanly. Two produce expected non-failures:

**Trick** warns that no memories were extracted from a one-sentence transcript. This is an expected limitation of gemma3:1b — a single-line input often falls below the extraction threshold. The probe confirms trick can receive input, call the model, and write to crib. The zero-entry result reflects model capability, not a shape violation.

**Peep** skips because the aggregator runs without `CRIB_DB` set in its environment. Peep requires a crib database to load interests for classification. When run in an environment with `CRIB_DB` set, the probe executes normally.

The protocol version gap — seven modules, all missing `protocol_version` — was the kind of silent drift that liveness checks cannot catch. Every doctor reported `ok: true` while the aggregator warned `no protocol_version reported` on every module. A seven-line fix closed a seven-module gap.

## Limits

**Shape is not semantics.** A probe that verifies `<memory context_time=` in the output does not verify the memory is relevant. A probe that verifies `yes` on stdout does not verify the classification is correct. Semantic correctness requires the [evaluation harness](/posts/testing-always-on), not a doctor check.

**Model-dependent flakiness.** Screen and trick probes depend on ollama model output. A model upgrade, a different quantization, or GPU memory pressure could cause a probe that passed yesterday to warn today. The warning-not-failure design absorbs this, but it means a probe warning is a signal to investigate, not a guarantee of breakage.

**Hooker context dependency.** The hooker probe sends a minimal event with the current working directory. If no policies exist in that directory, hooker exits 0 with no output — which the probe treats as success. This means the probe validates parsing and exit behavior but not the full policy-evaluation pipeline. A deeper probe would require a test policy file.

**Peep environment dependency.** The peep probe requires `CRIB_DB` in the environment. Running `bin/doctor` from a context without this variable causes the probe to skip. This is an environment gap, not a code gap, but it means the aggregator's probe coverage depends on how the aggregator is invoked.