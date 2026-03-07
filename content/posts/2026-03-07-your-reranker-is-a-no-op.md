---
title: "Your reranker is a no-op"
date: 2026-03-07
description: "A cross-encoder reranker that appeared to work for three weeks was silently broken. The gemma3:1b model answered no to every relevance query with 99.9999 percent confidence, including a document containing the exact query term. The system ran on fallback code the entire time. Switching the reranker and extraction model to the gemma3:4b model fixed both retrieval scoring and preference classification. The deeper lesson: a system that degrades gracefully can degrade so gracefully that you never notice the core component is dead."
---

**TL;DR** — The [cross-encoder reranker](/posts/cross-encoder-reranking) that I evaluated three weeks ago was broken in production the entire time. gemma3:1b answered "no" to every relevance query — including "bananaphone" vs. "bananaphone" — with 99.9999% confidence. Every rerank score was 0.000. The system ran on a rescue clause that returned all candidates unfiltered. Switching both the reranker and the extraction model from gemma3:1b to gemma3:4b fixed retrieval scoring (1.0 relevant, 0.0 irrelevant) and memory classification (4/4 eval scenarios correct). A system designed to degrade gracefully can degrade so gracefully that the failure becomes invisible.

---

## What happened

I went looking for a signal-to-noise problem. For the query "Why did we choose Ruby?", crib (my memory store) returned 17 entries (3,137 bytes) when the useful answer was 3 entries (~200 bytes). Two causes were obvious:

