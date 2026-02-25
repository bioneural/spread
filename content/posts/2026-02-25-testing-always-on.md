---
title: "Testing always-on"
date: 2026-02-25
description: "How to evaluate a feature whose job is to always be present: a seven-category taxonomy of test fixtures, discriminator tests that prove the feature works independently of semantic similarity, and three bugs identified by five independent reviewers — including test fixtures that passed for the wrong reason."
---

**TL;DR** — An always-on feature — one that should produce output regardless of input — inverts the normal testing problem. Instead of "does the right thing appear when the right query arrives?" the question becomes "does the right thing appear when an unrelated query arrives, and does the wrong thing stay absent?" A seven-category taxonomy of test fixtures, discriminator tests, negative assertions, and a correction-chain bug that caused three tests to pass for the wrong reason.

---

## The problem

My memory system gained a new feature: [dispositional injection](/posts/dispositional-memory). Active preferences — stated values, trade-off patterns, judgment signals — always surface in retrieval output, regardless of query topic. A preference about commit hygiene appears when the query asks about nginx configuration. A preference about error handling appears when the query asks about color palettes.

The feature works correctly when it always fires. It fails when it does not fire, or when it fires and also surfaces content that should not appear. Testing this requires fixtures that prove presence and absence simultaneously.

Standard retrieval fixtures test topic matching: set up entries about databases, query about databases, verify a database entry appears. The expected baseline is silence — no matching entries, no output. The feature under test is recall precision.

Always-on fixtures must test something different. The feature under test is unconditional activation. The expected behavior: these preferences appear regardless of what the query asks about. The baseline is not silence — it is presence.

## The taxonomy

Seven categories, three fixtures each, twenty-one total.

**A. Semantic match.** A preference found by keyword or vector overlap with the query. A preference about SQLite surfaces when the query asks about databases. These tests establish that preferences participate in normal retrieval and that the preference type itself works. Expected to pass without dispositional injection.

**B. No-keyword conceptual.** A preference found by vector inference only — no shared keywords between preference and query, but a conceptual bridge exists. A preference about "always write tests before implementation" surfacing when the query says "I have a new feature to build." The embedding model must infer the relationship. Expected to pass partially at baseline.

**C. Pure dispositional.** A preference with zero relation to the query — no keywords, no semantic bridge, no topical connection. "Never auto-commit without user approval" surfacing when the query asks "what color palette should the dashboard use?" These tests cannot pass without dispositional injection. They are the existence proof.

**D. Negatives.** No preferences exist in the database. The system should return nothing, and specifically should not hallucinate a preference section. These verify that the injection mechanism produces no output when there is nothing to inject.

**E. Correction chains.** A preference that has been corrected — "prefer tabs" superseded by "switched to 2-space indentation." The corrected version should appear; the original should not. These test the interaction between the supersession mechanism and dispositional injection.

**F. Multiple preferences.** Five or more active preferences exist. The injection limit is five. These test that selection among many preferences works correctly and that the most recently created preferences take priority.

**G. Discriminators.** The hardest category. These fixtures include both a preference and an unrelated non-preference entry (a note, a decision, an error). The test asserts that the preference appears **and** the unrelated entry does not. This is the only category that uses negative assertions. Without it, a system that returns everything would pass all other categories.

## The discriminator insight

Categories A through F test presence. Category G tests discrimination. The difference matters.

A system with a bug that returns all stored entries would pass categories A, B, C, E, and F — because the preference would appear in the output alongside everything else. Category D would catch it only if no preferences exist. Only Category G, which asserts both that a preference appears and that an unrelated entry does not, catches an all-return bug.

This is a general principle for testing always-on features: presence tests are necessary but insufficient. Without absence tests, an evaluation cannot distinguish "the feature works" from "the feature returns everything."

The evaluation harness did not originally support negative assertions. Adding a `not_contains` field to the fixture schema and extending the assertion logic was a three-line change:

```ruby
excluded = tc.dig('expected', 'not_contains') || []
has_none = excluded.none? { |term| output.include?(term) }
trial_results << (has_all && has_none)
```

The insight was more expensive than the implementation.

## The correction chain bug

Three fixtures in Category E tested whether a corrected preference supersedes the original. They all passed. They were all testing the wrong thing.

The memory system's supersession mechanism works as follows: a `correction` entry is linked to the entry it corrects via a `superseded_by` column. Superseded entries are excluded from retrieval queries (`WHERE superseded_by IS NULL`). The linking happens in a maintenance subcommand — `maintain` — which uses vector search to find the original entry closest to the correction and sets the pointer.

The evaluation harness called `write` and `retrieve`. It never called `maintain`. Without that step, both the original preference and its correction coexisted with `superseded_by IS NULL`. The correction chain was never linked.

Why did the tests pass? Because the correction text — "Switched from tabs to 2-space indentation" — was found by full-text search (FTS) and vector search when the query mentioned indentation. The test checked `contains: ["2-space"]` and found it. The original preference ("prefer tabs") also appeared in the output, but no assertion checked for its absence.

Two independent failures conspired to produce a false pass:

1. The maintenance step was never called, so supersession did not occur.
2. The assertion checked for presence only, so the unsuperseded original was invisible to the test.

Five independent reviewers, examining the implementation before the evaluation ran, all identified this bug. The fix: call `maintain` between writes and retrieve when a fixture contains correction entries.

```ruby
has_corrections = (tc['setup'] || []).any? { |e| e['type'] == 'correction' }
if has_corrections
  Open3.capture2e(env, 'ruby', CRIB_BIN, 'maintain')
end
```

The harness now detects whether any setup entry has `type: correction` and, if so, runs the maintenance subcommand before querying.

## What to steal

Three patterns transfer to any evaluation of always-on features.

**Discriminator fixtures.** Include entries that should not appear alongside entries that should. Assert both presence and absence. A test suite that only checks for presence cannot distinguish correct behavior from over-retrieval.

**Hidden dependency audit.** For each fixture, enumerate every system component that must execute between setup and assertion. If a component is missing, the test may pass for the wrong reason. The correction chain bug existed because the test assumed two steps (write, retrieve) when three were required (write, maintain, retrieve).

**Ablation control.** Run the evaluation with the feature disabled. Any test that passes in both the enabled and disabled runs is not testing the feature — it is testing something else. For the preference injection feature, `CRIB_PREF_LIMIT=0` provides a clean ablation for free.

## Results

F1 score (harmonic mean of precision and recall) = 0.971. Twenty of twenty-one cases passed, all with 3/3 trial unanimity. The one failure (discriminator G3) is a reranker discrimination limit documented in the [companion post](/posts/dispositional-memory). All three review-panel bugs were fixed before the evaluation ran.

## Limits

**Twenty-one fixtures is a small sample.** Three cases per category provides existence proofs, not statistical power. A single flaky trial could flip a category. The [majority voting mechanism](/posts/observable-by-default) — three trials per case, pass if majority pass — mitigates non-determinism but does not compensate for small N.

**The negative assertions are string-matching.** The `not_contains` check searches for literal substrings in the output. A paraphrase of the excluded content — "Postgres" instead of "PostgreSQL" — would evade the check. Semantic absence testing would require a classifier, which would add a model dependency to the evaluation itself.

**The ablation was not run.** The evaluation confirmed F1 score = 0.971 with injection enabled. The companion run with injection disabled — which would confirm that categories C and G fail without it — was identified as necessary but not executed. The architecture supports it. The data does not exist yet.