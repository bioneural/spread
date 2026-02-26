---
title: "Dispositional ablation"
date: 2026-02-26
description: "A dispositional injection feature (always-on preference surfacing) passed 20 of 21 evaluation fixtures — but passing does not prove necessity. An ablation run with the feature disabled dropped F1 (precision: fraction of returned results that were correct; recall: fraction of available results returned) from 0.971 to 0.714. Seven cases broke. Precision stayed at 1.0. The system never hallucinates preferences — it only misses them."
---

**TL;DR** — [Dispositional injection](/posts/dispositional-memory) passed an evaluation with F1 = 0.971 (combining precision and recall). But a feature that passes when enabled might also pass when disabled — which would mean the evaluation is testing the wrong thing. An ablation run with `CRIB_PREF_LIMIT=0` (injection disabled) dropped F1 from 0.971 to 0.714. Seven cases broke across three categories. Six held steady. Precision (the fraction of returned results that were correct) remained 1.0 in both runs. The feature is necessary, and the evaluation is testing the right thing.

---

## The gap

The [testing always-on post](/posts/testing-always-on) described a seven-category evaluation taxonomy for dispositional injection — a feature that always surfaces active preferences regardless of query topic. Twenty-one fixtures. Three trials per case. Majority voting. F1 = 0.971.

That evaluation confirmed the feature works. It did not confirm the feature is necessary.

A test that passes with a feature enabled and also passes with it disabled is not testing the feature. It is testing something else — vector similarity, keyword overlap, or the test infrastructure itself. The [testing always-on post](/posts/testing-always-on) identified this risk explicitly: "Run the evaluation with the feature disabled. Any test that passes in both the enabled and disabled runs is not testing the feature." The architecture supports the ablation — `CRIB_PREF_LIMIT=0` disables injection entirely — but the data did not exist.

Now it does.

## The method

Two runs of the same 21-fixture evaluation suite (`retrieval-intent.yml`), three trials per case, majority voting:

1. **Baseline.** Default configuration. Dispositional injection enabled (limit = 5 preferences).
2. **Ablation.** `CRIB_PREF_LIMIT=0`. Injection disabled. All other retrieval channels remain active.

The ablation isolates one variable: the SQL query that unconditionally surfaces preferences. Everything else — vector embedding, result reranking, preference correction chains, and negative filtering — operates identically.

All other retrieval channels (full-text search, vector similarity, entity-graph lookup (knowledge graph retrieval), [cross-encoder reranking](/posts/cross-encoder-reranking)) remain active.

## Results

### Aggregate

| Run | P | R | F1 | Passed | Failed |
|-----|---|---|----|--------|--------|
| Baseline | 1.000 | 0.944 | **0.971** | 20/21 | 1 |
| Ablation | 1.000 | 0.556 | **0.714** | 13/21 | 8 |
| Delta | 0.000 | −0.388 | **−0.257** | −7 | +7 |

Precision stayed at 1.0. The system never hallucinated a preference in either run — every failure was a recall miss (a preference that should have appeared but did not).

### Per-category breakdown

| Category | Cases | Baseline | Ablation | Delta |
|----------|-------|----------|----------|-------|
| A. Semantic match | 3 | 3/3 | 3/3 | 0 |
| B. Conceptual bridge | 3 | 3/3 | 3/3 | 0 |
| C. Pure dispositional | 3 | 3/3 | **0/3** | −3 |
| D. Negatives | 3 | 3/3 | 3/3 | 0 |
| E. Correction chains | 3 | 3/3 | 3/3 | 0 |
| F. Multiple preferences | 3 | 3/3 | **0/3** | −3 |
| G. Discriminators | 3 | 2/3 | **1/3** | −1 |

Three categories broke completely. One degraded. Three were unaffected.

### Per-case detail for affected categories

**Category C — Pure dispositional** (preference has zero topical relation to query):

| Case | Baseline | Ablation | Trial detail |
|------|----------|----------|-------------|
| C1: surfaces on unrelated query | PASS (3/3) | FAIL | 1/3 |
| C2: surfaces on infrastructure query | PASS (3/3) | FAIL | 0/3 |
| C3: surfaces on documentation query | PASS (3/3) | FAIL | 0/3 |

C1 passed one trial — likely an incidental vector similarity match. C2 and C3 failed unanimously.

**Category F — Multiple preferences** (five or more active preferences):

| Case | Baseline | Ablation | Trial detail |
|------|----------|----------|-------------|
| F1: all preferences surface | PASS (3/3) | FAIL | 0/3 |
| F2: ranked by recency | PASS (3/3) | FAIL | 0/3 |
| F3: five within limit all appear | PASS (3/3) | FAIL | 0/3 |

Without injection, vector search returns at most one or two preferences — the ones closest to the query embedding. The rest are invisible.

**Category G — Discriminators** (preference must appear, unrelated entry must not):

| Case | Baseline | Ablation | Trial detail |
|------|----------|----------|-------------|
| G1: preference appears, note excluded | PASS (3/3) | FAIL | 0/3 |
| G2: injection vs pure vector, zero overlap | PASS (3/3) | PASS | 3/3 |
| G3: preference present, unrelated excluded | FAIL (0/3) | FAIL | 0/3 |

G2 passed in both runs — a case where vector similarity happened to surface the preference even without injection. G3 failed in both — a pre-existing reranker discrimination limit documented in the [dispositional memory post](/posts/dispositional-memory).

## Interpretation

The ablation answers three questions.

**Is the feature necessary?** Yes. Seven cases that passed with injection enabled failed with it disabled. The evaluation is not measuring vector similarity dressed up as injection testing. It is measuring injection.

**Which categories depend on injection?** C (pure dispositional) and F (multiple preferences) depend entirely. Without injection, no case in either category passes. G (discriminators) depends partially — one case requires injection, one does not, one is a pre-existing failure. Categories A, B, D, and E are independent of injection, which is correct: semantic match and conceptual bridge cases should pass via vector similarity alone, negatives have nothing to inject, and correction chains work through the supersession mechanism.

**Does disabling injection cause false positives?** No. Precision stayed at 1.0 in both runs. The system's failure mode is silence, not hallucination. When injection is off and a preference cannot be found by vector similarity, the preference simply does not appear. The system does not invent preferences to fill the gap.

## Limits

**One model, one corpus.** Both runs used gemma3:1b for reranking and nomic-embed-text for embeddings. A different model might change which categories survive ablation — a stronger embedding model could make some Category C cases pass via vector similarity alone. Cross-model validation would strengthen the finding.

**Twenty-one cases is small.** Three cases per category provides existence proofs. A single flaky trial could flip a category result. The finding that entire categories break (0/3 across all cases) is more robust than a finding that one case breaks, but statistical power is limited.

**G3 remains undiagnosed.** Case G3 ("preference present, unrelated entries excluded") fails 0/3 in both baseline and ablation. This is a pre-existing reranker discrimination limit — [gemma3:1b](/posts/cross-encoder-reranking) assigns nonzero relevance to entries that a larger model would likely exclude — but the specific failure mechanism in this fixture has not been investigated.

**The ablation is binary.** `CRIB_PREF_LIMIT=0` disables injection entirely. A more informative ablation would vary the limit — 1, 2, 3, 5 — to measure how Category F (multiple preferences) degrades as the limit drops. The current experiment shows only the extreme: all or nothing.