1. The background extractor ([trick](https://github.com/bioneural/trick)) was classifying debugging observations as preferences. "Avoid using relative paths to CRIB_DB" is not a durable behavioral directive. It is something that happened once during debugging.

2. [Dispositional injection](/posts/dispositional-memory) — the mechanism that surfaces preferences on every retrieval — was bypassing the reranker entirely. Line 788 said "always surface active preferences regardless of query." Preferences skipped relevance scoring.

The fixes were straightforward: tighten the extraction prompt, run preferences through the same reranker as regular entries, delete 17 garbage preferences from the database. I wrote the code, ran the smoke tests, and the tests passed. Then I tried to raise the rerank threshold from 0.0 to 0.5.

The FTS (Full-Text Search) round-trip test — the most basic retrieval test in the suite — failed. Writing "bananaphone" and retrieving "bananaphone" returned nothing.

## The reranker was dead

I checked the raw ollama (local inference server) API response for the reranker query "Is this document about bananaphone relevant to a query about bananaphone?"

```
answer: no
  yes        -20.014711
  no         -0.000001
```

gemma3:1b said "no" with a logprob of -0.000001 — meaning P(no) ≈ 1.0 and P(yes) ≈ 0.000000002. The computed rerank score: 0.000. For a document containing the exact query term.

I tested four query-document pairs:

| Query | Document | Score |
|-------|----------|-------|
| bananaphone communication | Chose bananaphone as the primary communication device | 0.000 |
| Why did we choose Ruby? | Chose Ruby for all prophet scripts | 0.000 |
| Why did we choose Ruby? | Always use tabs instead of spaces | 0.000 |
| Why did we choose Ruby? | Simplicity & Minimize Operational Complexity | 0.003 |

Every score was zero or near-zero. The reranker judged every document irrelevant to every query. The function was mathematically incapable of passing a single entry through a threshold of 0.5.

## How it stayed hidden

The system had two layers of defense. Both masked the failure.

**Layer 1: the rescue clause.** The `cross_encoder_rerank` function wraps scoring in a rescue block. If scoring raises an exception, it returns all candidates unfiltered:

```ruby
def cross_encoder_rerank(prompt, entries)
  scored = entries.map { |entry|
    score = rerank_score(prompt, entry['content'])
    entry.merge('rerank_score' => score)
  }
  scored.select { |e| e['rerank_score'] > RERANK_THRESHOLD }
        .sort_by { |e| -e['rerank_score'] }
        .first(RERANK_LIMIT)
rescue => e
  entries.first(RERANK_LIMIT)
end
```

When ollama was unavailable — during CI, during cold starts, during the smoke tests that ran without a local model — `rerank_score` raised `Errno::ECONNREFUSED`. The rescue caught it, returned all entries, and the tests passed. The reranker was never tested.

**Layer 2: the threshold.** The default `RERANK_THRESHOLD` was 0.0. In Ruby, `0.0 > 0.0` is false, so entries scoring exactly 0.0 were filtered. But when ollama was available and returning real scores, `rerank_score` caught `Errno::ECONNREFUSED` internally and returned 0.0 — never raising to the batch-level rescue. The threshold then filtered everything out. But the tests that exercised retrieval used `CRIB_CHANNEL=fts`, which also triggered the reranker. When ollama was down, the rescue returned results. When ollama was up, the reranker scored everything at 0.0 and filtered everything. Whether retrieval worked depended on whether ollama was running — a race condition in test infrastructure.

The test passed. The feature was broken.

## The extraction model was broken too

The same gemma3:1b model powered memory extraction in trick. I had tightened the preference prompt to require "a direct quote or close paraphrase of user words." I ran a synthetic eval: four transcripts, three trials each.

| Scenario | Should produce preference? | gemma3:1b result |
|----------|--------------------------|------------------|
| Debugging fix | No | 3/3 produced a preference |
| Error resolution | No | 1/3 (pass) |
| Implementation choice | No | 1/3 (pass) |
| Explicit user preference | Yes | 2/3 (pass) |

The debugging scenario failed every trial. The user said "That fixed it, thanks" after resolving a path issue. The model extracted "User prefers absolute paths for file paths." The prompt said "NOT debugging fixes." The model ignored the constraint and inferred a preference from behavior.

A 1B model cannot reliably distinguish "user adopted a fix" from "user stated a standing rule." The nuance exceeds the model's capacity.

## gemma3:4b

Both models were available on the same machine. I tested gemma3:4b as a reranker:

| Query | Document | 1b score | 4b score |
|-------|----------|----------|----------|
| bananaphone communication | Chose bananaphone as the primary communication device | 0.000 | 1.000 |
| Why did we choose Ruby? | Chose Ruby for all prophet scripts | 0.000 | 1.000 |
| Why did we choose Ruby? | Always use tabs instead of spaces | 0.000 | 0.000 |
| Why did we choose Ruby? | Simplicity & Minimize Operational Complexity | 0.003 | 0.000 |

Perfect binary separation. gemma3:4b says "yes" with ~100% confidence for relevant documents and "no" with ~100% confidence for irrelevant ones. The threshold of 0.5 becomes a natural decision boundary — it works exactly as intended.

The extraction eval on gemma3:4b:

| Scenario | Should produce preference? | 4b result |
|----------|--------------------------|-----------|
| Debugging fix | No | 0/3 (pass) |
| Error resolution | No | 0/3 (pass) |
| Implementation choice | No | 0/3 (pass) |
| Explicit user preference | Yes | 3/3 (pass) |

4/4 scenarios correct. Zero false-positive preferences across all negative scenarios. The explicit preference was classified correctly in every trial. The output quality improved dramatically — clean JSON, proper rationale in decisions, exact user quotes for preferences.

## What changed

The [original cross-encoder post](/posts/cross-encoder-reranking) showed gemma3:1b producing well-calibrated scores: 0.992 for an exact match, 0.610 for an indirect match, 0.000 for irrelevant documents. Those results were real at the time of the experiment. Between then and now, something changed — most likely a model update via `ollama pull`. The model weights shipped under the same name are not the same weights I evaluated. There is no version pinning in ollama's default model references; `gemma3:1b` resolves to whatever Google last published.

The system had no monitoring that would catch this. Smoke tests exercised retrieval, but the reranker was a passthrough — it either raised (rescue caught it, tests passed) or scored everything at zero (threshold of 0.0 was too permissive to catch it). A regression in the upstream model silently disabled a core component.

## The fixes

Eight changes across two repositories:

**crib** (memory storage and retrieval):
- Switch `RERANK_MODEL` from gemma3:1b to gemma3:4b
- Raise `RERANK_THRESHOLD` from 0.0 to 0.5
- Re-raise `Errno::ECONNREFUSED` in `rerank_score` so the batch-level rescue fires (preserving fail-open when ollama is down)
- Run preferences through `cross_encoder_rerank` instead of injecting unconditionally
- Add a smoke test that writes a preference and verifies FTS channel isolation excludes it
- Fix a stale doctor probe checking for `<memory context_time=` instead of `<memory retrieved=`

**trick** (background memory extraction):
- Switch `TRICK_MODEL` from gemma3:1b to gemma3:4b
- Tighten the preference type definition to require explicit user language
- Replace `trim_to_budget` (which dropped oldest turns) with `summarize_to_budget` (which LLM-summarizes the conversation to preserve all content)

**Database cleanup:** deleted 17 of 18 junk preference entries. One genuine user-stated directive survived: "Simplicity & Minimize Operational Complexity."

## Limits

**No version pinning.** The root cause — an upstream model changing behavior under a stable name — is unresolved. gemma3:4b will eventually update too. Ollama supports digest-pinned references (`gemma3:4b@sha256:...`), but I am not using them. The next silent regression is a matter of time.

**Binary scoring.** gemma3:4b produces 1.0 or 0.0 with no middle ground. The [original experiment](/posts/cross-encoder-reranking) showed gemma3:1b producing 0.610 for an indirect match — a useful intermediate signal. gemma3:4b loses that nuance. A document that is partially relevant scores the same as a completely irrelevant one. Whether this matters depends on the corpus; for a small personal memory store, binary discrimination may be sufficient.

**Four-scenario eval.** The extraction eval tests four synthetic transcripts, three trials each. A production evaluation would need dozens of real transcripts spanning the failure modes that actually occur during development sessions. The eval confirms the direction; it does not prove coverage.

**Latency.** gemma3:4b is slower than gemma3:1b per inference call. Reranking 20 candidates takes longer. I have not measured the difference. For a push-based system where retrieval happens before the agent begins reasoning, the added latency is less critical than for an interactive search — but it is not free.

## The lesson

A rescue clause is not a test. A fallback that fires silently is indistinguishable from a feature that works. The reranker had a rescue clause, a permissive threshold, and a test suite that exercised the rescue path instead of the scoring path. Every test passed. The feature was dead.

The [dispositional memory post](/posts/dispositional-memory) noted: "A 1-billion parameter reranker limits discrimination. The one test failure traces to gemma3:1b assigning nonzero relevance to entries that a larger model would likely exclude." That was an understatement. The reranker was not assigning nonzero relevance to irrelevant entries. It was assigning zero relevance to everything — relevant and irrelevant alike. The system appeared to work because the fallback code did the right thing often enough that no one noticed the primary path was broken.

Graceful degradation is a design goal. Invisible degradation is a design failure. The difference is monitoring.