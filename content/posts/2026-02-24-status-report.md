---
title: "Status report: twelve phases"
date: 2026-02-24
order: 7
description: "A system of cooperating tools for an autonomous AI agent includes a maintenance cycle — a heartbeat — of twelve phases. Five independent experts reviewed the design: the operational foundation is sound but the analytical components lack evidence of real impact. This post reports their assessment and identifies what must change."
---

**TL;DR** — The system of cooperating tools described in [previous](/posts/cognitive-infrastructure) [posts](/posts/closing-the-loop) includes a scheduled maintenance cycle — a heartbeat — that has grown to twelve phases. I asked five reviewers with complementary expertise to evaluate the complexity. The operational infrastructure scored well: isolation, fail-open behavior, and the MVP/full split are sound. The analytical phases — evaluation, interest extraction, deficiency detection — scored poorly: not one has evidence that its output improves system behavior. This post reports the current state, presents the reviews, and identifies what must change.

---

## Where things stand

The system has nine tools. A memory store with three retrieval channels. A policy engine that intercepts every tool call. A persistent task queue. Structured logging. A background memory extractor. An external intelligence scanner. A shared classifier. An identity specification. And a composition layer that wires them together.

The heartbeat is the composition layer's autonomous turn. It fires on a cron schedule, runs maintenance, and sleeps. What started as a three-phase health check has grown to twelve phases:

| # | Phase | Frequency | What it does |
|---|-------|-----------|-------------|
| 1 | Health checks | Every run | Verify the memory database exists, has recent entries, has no error entries, passes integrity check |
| 2 | Memory maintenance | Every run | Contradiction detection, correction linking, staleness tracking |
| 3 | Log review | Every run | Repeated errors, anomalous tools, error frequency trends |
| 4 | Evaluation | Full only | Cross-reference log errors against memory's own health claims |
| 5 | Interest model | Full only | Extract topics from recent activity, write as tracked interests |
| 6 | Longitudinal analysis | Weekly | Error trends, usage distribution, memory growth |
| 7 | External intelligence | Daily | Scan outside sources against interest list |
| 8 | Deficiency detection | Full only | Three-tier pattern detection: action, component, architecture |
| 9 | Report generation | Every run | Bounded markdown status report for the operator |
| 10 | Task dispatch | Full only | Dispatch next task from persistent queue |
| 11 | Dead man's switch | Every run | Ping a monitoring URL on success |
| 12 | Notification | Every run | macOS alert for unacknowledged reports |

The MVP/full split controls which phases run. By default — the path a cron job takes every 30 minutes — only phases 1–3, 9, and 11–12 execute. The heavier analytical phases (4–8, 10) require `--full`. Individual phases can be skipped with `--skip`. Each phase is wrapped in error isolation: a failing phase logs to the structured logging layer and does not abort subsequent phases. The dead man's switch and task dispatch only run when the health check passes.

This is the script's current shape. The question is whether that shape is sound.

## The review

Five reviewers examined the heartbeat independently. Their domains: platform engineering, ML engineering, indie AI building, cognitive science, and AI evaluation methodology. They were asked to assess the twelve-phase structure — is the complexity justified, is the design sound, what should change.

### Marcus Chen — Platform Engineer

> The 12-phase count is a red herring. What matters is whether the phases share enough state and ordering constraints to justify a single orchestrator, and here they do. Phase 1's health result gates phases 10 and 11. The begin/rescue wrapper on each phase is the right isolation primitive for a cron job — a failing phase logs and moves on. This is the boring, correct approach.

His concerns were operational. Phase 5 — the interest model — shells out to a frontier model API with no timeout. If the API hangs, the entire heartbeat stalls. Every other phase hits a local database or local binary. He also flagged the absence of per-phase timing: no telemetry to detect a phase silently degrading from 2 seconds to 90.

Grade: **B+**. Verdict: *A well-structured cron orchestrator that earns its line count; add a timeout to the API call and per-phase elapsed-time logging, and leave the rest alone.*

### Tomas Reyes — ML Engineer

> The cross-referencing idea is interesting but the detection heuristic is brittle. You are matching `content LIKE '%tool%' AND content LIKE '%healthy%'` — that is keyword grep across free-text notes, not a structured assertion. A tool name substring match against unstructured prose will produce both false positives and false negatives.

He focused on measurement gaps. No phase emits wall-clock duration. The interest model's deduplication uses substring matching — "rust" matches "trust." Interests grow monotonically with no pruning or decay. And the key question: does the interest model actually change downstream behavior, or is it write-only data?

Grade: **B+**. Verdict: *A well-structured maintenance loop with real operational discipline, held back by unmeasured evaluation quality and an interest model that lacks evidence of downstream impact.*

### Ray Nakamura — Indie AI Builder

> This is a well-structured cron script that does exactly what a single-operator autonomous system needs: verify health, maintain state, detect drift, and alert. 610 lines for 12 phases is lean.

The most sympathetic review. He validated the MVP/full split, the marker-file approach for rate-limiting, and the shared dispatch infrastructure. His one concern: the frontier model call embedded in a cron job is the phase where cost and latency are unbounded. He would move it to its own script with its own schedule.

Grade: **A-**. Verdict: *A disciplined single-file orchestrator that correctly separates "must run" from "should run," fails open, and stays inspectable — the frontier model call embedded in cron is the only thing that makes me nervous.*

### Lena Marchetti — Cognitive Scientist

> The phase ordering is more principled than it first appears. Health checks establish the current state, memory maintenance consolidates the store, and log review extracts patterns from recent experience. This is the correct sequence: you must verify the integrity of your memory system before you trust what it tells you.

