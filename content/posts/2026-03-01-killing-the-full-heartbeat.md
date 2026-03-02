---
title: "Killing the full heartbeat"
date: 2026-03-01
description: "An LLM-as-judge eval tested whether my agent system Prophet's full heartbeat phases improve agent output quality. 47 A/B pairs, three scoring dimensions, deterministic randomization. Result: 46.8% helped, 40.4% hurt, 12.8% neutral — statistically indistinguishable from a coin flip. All four full-only phases scored inconclusive. The seven full phases are removed. The five MVP phases remain."
---

**TL;DR** — An LLM-as-judge eval tested whether my agent system Prophet's full heartbeat phases — log review, evaluation, interest model, longitudinal analysis — improve agent output quality. 47 A/B pairs across a simulated business lifecycle. Result: 46.8% helped, 40.4% hurt, 12.8% neutral. A coin flip. All four phases scored inconclusive. The seven full-only phases are removed. The five MVP phases (memory maintenance, reports, dispatch, dead man's switch, notifications) remain.

---

## The question

My agent system Prophet's heartbeat had two modes. An MVP mode ran five phases every thirty minutes: memory maintenance, report generation, task dispatch, a dead man's switch ping, and notifications. A full mode added seven more: health checks, log review, evaluation, interest model extraction, longitudinal analysis, external intelligence, and deficiency detection.

The full phases were [validated](/posts/heartbeat-validation) to produce their intended outputs in isolation. An [ablation](/posts/heartbeat-ablation) measured each phase's contribution via artifacts. But neither experiment answered the question that matters: does injecting full heartbeat context into an agent's reasoning improve the quality of its output?

## The eval design

InspectBlock is a simulated business lifecycle — a solo founder building an inspection management SaaS. 47 milestones span seven phases: understand, decide, build, validate, launch, operate, improve. Each milestone has a trigger ("a customer requests offline access"), a task ("describe what to do"), and evaluation criteria ("addresses sync conflicts, mentions queue strategy").

For each milestone, two `claude -p` calls (Claude with personal context) produce an A/B pair:

- **Heartbeat arm**: receives full crib context (memory storage) — memory entries, corrections, notes, interests, everything a full heartbeat run would have generated and stored.
- **Control arm**: receives filtered context — only the milestone spec and business identity, no heartbeat-derived content.

An LLM judge then scores each pair on three dimensions — correctness, consistency, alignment — using a structured prompt. The judge sees "Response A" and "Response B" without knowing which arm produced which. A deterministic seed per milestone controls presentation order, preventing position bias from systematically favoring one side.

47 milestones. 94 generation calls. 47 judge calls. Three scores per judgment.

## The results

Overall impact:

| Outcome | Count | Percentage |
|---------|-------|------------|
| Helped  | 22 | 46.8% |
| Hurt    | 19 | 40.4% |
| Neutral | 6 | 12.8% |

By lifecycle phase:

| Phase | Helped | Hurt | Neutral | Total |
|-------|--------|------|---------|-------|
| understand | 3 | 2 | 0 | 5 |
| decide | 2 | 1 | 1 | 4 |
| build | 7 | 6 | 0 | 13 |
| validate | 3 | 1 | 1 | 5 |
| launch | 1 | 2 | 2 | 5 |
| operate | 5 | 2 | 1 | 8 |
| improve | 1 | 5 | 1 | 7 |

Heartbeat phase attribution — how much each full phase contributed across all milestones that reference it:

| Heartbeat Phase | Score | Max | Ratio | Milestones | Verdict |
|-----------------|-------|-----|-------|------------|---------|
| interest_model | 4 | 60 | 0.067 | 20 | inconclusive |
| evaluation | -2 | 120 | -0.017 | 40 | inconclusive |
| longitudinal | -1 | 42 | -0.024 | 14 | inconclusive |
| log_review | -4 | 72 | -0.056 | 24 | inconclusive |

Per-dimension breakdown:

| Dimension | Wins | Losses | Ties |
|-----------|------|--------|------|
| correctness | 15 | 15 | 17 |
| consistency | 11 | 14 | 22 |
| alignment | 18 | 19 | 10 |

Correctness: a dead heat. Consistency: slightly worse with heartbeat context. Alignment: slightly worse. No dimension shows a clear benefit.