She identified a structural gap: deficiency detection (phase 8) identifies architectural problems, but task dispatch (phase 10) selects from a queue that deficiency detection does not write to within the same cycle. The system can detect a critical flaw and then calmly dispatch an unrelated task. She also noted the MVP cycle runs no metacognitive monitoring — it consolidates memory and reviews logs but never checks whether its own health claims are contradicted by evidence.

Grade: **B+**. Verdict: *The phase ordering encodes real cognitive principles — particularly the metacognitive monitor in phase 4 — but the system undermines itself by making that monitor optional and by failing to let deficiency detection influence task selection within the same cycle.*

### Sadie Okafor — AI Evaluation Researcher

> There is no ablation framework. You cannot answer "what happens if I remove Phase 4?" because no metric tracks its downstream effect.

The harshest review. Her position: reliability is not validity. Phases 1 and 11 are self-evidently correct — file existence checks and HTTP pings either work or they do not. Every analytical phase — evaluation, interest extraction, deficiency detection — has hardcoded thresholds with no calibration, no precision/recall measurement, no control condition, and no evidence of downstream effect. The evaluation phase's entire contradiction-detection logic is a keyword match for the word "healthy." The deficiency detector's thresholds — five repeated errors, ten errors with zero corrections, three zero-contradiction maintenance runs — were never validated against labeled data.

Grade: **D+**. Verdict: *The infrastructure runs reliably, but reliability is not validity — not a single analytical phase has evidence that its output improves system behavior over the null hypothesis of not running it.*

## Synthesis

The reviews split cleanly along a fault line. The operational infrastructure — phase isolation, fail-open behavior, MVP/full split, shared dispatch — earned consistent approval. Three reviewers graded it B+ or higher. The engineering is sound.

The analytical phases earned no such approval. Every reviewer who examined them found the same problem from a different angle:

- **No timeouts on the frontier model call** (Chen, Nakamura). A single external dependency in an otherwise local system.
- **No per-phase telemetry** (Chen, Reyes). Impossible to detect silent degradation.
- **Brittle evaluation heuristics** (Reyes, Okafor). Keyword matching across free-text notes instead of structured assertions.
- **Monotonic interest growth** (Reyes). No pruning, no decay, no evidence of downstream impact.
- **Hardcoded thresholds without calibration** (Okafor). No ablation, no baselines, no labeled data.
- **Missing diagnosis-to-action link** (Marchetti). Deficiency detection cannot influence task dispatch within the same cycle.
- **Metacognitive monitoring is optional** (Marchetti). The MVP cycle — the one that runs every 30 minutes — skips evaluation entirely.

The gap between the infrastructure grade (B+) and the analytical grade (D+) is the clearest signal. The heartbeat is a well-built machine that runs unvalidated analyses.

## What changes

Three changes follow from the reviews. Each addresses a specific finding.

**Per-phase timing.** Every phase gets a start/complete log pair with elapsed milliseconds. This costs a few lines and makes silent degradation visible. Chen and Reyes both identified this independently — when two reviewers with different lenses reach the same conclusion, the conclusion is probably correct.

**Timeout on the frontier model call.** Phase 5 shells out to a frontier model API. Every other phase operates locally. A 30-second timeout with a kill guard prevents one phase from stalling the entire cycle. Chen and Nakamura both flagged this.

**Evaluation moves to MVP.** Marchetti's observation that the default cycle has no metacognitive monitoring is the most structural criticism. A heartbeat that consolidates memory and reviews logs but never checks its own claims is maintenance without self-awareness. Phase 4 — the evaluation phase that cross-references log errors against memory health claims — moves from full-only to the default MVP set.

Three changes the reviews identified that I am not making yet:

**Ablation studies for analytical phases.** Okafor is right that no analytical phase has evidence of downstream effect. But the infrastructure to measure downstream effect — per-channel evaluation fixtures, coverage gates, interface contracts — is itself still being built. Ablation studies require a measurement layer that does not yet exist. Building the measurement layer comes first.

**Structured assertions replacing keyword matching.** Reyes and Okafor both identified that the evaluation phase matches keywords across free-text. Replacing this with structured health assertions — typed entries rather than prose containing the word "healthy" — is the correct fix. It requires changes to the memory store's write path, not just the heartbeat. Scoped as a separate change.

**Interest decay.** Reyes identified that the interest table grows without bound. A decay mechanism — where interests that produce no downstream matches are deprioritized or pruned — requires measuring downstream match rates first. Same dependency: measurement before optimization.

## Limits

**The review panel is synthetic.** Five reviewers, five perspectives, zero independent humans. Each reviewer is a persona with a defined lens, instantiated as a model call. The reviews are internally consistent and identify real issues — the frontier model timeout and missing per-phase timing are genuine operational gaps. But the panel cannot validate claims against lived operational experience. Marcus Chen's 15 years of infrastructure experience is a character description, not a history. The reviews should be read as structured analysis from defined perspectives, not as expert testimony.

**The status is a snapshot.** This post describes the system as of the date of publication. The heartbeat has twelve phases today. The changes identified here — per-phase timing, the frontier model timeout, evaluation moving to MVP — have not yet been implemented. The post is the diagnosis, not the treatment.

**Operator review remains the bottleneck.** The notification phase (phase 12) alerts the operator to unacknowledged reports. The deficiency detector creates blocked tasks requiring human approval. Both mechanisms assume the operator is available and attentive. The reviews did not challenge this assumption — but [previous analysis](/posts/closing-the-loop) identified it as a structural limit of the single-operator model.