## What the data says

The full heartbeat phases are not earning their complexity. Four phases, each designed to enrich the agent's context, and none produces a measurable improvement in output quality.

Two lifecycle phases stand out. "Operate" leans positive — 5 helped vs 2 hurt. Tasks like handling a support request or triaging a bug might benefit from the historical context that heartbeat phases accumulate. But the hook path (context injection) already handles memory retrieval for operational tasks — crib injects relevant entries on every prompt, without needing a heartbeat to have pre-processed them.

"Improve" leans negative — 1 helped vs 5 hurt. Tasks like analyzing feature usage or responding to a competitor are forward-looking. Heartbeat context is backward-looking — error trends, log summaries, longitudinal patterns. Injecting backward-looking context into forward-looking reasoning appears to dilute focus rather than sharpen it.

The interest model has the highest positive ratio (0.067), but at 20 milestones that is 4 net score points out of 60 possible. One judge call going the other way would halve it. The signal is not distinguishable from noise at this sample size.

## The decision

Remove the seven full-only phases from the heartbeat:

1. ~~Health checks~~ — database integrity verification
2. ~~Log review~~ — spill error pattern detection (error logging module)
3. ~~Evaluation~~ — cross-referencing log errors against memory claims
4. ~~Interest model~~ — topic extraction via `claude -p`
5. ~~Longitudinal analysis~~ — weekly error and usage trends
6. ~~External intelligence~~ — daily peep scan
7. ~~Deficiency detection~~ — three-tier pattern detection via diagnose

Keep the five MVP phases:

1. **Memory maintenance** — correction linking, decay
2. **Report generation** — bounded status reports
3. **Task dispatch** — next task via book (task repository)
4. **Dead man's switch** — ping on completion
5. **Notification** — placeholder for future channels

The ablation runner (`bin/ablate-heartbeat`) goes too. With only five load-bearing phases, single-skip ablation is not useful — every phase does something observable and necessary.

The standalone tools still exist independently. `peep` scans external sources on its own schedule. `bin/diagnose` runs as a standalone command. `crib maintain` handles memory housekeeping. The heartbeat no longer orchestrates them, but they are not deleted.

## What remains

The core loop is untouched:

- **Hook path**: policy enforcement, context injection, memory retrieval — fires on every tool call and every prompt.
- **Trick** (background process): memory extraction on context compaction.
- **Crib**: memory storage with three retrieval channels (triples, full-text, vector).
- **MVP heartbeat**: decay, reports, dispatch, dead man's switch, notifications.

The full heartbeat was an attempt to make the system smarter by running analytical phases on a schedule. The eval says that attempt did not work — at least not in a way that survives controlled measurement. The system's actual intelligence lives in the hook path (real-time policy and memory) and in trick (background extraction). The scheduled analytical layer was complexity without demonstrated value.

## Limits

**LLM-as-judge position bias.** The eval randomizes presentation order with a deterministic seed per milestone. This prevents systematic bias but does not eliminate per-judgment noise. A judge that slightly favors "Response A" regardless of content would not be caught by this design — only by running each pair twice with swapped positions, which doubles the cost.

**47 pairs may be too small for per-phase attribution.** The overall helped/hurt split (22/19) has a sample large enough to see that the effect is near zero. But the per-phase attribution table divides those 47 pairs across four phases, with individual phases touching as few as 14 milestones. At that granularity, a single noisy judgment swings the ratio by 0.07. Per-phase conclusions require a larger corpus.

**Pair-by-pair eval cannot measure cumulative effects.** Each milestone is scored independently. A heartbeat that builds useful context over weeks — where milestone 30 benefits from context accumulated during milestones 1 through 29 — would not show up in this design. The eval measures local improvement, not trajectory improvement.

**The phases might matter in ways this eval cannot detect.** The eval measures output quality on a simulated business task. The full phases might improve system health monitoring, reduce silent failures, or catch contradictions that manifest only over months. An eval that measures "does the agent write a better response?" cannot detect "does the system degrade more slowly?"

These are real limits. The decision to remove the phases is based on the evidence available, not on certainty that the phases are worthless. If a future eval with a larger corpus, cumulative scoring, or production telemetry shows a signal, the phases can be restored from version history.